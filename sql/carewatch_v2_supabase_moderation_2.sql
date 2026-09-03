-- ============================================================================
-- CareWatch v2.0 : compléments de modération (à exécuter après moderation.sql)
--   1. Statuts normalisés : tout témoignage hors cycle passe « soumis » (à relire)
--   2. Changement de mot de passe obligatoire à la première connexion
--   3. File « à relire » robuste aux statuts inconnus
--   4. Indice d'équité transparent par établissement (dans stats_publiques)
-- Idempotent.
-- ============================================================================

-- 1. Statuts ----------------------------------------------------------------
--    Le schéma d'origine porte une contrainte recits_statut_check avec une liste fermée
--    qui ne connaît pas « soumis » : on la remplace par la liste du cycle actuel.
select 'avant' as etape, statut, count(*) from public.recits group by statut;

alter table public.recits drop constraint if exists recits_statut_check;

update public.recits
   set statut = 'soumis'
 where statut is null or statut not in ('soumis', 'verifie', 'publie', 'rejete', 'retire');

alter table public.recits
  add constraint recits_statut_check check (statut in ('soumis', 'verifie', 'publie', 'rejete', 'retire'));
alter table public.recits alter column statut set default 'soumis';

-- 2. Mot de passe : date du dernier changement par la personne ---------------
alter table public.moderateurs add column if not exists mdp_change_le timestamptz;

create or replace function public.moderateur_mon_profil()
returns jsonb language sql stable security definer set search_path = public, extensions as $$
  select jsonb_build_object('nom', m.nom, 'mdp_change_le', m.mdp_change_le, 'ajoute_le', m.ajoute_le)
  from public.moderateurs m where m.user_id = auth.uid();
$$;
revoke execute on function public.moderateur_mon_profil() from public, anon;
grant  execute on function public.moderateur_mon_profil() to authenticated;

create or replace function public.moderateur_marquer_mdp_change()
returns boolean language plpgsql security definer set search_path = public, extensions as $$
begin
  update public.moderateurs set mdp_change_le = now() where user_id = auth.uid();
  return found;
end $$;
revoke execute on function public.moderateur_marquer_mdp_change() from public, anon;
grant  execute on function public.moderateur_marquer_mdp_change() to authenticated;

-- 3. File de modération : « soumis » = tout ce qui n'est ni vérifié, ni publié, ni rejeté, ni retiré
create or replace function public.admin_lister_recits(p_statut text default null, p_limite integer default 300)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  if not public.cw_est_moderateur() then
    raise exception 'Accès refusé' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'numero', r.numero, 'type', r.type, 'statut', r.statut, 'cree_le', r.cree_le, 'modifie_le', r.modifie_le,
      'canton', r.canton, 'etablissement_nom', r.etablissement_nom, 'service', r.service,
      'type_incident', r.type_incident, 'dms_score', r.dms_score, 'dms_max', r.dms_max,
      'npa_coherent', r.npa_coherent, 'publier_fiche', r.publier_fiche, 'modere_le', r.modere_le
    ) order by r.cree_le desc)
    from (
      select * from public.recits
      where p_statut is null
         or (p_statut = 'soumis' and coalesce(statut, 'soumis') not in ('verifie', 'publie', 'rejete', 'retire'))
         or (p_statut <> 'soumis' and statut = p_statut)
      order by cree_le desc
      limit least(coalesce(p_limite, 300), 1000)
    ) r
  ), '[]'::jsonb);
end $$;

-- 3a. Colonnes facultatives : un retour positif n'a ni service, ni type d'incident, ni questionnaire.
--     « drop not null » est sans effet si la colonne est déjà facultative.
alter table public.recits
  alter column service          drop not null,
  alter column type_incident    drop not null,
  alter column dms              drop not null,
  alter column dms_score        drop not null,
  alter column dms_max          drop not null,
  alter column impact           drop not null,
  alter column motifs_percus    drop not null,
  alter column date_incident    drop not null,
  alter column role             drop not null,
  alter column tranche_age      drop not null,
  alter column canton           drop not null,
  alter column etablissement_id drop not null,
  alter column etablissement_nom drop not null,
  alter column npa_coherent     drop not null;

