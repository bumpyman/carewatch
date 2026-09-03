-- ============================================================================
-- CareWatch v2.0 : vue publique des fiches résumées (données ouvertes)
-- À exécuter une fois, après moderation_2.sql. Idempotent.
--
-- Une fiche n'est visible que si : publier_fiche = true (case cochée par la personne)
--                              ET statut = 'publie' (décision de la modération).
-- Aucun récit, aucune date précise, aucun identifiant de personne.
-- ============================================================================
drop view if exists public.recits_publics;
create view public.recits_publics as
  select numero, type, to_char(cree_le, 'YYYY') as annee, tranche_age, canton,
         etablissement_nom, service, type_incident, categories_positives, dms_score, dms_max
  from public.recits
  where publier_fiche = true and statut = 'publie';
grant select on public.recits_publics to anon, authenticated;

-- Contrôle
select count(*) as fiches_publiees from public.recits_publics;
