-- ============================================================================
-- CareWatch v2.0 : modification d'un témoignage + espace de modération sécurisé
-- À exécuter une fois dans Supabase > SQL Editor, après patch_complet.sql et stats.sql.
-- Idempotent.
--
-- Cycle de vie (recits.statut) :
--   soumis (à l'envoi)  →  verifie  →  publie (si publier_fiche)     comptés « vérifiés »
--                       →  rejete                                     exclu des compteurs
--   retire (par la personne)                                          exclu des compteurs
--   Une modification du texte par la personne remet le statut à « soumis » (re-modération).
--
-- PRÉREQUIS côté tableau de bord Supabase (à faire une fois, à la main) :
--   1. Authentication > Providers > Email : activé (par défaut). Désactiver « Allow new users
--      to sign up » pour que personne ne puisse créer un compte depuis l'extérieur.
--   2. Authentication > Users > Add user : créer chaque modérateur·rice avec e-mail + mot de
--      passe, case « Auto Confirm User » cochée.
--   3. Authentication > Multi-Factor > TOTP : activé (c'est le cas par défaut).
--   4. Puis, ci-dessous, section 5 : inscrire chaque compte dans la table moderateurs.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Colonnes de modération
-- ---------------------------------------------------------------------------
alter table public.recits
  add column if not exists note_moderation text,
  add column if not exists modere_le timestamptz;

-- ---------------------------------------------------------------------------
-- 2. Modification par la personne (numéro + code personnel)
-- ---------------------------------------------------------------------------
create or replace function public.modifier_recit(p_numero text, p_code text, p jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_emp    text := public.cw_empreinte_client();
  v_id     uuid;
  v_statut text;
  v_desc   text := nullif(trim(coalesce(p->>'description', '')), '');
  v_impact text := p->>'impact';
begin
  if v_emp is not null then
    perform public.cw_controler_quota('ip:lire:' || v_emp, 60, interval '1 hour');
  end if;
  v_id := public.cw_verifier(p_numero, p_code);
  if v_id is null then
    return jsonb_build_object('ok', false, 'raison', 'code');
  end if;
  select statut into v_statut from public.recits where id = v_id;
  if v_statut = 'retire' then
    return jsonb_build_object('ok', false, 'raison', 'retire');
  end if;
  if v_desc is not null and length(v_desc) < 20 then
    return jsonb_build_object('ok', false, 'raison', 'description_courte');
  end if;
  if length(coalesce(v_desc, '')) > 3000 or length(coalesce(v_impact, '')) > 3000 then
    return jsonb_build_object('ok', false, 'raison', 'trop_long');
  end if;

  update public.recits set
    description   = coalesce(v_desc, description),
    impact        = coalesce(v_impact, impact),
    service       = coalesce(nullif(p->>'service', ''), service),
    type_incident = coalesce(nullif(p->>'type_incident', ''), type_incident),
    date_incident = coalesce(nullif(p->>'date_incident', '')::date, date_incident),
    -- un texte modifié doit être relu : retour en file de modération
    statut        = case when statut in ('verifie', 'publie', 'rejete') then 'soumis' else statut end,
    modifie_le    = now()
  where id = v_id;

  insert into public.recits_journal (numero, action) values (upper(trim(p_numero)), 'modifie');
  return jsonb_build_object('ok', true, 'statut', (select statut from public.recits where id = v_id));
end $$;
grant execute on function public.modifier_recit(text, text, jsonb) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Modérateur·rice·s : comptes Supabase Auth autorisés, connexion en 2 étapes exigée
-- ---------------------------------------------------------------------------
create table if not exists public.moderateurs (
  user_id   uuid primary key references auth.users(id) on delete cascade,
  nom       text,
  ajoute_le timestamptz not null default now()
);
alter table public.moderateurs enable row level security;
revoke all on public.moderateurs from public, anon, authenticated;

-- Vrai si : connecté, inscrit dans moderateurs, ET second facteur validé (aal2)
create or replace function public.cw_est_moderateur()
returns boolean language sql stable security definer set search_path = public, extensions as $$
  select auth.uid() is not null
     and exists (select 1 from public.moderateurs m where m.user_id = auth.uid())
     and coalesce(auth.jwt() ->> 'aal', '') = 'aal2';
$$;
revoke execute on function public.cw_est_moderateur() from public, anon;
grant  execute on function public.cw_est_moderateur() to authenticated;

-- Liste (sans le texte) pour la file de modération
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
      where (p_statut is null or statut = p_statut)
      order by cree_le desc
      limit least(coalesce(p_limite, 300), 1000)
    ) r
  ), '[]'::jsonb);
