-- ============================================================================
-- CareWatch : retrait complet d'un compte de modération + nettoyage des comptes orphelins
-- À exécuter après acces_2.sql. Idempotent.
--
-- Jusqu'ici, « Retirer » ne supprimait que les droits (table moderateurs) : le compte
-- Supabase Auth restait visible dans Authentication > Users. Désormais le compte est
-- supprimé aussi, ainsi que ses facteurs et ses sessions.
-- ============================================================================

create or replace function public.admin_acces_ecrire(p_op text, p jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_code text;
  v_uid  uuid;
begin
  if not public.cw_est_admin() then raise exception 'Accès refusé' using errcode = '42501'; end if;
  if p_op = 'invitation_creer' then
    v_code := lower(coalesce(nullif(trim(p->>'code'), ''), 'cw-' || (select string_agg(substr('abcdefghjkmnpqrstuvwxyz23456789', 1 + floor(random() * 31)::int, 1), '') from generate_series(1, 4))));
    insert into public.invitations (code, attribue_a, email, attribue_le) values (v_code, p->>'attribue_a', p->>'email', coalesce((p->>'attribue_le')::date, current_date))
    on conflict (code) do update set attribue_a = excluded.attribue_a, email = excluded.email;
    return jsonb_build_object('ok', true, 'code', v_code);
  elsif p_op = 'invitation_actif' then
    update public.invitations set actif = coalesce((p->>'actif')::boolean, actif) where code = lower(p->>'code');
    return jsonb_build_object('ok', true);
  elsif p_op = 'autoriser' then
    -- conservé pour compatibilité ; l'interface utilise admin_autoriser_moderateur (code d'accès)
    insert into public.moderateurs_autorises (email, nom, role, ajoute_par) values (lower(trim(p->>'email')), p->>'nom', coalesce(p->>'role', 'moderateur'), auth.uid())
    on conflict (email) do update set nom = excluded.nom, role = excluded.role;
    return jsonb_build_object('ok', true, 'etat', 'en_attente');
  elsif p_op = 'retirer_autorisation' then
    delete from public.moderateurs_autorises where email = lower(trim(p->>'email'));
    return jsonb_build_object('ok', true);
  elsif p_op = 'role' then
    if (p->>'user_id')::uuid = auth.uid() and p->>'role' <> 'admin' then raise exception 'Vous ne pouvez pas retirer votre propre rôle admin'; end if;
    update public.moderateurs set role = p->>'role' where user_id = (p->>'user_id')::uuid;
    return jsonb_build_object('ok', true);
  elsif p_op = 'retirer_moderateur' then
    v_uid := (p->>'user_id')::uuid;
    if v_uid = auth.uid() then raise exception 'Vous ne pouvez pas vous retirer vous-même'; end if;
    delete from public.moderateurs where user_id = v_uid;
    -- suppression du compte Supabase Auth lui-même (sessions, facteurs, identités suivent en cascade)
    delete from auth.users where id = v_uid;
    return jsonb_build_object('ok', true, 'compte_supprime', true);
  elsif p_op = 'supprimer_compte_orphelin' then
    -- compte Auth sans droits de modération (ancienne suppression partielle, ou inscription non autorisée)
    v_uid := (p->>'user_id')::uuid;
    if v_uid = auth.uid() then raise exception 'Vous ne pouvez pas vous supprimer vous-même'; end if;
    if exists (select 1 from public.moderateurs where user_id = v_uid) then raise exception 'Ce compte a des droits : utilisez « Retirer »'; end if;
    delete from auth.users where id = v_uid;
    return jsonb_build_object('ok', true);
  end if;
  raise exception 'Opération inconnue';
end $$;
revoke execute on function public.admin_acces_ecrire(text, jsonb) from public, anon;
grant  execute on function public.admin_acces_ecrire(text, jsonb) to authenticated;

-- La lecture liste aussi les comptes orphelins
create or replace function public.admin_acces_lire()
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  if not public.cw_est_admin() then raise exception 'Accès refusé' using errcode = '42501'; end if;
  return jsonb_build_object(
    'invitations', coalesce((select jsonb_agg(jsonb_build_object('code', i.code, 'attribue_a', i.attribue_a, 'email', i.email, 'attribue_le', i.attribue_le, 'actif', i.actif,
                        'nda_signe_le', (select max(s.signe_le) from public.nda_signatures s where s.code = i.code)) order by i.attribue_le desc nulls last, i.code) from public.invitations i), '[]'::jsonb),
    'moderateurs', coalesce((select jsonb_agg(jsonb_build_object('user_id', m.user_id, 'nom', m.nom, 'role', m.role, 'email', u.email, 'ajoute_le', m.ajoute_le, 'mdp_change_le', m.mdp_change_le, 'derniere_connexion', u.last_sign_in_at) order by m.ajoute_le)
                      from public.moderateurs m join auth.users u on u.id = m.user_id), '[]'::jsonb),
    'autorises',   coalesce((select jsonb_agg(jsonb_build_object('email', a.email, 'nom', a.nom, 'role', a.role, 'ajoute_le', a.ajoute_le, 'expire_le', a.expire_le) order by a.ajoute_le desc) from public.moderateurs_autorises a), '[]'::jsonb),
    'orphelins',   coalesce((select jsonb_agg(jsonb_build_object('user_id', u.id, 'email', u.email, 'cree_le', u.created_at, 'derniere_connexion', u.last_sign_in_at) order by u.created_at desc)
                      from auth.users u where not exists (select 1 from public.moderateurs m where m.user_id = u.id)), '[]'::jsonb)
  );
end $$;
revoke execute on function public.admin_acces_lire() from public, anon;
grant  execute on function public.admin_acces_lire() to authenticated;

-- Contrôle : comptes Auth sans droits
select u.email, u.created_at, u.last_sign_in_at from auth.users u where not exists (select 1 from public.moderateurs m where m.user_id = u.id);
