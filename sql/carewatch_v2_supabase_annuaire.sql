-- =============================================================================
-- CareWatch · Annuaire participatif
-- Toute personne recommande un·e soignant·e ; la fiche est publiée tout de suite
-- avec la mention « En attente de vérification », puis « Validé par l'équipe »
-- quand la modération a contrôlé l'existence et la source.
--
-- Règles de publication
--   · Recommandations positives uniquement, sous forme de critères cochés. Aucun texte libre n'est publié.
--     Les critères décrivent l'accueil reçu par les patient·e·s : écoute, langue, accessibilité, précarité,
--     LGBTIQA+, identité de genre, racisme, religions, voile, migration, handicap, santé mentale, poids,
--     maladie chronique. Ils ne décrivent jamais l'identité du ou de la soignant·e.
--   · Le téléphone proposé reste en base et ne s'affiche qu'après validation par l'équipe.
--   · La personne concernée retire sa fiche en un clic (« Cette fiche me concerne ») ; la fiche est
--     masquée aussitôt et la modération contrôle la demande ensuite.
--   · Une personne ne recommande une même fiche qu'une seule fois. L'empreinte de connexion stockée est
--     propre à chaque fiche (hachage non réversible), donc impossible à relier d'une fiche à l'autre.
--
-- À coller dans SQL Editor puis Run. Ré-exécutable sans risque.
-- Prérequis : patch_complet (quotas, empreinte), moderation (cw_est_moderateur).
-- =============================================================================

-- 1. Tables ------------------------------------------------------------------
create table if not exists public.annuaire_fiches (
  id          uuid primary key default gen_random_uuid(),
  cle         text not null unique,
  cree_le     timestamptz not null default now(),
  nom         text not null,
  specialite  text not null,
  ville       text not null,
  canton      text not null check (canton in ('GE', 'VD', 'VS', 'FR', 'NE', 'JU', 'BE')),
  langues     text[] not null default '{}',
  source_url  text,
  telephone   text,
  valide      boolean not null default false,
  valide_le   timestamptz,
  valide_par  uuid,
  masque      boolean not null default false,
  masque_motif text
);
create index if not exists annuaire_fiches_liste_idx on public.annuaire_fiches (masque, valide desc);

create table if not exists public.annuaire_recos (
  id        uuid primary key default gen_random_uuid(),
  fiche_id  uuid not null references public.annuaire_fiches (id) on delete cascade,
  cree_le   timestamptz not null default now(),
  criteres  text[] not null,
  empreinte text not null,
  unique (fiche_id, empreinte)
);

create table if not exists public.annuaire_signalements (
  id        uuid primary key default gen_random_uuid(),
  fiche_id  uuid not null references public.annuaire_fiches (id) on delete cascade,
  cree_le   timestamptz not null default now(),
  motif     text not null check (motif in ('concerne', 'erreur', 'autre')),
  detail    text,
  contact   text,
  traite    boolean not null default false
);
create index if not exists annuaire_signalements_fiche_idx on public.annuaire_signalements (fiche_id, traite);

alter table public.annuaire_fiches        enable row level security;
alter table public.annuaire_recos         enable row level security;
alter table public.annuaire_signalements  enable row level security;
revoke all on public.annuaire_fiches, public.annuaire_recos, public.annuaire_signalements from public, anon, authenticated;

-- 2. Clé de rapprochement : même personne, même ville, même canton -> même fiche
--    Titres (Dr, Pr, Mme…), accents, ponctuation et casse sont ignorés.
create or replace function public.cw_cle_annuaire(p_nom text, p_ville text, p_canton text)
returns text language sql immutable as $$
  select
    regexp_replace(
      regexp_replace(
        lower(translate(trim(coalesce(p_nom, '')), 'ÀÂÄÉÈÊËÎÏÔÖÙÛÜÇàâäéèêëîïôöùûüç', 'AAAEEEEIIOOUUUCaaaeeeeiioouuuc')),
        '^(docteure?|dre?|professeure?|prof|pre?|mme|madame|monsieur)\.?\s+', ''),
      '[^a-z0-9]+', '', 'g')
    || '|' ||
    regexp_replace(lower(translate(trim(coalesce(p_ville, '')), 'ÀÂÄÉÈÊËÎÏÔÖÙÛÜÇàâäéèêëîïôöùûüç', 'AAAEEEEIIOOUUUCaaaeeeeiioouuuc')), '[^a-z0-9]+', '', 'g')
    || '|' || upper(trim(coalesce(p_canton, '')));
