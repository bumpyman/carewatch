# CareWatch

Observatoire participatif de l'équité des soins en Suisse romande. Version 0.4.1-alpha, alpha fermée sur invitation.

Site : https://carewat.ch

## Contenu du dépôt

| Dossier ou fichier | Rôle |
|---|---|
| `carewat.ch/` | Racine web déployée sur Infomaniak. `index.html` contient toute l'application (React 18 compilé dans le navigateur par Babel). `vendor/` : React, Babel, Tailwind purgé. |
| `carewat.ch/api/notifier.php` | Envoi des e-mails (accusés de réception, accord de confidentialité, codes d'accès) par SMTP Infomaniak. La configuration avec le mot de passe est déposée hors du dossier web et n'est pas dans ce dépôt. |
| `sql/` | Schéma, fonctions et politiques Supabase, à exécuter dans l'ordre indiqué ci-dessous. |
| `infomaniak/` | Modèle de configuration SMTP (sans identifiants). |
| `docs/` | Documents de cadrage (demande de clarification aux commissions d'éthique). |

## Architecture

- Front : un seul fichier `index.html`, sans étape de build. Les classes Tailwind sont purgées : toute nouvelle classe doit exister dans `vendor/tailwind.css` ou passer par un style en ligne.
- Base : Supabase (PostgreSQL, région Zurich). Le navigateur n'accède qu'à des fonctions `security definer` exposées par PostgREST ; les tables sont fermées au rôle anonyme. Quotas anti-abus par empreinte salée d'adresse IP, 24 h.
- Comptes d'administration : Supabase Auth, mot de passe et second facteur TOTP obligatoires, contrôle du niveau `aal2` côté base.
- Données ouvertes : uniquement les témoignages vérifiés, dé-identifiés, agrégés par établissement avec un seuil minimal de 5 témoignages.

## Installation

1. Créer un projet Supabase et exécuter dans l'éditeur SQL, dans cet ordre : `carewatch_v2_supabase_patch_complet.sql`, `moderation.sql`, `moderation_2.sql`, `opendata.sql`, `referentiels_schema.sql`, `referentiels_donnees.sql`, `acces_2.sql`, `acces_3.sql`. Les fichiers d'invitations (codes et noms des testeurs) ne sont pas publiés.
2. Reporter l'URL du projet et la clé `anon` dans `index.html` (constantes en tête du script).
3. Copier `infomaniak/carewatch_smtp.example.php` en `carewatch_smtp.php`, le compléter et le déposer hors du dossier web, au chemin indiqué dans `api/notifier.php`.
4. Déposer le contenu de `carewat.ch/` à la racine du site.
5. Dans Supabase Auth : inscriptions activées, modèles « Magic Link » et « Reset Password » contenant `{{ .Token }}`, URL du site `https://carewat.ch/?m=moderation`.

## Comptes de démonstration

L'e-mail `admin@carewat.ch` avec le mot de passe `admin1234` ouvre une interface de démonstration alimentée par des données fictives. Tout autre compte administrateur passe par la connexion réelle.

## Licence et citation

Code sous licence AGPL-3.0-or-later. Voir `CITATION.cff` pour citer le dépôt.
