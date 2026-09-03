-- ============================================================================
-- CareWatch : référentiels en base + rôles d'administration
-- À exécuter après invitations_etudiants.sql, PUIS carewatch_v2_supabase_referentiels_donnees.sql.
-- Idempotent.
--
-- Rôles :
--   moderateur : lit et traite les témoignages
--   admin      : en plus, gère les référentiels (établissements, services, organisations,
--                ressources cantonales, actualités), les invitations et les comptes de modération
-- Le second facteur reste obligatoire pour les deux.
-- ============================================================================

-- 1. Rôles ---------------------------------------------------------------------
alter table public.moderateurs add column if not exists role text not null default 'moderateur';
alter table public.moderateurs drop constraint if exists moderateurs_role_check;
alter table public.moderateurs add constraint moderateurs_role_check check (role in ('moderateur', 'admin'));

-- Premier compte administrateur : le vôtre
update public.moderateurs m set role = 'admin'
from auth.users u where u.id = m.user_id and lower(u.email) = 'davidzac.issom@hes-so.ch';

create or replace function public.cw_est_admin()
returns boolean language sql stable security definer set search_path = public, extensions as $$
  select auth.uid() is not null
     and exists (select 1 from public.moderateurs m where m.user_id = auth.uid() and m.role = 'admin')
     and coalesce(auth.jwt() ->> 'aal', '') = 'aal2';
$$;
revoke execute on function public.cw_est_admin() from public, anon;
grant  execute on function public.cw_est_admin() to authenticated;

-- 2. Comptes de modération créés depuis l'interface -------------------------------
--    L'admin autorise une adresse ; la personne demande un lien de connexion par e-mail
--    (Supabase crée alors son compte) ; à sa première connexion, elle est inscrite automatiquement.
--    Réglage Supabase requis : Authentication > Providers > Email : « Allow new users to sign up » ACTIVÉ.
--    Un compte créé par une adresse non autorisée n'obtient aucun droit.
create table if not exists public.moderateurs_autorises (
  email      text primary key,
  nom        text,
  role       text not null default 'moderateur' check (role in ('moderateur', 'admin')),
  ajoute_le  timestamptz not null default now(),
  ajoute_par uuid
);
alter table public.moderateurs_autorises enable row level security;
revoke all on public.moderateurs_autorises from public, anon, authenticated;

-- Profil : inscrit automatiquement un compte dont l'adresse a été autorisée
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
    insert into public.moderateurs (user_id, nom, role) values (auth.uid(), a.nom, a.role)
    on conflict (user_id) do nothing;
    delete from public.moderateurs_autorises where email = v_email;
    select * into m from public.moderateurs where user_id = auth.uid();
  end if;
  return jsonb_build_object('nom', m.nom, 'role', m.role, 'mdp_change_le', m.mdp_change_le, 'ajoute_le', m.ajoute_le, 'email', v_email);
end $$;
revoke execute on function public.moderateur_mon_profil() from public, anon;
grant  execute on function public.moderateur_mon_profil() to authenticated;

