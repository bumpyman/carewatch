# Audit des textes CareWatch

Portée : `carewat.ch/index.html`, `carewat.ch/seuils/index.html`, `carewat.ch/policy/index.html`, `docs/Grille_maturite_equite_CareWatch.md`.
Aucune logique, aucun seuil réel, aucun calcul (SQL, note) n'a été modifié. Seuls des textes et titres.
Le site est servi tel quel : JSX compilé dans le navigateur par `vendor/babel.min.js` (balise `text/babel`). La syntaxe a été validée hors ligne avec ce même Babel.

## 1. Textes supprimés (règles de publication hors Méthodologie)

Les seuils (3 et 5), l'agrégation et l'anonymisation restent dits sur les pages Méthodologie, Confidentialité, Données ouvertes et FAQ.

| Où | Avant | Après | Raison |
|---|---|---|---|
| Questionnaire rapide, exemple (graphique) | « 0 % jamais, 100 % toujours, sur l'échelle DMS. Avec de vraies données, ce détail par service apparaît dès cinq témoignages vérifiés pour l'établissement, et trois par service. » | « 0 % : jamais vécue. 100 % : toujours vécue. » | Note de seuil sous un graphique |
| Questionnaire rapide, exemple | « Le pourcentage est le ressenti moyen ... dès cinq témoignages vérifiés par établissement. » | idem (même phrase courte) | idem |
| Fiche établissement | « Indice d'équité : 70 % ressenti de traitement (échelle DMS), 30 % ..., publié dès cinq. » | « Note d'équité de 0 à 100, calculée sur les témoignages vérifiés. » + lien Méthodologie | Formule et seuil déplacés vers Méthodologie |
| Liste des établissements | « Indice publié dès 5 témoignages vérifiés » | « Pas encore de note » | Seuil |
| Niveaux (`no_data`) | « Indice calculé automatiquement dès 5 témoignages vérifiés par la modération » | « Pas assez de témoignages vérifiés pour calculer une note » | Seuil |
| Questionnaire rapide, fin du formulaire | « Vos réponses rejoignent la note d'équité ..., sans texte libre. Vous recevrez ... » | « Vous recevrez un numéro et un code personnel pour retirer votre réponse. » | Un message par bloc |
| Questionnaire rapide, confirmation | « ... dès que cinq témoignages vérifiés le concernent. » | « Elle compte dans la note d'équité de l'établissement. » | Seuil |
| Tableau de bord établissement | « agrégés par service, par motif et par mois. Les cellules de moins de trois témoignages sont masquées ; les textes libres restent dans la base. » | « Témoignages vérifiés de votre établissement, par service, par motif et par mois. Les récits ne sont pas montrés. » | Note technique de seuil |
| Tableau de bord, cellule masquée | « moins de 3 » | « masqué » | Seuil visible dans le tableau |
| Accueil (méthode) | « Un indice d'équité de 0 à 100 par établissement, publié dès 5 témoignages vérifiés. » | « Une note d'équité de 0 à 100 par établissement. » | Seuil |
| Accueil (mission) | « ... publié seulement au-delà d'un seuil minimal. » | « Une note d'équité par établissement, calculée sur des témoignages vérifiés. » | Seuil |
| État du projet | « Calcul en base, publié dès 5 témoignages vérifiés » ; « Publication seulement sous forme agrégée dès cinq témoignages vérifiés ... » ; « publié dès cinq témoignages » | Formules sans seuil ; renvoi vers Méthodologie | Seuil |
| Maturité | « indice publié dès 5 » | « note pas encore publiée » | Seuil |
| Questionnaires du signalement (étape 7) | « ... permettent de calculer un score d'équité comparable entre établissements. » | « Vos réponses sont anonymes. » | Superflu |
| Bandeau d'essai | « Les signalements que vous envoyez sont réels et enregistrés · Les évaluations, chiffres et annuaire affichés sont des données de démonstration » | « Vos signalements sont réels et enregistrés. Les notes, chiffres et annuaire sont fictifs. » | Plus court |
| Compteurs | « Chiffres réels, l'observatoire démarre, les compteurs se rempliront ... » | « Chiffres réels. Les compteurs se remplissent au fil des témoignages. » | Plus court |