end $$;

-- Fiche complète d'un témoignage (tout sauf l'empreinte du code)
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
            select jsonb_agg(jsonb_build_object('action', j.action, 'quand', j.cree_le) order by j.cree_le)
            from public.recits_journal j where j.numero = r.numero), '[]'::jsonb));
end $$;

-- Changement de statut avec note
create or replace function public.admin_changer_statut(p_numero text, p_statut text, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_fiche boolean;
begin
  if not public.cw_est_moderateur() then
    raise exception 'Accès refusé' using errcode = '42501';
  end if;
  if p_statut not in ('soumis', 'verifie', 'publie', 'rejete') then
    raise exception 'Statut inconnu';
  end if;
  select publier_fiche into v_fiche from public.recits where numero = upper(trim(p_numero)) and statut <> 'retire';
  if v_fiche is null then
    return jsonb_build_object('ok', false, 'raison', 'introuvable_ou_retire');
  end if;
  if p_statut = 'publie' and not v_fiche then
    return jsonb_build_object('ok', false, 'raison', 'fiche_non_autorisee');
  end if;
  update public.recits set
    statut          = p_statut,
    note_moderation = coalesce(nullif(trim(p_note), ''), note_moderation),
    modere_le       = now(),
    modifie_le      = now()
  where numero = upper(trim(p_numero));
  insert into public.recits_journal (numero, action) values (upper(trim(p_numero)), 'moderation:' || p_statut);
  return jsonb_build_object('ok', true, 'statut', p_statut);
end $$;

revoke execute on function public.admin_lister_recits(text, integer)       from public, anon;
revoke execute on function public.admin_lire_recit(text)                    from public, anon;
revoke execute on function public.admin_changer_statut(text, text, text)    from public, anon;
grant  execute on function public.admin_lister_recits(text, integer)       to authenticated;
grant  execute on function public.admin_lire_recit(text)                    to authenticated;
grant  execute on function public.admin_changer_statut(text, text, text)    to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Compteurs publics : les témoignages rejetés ne comptent plus comme « reçus »
-- ---------------------------------------------------------------------------
drop function if exists public.stats_publiques();
create or replace function public.stats_publiques()
returns jsonb language sql stable security definer set search_path = public, extensions as $$
  with base as (
    select * from public.recits where statut not in ('retire', 'rejete')
  ),
  par_canton as (
    select canton, count(*) as n from base where canton is not null group by canton having count(*) >= 5
  ),
  -- comptes par établissement (aucun détail de récit : juste des nombres, pour la liste des établissements)
  par_etab as (
    select etablissement_id,
           count(*) filter (where type = 'signalement')            as signalements,
           count(*) filter (where type = 'positif')                as positifs,
           count(*) filter (where statut in ('verifie', 'publie')) as verifies
    from base where etablissement_id is not null
    group by etablissement_id
  )
  select jsonb_build_object(
    'par_etablissement', coalesce((select jsonb_object_agg(etablissement_id,
                            jsonb_build_object('signalements', signalements, 'positifs', positifs, 'verifies', verifies)) from par_etab), '{}'::jsonb),
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

-- ---------------------------------------------------------------------------
-- 5. Inscrire un·e modérateur·rice (après création du compte dans Authentication > Users)
--    Remplacer l'adresse et le nom, exécuter une ligne par personne.
-- ---------------------------------------------------------------------------
-- insert into public.moderateurs (user_id, nom)
--   select id, 'Prénom Nom' from auth.users where email = 'moderation@carewat.ch'
--   on conflict (user_id) do nothing;

-- Contrôle : comptes autorisés
select m.nom, u.email, m.ajoute_le from public.moderateurs m join auth.users u on u.id = m.user_id;
