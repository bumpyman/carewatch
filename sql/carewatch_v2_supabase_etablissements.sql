-- =============================================================================
-- CareWatch · Établissements : tableau de bord, droit de réponse, compléments
-- - comptes « établissement » (même circuit d'accès que la modération, droits limités
--   aux indicateurs de leur établissement, sans texte libre) ;
-- - droit de réponse sur chaque témoignage vérifié, visible par la personne et en fiche publique ;
-- - compléments d'un témoignage par son auteur·e : renoncement aux soins, confiance,
--   vérification d'une adresse professionnelle (jeton signé par api/notifier.php) ;
-- - baromètre : renoncement et confiance enregistrés ;
-- - statistiques publiques : réponses dans les 14 jours.
-- À coller dans SQL Editor puis Run. Ré-exécutable sans risque.
-- Prérequis : patch_complet, moderation, moderation_2, referentiels_schema, acces_2, barometre.
-- =============================================================================

-- 1. Colonnes ----------------------------------------------------------------
alter table public.recits
  add column if not exists renoncement      text,          -- oui | non | ne_sait_pas
  add column if not exists confiance        integer,       -- 1 à 5
  add column if not exists verification_pro text,          -- email_institutionnel:domaine | email_professionnel:domaine
  add column if not exists verifie_le       timestamptz;   -- passage en verifie / publie

create or replace function public.cw_recit_verifie_le()
returns trigger language plpgsql as $$
begin
  if new.statut in ('verifie', 'publie') and (old.statut is distinct from new.statut) and new.verifie_le is null then
    new.verifie_le := now();
  end if;
  return new;
end $$;
drop trigger if exists trg_recit_verifie_le on public.recits;
create trigger trg_recit_verifie_le before update on public.recits for each row execute function public.cw_recit_verifie_le();
update public.recits set verifie_le = coalesce(modere_le, modifie_le, cree_le) where statut in ('verifie', 'publie') and verifie_le is null;

alter table public.moderateurs           add column if not exists etablissement_id text;
alter table public.moderateurs_autorises add column if not exists etablissement_id text;

create table if not exists public.reponses_etablissement (
  numero           text primary key,
  etablissement_id text not null,
  texte            text not null,
  user_id          uuid,
  cree_le          timestamptz not null default now(),
  modifie_le       timestamptz not null default now()
);
alter table public.reponses_etablissement enable row level security;
revoke all on public.reponses_etablissement from public, anon, authenticated;

insert into public.cw_config (cle, valeur) values ('secret_verification', encode(extensions.gen_random_bytes(24), 'hex')) on conflict (cle) do nothing;

-- 2. Rôles --------------------------------------------------------------------
-- Les comptes établissement ne sont pas modérateurs : ils ne voient ni la file ni les textes.
create or replace function public.cw_est_moderateur()
returns boolean language sql stable security definer set search_path = public, extensions as $$
  select auth.uid() is not null
     and exists (select 1 from public.moderateurs m where m.user_id = auth.uid() and coalesce(m.role, 'moderateur') <> 'etablissement')
     and coalesce(auth.jwt() ->> 'aal', '') = 'aal2';
$$;
revoke execute on function public.cw_est_moderateur() from public, anon;
grant  execute on function public.cw_est_moderateur() to authenticated;

create or replace function public.cw_etablissement_courant()
returns text language sql stable security definer set search_path = public, extensions as $$
  select m.etablissement_id from public.moderateurs m
  where m.user_id = auth.uid() and m.role = 'etablissement' and m.etablissement_id is not null
    and coalesce(auth.jwt() ->> 'aal', '') = 'aal2';
$$;
revoke execute on function public.cw_etablissement_courant() from public, anon;
grant  execute on function public.cw_etablissement_courant() to authenticated;

-- Profil : reprend l'établissement de l'autorisation
create or replace function public.moderateur_mon_profil()
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  a       public.moderateurs_autorises;
  m       public.moderateurs;