La phrase « Comprendre, être écouté·e, décider ensemble : moyenne de trois questions ... » et « Publié dès cinq témoignages vérifiés par établissement. » n'existent pas dans la branche `claude/jolly-ride-mk9dio` ni dans `main` (recherche dans tout le dépôt). Elles viennent sans doute d'une version non fusionnée (branche `claude/fervent-brahmagupta-41jjiq`, « Rapports ... »). À supprimer lors de la fusion de cette branche.

## 2. Renommages (cohérence dans tout le site)

| Avant | Après | Où |
|---|---|---|
| Baromètre d'expérience, Baromètre, le baromètre | Questionnaire rapide | menu, titre de page, boutons, libellé de type (`cwTypeLibelle`), tableaux de bord, état du projet, méthodologie, FAQ, commentaires |
| `cwTypeLibelle` : « Signalement » | « Signalement de discrimination » | listes et fiches |
| `cwTypeLibelle` / menus : « Expérience positive », « Positif » | « Retour positif » | menus, titres, objet des courriels, listes |
| « Signaler », « Signaler un incident », « Témoigner », « Faire un signalement » | « Signaler une discrimination » | menus, boutons, bouton flottant, accueils, fin de page |
| « Racontez votre expérience » | « Raconter ce qui s'est passé » (profil victime) ; « Raconter ce que vous avez observé » (témoin) | étape 3 du signalement |
| « Partager une bonne expérience » | « Partager un retour positif » | boutons, titre, FAQ |
| Indice d'équité | Note d'équité | tout le site (formule inchangée) |
| Ressenti de discrimination, ressenti DMS, échelle DMS | Discrimination vécue ; « sept questions » | tableaux, graphiques, méthodologie |
| Badge « alpha », « Alpha fermée » (bandeaux, pieds de page, état du projet) | « en test », « Version de test » | bandeaux et badges |
| Observatoire (participatif) | Plateforme participative pour l'équité des soins | accueil, à propos, politique de confidentialité |
| Dé-identifié(e)(s) | Anonymisé(e)(s) | tout le site |
| Données / indicateurs agrégé(e)s | Chiffres d'ensemble | tout le site |
| Stratifiés (rapport annuel) | « par canton et par type d'établissement » | état du projet |
| PREMs de l'ANQ | Enquêtes de satisfaction de l'ANQ | état du projet, méthodologie |
| Impact ressenti | Conséquences pour vous | formulaires |
| Étape « Ressenti » | « Votre vécu » | étapes du signalement |

## 3. Définitions plus claires

| Où | Avant | Après |
|---|---|---|
| Questionnaire rapide, en-tête | « Sept questions sur la façon dont vous avez été traité·e lors d'un épisode de soins, avec ou sans incident. Deux minutes, sans récit, anonyme. » | « Avez-vous été traité·e différemment dans les soins à cause de qui vous êtes ? 7 questions, 2 minutes, anonyme. Pour raconter ce qui s'est passé, choisissez « Signaler une discrimination ». » |
| Accueil patient·e | « Documentez votre expérience, positive ou négative, ... » | « Trois façons d'agir : signaler une discrimination, répondre au questionnaire rapide ou partager un retour positif. » |
| Carte du questionnaire | « Évaluer une expérience de soins en deux minutes » | « Avez-vous été traité·e différemment dans les soins ? 7 questions, 2 minutes, sans récit » |
| Signalement, étape 1 | « Bienvenue sur CareWatch™ » + paragraphe sur les valeurs | « Signaler une discrimination » : on raconte ce qui s'est passé, 5 à 10 minutes ; renvoi vers le questionnaire rapide et le retour positif |
| Accueil, dimensions | « Sept questions de l'échelle DMS (Discrimination in Medical Settings), posées après un incident ou dans le baromètre ... avec ou sans incident. » | « Sept questions pour savoir si vous avez été traité·e différemment dans les soins, dans le signalement ou le questionnaire rapide. » |
| Méthodologie 1 | « Le questionnaire DMS ... mesure 7 dimensions ... » | « Sept questions mesurent la discrimination vécue dans les soins. Elles viennent d'un questionnaire scientifique, le DMS (Discrimination in Medical Settings). » (seul endroit où le sigle est expliqué) |
| Méthodologie 2 | formule avec « ressenti moyen » | « Note (0 à 100) = 70 × (1 − discrimination vécue moyenne) + 30 × part des retours positifs » (calcul identique) |
| Guide juridique | « Questionnaire DMS » | « Les sept questions (DMS) » avec explication d'une ligne |

