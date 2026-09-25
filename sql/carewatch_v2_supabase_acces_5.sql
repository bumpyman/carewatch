-- =============================================================================
-- CareWatch · Accès à la modération : quotas adaptés aux réseaux partagés
-- Les quotas sont comptés par adresse IP. Sur un campus ou dans un hôpital, des
-- dizaines de personnes partagent la même adresse : 60 lectures d'état et
-- 10 vérifications de code par heure s'épuisent vite et bloquent tout le monde.
-- À coller dans SQL Editor puis Run. Ré-exécutable sans risque. Prérequis : acces_4.sql.
-- =============================================================================

create or replace function public.moderateur_verifier_code(p_email text, p_code text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_emp text := public.cw_empreinte_client();
  a     public.moderateurs_autorises;
begin
  if v_emp is not null then
    perform public.cw_controler_quota('ip:modcode:' || v_emp, 40, interval '1 hour');
  end if;
  select * into a from public.moderateurs_autorises where email = lower(trim(coalesce(p_email, '')));
  if a.email is null or a.code_hash is null then return jsonb_build_object('ok', false, 'raison', 'inconnu'); end if;
  if a.expire_le is not null and a.expire_le < now() then return jsonb_build_object('ok', false, 'raison', 'expire'); end if;
  if a.code_hash <> public.cw_hash(upper(trim(coalesce(p_code, '')))) then return jsonb_build_object('ok', false, 'raison', 'code'); end if;
  return jsonb_build_object('ok', true, 'nom', a.nom, 'role', a.role);
end $$;
grant execute on function public.moderateur_verifier_code(text, text) to anon, authenticated;

create or replace function public.moderateur_etat(p_email text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_emp   text := public.cw_empreinte_client();
  v_email text := lower(trim(coalesce(p_email, '')));
  v_uid   uuid;
  v_deja  boolean;
begin
  if v_emp is not null then
    perform public.cw_controler_quota('ip:modetat:' || v_emp, 400, interval '1 hour');
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

-- Remise à zéro des compteurs d'accès en cours
delete from public.cw_quota where cle like 'ip:modcode:%' or cle like 'ip:modetat:%';

-- Contrôle : adresses autorisées, octets exacts (repère les espaces ou caractères invisibles)
select email, length(email) as longueur, encode(convert_to(email, 'UTF8'), 'hex') as hex, expire_le from public.moderateurs_autorises order by email;
