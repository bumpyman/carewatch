-- =============================================================================
-- CareWatch · Questions et réponses publiques
-- Toute personne pose une question anonyme ; l'équipe répond et publie la paire
-- question-réponse, réécrite si besoin pour ne rien contenir d'identifiant.
-- Inspiré de violencequefaire.ch (« Poser une question »).
-- À coller dans SQL Editor puis Run. Ré-exécutable sans risque.
-- Prérequis : patch_complet (quotas), moderation (cw_est_moderateur).
-- =============================================================================

create table if not exists public.questions_publiques (
  id          uuid primary key default gen_random_uuid(),
  cree_le     timestamptz not null default now(),
  profil      text check (profil in ('patient', 'proche', 'professionnel', 'autre')),
  question    text not null,
  reponse     text,
  repondu_le  timestamptz,
  repondu_par uuid,
  publie      boolean not null default false,
  archive     boolean not null default false
);
create index if not exists questions_publiques_publie_idx on public.questions_publiques (publie, repondu_le desc);
alter table public.questions_publiques enable row level security;
revoke all on public.questions_publiques from public, anon, authenticated;

-- 1. Poser une question (public, anonyme) : 3 par jour et par connexion, 1000 caractères au plus
create or replace function public.poser_question(p_question text, p_profil text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_emp text := public.cw_empreinte_client();
  v_q   text := trim(coalesce(p_question, ''));
begin
  perform public.cw_controler_quota('ip:question:' || coalesce(v_emp, 'x'), 3, interval '24 hours');
  if length(v_q) < 15 then return jsonb_build_object('ok', false, 'erreur', 'Question trop courte'); end if;
  if length(v_q) > 1000 then return jsonb_build_object('ok', false, 'erreur', 'Question trop longue (1000 caractères au plus)'); end if;
  insert into public.questions_publiques (question, profil)
  values (v_q, case when p_profil in ('patient', 'proche', 'professionnel', 'autre') then p_profil end);
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function public.poser_question(text, text) from public;
grant execute on function public.poser_question(text, text) to anon, authenticated;

-- 2. Questions publiées (public) : réponse et date, sans aucune donnée technique
create or replace function public.questions_publiees()
returns jsonb language sql stable security definer set search_path = public, extensions as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'question', question, 'reponse', reponse, 'profil', profil, 'repondu_le', to_char(repondu_le, 'YYYY-MM-DD')) order by repondu_le desc), '[]'::jsonb)
  from public.questions_publiques where publie and not archive and reponse is not null;
$$;
revoke execute on function public.questions_publiees() from public;
grant execute on function public.questions_publiees() to anon, authenticated;

-- 3. Équipe : lecture de tout, réponse, publication, archivage
create or replace function public.admin_questions_lire()
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  if not public.cw_est_moderateur() then raise exception 'Accès refusé' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(to_jsonb(q) - 'repondu_par' order by (q.reponse is null) desc, q.cree_le desc) from public.questions_publiques q where not q.archive), '[]'::jsonb);
end $$;
revoke execute on function public.admin_questions_lire() from public, anon;
grant  execute on function public.admin_questions_lire() to authenticated;

create or replace function public.admin_question_ecrire(p_id uuid, p_op text, p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  if not public.cw_est_moderateur() then raise exception 'Accès refusé' using errcode = '42501'; end if;
  if p_op = 'repondre' then
    if length(trim(coalesce(p->>'reponse', ''))) < 10 then raise exception 'Réponse trop courte'; end if;
    update public.questions_publiques
       set reponse = trim(p->>'reponse'), question = coalesce(nullif(trim(p->>'question'), ''), question),
           repondu_le = now(), repondu_par = auth.uid(), publie = coalesce((p->>'publie')::boolean, publie)
     where id = p_id;
  elsif p_op = 'publier' then
    update public.questions_publiques set publie = coalesce((p->>'publie')::boolean, true) where id = p_id and reponse is not null;
  elsif p_op = 'archiver' then
    update public.questions_publiques set archive = true, publie = false where id = p_id;
  else
    raise exception 'Opération inconnue';
  end if;
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function public.admin_question_ecrire(uuid, text, jsonb) from public, anon;
grant  execute on function public.admin_question_ecrire(uuid, text, jsonb) to authenticated;
