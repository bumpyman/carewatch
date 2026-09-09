-- =============================================================================
-- CareWatch · Veille automatique : entrées masquées par l'équipe
-- Les articles eux-mêmes viennent de api/actualites.php (flux RSS, cache 6 h).
-- Ici, seulement la liste des liens qu'un·e modérateur·rice a choisi de masquer.
-- À coller dans SQL Editor puis Run. Ré-exécutable sans risque.
-- =============================================================================

create table if not exists public.veille_masquee (
  url       text primary key,
  masque_le timestamptz not null default now(),
  par       uuid
);
alter table public.veille_masquee enable row level security;
-- aucune politique : les tables restent fermées, tout passe par les fonctions ci-dessous

-- Liste publique des liens masqués (le navigateur filtre le flux avec)
create or replace function public.veille_masquee_liste()
returns jsonb language sql security definer set search_path = public, extensions as $$
  select coalesce(jsonb_agg(url order by masque_le desc), '[]'::jsonb) from public.veille_masquee;
$$;
revoke execute on function public.veille_masquee_liste() from public;
grant execute on function public.veille_masquee_liste() to anon, authenticated;

-- Masquer ou réafficher un lien : modérateur·rice·s connecté·e·s (second facteur exigé)
create or replace function public.admin_veille_masquer(p_url text, p_masquer boolean)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  if not public.cw_est_moderateur() then
    raise exception 'Accès réservé à l’équipe de modération';
  end if;
  if p_url is null or length(p_url) < 8 then
    raise exception 'Lien invalide';
  end if;
  if p_masquer then
    insert into public.veille_masquee (url, par) values (p_url, auth.uid()) on conflict (url) do nothing;
  else
    delete from public.veille_masquee where url = p_url;
  end if;
  return public.veille_masquee_liste();
end;
$$;
revoke execute on function public.admin_veille_masquer(text, boolean) from public, anon;
grant execute on function public.admin_veille_masquer(text, boolean) to authenticated;