-- 3a'. Quota par connexion desserré : un hôpital ou un foyer partage souvent une seule adresse.
--      20 envois par heure et par empreinte ; le plafond global (60 par 10 minutes) reste.
create or replace function public.soumettre_recit(p jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_numero text;
  v_code   text;
  v_emp    text;
begin
  if p is null or pg_column_size(p) > 40000 then
    raise exception 'Requête trop volumineuse';
  end if;
  if length(coalesce(p->>'description','')) < 20 then
    raise exception 'Description trop courte';
  end if;
  if length(p->>'description') > 3000 or length(coalesce(p->>'impact','')) > 3000 then
    raise exception 'Description trop longue';
  end if;
  perform public.cw_controler_quota('global:soumettre', 60, interval '10 minutes');
  v_emp := public.cw_empreinte_client();
  if v_emp is not null then
    perform public.cw_controler_quota('ip:soumettre:' || v_emp, 20, interval '1 hour');
  end if;
  v_numero := 'CW-' || to_char(now(), 'YYYY') || '-' || lpad(nextval('recit_numero_seq')::text, 5, '0');
  v_code   := public.cw_nouveau_code(10);
  insert into public.recits (
    numero, code_hash, type,
    role, source_professionnel, tranche_age, canton, etablissement_id, etablissement_nom,
    service, date_incident, type_periode, type_incident, motifs_percus, categories_positives,
    npa_coherent, description, impact, dms, dms_score, dms_max,
    a_cherche_aide, souhaite_en_parler,
    recevoir_resultats, recontact_echange, recontact_etude,
    publier_fiche, usage_recherche, lecture_texte_complet, accepte_recontact_email
  ) values (
    v_numero, public.cw_hash(v_code), coalesce(p->>'type','signalement'),
    p->>'role', p->>'source_professionnel', p->>'tranche_age', p->>'canton',
    p->>'etablissement_id', p->>'etablissement_nom',
    p->>'service', nullif(p->>'date_incident','')::date, p->>'type_periode', p->>'type_incident',
    p->'motifs_percus', p->'categories_positives',
    p->>'npa_coherent', p->>'description', p->>'impact', p->'dms',
    nullif(p->>'dms_score','')::int, nullif(p->>'dms_max','')::int,
    coalesce((p->>'a_cherche_aide')::boolean, false),
    coalesce((p->>'souhaite_en_parler')::boolean, false),
    coalesce((p->>'recevoir_resultats')::boolean, false),
    coalesce((p->>'recontact_echange')::boolean, false),
    coalesce((p->>'recontact_etude')::boolean, false),
    coalesce((p->>'publier_fiche')::boolean, false),
    coalesce((p->>'usage_recherche')::boolean, false),
    coalesce((p->>'lecture_texte_complet')::boolean, false),
    coalesce((p->>'accepte_recontact_email')::boolean, false)
  );
  insert into public.recits_journal (numero, action) values (v_numero, 'soumis');
  return jsonb_build_object('numero', v_numero, 'code', v_code);
end $$;

-- Pour vos tests : remettre les compteurs anti-abus à zéro (sans effet sur les témoignages)
delete from public.cw_quota;

-- 3b. Fiche complète : correction, la table recits_journal n'a pas de colonne cree_le
--     (le journal est renvoyé tel quel, dans l'ordre d'insertion)
create or replace function public.admin_lire_recit(p_numero text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  r public.recits;
begin
  if not public.cw_est_moderateur() then
    raise exception 'Accès refusé' using errcode = '42501';
  end if;
  select * into r from public.recits where numero = upper(trim(p_numero));
  if r.id is null then return null; end if;
  return to_jsonb(r) - 'code_hash' - 'id'
       || jsonb_build_object('journal', coalesce((
            select jsonb_agg(to_jsonb(j) - 'id' order by j.ctid)
            from public.recits_journal j where j.numero = r.numero), '[]'::jsonb));
end $$;

-- 3c. Lecture par la personne : renvoie aussi le rôle, pour ouvrir le bon espace du site
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
    'lecture_texte_complet', r.lecture_texte_complet, 'accepte_recontact_email', r.accepte_recontact_email
  );
end $$;

-- 4. Indice d'équité par établissement ---------------------------------------
--   Méthode publique (voir page Méthodologie du site) :
--     · seuls les témoignages VÉRIFIÉS par la modération comptent ;
--     · rien n'est calculé sous 5 témoignages vérifiés pour un établissement ;
--     · ressenti = moyenne de dms_score / dms_max des signalements vérifiés (0 = jamais, 1 = toujours) ;
--     · part_positifs = retours positifs vérifiés / témoignages vérifiés ;
--     · indice (0-100) = 70 × (1 − ressenti) + 30 × part_positifs ;
--     · niveau : ≥ 75 Exemplaire · 50-74 Satisfaisant · 25-49 À améliorer · < 25 Insuffisant.
drop function if exists public.stats_publiques();
create or replace function public.stats_publiques()
returns jsonb language sql stable security definer set search_path = public, extensions as $$
  with base as (
    select * from public.recits where coalesce(statut, 'soumis') not in ('retire', 'rejete')
  ),
  par_canton as (
    select canton, count(*) as n from base where canton is not null group by canton having count(*) >= 5
  ),
  par_etab as (
    select etablissement_id,
           count(*) filter (where type = 'signalement')                                          as signalements,
           count(*) filter (where type = 'positif')                                              as positifs,
           count(*) filter (where statut in ('verifie', 'publie'))                               as verifies,
           count(*) filter (where statut in ('verifie', 'publie') and type = 'positif')          as positifs_verifies,
           avg(dms_score::numeric / nullif(dms_max, 0))
             filter (where statut in ('verifie', 'publie') and type = 'signalement' and dms_max > 0) as ressenti
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
    'methode', 'indice = 70 × (1 − ressenti moyen) + 30 × part des retours positifs, sur témoignages vérifiés, dès 5 témoignages vérifiés',
    'par_etablissement', coalesce((select jsonb_object_agg(etablissement_id, jsonb_build_object(
        'signalements', signalements, 'positifs', positifs, 'verifies', verifies,
        'ressenti', case when verifies >= 5 then round(coalesce(ressenti, 0), 2) end,
        'indice', indice,
        'niveau', case when indice is null then null
                       when indice >= 75 then 'outstanding'
                       when indice >= 50 then 'good'
                       when indice >= 25 then 'requires_improvement'
                       else 'inadequate' end
      )) from evalue), '{}'::jsonb),
    'recus',          (select count(*) from base),
    'verifies',       (select count(*) from base where statut in ('verifie', 'publie')),
    'signalements',   (select count(*) from base where type = 'signalement'),
    'positifs',       (select count(*) from base where type = 'positif'),
    'etablissements', (select count(distinct etablissement_id) from base where etablissement_id is not null),
    'cantons',        (select count(distinct canton) from base where canton is not null),
    'par_canton',     coalesce((select jsonb_object_agg(canton, n) from par_canton), '{}'::jsonb),
    'premier_le',     (select to_char(min(cree_le), 'YYYY-MM-DD') from base),
    'calcule_le',     to_char(now(), 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
  );
$$;
grant execute on function public.stats_publiques() to anon, authenticated;

-- Contrôles
select statut, count(*) from public.recits group by statut;
select public.stats_publiques();