## 4. Écriture et ton

- Tirets cadratins : 0 restant dans `index.html`, `policy`, `seuils` (environ 340 + 90 + 1 remplacés par virgule, deux-points, point ou « - »). Puces des courriers modèles : « - ». Titres de l'export texte : `== FAITS ==`.
- Phrases raccourcies sur les écrans listés ci-dessus (état du projet, méthodologie, boucle d'amélioration, données). Le reste des pages (guide juridique, FAQ longue, politique de confidentialité) n'a pas été récrit en entier.
- Écriture inclusive : forme `·e·s` conservée, rien d'autre changé.
- Politique `policy/index.html` : « Observatoire participatif » devient « Plateforme participative », menu déroulant « Préréglage ».
- `seuils/index.html` : « observatoire » devient « projet », « Version alpha » devient « Version de test ». Cette page est un autre projet (expériences non ordinaires) : à confirmer qu'elle doit suivre ces règles.
- `docs/Grille_maturite_equite_CareWatch.md` : note au lieu d'indice, DMS expliqué.

## 5. Contrôles

- Compilation : le script `text/babel` d'`index.html` passe avec `vendor/babel.min.js` (avant et après). Les scripts de `policy` et `seuils` passent `new Function`.
- Anciens libellés restants dans le dépôt : uniquement `sql/carewatch_v2_supabase_barometre.sql` et `sql/carewatch_v2_supabase_etablissements.sql` (description stockée en base « Baromètre d'expérience patient : réponse sans récit. » et commentaires). Non modifiés, voir section 6.

## 6. Reste à décider

1. Texte stocké en base (`soumettre_enquete`) : renommer « Baromètre d'expérience patient » en « Questionnaire rapide » demande de rejouer le SQL en production. Touche seulement un texte, mais à valider.
2. Phrase « Comprendre, être écouté·e, décider ensemble ... » et « Publié dès cinq témoignages vérifiés par établissement » : introuvables ici (voir section 1).
3. Textes juridiques et de sécurité conservés tels quels : accord de confidentialité (« version alpha fermée »), politique de confidentialité (phase alpha, 12b), CGU, guide juridique, modèles de courriers. À faire relire par les juristes avant de changer « alpha ».
4. Termes laissés volontairement : « ressenti » dans les formulaires où la personne décrit ses sentiments (« votre ressenti est légitime »), les courriers modèles et l'en-tête CSV `ressenti` (nom de colonne des données ouvertes, à ne pas changer sans version de l'API). « Indice » dans les clés de données (`indice`, `indice_equite`).
5. Les pages longues (FAQ, guide juridique, politique de confidentialité, à propos) ont encore des phrases de plus de 15 mots. Un second passage ligne à ligne est à planifier.
6. Nom du troisième parcours : « Retour positif » (choisi). Alternative : « Bonne expérience ».
7. « Note d'équité » : à confirmer avec l'équipe scientifique, le sigle DMS et le nom « indice » figurant dans des documents externes (CER-VD).
8. Objet des courriels : l'objet change de « Expérience positive » en « Retour positif » ; vérifier les filtres de la boîte de réception.