begin
  if auth.uid() is null then return null; end if;
  select * into m from public.moderateurs where user_id = auth.uid();
  if m.user_id is null then
    select * into a from public.moderateurs_autorises where email = v_email;
    if a.email is null then return null; end if;
    insert into public.moderateurs (user_id, nom, role, etablissement_id) values (auth.uid(), a.nom, a.role, a.etablissement_id)
    on conflict (user_id) do nothing;
    delete from public.moderateurs_autorises where email = v_email;
    select * into m from public.moderateurs where user_id = auth.uid();
  end if;
  return jsonb_build_object('nom', m.nom, 'role', m.role, 'mdp_change_le', m.mdp_change_le, 'ajoute_le', m.ajoute_le, 'email', v_email,
    'etablissement_id', m.etablissement_id,
    'etablissement_nom', (select nom_complet from public.etablissements e where e.id = m.etablissement_id));
end $$;
revoke execute on function public.moderateur_mon_profil() from public, anon;
grant  execute on function public.moderateur_mon_profil() to authenticated;

-- Autorisation : rôle « etablissement » avec l'identifiant de l'établissement
drop function if exists public.admin_autoriser_moderateur(text, text, text);
create or replace function public.admin_autoriser_moderateur(p_email text, p_nom text, p_role text default 'moderateur', p_etablissement text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_email text := lower(trim(p_email));
  v_code  text;
  v_uid   uuid;
  v_etab  text := nullif(trim(coalesce(p_etablissement, '')), '');
begin
  if not public.cw_est_admin() then raise exception 'Accès refusé' using errcode = '42501'; end if;
  if v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then raise exception 'Adresse e-mail invalide'; end if;
  if p_role not in ('moderateur', 'admin', 'etablissement') then raise exception 'Rôle inconnu'; end if;
  if p_role = 'etablissement' then
    if v_etab is null or not exists (select 1 from public.etablissements where id = v_etab) then raise exception 'Établissement inconnu'; end if;
  else
    v_etab := null;
  end if;

  select id into v_uid from auth.users where lower(email) = v_email;
  if v_uid is not null then
    insert into public.moderateurs (user_id, nom, role, etablissement_id) values (v_uid, p_nom, p_role, v_etab)
    on conflict (user_id) do update set nom = excluded.nom, role = excluded.role, etablissement_id = excluded.etablissement_id;
    delete from public.moderateurs_autorises where email = v_email;
    return jsonb_build_object('ok', true, 'etat', 'inscrit');
  end if;

  v_code := upper(public.cw_nouveau_code(8));
  insert into public.moderateurs_autorises (email, nom, role, ajoute_par, code_hash, expire_le, etablissement_id)
  values (v_email, p_nom, p_role, auth.uid(), public.cw_hash(v_code), now() + interval '14 days', v_etab)
  on conflict (email) do update set nom = excluded.nom, role = excluded.role, code_hash = excluded.code_hash, expire_le = excluded.expire_le, ajoute_le = now(), etablissement_id = excluded.etablissement_id;
  return jsonb_build_object('ok', true, 'etat', 'en_attente', 'code', v_code, 'expire_le', now() + interval '14 days');
end $$;
revoke execute on function public.admin_autoriser_moderateur(text, text, text, text) from public, anon;
grant  execute on function public.admin_autoriser_moderateur(text, text, text, text) to authenticated;

-- 3. Tableau de bord de l'établissement (agrégats, sans texte libre) -----------
--    Les cellules de moins de 3 témoignages sont masquées.
create or replace function public.etab_tableau_de_bord()
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_etab text := public.cw_etablissement_courant();
begin
  if v_etab is null then raise exception 'Accès réservé aux comptes établissement' using errcode = '42501'; end if;
  return (
    with base as (
      select r.*, rep.texte as reponse, rep.cree_le as reponse_le
      from public.recits r
      left join public.reponses_etablissement rep on rep.numero = r.numero
      where r.etablissement_id = v_etab and r.statut in ('verifie', 'publie')
    ),
    par_service as (
      select coalesce(nullif(service, ''), 'Non précisé') as service, count(*) as n,
             avg(dms_score::numeric / nullif(dms_max, 0)) filter (where type in ('signalement', 'enquete') and dms_max > 0) as ressenti,
             count(*) filter (where type = 'positif') as positifs
      from base group by 1
    ),
    par_motif as (
      select m as motif, count(*) as n
      from base, jsonb_array_elements_text(coalesce(motifs_percus, '[]'::jsonb)) as m
      group by m
    ),
    par_mois as (
      select to_char(cree_le, 'YYYY-MM') as mois, count(*) as n,
             avg(dms_score::numeric / nullif(dms_max, 0)) filter (where type in ('signalement', 'enquete') and dms_max > 0) as ressenti
      from base group by 1
    )
    select jsonb_build_object(
      'etablissement_id', v_etab,
      'etablissement_nom', (select nom_complet from public.etablissements where id = v_etab),
      'calcule_le', now(),
      'total', jsonb_build_object(
        'verifies', (select count(*) from base),
        'signalements', (select count(*) from base where type = 'signalement'),
        'positifs', (select count(*) from base where type = 'positif'),
        'enquetes', (select count(*) from base where type = 'enquete'),
        'ressenti', (select round(avg(dms_score::numeric / nullif(dms_max, 0)), 2) from base where type in ('signalement', 'enquete') and dms_max > 0),
        'renoncement_oui', (select count(*) from base where renoncement = 'oui'),
        'renoncement_repondu', (select count(*) from base where renoncement is not null),
        'confiance', (select round(avg(confiance), 1) from base where confiance is not null),
        'a_repondre', (select count(*) from base where type <> 'enquete' and reponse is null),
        'repondus', (select count(*) from base where reponse is not null),
        'repondus_14j', (select count(*) from base where reponse is not null and reponse_le <= coalesce(verifie_le, cree_le) + interval '14 days'),
        'en_retard', (select count(*) from base where type <> 'enquete' and reponse is null and coalesce(verifie_le, cree_le) < now() - interval '14 days')
      ),
      'par_service', coalesce((select jsonb_agg(jsonb_build_object('service', service, 'n', case when n >= 3 then n end, 'masque', n < 3,
                        'ressenti', case when n >= 3 then round(ressenti, 2) end, 'positifs', case when n >= 3 then positifs end) order by n desc) from par_service), '[]'::jsonb),
      'par_motif', coalesce((select jsonb_agg(jsonb_build_object('motif', motif, 'n', case when n >= 3 then n end, 'masque', n < 3) order by n desc) from par_motif), '[]'::jsonb),
      'par_mois', coalesce((select jsonb_agg(jsonb_build_object('mois', mois, 'n', n, 'ressenti', case when n >= 3 then round(ressenti, 2) end) order by mois) from par_mois), '[]'::jsonb),
      'temoignages', coalesce((select jsonb_agg(jsonb_build_object(
          'numero', numero, 'type', type, 'mois', to_char(cree_le, 'YYYY-MM'), 'verifie_le', verifie_le, 'service', service,
          'type_incident', type_incident, 'motifs', motifs_percus, 'dms_score', dms_score, 'dms_max', dms_max,
          'reponse', reponse, 'reponse_le', reponse_le,
          'echeance', coalesce(verifie_le, cree_le) + interval '14 days'
        ) order by coalesce(verifie_le, cree_le) desc) from base where type <> 'enquete'), '[]'::jsonb)
    )
  );
end $$;
revoke execute on function public.etab_tableau_de_bord() from public, anon;
grant  execute on function public.etab_tableau_de_bord() to authenticated;

-- Droit de réponse : texte court, sans données personnelles, visible par la personne et en fiche publique
create or replace function public.etab_repondre(p_numero text, p_texte text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_etab   text := public.cw_etablissement_courant();
  v_numero text := upper(trim(coalesce(p_numero, '')));
  v_texte  text := trim(coalesce(p_texte, ''));
begin
  if v_etab is null then raise exception 'Accès réservé aux comptes établissement' using errcode = '42501'; end if;
  if length(v_texte) < 20 then raise exception 'Réponse trop courte (20 caractères au moins)'; end if;
  if length(v_texte) > 2000 then raise exception 'Réponse trop longue (2000 caractères au plus)'; end if;
  if not exists (select 1 from public.recits where numero = v_numero and etablissement_id = v_etab and statut in ('verifie', 'publie') and type <> 'enquete') then
    raise exception 'Témoignage introuvable pour cet établissement';
  end if;
  insert into public.reponses_etablissement (numero, etablissement_id, texte, user_id)
  values (v_numero, v_etab, v_texte, auth.uid())
  on conflict (numero) do update set texte = excluded.texte, user_id = excluded.user_id, modifie_le = now();
  insert into public.recits_journal (numero, action) values (v_numero, 'reponse_etablissement');
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function public.etab_repondre(text, text) from public, anon;
grant  execute on function public.etab_repondre(text, text) to authenticated;

-- Pour la modération : la réponse d'un établissement à un témoignage
create or replace function public.admin_reponse_etablissement(p_numero text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  if not public.cw_est_moderateur() then raise exception 'Accès refusé' using errcode = '42501'; end if;
  return (select jsonb_build_object('texte', texte, 'cree_le', cree_le, 'modifie_le', modifie_le) from public.reponses_etablissement where numero = upper(trim(coalesce(p_numero, ''))));
end $$;
revoke execute on function public.admin_reponse_etablissement(text) from public, anon;
grant  execute on function public.admin_reponse_etablissement(text) to authenticated;

-- 4. Lecture par la personne : réponse de l'établissement et compléments -----
create or replace function public.lire_recit(p_numero text, p_code text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_emp text := public.cw_empreinte_client();
  v_id  uuid;
  r     public.recits;
begin
  if v_emp is not null then
    perform public.cw_controler_quota('ip:lire:' || v_emp, 60, interval '1 hour');
  end if;
  v_id := public.cw_verifier(p_numero, p_code);
  if v_id is null then return null; end if;
  select * into r from public.recits where id = v_id;
  return jsonb_build_object(
    'numero', r.numero, 'type', r.type, 'statut', r.statut, 'cree_le', r.cree_le, 'modifie_le', r.modifie_le,
    'role', r.role, 'source_professionnel', r.source_professionnel,
    'canton', r.canton, 'etablissement_nom', r.etablissement_nom, 'service', r.service,
    'date_incident', r.date_incident, 'type_incident', r.type_incident,
    'dms_score', r.dms_score, 'dms_max', r.dms_max,
    'recevoir_resultats', r.recevoir_resultats, 'recontact_echange', r.recontact_echange,
    'recontact_etude', r.recontact_etude, 'publier_fiche', r.publier_fiche,
    'usage_recherche', r.usage_recherche,
    'lecture_texte_complet', r.lecture_texte_complet, 'accepte_recontact_email', r.accepte_recontact_email,
    'renoncement', r.renoncement, 'confiance', r.confiance, 'verification_pro', r.verification_pro, 'verifie_le', r.verifie_le,
    'reponse_etablissement', (select jsonb_build_object('texte', texte, 'cree_le', cree_le) from public.reponses_etablissement where numero = r.numero)
  );
end $$;
grant execute on function public.lire_recit(text, text) to anon, authenticated;

-- Compléments par l'auteur·e (numéro + code) : renoncement, confiance, vérification professionnelle
create or replace function public.recit_completer(p_numero text, p_code text, p jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_id     uuid;
  v_numero text := upper(trim(coalesce(p_numero, '')));
  v_verif  text := nullif(trim(coalesce(p->>'verification_pro', '')), '');
  v_secret text;
begin
  v_id := public.cw_verifier(p_numero, p_code);
  if v_id is null then return jsonb_build_object('ok', false, 'erreur', 'Numéro ou code incorrect'); end if;
  if p ? 'renoncement' then
    if p->>'renoncement' not in ('oui', 'non', 'ne_sait_pas') then raise exception 'Valeur de renoncement inconnue'; end if;
    update public.recits set renoncement = p->>'renoncement' where id = v_id;
  end if;
  if p ? 'confiance' then
    if (p->>'confiance')::int not between 1 and 5 then raise exception 'Confiance entre 1 et 5'; end if;
    update public.recits set confiance = (p->>'confiance')::int where id = v_id;
  end if;
  if v_verif is not null then
    select valeur into v_secret from public.cw_config where cle = 'secret_verification';
    if v_verif !~ '^email_(institutionnel|professionnel):[a-z0-9.-]+$' then raise exception 'Vérification invalide'; end if;
    if encode(extensions.hmac((v_verif || '|' || v_numero)::bytea, v_secret::bytea, 'sha256'), 'hex') <> lower(coalesce(p->>'jeton', '')) then
      raise exception 'Jeton de vérification invalide';
    end if;
    update public.recits set verification_pro = v_verif where id = v_id;
    insert into public.recits_journal (numero, action) values (v_numero, 'verification_pro');
  end if;
  return jsonb_build_object('ok', true);
end $$;
grant execute on function public.recit_completer(text, text, jsonb) to anon, authenticated;

-- Baromètre : renoncement et confiance enregistrés
create or replace function public.soumettre_enquete(p jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_res jsonb;
  v_p   jsonb;
begin
  if p is null or pg_column_size(p) > 20000 then
    raise exception 'Requête trop volumineuse';
  end if;
  if coalesce((p->>'dms_max')::int, 0) < 28 or (p->>'dms_score') is null then
    raise exception 'Les sept questions doivent être renseignées';
  end if;
  v_p := (p - 'description' - 'impact' - 'type')
         || jsonb_build_object('type', 'enquete', 'description', 'Baromètre d’expérience patient : réponse sans récit.',
                               'publier_fiche', false, 'lecture_texte_complet', false, 'accepte_recontact_email', false);
  v_res := public.soumettre_recit(v_p);
  update public.recits
     set statut = 'verifie', modifie_le = now(),
         renoncement = case when p->>'renoncement' in ('oui', 'non', 'ne_sait_pas') then p->>'renoncement' end,
         confiance   = case when (p->>'confiance') ~ '^[1-5]$' then (p->>'confiance')::int end
   where numero = v_res->>'numero' and type = 'enquete';
  return v_res;
end $$;
revoke execute on function public.soumettre_enquete(jsonb) from public;
grant execute on function public.soumettre_enquete(jsonb) to anon, authenticated;

-- 5. Fiches publiques : la réponse de l'établissement accompagne la fiche ---
drop view if exists public.recits_publics;
create view public.recits_publics as
  select r.numero, r.type, to_char(r.cree_le, 'YYYY') as annee, r.tranche_age, r.canton,
         r.etablissement_nom, r.service, r.type_incident, r.categories_positives, r.dms_score, r.dms_max,
         rep.texte as reponse_etablissement, to_char(rep.cree_le, 'YYYY-MM') as reponse_mois
  from public.recits r
  left join public.reponses_etablissement rep on rep.numero = r.numero
  where r.publier_fiche = true and r.statut = 'publie';
grant select on public.recits_publics to anon, authenticated;

-- 6. Statistiques publiques : réponses des établissements dans les 14 jours ---
drop function if exists public.stats_publiques();
create or replace function public.stats_publiques()
returns jsonb language sql stable security definer set search_path = public, extensions as $$
  with base as (
    select r.*, rep.cree_le as reponse_le
    from public.recits r left join public.reponses_etablissement rep on rep.numero = r.numero
    where coalesce(r.statut, 'soumis') not in ('retire', 'rejete')
  ),
  par_canton as (
    select canton, count(*) as n from base where canton is not null group by canton having count(*) >= 5
  ),
  par_etab as (
    select etablissement_id,
           count(*) filter (where type = 'signalement')                                          as signalements,
           count(*) filter (where type = 'positif')                                              as positifs,
           count(*) filter (where type = 'enquete')                                              as enquetes,
           count(*) filter (where statut in ('verifie', 'publie'))                               as verifies,
           count(*) filter (where statut in ('verifie', 'publie') and type = 'positif')          as positifs_verifies,
           count(*) filter (where statut in ('verifie', 'publie') and type <> 'enquete' and coalesce(verifie_le, cree_le) < now() - interval '14 days') as echus,
           count(*) filter (where statut in ('verifie', 'publie') and type <> 'enquete' and reponse_le is not null and reponse_le <= coalesce(verifie_le, cree_le) + interval '14 days') as repondus_14j,
           avg(dms_score::numeric / nullif(dms_max, 0))
             filter (where statut in ('verifie', 'publie') and type in ('signalement', 'enquete') and dms_max > 0) as ressenti
    from base where etablissement_id is not null
    group by etablissement_id
  ),
  evalue as (
    select *,
           case when verifies >= 5 then
             round(70 * (1 - coalesce(ressenti, 0)) + 30 * (positifs_verifies::numeric / verifies))
           end as indice
    from par_etab
  )
  select jsonb_build_object(
    'methode', 'indice = 70 × (1 − ressenti moyen) + 30 × part des retours positifs, sur témoignages vérifiés (signalements, baromètre, retours positifs), dès 5 témoignages vérifiés',
    'par_etablissement', coalesce((select jsonb_object_agg(etablissement_id, jsonb_build_object(
        'signalements', signalements, 'positifs', positifs, 'enquetes', enquetes, 'verifies', verifies,
        'ressenti', case when verifies >= 5 then round(coalesce(ressenti, 0), 2) end,
        'indice', indice,
        'niveau', case when indice is null then null
                       when indice >= 75 then 'outstanding'
                       when indice >= 50 then 'good'
                       when indice >= 25 then 'requires_improvement'
                       else 'inadequate' end,
        'echus', echus, 'repondus_14j', repondus_14j
      )) from evalue), '{}'::jsonb),
    'recus',          (select count(*) from base),
    'verifies',       (select count(*) from base where statut in ('verifie', 'publie')),
    'signalements',   (select count(*) from base where type = 'signalement'),
    'positifs',       (select count(*) from base where type = 'positif'),
    'enquetes',       (select count(*) from base where type = 'enquete'),
    'etablissements', (select count(distinct etablissement_id) from base where etablissement_id is not null),
    'cantons',        (select count(distinct canton) from base where canton is not null),
    'par_canton',     coalesce((select jsonb_object_agg(canton, n) from par_canton), '{}'::jsonb),
    'reponses',       jsonb_build_object('echus', (select coalesce(sum(echus), 0) from par_etab), 'repondus_14j', (select coalesce(sum(repondus_14j), 0) from par_etab)),
    'renoncement',    jsonb_build_object('oui', (select count(*) from base where renoncement = 'oui'), 'repondu', (select count(*) from base where renoncement is not null)),
    'premier_le',     (select to_char(min(cree_le), 'YYYY-MM-DD') from base),
    'calcule_le',     to_char(now(), 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
  );
$$;
grant execute on function public.stats_publiques() to anon, authenticated;

-- 7. Clé de vérification à recopier dans carewatch_smtp.php : 'secret_verification' => '...'
select valeur as secret_verification_a_copier_dans_carewatch_smtp_php from public.cw_config where cle = 'secret_verification';
