-- CareWatch v2.0 : remise à zéro des témoignages de test (Supabase > SQL Editor)
-- ATTENTION : irréversible.
--
--   Efface   : tous les témoignages (signalements et retours positifs), leur journal,
--              les compteurs anti-abus. Repart au numéro CW-AAAA-00001.
--   Conserve : les codes d'invitation et leurs attributions, les accords de confidentialité signés,
--              les comptes de modération, les comptes Supabase Auth, les fonctions, les vues,
--              le sel du mécanisme anti-abus (cw_config).
--
--   Les fiches publiques (vue recits_publics) et les compteurs du site se vident d'eux-mêmes,
--   puisqu'ils lisent la table recits.

begin;

select 'avant' as etape,
       (select count(*) from public.recits)         as recits,
       (select count(*) from public.recits_journal) as journal,
       (select count(*) from public.cw_quota)       as quotas,
       (select count(*) from public.nda_signatures) as accords_conserves,
       (select count(*) from public.invitations)    as invitations_conservees;

truncate table public.recits_journal, public.recits, public.cw_quota;
alter sequence public.recit_numero_seq restart with 1;

-- Option, normalement inutile : effacer aussi les accords de confidentialité signés.
-- À n'activer que si l'accord change de version et doit être signé à nouveau par tout le monde.
-- truncate table public.nda_signatures;

commit;

-- Contrôle : recits = 0, journal = 0, quotas = 0, prochain_numero = 1 ; accords et invitations inchangés
select
  (select count(*) from public.recits)         as recits,
  (select count(*) from public.recits_journal) as journal,
  (select count(*) from public.cw_quota)       as quotas,
  (select case when is_called then last_value + 1 else last_value end
     from public.recit_numero_seq)             as prochain_numero,
  (select count(*) from public.nda_signatures) as accords_conserves,
  (select count(*) from public.invitations)    as invitations_conservees;
