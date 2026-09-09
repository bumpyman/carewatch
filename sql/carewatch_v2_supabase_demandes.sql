-- =============================================================================
-- CareWatch · Demandes d'invitation
-- Une personne demande un accès depuis la porte d'entrée ; un·e admin approuve
-- dans « Accès et comptes », ce qui crée un code d'invitation, renvoyé au
-- navigateur pour l'envoi par courriel (api/notifier.php, mode « invitation »).
-- À coller dans SQL Editor puis Run. Ré-exécutable sans risque.
-- Prérequis : patch_complet (quotas), invitations_nda (table invitations), acces_3 (cw_est_admin).
-- =============================================================================

create table if not exists public.demandes_invitation (
  id           uuid primary key default gen_random_uuid(),
  cree_le      timestamptz not null default now(),
  email        text not null,
  nom          text,
  organisation text,
  message      text,
  statut       text not null default 'en_attente' check (statut in ('en_attente', 'approuvee', 'refusee')),
  code         text,
  traite_le    timestamptz,
  traite_par   uuid
);
create index if not exists demandes_invitation_statut_idx on public.demandes_invitation (statut, cree_le desc);
alter table public.demandes_invitation enable row level security;
revoke all on public.demandes_invitation from public, anon, authenticated;

-- 1. Dépôt d'une demande (public, anonyme) : quota par connexion, une demande en attente par adresse
create or replace function public.demander_invitation(p_email text, p_nom text default null, p_organisation text default null, p_message text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_emp   text := public.cw_empreinte_client();
  v_email text := lower(trim(coalesce(p_email, '')));
begin
  perform public.cw_controler_quota('ip:demande:' || v_emp, 3, interval '24 hours');
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or length(v_email) > 200 then
    return jsonb_build_object('ok', false, 'erreur', 'Adresse e-mail invalide');
  end if;
  if exists (select 1 from public.demandes_invitation where email = v_email and statut = 'en_attente') then
    return jsonb_build_object('ok', true, 'deja', true);
  end if;
  insert into public.demandes_invitation (email, nom, organisation, message)
  values (v_email, nullif(left(trim(coalesce(p_nom, '')), 120), ''), nullif(left(trim(coalesce(p_organisation, '')), 120), ''), nullif(left(trim(coalesce(p_message, '')), 500), ''));
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function public.demander_invitation(text, text, text, text) from public;
grant execute on function public.demander_invitation(text, text, text, text) to anon, authenticated;

-- 2. Lecture par les admins : en attente d'abord, puis les 50 dernières décisions
create or replace function public.admin_demandes_lire()
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  if not public.cw_est_admin() then raise exception 'Accès refusé' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(to_jsonb(d) order by (d.statut = 'en_attente') desc, d.cree_le desc)
    from (
      select id, cree_le, email, nom, organisation, message, statut, code, traite_le
      from public.demandes_invitation
      where statut = 'en_attente'
      union all
      (select id, cree_le, email, nom, organisation, message, statut, code, traite_le
       from public.demandes_invitation where statut <> 'en_attente' order by traite_le desc limit 50)
    ) d
  ), '[]'::jsonb);
end $$;
revoke execute on function public.admin_demandes_lire() from public, anon;
grant execute on function public.admin_demandes_lire() to authenticated;

-- 3. Décision : approuver crée le code d'invitation (même format que les codes manuels) et le renvoie
create or replace function public.admin_demande_traiter(p_id uuid, p_decision text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_d    public.demandes_invitation%rowtype;
  v_code text;
begin
  if not public.cw_est_admin() then raise exception 'Accès refusé' using errcode = '42501'; end if;
  select * into v_d from public.demandes_invitation where id = p_id for update;
  if v_d.id is null then return jsonb_build_object('ok', false, 'erreur', 'Demande introuvable'); end if;
  if v_d.statut <> 'en_attente' then return jsonb_build_object('ok', false, 'erreur', 'Demande déjà traitée'); end if;

  if p_decision = 'approuver' then
    loop
      v_code := 'cw-' || (select string_agg(substr('abcdefghjkmnpqrstuvwxyz23456789', 1 + floor(random() * 31)::int, 1), '') from generate_series(1, 4));
      exit when not exists (select 1 from public.invitations where code = v_code);
    end loop;
    insert into public.invitations (code, attribue_a, email, attribue_le) values (v_code, coalesce(v_d.nom, v_d.email), v_d.email, current_date);
    update public.demandes_invitation set statut = 'approuvee', code = v_code, traite_le = now(), traite_par = auth.uid() where id = p_id;
    return jsonb_build_object('ok', true, 'code', v_code, 'email', v_d.email, 'nom', v_d.nom);
  elsif p_decision = 'refuser' then
    update public.demandes_invitation set statut = 'refusee', traite_le = now(), traite_par = auth.uid() where id = p_id;
    return jsonb_build_object('ok', true);
  end if;
  return jsonb_build_object('ok', false, 'erreur', 'Décision inconnue');
end $$;
revoke execute on function public.admin_demande_traiter(uuid, text) from public, anon;
grant execute on function public.admin_demande_traiter(uuid, text) to authenticated;
