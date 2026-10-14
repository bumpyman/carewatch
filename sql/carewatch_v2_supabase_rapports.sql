-- ============================================================================
-- CareWatch v2.0 : page « Rapports », lecture par trimestre des fiches publiques
-- À exécuter une fois, après etablissements.sql. Idempotent.
--
-- La vue recits_publics gagne une colonne « trimestre » (format 2026-T3), dérivée de la
-- date de dépôt. La page Rapports lit cette colonne quand elle existe et retombe sur
-- « annee » sinon : le fichier est donc facultatif. Granularité publiée : le trimestre,
-- sans date précise, dans la continuité de la règle des fiches résumées.
-- ============================================================================
drop view if exists public.recits_publics;
create view public.recits_publics as
  select r.numero, r.type,
         to_char(r.cree_le, 'YYYY') as annee,
         to_char(r.cree_le, 'YYYY-"T"Q') as trimestre,
         r.tranche_age, r.canton,
         r.etablissement_nom, r.service, r.type_incident, r.categories_positives, r.dms_score, r.dms_max,
         rep.texte as reponse_etablissement, to_char(rep.cree_le, 'YYYY-MM') as reponse_mois
  from public.recits r
  left join public.reponses_etablissement rep on rep.numero = r.numero
  where r.publier_fiche = true and r.statut = 'publie';
grant select on public.recits_publics to anon, authenticated;

-- Contrôle
select trimestre, count(*) as fiches from public.recits_publics group by trimestre order by trimestre;