$$;

-- 2b. Critères admis ; la liste est lue par annuaire_proposer et reste modifiable à un seul endroit
create or replace function public.cw_criteres_annuaire()
returns text[] language sql immutable as $$
  select array['ecoute', 'interprete', 'accessible', 'precarite',
               'lgbtiqa', 'identite', 'racisme', 'religions', 'voile', 'migration', 'handicap', 'sante_mentale', 'poids', 'chronique'];
$$;

-- 3. Recommander (public, anonyme) --------------------------------------------
--    5 recommandations par jour et par connexion. Critères admis : voir la liste ci-dessous.
create or replace function public.annuaire_proposer(p jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_emp      text := public.cw_empreinte_client();
  v_nom      text := trim(coalesce(p->>'nom', ''));
  v_spec     text := trim(coalesce(p->>'specialite', ''));
  v_ville    text := trim(coalesce(p->>'ville', ''));
  v_canton   text := upper(trim(coalesce(p->>'canton', '')));
  v_source   text := nullif(trim(coalesce(p->>'source_url', '')), '');
  v_tel      text := nullif(trim(coalesce(p->>'telephone', '')), '');
  v_langues  text[];
  v_crit     text[];
  v_cle      text;
  v_fiche    public.annuaire_fiches%rowtype;
  v_nouvelle boolean := false;
  v_n        integer;
begin
  perform public.cw_controler_quota('ip:annuaire:' || coalesce(v_emp, 'x'), 5, interval '24 hours');

  if coalesce(p->>'consentement', 'false') <> 'true' then return jsonb_build_object('ok', false, 'erreur', 'Confirmation manquante'); end if;
  if length(v_nom) < 3 or length(v_nom) > 120 then return jsonb_build_object('ok', false, 'erreur', 'Nom : 3 à 120 caractères'); end if;
  if length(v_spec) < 3 or length(v_spec) > 80 then return jsonb_build_object('ok', false, 'erreur', 'Spécialité : 3 à 80 caractères'); end if;
  if length(v_ville) < 2 or length(v_ville) > 80 then return jsonb_build_object('ok', false, 'erreur', 'Ville : 2 à 80 caractères'); end if;
  if v_canton not in ('GE', 'VD', 'VS', 'FR', 'NE', 'JU', 'BE') then return jsonb_build_object('ok', false, 'erreur', 'Canton non reconnu'); end if;
  if v_source is not null and v_source !~ '^https://[^[:space:]]{4,250}$' then return jsonb_build_object('ok', false, 'erreur', 'Le lien source doit commencer par https://'); end if;
  if v_tel is not null and v_tel !~ '^[+0-9 ().-]{7,24}$' then return jsonb_build_object('ok', false, 'erreur', 'Numéro de téléphone non reconnu'); end if;

  select coalesce(array_agg(distinct left(trim(x), 30)) filter (where trim(x) <> ''), '{}') into v_langues
    from jsonb_array_elements_text(case when jsonb_typeof(p->'langues') = 'array' then p->'langues' else '[]'::jsonb end) x;
  v_langues := v_langues[1:6];

  select coalesce(array_agg(distinct x), '{}') into v_crit
    from jsonb_array_elements_text(case when jsonb_typeof(p->'criteres') = 'array' then p->'criteres' else '[]'::jsonb end) x
   where x = any (public.cw_criteres_annuaire());
  if coalesce(array_length(v_crit, 1), 0) = 0 then return jsonb_build_object('ok', false, 'erreur', 'Cochez au moins un critère'); end if;

  v_cle := public.cw_cle_annuaire(v_nom, v_ville, v_canton);
  select * into v_fiche from public.annuaire_fiches where cle = v_cle;
  if found then
    if v_fiche.masque then return jsonb_build_object('ok', false, 'erreur', 'Cette fiche est retirée de l’annuaire'); end if;
    -- complète les champs vides ; une fiche validée par l'équipe ne change plus
    if not v_fiche.valide then
      update public.annuaire_fiches
         set source_url = coalesce(source_url, v_source),
             telephone  = coalesce(telephone, v_tel),
             langues    = (select coalesce(array_agg(distinct l), '{}') from unnest(langues || v_langues) l)
       where id = v_fiche.id;
    end if;
  else
    insert into public.annuaire_fiches (cle, nom, specialite, ville, canton, langues, source_url, telephone)
    values (v_cle, v_nom, v_spec, v_ville, v_canton, v_langues, v_source, v_tel)
    returning * into v_fiche;
    v_nouvelle := true;
  end if;

  insert into public.annuaire_recos (fiche_id, criteres, empreinte)
  values (v_fiche.id, v_crit, encode(digest(coalesce(v_emp, gen_random_uuid()::text) || '|' || v_fiche.id::text, 'sha256'), 'hex'))
  on conflict (fiche_id, empreinte) do nothing;
  get diagnostics v_n = row_count;

  return jsonb_build_object('ok', true, 'id', v_fiche.id, 'nouvelle', v_nouvelle, 'deja', v_n = 0, 'valide', v_fiche.valide);
end $$;
revoke execute on function public.annuaire_proposer(jsonb) from public;
grant execute on function public.annuaire_proposer(jsonb) to anon, authenticated;

-- 4. Fiches publiées (public) -------------------------------------------------
--    Téléphone : seulement après validation. Aucun identifiant de la personne qui recommande.
create or replace function public.annuaire_publie()
returns jsonb language sql stable security definer set search_path = public, extensions as $$
  select coalesce(jsonb_agg(to_jsonb(x) order by x.valide desc, x.nb desc, x.nom), '[]'::jsonb)
  from (
    select f.id, f.nom, f.specialite, f.ville, f.canton, f.langues, f.source_url, f.valide,
           case when f.valide then f.telephone end as telephone,
           to_char(f.cree_le, 'YYYY-MM') as mois,
           (select count(*) from public.annuaire_recos r where r.fiche_id = f.id) as nb,
           (select coalesce(jsonb_object_agg(c, n), '{}'::jsonb)
              from (select unnest(r.criteres) as c, count(*) as n from public.annuaire_recos r where r.fiche_id = f.id group by 1) q) as criteres
      from public.annuaire_fiches f
     where not f.masque
     order by f.valide desc, f.cree_le desc
     limit 2000
  ) x;
$$;
revoke execute on function public.annuaire_publie() from public;
grant execute on function public.annuaire_publie() to anon, authenticated;

-- 5. Retrait ou correction (public) -------------------------------------------
--    « concerne » : la fiche est masquée tout de suite, la modération contrôle ensuite.
create or replace function public.annuaire_signaler(p_id uuid, p_motif text, p_precision text default null, p_contact text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_emp text := public.cw_empreinte_client();
  v_pre text := nullif(trim(coalesce(p_precision, '')), '');
  v_con text := nullif(trim(coalesce(p_contact, '')), '');
begin
  perform public.cw_controler_quota('ip:annuaire_signal:' || coalesce(v_emp, 'x'), 5, interval '24 hours');
  if p_motif not in ('concerne', 'erreur', 'autre') then return jsonb_build_object('ok', false, 'erreur', 'Motif non reconnu'); end if;
  if v_pre is not null and length(v_pre) > 500 then return jsonb_build_object('ok', false, 'erreur', 'Précision trop longue (500 caractères au plus)'); end if;
  if v_con is not null and length(v_con) > 120 then return jsonb_build_object('ok', false, 'erreur', 'Contact trop long'); end if;
  if not exists (select 1 from public.annuaire_fiches where id = p_id) then return jsonb_build_object('ok', false, 'erreur', 'Fiche introuvable'); end if;
  insert into public.annuaire_signalements (fiche_id, motif, detail, contact) values (p_id, p_motif, v_pre, v_con);
  if p_motif = 'concerne' then
    update public.annuaire_fiches set masque = true, masque_motif = 'Retrait demandé par la personne concernée' where id = p_id and not masque;
  end if;
  return jsonb_build_object('ok', true, 'masquee', p_motif = 'concerne');
end $$;
revoke execute on function public.annuaire_signaler(uuid, text, text, text) from public;
grant execute on function public.annuaire_signaler(uuid, text, text, text) to anon, authenticated;

-- 6. Équipe : lecture de tout ---------------------------------------------------
create or replace function public.admin_annuaire_lire()
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  if not public.cw_est_moderateur() then raise exception 'Accès refusé' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(to_jsonb(x) order by x.a_traiter desc, x.cree_le desc)
    from (
      select f.id, f.cree_le, f.nom, f.specialite, f.ville, f.canton, f.langues, f.source_url, f.telephone,
             f.valide, f.valide_le, f.masque, f.masque_motif,
             (select count(*) from public.annuaire_recos r where r.fiche_id = f.id) as nb,
             (select coalesce(jsonb_object_agg(c, n), '{}'::jsonb)
                from (select unnest(r.criteres) as c, count(*) as n from public.annuaire_recos r where r.fiche_id = f.id group by 1) q) as criteres,
             coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'motif', s.motif, 'detail', s.detail, 'contact', s.contact, 'cree_le', s.cree_le) order by s.cree_le desc)
                         from public.annuaire_signalements s where s.fiche_id = f.id and not s.traite), '[]'::jsonb) as signalements,
             (not f.valide or f.masque or exists (select 1 from public.annuaire_signalements s where s.fiche_id = f.id and not s.traite)) as a_traiter
        from public.annuaire_fiches f
    ) x
  ), '[]'::jsonb);