-- 3. Référentiels ------------------------------------------------------------------
create table if not exists public.etablissements (
  id          text primary key,
  nom         text not null,
  nom_complet text not null,
  type        text,
  ville       text,
  canton      text not null,
  actif       boolean not null default true,
  modifie_le  timestamptz not null default now()
);
create table if not exists public.services_categories (
  id         serial primary key,
  ordre      integer not null default 0,
  categorie  text not null,
  contextes  jsonb not null default '["all"]'::jsonb,
  items      jsonb not null default '[]'::jsonb,
  actif      boolean not null default true,
  modifie_le timestamptz not null default now()
);
create table if not exists public.services_etablissement (
  id               serial primary key,
  etablissement_id text not null references public.etablissements(id) on delete cascade,
  ordre            integer not null default 0,
  categorie        text not null,
  items            jsonb not null default '[]'::jsonb,
  modifie_le       timestamptz not null default now()
);
create table if not exists public.organisations (
  id          serial primary key,
  type        text not null check (type in ('urgence', 'organisation')),
  ordre       integer not null default 0,
  nom         text not null,
  nom_complet text,
  telephone   text,
  description text,
  url         text,
  ville       text,
  actif       boolean not null default true,
  modifie_le  timestamptz not null default now()
);
create table if not exists public.ressources_cantonales (
  id          serial primary key,
  canton      text not null,
  type        text not null check (type in ('mediation', 'plainte', 'lavi')),
  ordre       integer not null default 0,
  nom         text not null,
  telephone   text,
  url         text,
  email       text,
  adresse     text,
  description text,
  actif       boolean not null default true,
  modifie_le  timestamptz not null default now()
);
create table if not exists public.actualites (
  id            serial primary key,
  date_affichee text,
  titre         text not null,
  resume        text,
  source        text,
  type          text,
  url           text,
  publie        boolean not null default true,
  modifie_le    timestamptz not null default now()
);
do $$ declare t text; begin
  foreach t in array array['etablissements', 'services_categories', 'services_etablissement', 'organisations', 'ressources_cantonales', 'actualites'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from public, anon, authenticated', t);
  end loop;
end $$;

-- 4. Lecture publique, en un seul appel ---------------------------------------------
create or replace function public.referentiels()
returns jsonb language sql stable security definer set search_path = public, extensions as $$
  select jsonb_build_object(
    'etablissements',          coalesce((select jsonb_agg(to_jsonb(e) order by e.canton, e.nom_complet) from public.etablissements e where e.actif), '[]'::jsonb),
    'services_categories',     coalesce((select jsonb_agg(to_jsonb(c) order by c.ordre) from public.services_categories c where c.actif), '[]'::jsonb),
    'services_etablissement',  coalesce((select jsonb_agg(to_jsonb(x) order by x.etablissement_id, x.ordre) from public.services_etablissement x), '[]'::jsonb),
    'organisations',           coalesce((select jsonb_agg(to_jsonb(o) order by o.type, o.ordre, o.nom) from public.organisations o where o.actif), '[]'::jsonb),
    'ressources_cantonales',   coalesce((select jsonb_agg(to_jsonb(r) order by r.canton, r.type, r.ordre) from public.ressources_cantonales r where r.actif), '[]'::jsonb),
    'actualites',              coalesce((select jsonb_agg(to_jsonb(a) order by a.id desc) from public.actualites a where a.publie), '[]'::jsonb),
    'calcule_le',              to_char(now(), 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
  );
$$;
grant execute on function public.referentiels() to anon, authenticated;

-- 5. Écriture par les admins : une fonction par opération, tables et colonnes en liste blanche --
create or replace function public.admin_ref_ecrire(p_table text, p_op text, p jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_cols  text[];
  v_id    text;
  v_sql   text;
  v_res   jsonb;
begin
  if not public.cw_est_admin() then
    raise exception 'Accès refusé' using errcode = '42501';
  end if;
  v_cols := case p_table
    when 'etablissements'         then array['id','nom','nom_complet','type','ville','canton','actif']
    when 'services_categories'    then array['id','ordre','categorie','contextes','items','actif']
    when 'services_etablissement' then array['id','etablissement_id','ordre','categorie','items']
    when 'organisations'          then array['id','type','ordre','nom','nom_complet','telephone','description','url','ville','actif']
    when 'ressources_cantonales'  then array['id','canton','type','ordre','nom','telephone','url','email','adresse','description','actif']
    when 'actualites'             then array['id','date_affichee','titre','resume','source','type','url','publie']
    else null end;
  if v_cols is null then raise exception 'Table inconnue'; end if;
  v_id := p->>'id';

  if p_op = 'supprimer' then
    if v_id is null then raise exception 'Identifiant requis'; end if;
    execute format('delete from public.%I where id::text = $1', p_table) using v_id;
    return jsonb_build_object('ok', true);
  end if;

  if p_op = 'enregistrer' then
    -- insertion ou mise à jour : jsonb_populate_record garantit le typage des colonnes
    if p_table = 'etablissements' then
      insert into public.etablissements select * from jsonb_populate_record(null::public.etablissements, (p - 'modifie_le') || jsonb_build_object('modifie_le', now()))
      on conflict (id) do update set nom = excluded.nom, nom_complet = excluded.nom_complet, type = excluded.type, ville = excluded.ville, canton = excluded.canton, actif = coalesce(excluded.actif, true), modifie_le = now();
    elsif p_table = 'services_categories' then
      if v_id is null or v_id = '' then
        insert into public.services_categories (ordre, categorie, contextes, items, actif) values (coalesce((p->>'ordre')::int, 0), p->>'categorie', coalesce(p->'contextes', '["all"]'::jsonb), coalesce(p->'items', '[]'::jsonb), coalesce((p->>'actif')::boolean, true)) returning id::text into v_id;
      else
        update public.services_categories set ordre = coalesce((p->>'ordre')::int, ordre), categorie = coalesce(p->>'categorie', categorie), contextes = coalesce(p->'contextes', contextes), items = coalesce(p->'items', items), actif = coalesce((p->>'actif')::boolean, actif), modifie_le = now() where id = v_id::int;
      end if;
    elsif p_table = 'services_etablissement' then
      if v_id is null or v_id = '' then
        insert into public.services_etablissement (etablissement_id, ordre, categorie, items) values (p->>'etablissement_id', coalesce((p->>'ordre')::int, 0), p->>'categorie', coalesce(p->'items', '[]'::jsonb)) returning id::text into v_id;
      else
        update public.services_etablissement set etablissement_id = coalesce(p->>'etablissement_id', etablissement_id), ordre = coalesce((p->>'ordre')::int, ordre), categorie = coalesce(p->>'categorie', categorie), items = coalesce(p->'items', items), modifie_le = now() where id = v_id::int;
      end if;
    elsif p_table = 'organisations' then
      if v_id is null or v_id = '' then
        insert into public.organisations (type, ordre, nom, nom_complet, telephone, description, url, ville, actif) values (p->>'type', coalesce((p->>'ordre')::int, 0), p->>'nom', p->>'nom_complet', p->>'telephone', p->>'description', p->>'url', p->>'ville', coalesce((p->>'actif')::boolean, true)) returning id::text into v_id;
      else
        update public.organisations set type = coalesce(p->>'type', type), ordre = coalesce((p->>'ordre')::int, ordre), nom = coalesce(p->>'nom', nom), nom_complet = p->>'nom_complet', telephone = p->>'telephone', description = p->>'description', url = p->>'url', ville = p->>'ville', actif = coalesce((p->>'actif')::boolean, actif), modifie_le = now() where id = v_id::int;
      end if;
    elsif p_table = 'ressources_cantonales' then
      if v_id is null or v_id = '' then
        insert into public.ressources_cantonales (canton, type, ordre, nom, telephone, url, email, adresse, description, actif) values (p->>'canton', p->>'type', coalesce((p->>'ordre')::int, 0), p->>'nom', p->>'telephone', p->>'url', p->>'email', p->>'adresse', p->>'description', coalesce((p->>'actif')::boolean, true)) returning id::text into v_id;
      else
        update public.ressources_cantonales set canton = coalesce(p->>'canton', canton), type = coalesce(p->>'type', type), ordre = coalesce((p->>'ordre')::int, ordre), nom = coalesce(p->>'nom', nom), telephone = p->>'telephone', url = p->>'url', email = p->>'email', adresse = p->>'adresse', description = p->>'description', actif = coalesce((p->>'actif')::boolean, actif), modifie_le = now() where id = v_id::int;
      end if;
    elsif p_table = 'actualites' then
      if v_id is null or v_id = '' then
        insert into public.actualites (date_affichee, titre, resume, source, type, url, publie) values (p->>'date_affichee', p->>'titre', p->>'resume', p->>'source', p->>'type', p->>'url', coalesce((p->>'publie')::boolean, true)) returning id::text into v_id;
      else
        update public.actualites set date_affichee = p->>'date_affichee', titre = coalesce(p->>'titre', titre), resume = p->>'resume', source = p->>'source', type = p->>'type', url = p->>'url', publie = coalesce((p->>'publie')::boolean, publie), modifie_le = now() where id = v_id::int;
      end if;
    end if;
    return jsonb_build_object('ok', true, 'id', v_id);
  end if;
  raise exception 'Opération inconnue';
end $$;
revoke execute on function public.admin_ref_ecrire(text, text, jsonb) from public, anon;
grant  execute on function public.admin_ref_ecrire(text, text, jsonb) to authenticated;

-- Lecture complète pour l'admin (y compris inactifs et non publiés)
create or replace function public.admin_ref_lire()
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  if not public.cw_est_admin() then raise exception 'Accès refusé' using errcode = '42501'; end if;
  return jsonb_build_object(
    'etablissements',         coalesce((select jsonb_agg(to_jsonb(e) order by e.canton, e.nom_complet) from public.etablissements e), '[]'::jsonb),
    'services_categories',    coalesce((select jsonb_agg(to_jsonb(c) order by c.ordre) from public.services_categories c), '[]'::jsonb),
    'services_etablissement', coalesce((select jsonb_agg(to_jsonb(x) order by x.etablissement_id, x.ordre) from public.services_etablissement x), '[]'::jsonb),
    'organisations',          coalesce((select jsonb_agg(to_jsonb(o) order by o.type, o.ordre, o.nom) from public.organisations o), '[]'::jsonb),
    'ressources_cantonales',  coalesce((select jsonb_agg(to_jsonb(r) order by r.canton, r.type, r.ordre) from public.ressources_cantonales r), '[]'::jsonb),
    'actualites',             coalesce((select jsonb_agg(to_jsonb(a) order by a.id desc) from public.actualites a), '[]'::jsonb)
  );
end $$;
revoke execute on function public.admin_ref_lire() from public, anon;
grant  execute on function public.admin_ref_lire() to authenticated;

-- 6. Accès : invitations et comptes, gérés par les admins -----------------------------
create or replace function public.admin_acces_lire()
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  if not public.cw_est_admin() then raise exception 'Accès refusé' using errcode = '42501'; end if;
  return jsonb_build_object(
    'invitations', coalesce((select jsonb_agg(jsonb_build_object('code', i.code, 'attribue_a', i.attribue_a, 'email', i.email, 'attribue_le', i.attribue_le, 'actif', i.actif,
                        'nda_signe_le', (select max(s.signe_le) from public.nda_signatures s where s.code = i.code)) order by i.attribue_le desc nulls last, i.code) from public.invitations i), '[]'::jsonb),
    'moderateurs', coalesce((select jsonb_agg(jsonb_build_object('user_id', m.user_id, 'nom', m.nom, 'role', m.role, 'email', u.email, 'ajoute_le', m.ajoute_le, 'mdp_change_le', m.mdp_change_le, 'derniere_connexion', u.last_sign_in_at) order by m.ajoute_le)
                      from public.moderateurs m join auth.users u on u.id = m.user_id), '[]'::jsonb),
    'autorises',   coalesce((select jsonb_agg(to_jsonb(a) order by a.ajoute_le desc) from public.moderateurs_autorises a), '[]'::jsonb)
  );
end $$;
revoke execute on function public.admin_acces_lire() from public, anon;
grant  execute on function public.admin_acces_lire() to authenticated;

create or replace function public.admin_acces_ecrire(p_op text, p jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_code text;
  v_uid  uuid;
begin
  if not public.cw_est_admin() then raise exception 'Accès refusé' using errcode = '42501'; end if;
  if p_op = 'invitation_creer' then
    -- code aléatoire lisible, 4 caractères, ou code fourni
    v_code := lower(coalesce(nullif(trim(p->>'code'), ''), 'cw-' || (select string_agg(substr('abcdefghjkmnpqrstuvwxyz23456789', 1 + floor(random() * 31)::int, 1), '') from generate_series(1, 4))));
    insert into public.invitations (code, attribue_a, email, attribue_le) values (v_code, p->>'attribue_a', p->>'email', coalesce((p->>'attribue_le')::date, current_date))
    on conflict (code) do update set attribue_a = excluded.attribue_a, email = excluded.email;
    return jsonb_build_object('ok', true, 'code', v_code);
  elsif p_op = 'invitation_actif' then
    update public.invitations set actif = coalesce((p->>'actif')::boolean, actif) where code = lower(p->>'code');
    return jsonb_build_object('ok', true);
  elsif p_op = 'autoriser' then
    insert into public.moderateurs_autorises (email, nom, role, ajoute_par) values (lower(trim(p->>'email')), p->>'nom', coalesce(p->>'role', 'moderateur'), auth.uid())
    on conflict (email) do update set nom = excluded.nom, role = excluded.role;
    -- si le compte existe déjà, inscription immédiate
    select id into v_uid from auth.users where lower(email) = lower(trim(p->>'email'));
    if v_uid is not null then
      insert into public.moderateurs (user_id, nom, role) values (v_uid, p->>'nom', coalesce(p->>'role', 'moderateur'))
      on conflict (user_id) do update set nom = excluded.nom, role = excluded.role;
      delete from public.moderateurs_autorises where email = lower(trim(p->>'email'));
      return jsonb_build_object('ok', true, 'etat', 'inscrit');
    end if;
    return jsonb_build_object('ok', true, 'etat', 'en_attente');
  elsif p_op = 'retirer_autorisation' then
    delete from public.moderateurs_autorises where email = lower(trim(p->>'email'));
    return jsonb_build_object('ok', true);
  elsif p_op = 'role' then
    if (p->>'user_id')::uuid = auth.uid() and p->>'role' <> 'admin' then raise exception 'Vous ne pouvez pas retirer votre propre rôle admin'; end if;
    update public.moderateurs set role = p->>'role' where user_id = (p->>'user_id')::uuid;
    return jsonb_build_object('ok', true);
  elsif p_op = 'retirer_moderateur' then
    if (p->>'user_id')::uuid = auth.uid() then raise exception 'Vous ne pouvez pas vous retirer vous-même'; end if;
    delete from public.moderateurs where user_id = (p->>'user_id')::uuid;
    return jsonb_build_object('ok', true);
  end if;
  raise exception 'Opération inconnue';
end $$;
revoke execute on function public.admin_acces_ecrire(text, jsonb) from public, anon;
grant  execute on function public.admin_acces_ecrire(text, jsonb) to authenticated;

-- Contrôle
select m.nom, u.email, m.role from public.moderateurs m join auth.users u on u.id = m.user_id order by m.role, m.nom;
