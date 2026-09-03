-- ============================================================================
-- CareWatch : accord signé reconnu par code d'invitation + code d'accès pour les nouveaux comptes
-- À exécuter après referentiels_schema.sql. Idempotent.
-- ============================================================================

-- 1. La porte reconnaît un code d'invitation dont l'accord en vigueur est déjà signé
--    (la page ne redemande alors pas la signature, même depuis un autre appareil).
create or replace function public.verifier_invitation(p_code text, p_version_nda text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_emp text := public.cw_empreinte_client();
  r     public.invitations;
  v_nda timestamptz;
begin
  if v_emp is not null then
    perform public.cw_controler_quota('ip:invitation:' || v_emp, 30, interval '1 hour');
  end if;
  select * into r from public.invitations where code = lower(trim(coalesce(p_code, ''))) and actif;
  if r.code is null then
    return jsonb_build_object('ok', false);
  end if;
  select max(signe_le) into v_nda from public.nda_signatures
   where code = r.code and (p_version_nda is null or version = p_version_nda);
  return jsonb_build_object('ok', true, 'attribue_a', r.attribue_a, 'nda_signe', v_nda is not null, 'nda_signe_le', v_nda);
end $$;
grant execute on function public.verifier_invitation(text, text) to anon, authenticated;
drop function if exists public.verifier_invitation(text);

-- 2. Nouveaux comptes de modération : code d'accès à usage unique, remis par l'admin
alter table public.moderateurs_autorises
  add column if not exists code_hash text,
  add column if not exists expire_le timestamptz;

-- L'admin autorise une adresse : un code aléatoire est généré, affiché une seule fois, valable 14 jours.
create or replace function public.admin_autoriser_moderateur(p_email text, p_nom text, p_role text default 'moderateur')
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_email text := lower(trim(p_email));
  v_code  text;
  v_uid   uuid;
begin
  if not public.cw_est_admin() then raise exception 'Accès refusé' using errcode = '42501'; end if;
  if v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then raise exception 'Adresse e-mail invalide'; end if;
  if p_role not in ('moderateur', 'admin') then raise exception 'Rôle inconnu'; end if;

  -- compte déjà existant : inscription immédiate, pas de code nécessaire
  select id into v_uid from auth.users where lower(email) = v_email;
  if v_uid is not null then
    insert into public.moderateurs (user_id, nom, role) values (v_uid, p_nom, p_role)
    on conflict (user_id) do update set nom = excluded.nom, role = excluded.role;
    delete from public.moderateurs_autorises where email = v_email;
    return jsonb_build_object('ok', true, 'etat', 'inscrit');
  end if;

  v_code := upper(public.cw_nouveau_code(8));
  insert into public.moderateurs_autorises (email, nom, role, ajoute_par, code_hash, expire_le)
  values (v_email, p_nom, p_role, auth.uid(), public.cw_hash(v_code), now() + interval '14 days')
  on conflict (email) do update set nom = excluded.nom, role = excluded.role, code_hash = excluded.code_hash, expire_le = excluded.expire_le, ajoute_le = now();
  return jsonb_build_object('ok', true, 'etat', 'en_attente', 'code', v_code, 'expire_le', now() + interval '14 days');
end $$;
revoke execute on function public.admin_autoriser_moderateur(text, text, text) from public, anon;
grant  execute on function public.admin_autoriser_moderateur(text, text, text) to authenticated;

-- La personne saisit e-mail + code sur l'écran de modération ; si c'est juste, la page lui envoie le lien de connexion.
create or replace function public.moderateur_verifier_code(p_email text, p_code text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_emp text := public.cw_empreinte_client();
  a     public.moderateurs_autorises;
begin
  if v_emp is not null then
    perform public.cw_controler_quota('ip:modcode:' || v_emp, 10, interval '1 hour');
  end if;
  select * into a from public.moderateurs_autorises where email = lower(trim(coalesce(p_email, '')));
  if a.email is null or a.code_hash is null then return jsonb_build_object('ok', false, 'raison', 'inconnu'); end if;
  if a.expire_le is not null and a.expire_le < now() then return jsonb_build_object('ok', false, 'raison', 'expire'); end if;
  if a.code_hash <> public.cw_hash(upper(trim(coalesce(p_code, '')))) then return jsonb_build_object('ok', false, 'raison', 'code'); end if;
  return jsonb_build_object('ok', true, 'nom', a.nom, 'role', a.role);
end $$;
grant execute on function public.moderateur_verifier_code(text, text) to anon, authenticated;

-- 3. État d'une adresse pour l'écran de connexion : la page adapte le formulaire sans bouton « première connexion »
--    'compte'   : compte existant et inscrit → mot de passe
--    'autorise' : adresse autorisée en attente → code d'accès puis lien
--    'inconnu'  : rien (la page affiche le mot de passe, sans rien révéler)
create or replace function public.moderateur_etat(p_email text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_emp   text := public.cw_empreinte_client();
  v_email text := lower(trim(coalesce(p_email, '')));
  v_uid   uuid;
begin
  if v_emp is not null then
    perform public.cw_controler_quota('ip:modetat:' || v_emp, 60, interval '1 hour');
  end if;
  select u.id into v_uid from auth.users u join public.moderateurs m on m.user_id = u.id where lower(u.email) = v_email;
  if v_uid is not null then return jsonb_build_object('etat', 'compte'); end if;
  if exists (select 1 from public.moderateurs_autorises where email = v_email and code_hash is not null and (expire_le is null or expire_le > now())) then
    return jsonb_build_object('etat', 'autorise');
  end if;
  return jsonb_build_object('etat', 'inconnu');
end $$;
grant execute on function public.moderateur_etat(text) to anon, authenticated;

-- Contrôle
select email, nom, role, expire_le, code_hash is not null as code_remis from public.moderateurs_autorises order by ajoute_le desc;
