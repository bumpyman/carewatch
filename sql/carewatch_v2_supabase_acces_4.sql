-- =============================================================================
-- CareWatch · Accès à la modération, correctifs (septembre 2026)
-- Problème observé : une première tentative de connexion crée le compte Supabase
-- (signInWithOtp) même si la personne n'a jamais validé le code. Si l'admin refait
-- ensuite un code d'accès, la fonction voyait « compte existant » et inscrivait la
-- personne sans code : elle se retrouvait devant un champ mot de passe, sans mot de passe.
-- Ici : un compte qui ne s'est jamais connecté est traité comme un nouveau compte,
-- et l'écran de connexion sait proposer un code de connexion par e-mail à un compte
-- inscrit sans mot de passe.
-- À coller dans SQL Editor puis Run. Ré-exécutable sans risque. Prérequis : etablissements.sql.
-- =============================================================================

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

  -- Compte existant AVEC un mot de passe : inscription immédiate. Un compte créé par un simple code e-mail n'en a pas.
  select id into v_uid from auth.users where lower(email) = v_email and coalesce(encrypted_password, '') <> '';
  if v_uid is not null then
    insert into public.moderateurs (user_id, nom, role, etablissement_id) values (v_uid, p_nom, p_role, v_etab)
    on conflict (user_id) do update set nom = excluded.nom, role = excluded.role, etablissement_id = excluded.etablissement_id;
    delete from public.moderateurs_autorises where email = v_email;
    return jsonb_build_object('ok', true, 'etat', 'inscrit');
  end if;

  -- Sinon : code d'accès à usage unique, 14 jours
  v_code := upper(public.cw_nouveau_code(8));
  insert into public.moderateurs_autorises (email, nom, role, ajoute_par, code_hash, expire_le, etablissement_id)
  values (v_email, p_nom, p_role, auth.uid(), public.cw_hash(v_code), now() + interval '14 days', v_etab)
  on conflict (email) do update set nom = excluded.nom, role = excluded.role, code_hash = excluded.code_hash, expire_le = excluded.expire_le, ajoute_le = now(), etablissement_id = excluded.etablissement_id;
  return jsonb_build_object('ok', true, 'etat', 'en_attente', 'code', v_code, 'expire_le', now() + interval '14 days');
end $$;
revoke execute on function public.admin_autoriser_moderateur(text, text, text, text) from public, anon;
grant  execute on function public.admin_autoriser_moderateur(text, text, text, text) to authenticated;

-- État d'une adresse pour l'écran de connexion
--   'compte'          : inscrit·e avec un mot de passe → mot de passe
--   'compte_sans_mdp' : inscrit·e sans mot de passe (connexion par code e-mail seulement) → code de connexion par e-mail
--   'autorise'        : code d'accès remis, en attente → code d'accès
--   'inconnu'         : rien
create or replace function public.moderateur_etat(p_email text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_emp   text := public.cw_empreinte_client();
  v_email text := lower(trim(coalesce(p_email, '')));
  v_uid   uuid;
  v_deja  boolean;
begin
  if v_emp is not null then
    perform public.cw_controler_quota('ip:modetat:' || v_emp, 60, interval '1 hour');
  end if;
  if exists (select 1 from public.moderateurs_autorises where email = v_email and code_hash is not null and (expire_le is null or expire_le > now())) then
    return jsonb_build_object('etat', 'autorise');
  end if;
  select u.id, coalesce(u.encrypted_password, '') <> '' into v_uid, v_deja
  from auth.users u join public.moderateurs m on m.user_id = u.id where lower(u.email) = v_email;
  if v_uid is not null then return jsonb_build_object('etat', case when v_deja then 'compte' else 'compte_sans_mdp' end); end if;
  return jsonb_build_object('etat', 'inconnu');
end $$;
grant execute on function public.moderateur_etat(text) to anon, authenticated;

-- Contrôle : autorisations en attente et comptes inscrits
select 'autorise' as source, email, nom, role, expire_le, code_hash is not null as code_remis from public.moderateurs_autorises
union all
select 'inscrit', u.email, m.nom, m.role, null, coalesce(u.encrypted_password, '') <> '' as a_un_mot_de_passe from public.moderateurs m join auth.users u on u.id = m.user_id
order by 1, 2;
