-- CareWatch v2.0 : ajout de l'autorisation « usage recherche, sensibilisation, formation »
-- À exécuter une fois dans Supabase > SQL Editor, après la partie A du correctif.
-- Les quatre fonctions sont recréées à l'identique, avec en plus :
--   - le champ usage_recherche
--   - set search_path = public, extensions  (indispensable pour pgcrypto)

alter table public.recits
  add column if not exists usage_recherche boolean not null default false;

create or replace function public.soumettre_recit(p jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_numero text;
  v_code   text;
begin
  if length(coalesce(p->>'description','')) < 20 then
    raise exception 'Description trop courte';
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

create or replace function public.lire_recit(p_numero text, p_code text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_id uuid := public.cw_verifier(p_numero, p_code);
  r    public.recits;
begin
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
  v_id uuid := public.cw_verifier(p_numero, p_code);
begin
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
  v_id uuid := public.cw_verifier(p_numero, p_code);
begin
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

-- Contrôle : chaque ligne doit afficher {search_path=public, extensions}
select p.proname, pg_get_function_identity_arguments(p.oid) as args, p.proconfig
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('soumettre_recit','lire_recit','modifier_autorisations','retirer_recit');