end $$;
revoke execute on function public.admin_annuaire_lire() from public, anon;
grant  execute on function public.admin_annuaire_lire() to authenticated;

-- 7. Équipe : valider, retirer la validation, masquer, restaurer, supprimer, clore les signalements
create or replace function public.admin_annuaire_ecrire(p_id uuid, p_op text, p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  f public.annuaire_fiches%rowtype;
  v_nom text; v_spec text; v_ville text; v_source text; v_tel text;
begin
  if not public.cw_est_moderateur() then raise exception 'Accès refusé' using errcode = '42501'; end if;
  select * into f from public.annuaire_fiches where id = p_id;
  if not found then raise exception 'Fiche introuvable'; end if;

  if p_op = 'valider' then
    v_nom    := coalesce(nullif(trim(p->>'nom'), ''), f.nom);
    v_spec   := coalesce(nullif(trim(p->>'specialite'), ''), f.specialite);
    v_ville  := coalesce(nullif(trim(p->>'ville'), ''), f.ville);
    v_source := case when p ? 'source_url' then nullif(trim(p->>'source_url'), '') else f.source_url end;
    v_tel    := case when p ? 'telephone' then nullif(trim(p->>'telephone'), '') else f.telephone end;
    if v_source is not null and v_source !~ '^https://[^[:space:]]{4,250}$' then raise exception 'Le lien source doit commencer par https://'; end if;
    if v_tel is not null and v_tel !~ '^[+0-9 ().-]{7,24}$' then raise exception 'Numéro de téléphone non reconnu'; end if;
    update public.annuaire_fiches
       set nom = v_nom, specialite = v_spec, ville = v_ville, source_url = v_source, telephone = v_tel,
           cle = public.cw_cle_annuaire(v_nom, v_ville, f.canton),
           valide = true, valide_le = now(), valide_par = auth.uid()
     where id = p_id;
  elsif p_op = 'invalider' then
    update public.annuaire_fiches set valide = false, valide_le = null, valide_par = null where id = p_id;
  elsif p_op = 'masquer' then
    update public.annuaire_fiches set masque = true, masque_motif = coalesce(nullif(trim(p->>'motif'), ''), 'Masquée par l’équipe') where id = p_id;
  elsif p_op = 'restaurer' then
    update public.annuaire_fiches set masque = false, masque_motif = null where id = p_id;
  elsif p_op = 'clore' then
    update public.annuaire_signalements set traite = true where fiche_id = p_id;
  elsif p_op = 'supprimer' then
    delete from public.annuaire_fiches where id = p_id;
  else
    raise exception 'Opération inconnue';
  end if;
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function public.admin_annuaire_ecrire(uuid, text, jsonb) from public, anon;
grant  execute on function public.admin_annuaire_ecrire(uuid, text, jsonb) to authenticated;

-- Contrôle
select count(*) as fiches, count(*) filter (where valide) as validees from public.annuaire_fiches;
