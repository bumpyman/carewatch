-- ============================================================================
-- CareWatch v2.0 : correctif complet Supabase (à exécuter une fois, SQL Editor)
-- Remplace le fichier carewatch_v2_supabase_patch_recherche.sql.
--
-- Contenu :
--   1. Colonne usage_recherche (case « recherche, sensibilisation, formation »)
--   2. Protection contre les abus : quotas de fréquence, limites de taille,
--      fermeture des fonctions utilitaires à l'accès anonyme
--   3. Les quatre fonctions recréées avec ces ajouts et
--      set search_path = public, extensions  (indispensable pour pgcrypto)
--
-- Idempotent : peut être relancé sans dommage.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Colonne pour la nouvelle autorisation
-- ---------------------------------------------------------------------------
alter table public.recits
  add column if not exists usage_recherche boolean not null default false;

-- ---------------------------------------------------------------------------
-- 2a. Fermer l'accès anonyme aux fonctions utilitaires
--     (cw_hash et cw_nouveau_code étaient appelables depuis l'extérieur)
-- ---------------------------------------------------------------------------
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('cw_hash', 'cw_nouveau_code', 'cw_verifier')
  loop
    execute format('revoke execute on function %s from public, anon, authenticated', r.sig);
    execute format('alter function %s set search_path = public, extensions', r.sig);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 2b. Tables internes : configuration (sel) et compteurs de quota
--     Aucun droit pour anon/authenticated : seules les fonctions
--     security definer y touchent.
-- ---------------------------------------------------------------------------
create table if not exists public.cw_config (
  cle    text primary key,
  valeur text not null
);
alter table public.cw_config enable row level security;
revoke all on public.cw_config from public, anon, authenticated;

insert into public.cw_config (cle, valeur)
values ('sel_quota', encode(extensions.gen_random_bytes(32), 'hex'))
on conflict (cle) do nothing;

create table if not exists public.cw_quota (
  cle   text primary key,
  debut timestamptz not null default now(),
  n     integer not null default 0
);
alter table public.cw_quota enable row level security;
revoke all on public.cw_quota from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2c. Empreinte non réversible du client (hachage salé de l'adresse IP)
--     Renvoie null hors contexte HTTP (par ex. depuis le SQL Editor).
--     L'adresse IP en clair n'est jamais écrite.
-- ---------------------------------------------------------------------------
create or replace function public.cw_empreinte_client()
returns text language plpgsql stable security definer set search_path = public, extensions as $$
declare
  h   jsonb;
  ip  text;
  sel text;
begin
  begin
    h := current_setting('request.headers', true)::jsonb;
  exception when others then
    return null;
  end;
  if h is null then return null; end if;
  ip := coalesce(h->>'cf-connecting-ip', h->>'x-real-ip', split_part(h->>'x-forwarded-for', ',', 1));
  if ip is null or ip = '' then return null; end if;
  select valeur into sel from public.cw_config where cle = 'sel_quota';
  return encode(digest(coalesce(sel, '') || '|' || trim(ip), 'sha256'), 'hex');
end $$;
revoke execute on function public.cw_empreinte_client() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2d. Compteur glissant : au plus p_max appels par fenêtre p_fenetre pour p_cle
-- ---------------------------------------------------------------------------
create or replace function public.cw_controler_quota(p_cle text, p_max integer, p_fenetre interval)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare
  v_n integer;
begin
  -- nettoyage opportuniste des compteurs anciens (au plus 24 h)
  delete from public.cw_quota where debut < now() - interval '24 hours';

  insert into public.cw_quota (cle, debut, n) values (p_cle, now(), 1)
  on conflict (cle) do update
    set n     = case when public.cw_quota.debut < now() - p_fenetre then 1 else public.cw_quota.n + 1 end,
        debut = case when public.cw_quota.debut < now() - p_fenetre then now() else public.cw_quota.debut end
  returning n into v_n;

  if v_n > p_max then
    raise exception 'Trop de demandes, réessayez plus tard' using errcode = 'P0002';
  end if;
end $$;
revoke execute on function public.cw_controler_quota(text, integer, interval) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Les quatre fonctions publiques
-- ---------------------------------------------------------------------------

-- Soumission : contrôle de taille, quotas, puis insertion
create or replace function public.soumettre_recit(p jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_numero text;
  v_code   text;
  v_emp    text;
begin
  -- garde-fous de taille
  if p is null or pg_column_size(p) > 40000 then
    raise exception 'Requête trop volumineuse';
  end if;
  if length(coalesce(p->>'description','')) < 20 then
    raise exception 'Description trop courte';
  end if;
  if length(p->>'description') > 3000 or length(coalesce(p->>'impact','')) > 3000 then
    raise exception 'Description trop longue';
  end if;

  -- quotas : 60 envois / 10 min pour tout le site, 5 envois / heure par empreinte client
  perform public.cw_controler_quota('global:soumettre', 60, interval '10 minutes');
  v_emp := public.cw_empreinte_client();
  if v_emp is not null then
    perform public.cw_controler_quota('ip:soumettre:' || v_emp, 5, interval '1 hour');
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

-- Lecture : quota par empreinte pour freiner les essais de codes
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
    'numero', r.numero, 'type', r.type, 'statut', r.statut, 'cree_le', r.cree_le,
    'canton', r.canton, 'etablissement_nom', r.etablissement_nom, 'service', r.service,
    'date_incident', r.date_incident, 'type_incident', r.type_incident,
    'dms_score', r.dms_score, 'dms_max', r.dms_max,
    'recevoir_resultats', r.recevoir_resultats, 'recontact_echange', r.recontact_echange,
    'recontact_etude', r.recontact_etude, 'publier_fiche', r.publier_fiche,
    'usage_recherche', r.usage_recherche,
    'lecture_texte_complet', r.lecture_texte_complet, 'accepte_recontact_email', r.accepte_recontact_email
  );
end $$;

create or replace function public.modifier_autorisations(p_numero text, p_code text, p jsonb)
returns boolean language plpgsql security definer set search_path = public, extensions as $$
declare
  v_emp text := public.cw_empreinte_client();
  v_id  uuid;
begin
  if v_emp is not null then
    perform public.cw_controler_quota('ip:lire:' || v_emp, 60, interval '1 hour');
  end if;
  v_id := public.cw_verifier(p_numero, p_code);
  if v_id is null then return false; end if;
  update public.recits set
    recevoir_resultats      = coalesce((p->>'recevoir_resultats')::boolean, false),
    recontact_echange       = coalesce((p->>'recontact_echange')::boolean, false),
    recontact_etude         = coalesce((p->>'recontact_etude')::boolean, false),
    publier_fiche           = coalesce((p->>'publier_fiche')::boolean, false),
    usage_recherche         = coalesce((p->>'usage_recherche')::boolean, false),
    lecture_texte_complet   = coalesce((p->>'lecture_texte_complet')::boolean, false),
    accepte_recontact_email = coalesce((p->>'accepte_recontact_email')::boolean, false),
    modifie_le              = now()
  where id = v_id;
  insert into public.recits_journal (numero, action) values (upper(trim(p_numero)), 'autorisations_modifiees');
  return true;
end $$;

create or replace function public.retirer_recit(p_numero text, p_code text)
returns boolean language plpgsql security definer set search_path = public, extensions as $$
declare
  v_emp text := public.cw_empreinte_client();
  v_id  uuid;
begin
  if v_emp is not null then
    perform public.cw_controler_quota('ip:lire:' || v_emp, 60, interval '1 hour');
  end if;
  v_id := public.cw_verifier(p_numero, p_code);
  if v_id is null then return false; end if;
  update public.recits set
    statut = 'retire', retire_le = now(), modifie_le = now(),
    description = null, impact = null, dms = null, dms_score = null,
    motifs_percus = null, categories_positives = null,
    recevoir_resultats = false, recontact_echange = false, recontact_etude = false,
    publier_fiche = false, usage_recherche = false, lecture_texte_complet = false, accepte_recontact_email = false
  where id = v_id;
  insert into public.recits_journal (numero, action) values (upper(trim(p_numero)), 'retire');
  return true;
end $$;

-- ---------------------------------------------------------------------------
-- Contrôles
--   a) chaque fonction doit afficher {search_path=public, extensions}
--   b) seules les 4 fonctions publiques doivent être exécutables par anon
-- ---------------------------------------------------------------------------
select p.proname, pg_get_function_identity_arguments(p.oid) as args, p.proconfig,
       has_function_privilege('anon', p.oid, 'execute') as anon_peut_appeler
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('soumettre_recit','lire_recit','modifier_autorisations','retirer_recit',
                    'cw_verifier','cw_hash','cw_nouveau_code','cw_empreinte_client','cw_controler_quota')
order by 1;
