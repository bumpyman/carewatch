<?php
/**
 * Configuration SMTP pour api/notifier.php (CareWatch).
 *
 * 1. Copier ce fichier sous le nom  carewatch_smtp.php
 * 2. Remplacer les deux valeurs marquées À COMPLÉTER
 * 3. Le déposer via FTP/SFTP HORS du dossier web, un niveau au-dessus de « sites » :
 *        /home/clients/<votre identifiant>/carewatch_smtp.php
 *    (le dossier web est /home/clients/<votre identifiant>/sites/carewat.ch/)
 *    Ne jamais le mettre dans sites/carewat.ch : il contient un mot de passe.
 *
 * Boîte à utiliser : une vraie boîte mail du domaine carewat.ch (par exemple
 * contact@carewat.ch). Un alias comme no-reply@carewat.ch ne peut pas s'authentifier,
 * mais peut servir d'expéditeur s'il est un alias de la boîte authentifiée.
 * Mot de passe : celui de la boîte, ou mieux un « mot de passe d'application »
 * créé dans Infomaniak > Service Mail > la boîte > Mots de passe d'application.
 */
return [
    'hote'         => 'mail.infomaniak.com',
    'port'         => 465,                      // 465 = TLS direct ; 587 = STARTTLS
    'utilisateur'  => 'no-reply@carewat.ch',     // À COMPLÉTER si autre boîte
    'mot_de_passe' => 'A_COMPLETER',
    'expediteur'   => 'no-reply@carewat.ch',    // alias de la boîte ci-dessus
    'secret_verification' => 'A_COMPLETER',   // clé affichée par sql/carewatch_v2_supabase_etablissements.sql (vérification des adresses professionnelles)
];
