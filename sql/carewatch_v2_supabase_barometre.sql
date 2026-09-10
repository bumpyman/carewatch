-- =============================================================================
-- CareWatch · Baromètre d'expérience patient
-- Mesure systématique de l'expérience de traitement (échelle DMS, 7 questions),
-- avec ou sans incident, sans récit. Répond à la critique de la CFQ (2026) :
-- « un système de signalement de cas, pas un monitorage systématique ».
-- À coller dans SQL Editor puis Run. Ré-exécutable sans risque.
-- Prérequis : patch_complet (soumettre_recit), moderation_2 (stats_publiques).
-- =============================================================================

-- 1. Dépôt d'une réponse au baromètre : même circuit que soumettre_recit
--    (quotas, numéro, code personnel), type « enquete », vérification automatique
--    puisqu'il n'y a pas de texte libre à relire.
create or replace function public.soumettre_enquete(p jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_res jsonb;
  v_p   jsonb;
begin
  if p is null or pg_column_size(p) > 20000 then
    raise exception 'Requête trop volumineuse';
  end if;
  if coalesce((p->>'dms_max')::int, 0) < 28 or (p->>'dms_score') is null then
    raise exception 'Les sept questions doivent être renseignées';
  end if;
  v_p := (p - 'description' - 'impact' - 'type')
         || jsonb_build_object('type', 'enquete', 'description', 'Baromètre d’expérience patient : réponse sans récit.',
                               'publier_fiche', false, 'lecture_texte_complet', false, 'accepte_recontact_email', false);
  v_res := public.soumettre_recit(v_p);
  update public.recits set statut = 'verifie', modifie_le = now() where numero = v_res->>'numero' and type = 'enquete';
  return v_res;
end $$;
revoke execute on function public.soumettre_enquete(jsonb) from public;
grant execute on function public.soumettre_enquete(jsonb) to anon, authenticated;

-- 2. Statistiques publiques : le ressenti moyen intègre les réponses au baromètre
--    (type « enquete ») en plus des signalements ; compteur « enquetes » ajouté.
drop function if exists public.stats_publiques();
create or replace function public.stats_publiques()
returns jsonb language sql stable security definer set search_path = public, extensions as $$
  with base as (
    select * from public.recits where coalesce(statut, 'soumis') not in ('retire', 'rejete')
  ),
  par_canton as (
    select canton, count(*) as n from base where canton is not null group by canton having count(*) >= 5
  ),
  par_etab as (
    select etablissement_id,
           count(*) filter (where type = 'signalement')                                          as signalements,
           count(*) filter (where type = 'positif')                                              as positifs,
           count(*) filter (where type = 'enquete')                                              as enquetes,
           count(*) filter (where statut in ('verifie', 'publie'))                               as verifies,
           count(*) filter (where statut in ('verifie', 'publie') and type = 'positif')          as positifs_verifies,
           avg(dms_score::numeric / nullif(dms_max, 0))
             filter (where statut in ('verifie', 'publie') and type in ('signalement', 'enquete') and dms_max > 0) as ressenti
    from base where etablissement_id is not null
    group by etablissement_id
  ),
  evalue as (
    select *,
           case when verifies >= 5 then
             round(70 * (1 - coalesce(ressenti, 0)) + 30 * (positifs_verifies::numeric / verifies))
           end as indice
    from par_etab
  )
  select jsonb_build_object(
    'methode', 'indice = 70 × (1 − ressenti moyen) + 30 × part des retours positifs, sur témoignages vérifiés (signalements, baromètre, retours positifs), dès 5 témoignages vérifiés',
    'par_etablissement', coalesce((select jsonb_object_agg(etablissement_id, jsonb_build_object(
        'signalements', signalements, 'positifs', positifs, 'enquetes', enquetes, 'verifies', verifies,
        'ressenti', case when verifies >= 5 then round(coalesce(ressenti, 0), 2) end,
        'indice', indice,
        'niveau', case when indice is null then null
                       when indice >= 75 then 'outstanding'
                       when indice >= 50 then 'good'
                       when indice >= 25 then 'requires_improvement'
                       else 'inadequate' end
      )) from evalue), '{}'::jsonb),
    'recus',          (select count(*) from base),
    'verifies',       (select count(*) from base where statut in ('verifie', 'publie')),
    'signalements',   (select count(*) from base where type = 'signalement'),
    'positifs',       (select count(*) from base where type = 'positif'),
    'enquetes',       (select count(*) from base where type = 'enquete'),
    'etablissements', (select count(distinct etablissement_id) from base where etablissement_id is not null),
    'cantons',        (select count(distinct canton) from base where canton is not null),
    'par_canton',     coalesce((select jsonb_object_agg(canton, n) from par_canton), '{}'::jsonb),
    'premier_le',     (select to_char(min(cree_le), 'YYYY-MM-DD') from base),
    'calcule_le',     to_char(now(), 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
  );
$$;
grant execute on function public.stats_publiques() to anon, authenticated;

-- Contrôle
select public.stats_publiques() -> 'enquetes' as enquetes;
