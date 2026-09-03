# CareWatch

**Observatoire participatif de l'équité des soins en Suisse romande.**

[![Licence: AGPL-3.0](https://img.shields.io/badge/Licence-AGPL--3.0-blue.svg)](https://www.gnu.org/licenses/agpl-3.0)
[![DOI](https://zenodo.org/badge/DOI/10.5281/zenodo.22284894.svg)](https://doi.org/10.5281/zenodo.22284894)
[![Hébergement](https://img.shields.io/badge/Hébergement-Suisse-red.svg)](https://carewat.ch)

CareWatch rend visible l'écart entre les droits formels des patientes et des patients et leur expérience vécue, avec une attention particulière aux personnes exposées à des vulnérabilités structurelles. La plateforme recueille et mesure les expériences d'inéquité et de discrimination dans les soins, aide chaque personne à comprendre ses droits et à accéder aux soins adaptés, et restitue des indicateurs agrégés aux institutions et aux autorités sanitaires pour soutenir l'amélioration de la qualité des prestations médicales.

Prototype en ligne : [carewat.ch](https://carewat.ch)

---

## Structure du projet

À la suite de la procédure d'évaluation de la Commission fédérale pour la qualité, CareWatch se développe en quatre volets indépendants. Deux d'entre eux font l'objet d'un Projet de Développement sur Mandat de la filière Informatique de gestion de la HEG-Genève, confiés à deux équipes étudiantes distinctes.

| Volet | Objet | Financement visé | Dépôt de code |
|---|---|---|---|
| **Volet 1, Observatoire** | Recueil, qualification et mesure des expériences, restitution aux institutions et aux autorités | Commission fédérale pour la qualité | `carewatch-observatoire` |
| **Volet 2, Navigation** | Accès aux soins, information sur les droits, orientation et accompagnement | Fondation Leenaards | `carewatch-navigation` |
| Volet 3, Personnel de santé | Expérience du personnel, pair-aidance, formations | Mandat cantonal, HUG | Déjà prototypé dans l'alpha |
| Volet 4, Inégalités et iniquités | Observation des inégalités de santé | Mandat cantonal, Direction de la santé | Prototype à carewat.ch/sage |

Les deux volets étudiants sont **autonomes** : dépôts séparés, déploiements séparés, recettes séparées. Ils communiquent uniquement par des interfaces publiques en lecture seule, décrites dans la section « Socle commun et contrat d'interfaces » de chaque cahier des charges.

Les Volets 3 et 4 correspondent à des fonctionnalités **déjà présentes dans la version alpha** et sont opérés comme des mandats cantonaux par l'équipe du projet, sur la plateforme industrialisée par les Volets 1 et 2. Les Volets 1 et 2, décrits dans les cahiers des charges ci-dessous, sont les deux Projets de Développement sur Mandat confiés aux équipes étudiantes.

### Cahiers des charges

Les spécifications complètes se trouvent dans `docs/` :

- `docs/CW-CDC-V1-OBS-2026.docx` — Volet 1, Observatoire de l'équité
- `docs/CW-CDC-V2-NAV-2026.docx` — Volet 2, Navigation dans les soins

Chaque cahier des charges est autoportant et définit les objectifs, le périmètre, les parties prenantes, les exigences fonctionnelles et non fonctionnelles priorisées selon la méthode MoSCoW, les contraintes d'architecture et les livrables.

---

## État actuel

Le prototype accessible à [carewat.ch](https://carewat.ch) est une version 2.0 à accès protégé par code d'invitation. Il réunit quatre portails, patient, professionnel, modules partagés et administration, et sert de **référence fonctionnelle**. Il est construit comme une application à interface React, avec une persistance des signalements sur une base de données PostgreSQL hébergée en Suisse.

Deux portails prototypes complètent l'alpha : **SaGe**, portail d'observation des inégalités du Volet 4, à [carewat.ch/sage](https://www.carewat.ch/sage), et la base de référence des politiques publiques, à [carewat.ch/policy](https://carewat.ch/policy).

Chaque équipe s'inspire directement de l'alpha pour son volet : l'équipe Observatoire y retrouve le signalement, la qualification et les tableaux de bord ; l'équipe Navigation y retrouve l'accès aux soins, les annuaires et les guides. Le prototype démontre l'intention et les parcours attendus, il sert de **source d'inspiration fonctionnelle**. Le mandat construit ensuite la version industrielle, maintenable et déployable. Le code du prototype ne constitue pas une base de code à reprendre telle quelle.

---

## Pour les équipes étudiantes

### Choix de la pile technologique

Le choix de la pile appartient à chaque équipe, dans le respect des contraintes d'architecture. Ce choix est un livrable évalué, la fiche de décision d'architecture initiale, défendue devant les mandants en revue de conception. Trois piles candidates sont documentées dans le cahier des charges, Java avec Spring Boot, Python avec Django, ou TypeScript avec NestJS ou Next.js, toutes avec une interface React et une base de données PostgreSQL.

### Invariants d'architecture

Quelle que soit la pile retenue, l'application respecte neuf contraintes qui garantissent la simplicité et la maintenabilité :

1. Monolithe modulaire, sans microservices.
2. Quatre couches nettes, présentation, interface de programmation, domaine métier, persistance, avec dépendances pointant vers le domaine.
3. Contrat d'interface au standard OpenAPI, écrit avant le code et opposable.
4. PostgreSQL comme unique source de vérité, migrations versionnées.
5. Configuration externalisée, aucun secret dans le code, exécution en conteneur.
6. Chaîne de qualité, revue par les pairs et intégration continue à chaque modification.
7. Décisions structurantes tracées dans un registre de décisions d'architecture.
8. Simplicité défendable, toute dépendance ajoutée se justifie en revue.
9. Licence libre et neutralité, code sous AGPL-3.0.

### Organisation recommandée du dépôt

```
carewatch/                  dépôt ombrelle (ce dépôt)
├── README.md
├── CITATION.cff            métadonnées de citation
├── .zenodo.json           métadonnées d'archivage Zenodo
├── LICENSE                 AGPL-3.0
├── docs/                   cahiers des charges et architecture
│   ├── CW-CDC-V1-OBS-2026.docx
│   └── CW-CDC-V2-NAV-2026.docx
└── prototype/             code du prototype carewat.ch (référence)

carewatch-observatoire/     dépôt du Volet 1 (équipe 1)
carewatch-navigation/       dépôt du Volet 2 (équipe 2)
```

Chaque équipe travaille dans son propre dépôt. Le dépôt ombrelle rassemble la documentation commune et le prototype de référence.

---

## Contribution

Le travail se fait à travers les comptes GitHub des membres de chaque équipe.

1. Chaque membre travaille sur une branche dédiée par fonctionnalité, nommée d'après l'identifiant de l'exigence, par exemple `feat/EF-10-signalement`.
2. Toute modification passe par une pull request, relue par au moins un autre membre et par le mandant ou un mentor.
3. L'intégration continue exécute les tests unitaires, d'intégration et d'accessibilité à chaque pull request. Une pull request ne fusionne qu'avec une chaîne verte.
4. Chaque décision structurante fait l'objet d'une fiche numérotée dans `docs/adr/`.
5. Les messages de commit décrivent l'intention et référencent l'exigence concernée.

Le développement se fait exclusivement sur des **données fictives**. Aucune donnée personnelle réelle ne figure dans le dépôt.

---

## Protection des données

CareWatch traite des données sensibles de santé et applique la nouvelle Loi fédérale sur la protection des données, en vigueur depuis le 1er septembre 2023.

- Hébergement exclusivement en Suisse.
- Chiffrement en transit et au repos, secrets hors du code.
- Minimisation, pseudonymisation et agrégation à seuil pour les restitutions.
- Analyse d'impact relative à la protection des données finalisée avant toute mise en production.

---

## Gouvernance et partenaires

CareWatch place les patientes et les patients au centre, dans une approche de recherche-action participative, avec un code sous licence libre.

- **Mandant** : Convivens Lab, Haute école de gestion de Genève (HES-SO), Dr David-Zacharie Issom.
- **Partenaire technologique** : KimboCare SA (Franck Eric Tiambo).
- **Conseil médical** : Dr Brock Chamberlain, médecin-entrepreneur, et autres membres.
- **Partenaires** : Unisanté (Département vulnérabilités et médecine sociale, Prof. Patrick Bodenmann, Dr Rainer Tan), Hôpitaux universitaires de Genève (Pôle diversité, équité et inclusion, laboratoire evalab), Association de Professionnels de Santé Racisés, Association Suisse Drépano, Fédération des Associations d'Afrodescendant.e.x.s de Genève en Suisse, Fondation PROFA intégrant le Centre de consultation d'aide aux victimes.

---

## Comment citer

Ce dépôt est archivé sur Zenodo avec un identifiant permanent (DOI). Le DOI concept ci-dessous pointe toujours vers la dernière version publiée ; la version citée est la première release, v0.4.1-alpha, publiée le 3 septembre 2026.

> Issom, D.-Z. (2026). *CareWatch : observatoire participatif de l'équité des soins en Suisse romande* (v0.4.1-alpha). Zenodo. https://doi.org/10.5281/zenodo.22284894

[![DOI](https://zenodo.org/badge/DOI/10.5281/zenodo.22284894.svg)](https://doi.org/10.5281/zenodo.22284894)

Le fichier `CITATION.cff` alimente le bouton « Cite this repository » de GitHub et la notice Zenodo.

---

## Licence

Code publié sous licence **GNU Affero General Public License version 3** (AGPL-3.0-or-later). Voir le fichier `LICENSE`. Toute contribution est acceptée sous cette même licence.

---

## Contact

Convivens Lab, Haute école de gestion de Genève (HES-SO)
Dr David-Zacharie Issom — [carewat.ch](https://carewat.ch)
Code source — [github.com/bumpyman/carewatch](https://github.com/bumpyman/carewatch)
