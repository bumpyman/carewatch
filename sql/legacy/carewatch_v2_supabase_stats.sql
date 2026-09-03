-- ============================================================================
-- CareWatch v2.0 : compteurs publics « témoignages reçus / vérifiés »
-- À exécuter une fois dans Supabase > SQL Editor, après patch_complet.sql.
--
-- Cycle de vie d'un signalement (colonne recits.statut) :
--   valeur à l'envoi (voir contrôle ci-dessous, en général 'soumis' ou 'en_moderation')
--   'verifie'  : lu et validé par l'équipe de modération        → compte comme « vérifié »
--   'publie'   : vérifié ET fiche résumée publiée en open data   → compte comme « vérifié »
--   'retire'   : retiré par la personne                          → ne compte plus nulle part
--
-- Pour vérifier un signalement aujourd'hui : Supabase > Table Editor > recits,
-- ouvrir la ligne, mettre statut = 'verifie' (ou 'publie' si publier_fiche = true).
-- Ou en SQL :  update public.recits set statut = 'verifie', modifie_le = now() where numero = 'CW-2026-00001';
-- ============================================================================

-- 0. Contrôle : quelles valeurs de statut existent déjà ?
select statut, count(*) from public.recits group by statut order by 2 desc;

-- 1. Fonction publique : uniquement des agrégats, jamais de récit ni de champ individuel.
--    Seuil de discrétion : les répartitions par canton ne sont renvoyées qu'à partir de 5 témoignages.
--    Une version antérieure (total / publies / par_canton, sans seuil) existe déjà : on la remplace.
drop function if exists public.stats_publiques();
create or replace function public.stats_publiques()
returns jsonb language sql stable security definer set search_path = public, extensions as $$
  with base as (
    select * from public.recits where statut <> 'retire'
  ),
  par_canton as (
    select canton, count(*) as n
    from base
    where canton is not null
    group by canton
    having count(*) >= 5
  )
  select jsonb_build_object(
    'recus',            (select count(*) from base),
    'verifies',         (select count(*) from base where statut in ('verifie', 'publie')),
    'signalements',     (select count(*) from base where type = 'signalement'),
    'positifs',         (select count(*) from base where type = 'positif'),
    'etablissements',   (select count(distinct etablissement_id) from base where etablissement_id is not null),
    'cantons',          (select count(distinct canton) from base where canton is not null),
    'par_canton',       coalesce((select jsonb_object_agg(canton, n) from par_canton), '{}'::jsonb),
    'premier_le',       (select to_char(min(cree_le), 'YYYY-MM-DD') from base),
    'calcule_le',       to_char(now(), 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
  );
$$;

grant execute on function public.stats_publiques() to anon, authenticated;

-- 2. Contrôle : doit renvoyer un objet JSON avec recus, verifies, etc.
select public.stats_publiques();
