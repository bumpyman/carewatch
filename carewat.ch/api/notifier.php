<?php
/**
 * CareWatch : notification par courriel via le SMTP Infomaniak (Suisse).
 * Remplace FormSubmit. Reçoit le même JSON que FormSubmit (_subject + champs),
 * construit un courriel texte et l'envoie à l'équipe.
 *
 * La fonction mail() est désactivée sur l'hébergement, l'envoi passe donc par
 * mail.infomaniak.com avec les identifiants d'une boîte du domaine, lus dans
 * un fichier HORS du dossier web :  /home/clients/<id>/carewatch_smtp.php
 * (modèle : carewatch_smtp.example.php, à copier, compléter et déposer
 *  un niveau au-dessus du dossier « sites »).
 *
 * Test après dépôt :
 *   curl -X POST https://carewat.ch/api/notifier.php -H "Content-Type: application/json" \
 *        -H "Origin: https://carewat.ch" -d '{"_subject":"Test CareWatch","message":"bonjour"}'
 */

ini_set('display_errors', '0');
error_reporting(E_ALL);
header('Content-Type: application/json; charset=utf-8');
header('X-Content-Type-Options: nosniff');

$DESTINATAIRE    = 'contact@carewat.ch';
$ORIGINES_OK     = ['https://carewat.ch', 'https://www.carewat.ch'];
$TAILLE_MAX      = 60000;   // octets de JSON acceptés
$QUOTA_PAR_HEURE = 120;     // envois par heure, tous clients confondus
$FICHIER_CONFIG  = __DIR__ . '/../../../carewatch_smtp.php';

function repondre($code, $ok, $message) {
    http_response_code($code);
    echo json_encode(['success' => $ok ? 'true' : 'false', 'message' => $message], JSON_UNESCAPED_UNICODE);
    exit;
}
// Erreurs PHP : les avertissements sont ignorés (l'envoi continue), les erreurs fatales
// deviennent une réponse JSON avec un détail nettoyé (aucun chemin serveur, aucun secret).
function nettoyer_detail($texte) {
    $texte = preg_replace('#(/[^\s:]+/)+([^\s/:]+)#', '$2', (string) $texte); // chemins → nom de fichier
    return substr(preg_replace('/\s+/', ' ', $texte), 0, 200);
}
set_error_handler(function ($no, $str, $file, $line) {
    if ($no & (E_ERROR | E_USER_ERROR | E_RECOVERABLE_ERROR)) {
        repondre(500, false, 'Erreur interne : ' . nettoyer_detail($str) . ' (ligne ' . $line . ')');
    }
    return true; // avertissement ou notice : on continue
});
set_exception_handler(function ($e) {
    repondre(500, false, 'Erreur interne : ' . nettoyer_detail($e->getMessage()) . ' (' . basename($e->getFile()) . ' ligne ' . $e->getLine() . ')');
});

// 1. Méthode et origine
if ($_SERVER['REQUEST_METHOD'] === 'OPTIONS') {
    header('Access-Control-Allow-Origin: https://carewat.ch');
    header('Access-Control-Allow-Headers: Content-Type');
    exit;
}
if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    repondre(405, false, 'Méthode non autorisée');
}
$origine = isset($_SERVER['HTTP_ORIGIN']) ? $_SERVER['HTTP_ORIGIN'] : '';
$referer = isset($_SERVER['HTTP_REFERER']) ? $_SERVER['HTTP_REFERER'] : '';
$origineOk = false;
foreach ($ORIGINES_OK as $o) {
    if ($origine === $o || strpos($referer, $o . '/') === 0) { $origineOk = true; }
}
if (!$origineOk) {
    repondre(403, false, 'Origine refusée');
}

// 2. Configuration SMTP (hors dossier web)
if (!is_readable($FICHIER_CONFIG)) {
    repondre(500, false, 'Configuration SMTP manquante');
}
$SMTP = include $FICHIER_CONFIG;
foreach (['hote', 'port', 'utilisateur', 'mot_de_passe', 'expediteur'] as $cle) {
    if (empty($SMTP[$cle])) { repondre(500, false, 'Configuration SMTP incomplète'); }
}

// 3. Corps JSON
$brut = file_get_contents('php://input', false, null, 0, $TAILLE_MAX + 1);
if ($brut === false || strlen($brut) === 0) {
    repondre(400, false, 'Corps vide');
}
if (strlen($brut) > $TAILLE_MAX) {
    repondre(413, false, 'Requête trop volumineuse');
}
$donnees = json_decode($brut, true);
if (!is_array($donnees)) {
    repondre(400, false, 'JSON invalide');
}

// 4. Quota global simple (fichier compteur horaire dans le dossier temporaire)
$fichierQuota = sys_get_temp_dir() . '/carewatch_notifier_' . gmdate('YmdH') . '.cnt';
$compte = 0;
$fp = @fopen($fichierQuota, 'c+');
if ($fp) {
    if (flock($fp, LOCK_EX)) {
        $compte = (int) stream_get_contents($fp);
        $compte++;
        ftruncate($fp, 0);
        rewind($fp);
        fwrite($fp, (string) $compte);
        flock($fp, LOCK_UN);
    }
    fclose($fp);
}
if ($compte > $QUOTA_PAR_HEURE) {
    repondre(429, false, 'Trop de demandes, réessayez plus tard');
}

// 4b. Copie de l'accord de confidentialité à la personne qui vient de le signer.
//     Le texte de l'accord est CÔTÉ SERVEUR : le navigateur ne fournit que le nom, l'organisation,
//     le code, la date et l'adresse. Un seul destinataire externe, quota propre, copie à l'équipe.
if (isset($donnees['_mode']) && $donnees['_mode'] === 'nda') {
    $fichierQuotaNda = sys_get_temp_dir() . '/carewatch_nda_' . gmdate('YmdH') . '.cnt';
    $compteNda = 0;
    $fp = @fopen($fichierQuotaNda, 'c+');
    if ($fp) {
        if (flock($fp, LOCK_EX)) { $compteNda = (int) stream_get_contents($fp) + 1; ftruncate($fp, 0); rewind($fp); fwrite($fp, (string) $compteNda); flock($fp, LOCK_UN); }
        fclose($fp);
    }
    if ($compteNda > 30) { repondre(429, false, 'Trop de demandes, réessayez plus tard'); }

    $emailPersonne = trim((string) ($donnees['email'] ?? ''));
    if (!filter_var($emailPersonne, FILTER_VALIDATE_EMAIL) || preg_match('/[\r\n]/', $emailPersonne)) {
        repondre(400, false, 'Adresse e-mail invalide');
    }
    $nom   = preg_replace('/[\r\n]+/', ' ', mb_substr(trim((string) ($donnees['nom'] ?? '')), 0, 120));
    $org   = preg_replace('/[\r\n]+/', ' ', mb_substr(trim((string) ($donnees['organisation'] ?? '')), 0, 120));
    $code  = preg_replace('/[^a-z0-9\-]/', '', strtolower((string) ($donnees['code'] ?? '')));
    $vers  = preg_replace('/[^0-9\-]/', '', (string) ($donnees['version'] ?? ''));
    $quand = preg_replace('/[^0-9TZ:\-\.+ ]/', '', (string) ($donnees['signe_le'] ?? ''));
    $ident = preg_replace('/[^0-9a-f\-]/', '', (string) ($donnees['id'] ?? ''));

    $ACCORD = [
        ['1. Objet', ["Le présent accord encadre l'accès à la version alpha fermée de la plateforme CareWatch(TM) (carewat.ch), développée et exploitée par la Haute école de gestion de Genève (HEG-Genève, HES-SO), avec Unisanté pour l'épidémiologie et la recherche. L'accès est personnel, accordé sur invitation, à des fins d'essai et de retour d'expérience."]],
        ['2. Informations confidentielles', ["Sont confidentiels : la plateforme et ses fonctionnalités, son apparence et ses textes, les indicateurs et résultats affichés, les témoignages ou fiches consultables, les codes d'invitation, les échanges avec l'équipe et tout défaut constaté.", "Ne sont pas confidentielles les informations que l'équipe a elle-même rendues publiques, notamment sur le site public et dans ses communications officielles."]],
        ['3. Engagements de la personne invitée', ["Ne pas divulguer les informations confidentielles à des tiers, sous quelque forme que ce soit, y compris par captures d'écran, enregistrements ou copies.", "Ne pas transmettre son code d'invitation et ne pas donner accès à la plateforme à d'autres personnes.", "Ne pas tenter de contourner les protections techniques, ni d'extraire des données au-delà de l'usage normal de la plateforme.", "Signaler à l'équipe (contact@carewat.ch) les défauts, incohérences ou risques constatés.", "Ne saisir aucune information permettant d'identifier une personne tierce."]],
        ["4. Témoignages saisis pendant l'alpha", ["Les témoignages envoyés pendant la phase alpha sont traités selon la politique de confidentialité du site. Ils peuvent toutefois être effacés lors des remises à zéro de la base qui précèdent le lancement public. La personne invitée en est informée et l'accepte."]],
        ['5. Durée', ["L'accord prend effet à la signature et court jusqu'au lancement public de la plateforme, puis pendant deux ans pour les informations qui n'auront pas été rendues publiques."]],
        ['6. Données enregistrées au titre du présent accord', ["Nom, organisation, adresse e-mail, code d'invitation, date et heure, version de l'accord, identification du navigateur et empreinte technique non réversible de la connexion. Ces données servent uniquement à établir l'existence de l'accord et à contacter la personne au sujet de la phase alpha. Elles sont conservées cinq ans après la fin de la phase alpha. Responsable : HEG-Genève, contact@carewat.ch."]],
        ['7. Signature électronique', ["En cochant la case prévue et en cliquant sur « Signer et accéder », la personne invitée manifeste son accord. Cette signature électronique simple vaut acceptation du présent accord au sens des art. 1 ss du Code des obligations ; l'enregistrement décrit au point 6 en constitue la preuve."]],
        ['8. Droit applicable et for', ["Droit suisse. For à Genève, sous réserve de dispositions impératives contraires."]],
    ];

    $corps  = "Bonjour" . ($nom !== '' ? ' ' . $nom : '') . ",\r\n\r\n";
    $corps .= "Voici la copie de l'accord de confidentialité que vous avez signé électroniquement pour accéder à la version alpha fermée de CareWatch(TM).\r\n\r\n";
    $corps .= str_repeat('=', 64) . "\r\n";
    $corps .= "ACCORD DE CONFIDENTIALITÉ - ALPHA FERMÉE CAREWATCH(TM)\r\n";
    $corps .= "Version de l'accord : " . ($vers !== '' ? $vers : 'n/d') . "\r\n";
    $corps .= str_repeat('=', 64) . "\r\n\r\n";
    foreach ($ACCORD as $section) {
        $corps .= $section[0] . "\r\n";
        foreach ($section[1] as $par) { $corps .= wordwrap($par, 76, "\r\n") . "\r\n"; }
        $corps .= "\r\n";
    }
    $corps .= str_repeat('-', 64) . "\r\n";
    $corps .= "SIGNATURE ÉLECTRONIQUE\r\n";
    $corps .= "Signataire        : " . ($nom !== '' ? $nom : 'n/d') . ($org !== '' ? ' (' . $org . ')' : '') . "\r\n";
    $corps .= "Adresse e-mail    : " . $emailPersonne . "\r\n";
    $corps .= "Code d'invitation : " . ($code !== '' ? $code : 'n/d') . "\r\n";
    $corps .= "Signé le          : " . ($quand !== '' ? $quand : date('c')) . " (UTC)\r\n";
    $corps .= "Référence         : " . ($ident !== '' ? $ident : 'n/d') . "\r\n";
    $corps .= str_repeat('-', 64) . "\r\n\r\n";
    $corps .= "Conservez ce courriel. Pour toute question : contact@carewat.ch\r\n";
    $corps .= "HEG-Genève - CareWatch(TM), plateforme en phase alpha fermée.\r\n";

    $sujetNda = '=?UTF-8?B?' . base64_encode('Votre accord de confidentialité CareWatch (alpha fermée)') . '?=';
    $entetesNda  = "From: CareWatch <" . $SMTP['expediteur'] . ">\r\n";
    $entetesNda .= "To: <" . $emailPersonne . ">\r\n";
    $entetesNda .= "Reply-To: <" . $DESTINATAIRE . ">\r\n";
    $entetesNda .= "Subject: " . $sujetNda . "\r\n";
    $entetesNda .= "Date: " . date('r') . "\r\n";
    $entetesNda .= "Message-ID: <" . bin2hex(random_bytes(12)) . "@carewat.ch>\r\n";
    $entetesNda .= "MIME-Version: 1.0\r\nContent-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: 8bit\r\nX-Mailer: CareWatch-notifier\r\n";

    $etape = '';
    $okPersonne = smtp_envoyer($SMTP, $emailPersonne, $entetesNda . "\r\n" . $corps, $etape);
    // copie pour l'équipe, avec l'adresse du signataire en en-tête To d'origine conservée dans le corps
    $entetesEquipe = str_replace("To: <" . $emailPersonne . ">", "To: <" . $DESTINATAIRE . ">", $entetesNda);
    $entetesEquipe = preg_replace('/Subject: .*\r\n/', "Subject: " . '=?UTF-8?B?' . base64_encode('[CareWatch] Accord de confidentialité signé - ' . ($nom !== '' ? $nom : $emailPersonne)) . '?=' . "\r\n", $entetesEquipe);
    $etape2 = '';
    smtp_envoyer($SMTP, $DESTINATAIRE, $entetesEquipe . "\r\n" . $corps, $etape2);
    if (!$okPersonne) { repondre(500, false, 'Envoi impossible (SMTP : ' . $etape . ')'); }
    repondre(200, true, 'Copie envoyée');
}

// 4c. Code d'accès pour un nouveau compte de modération : envoyé à la personne, copie à l'équipe.
//     Texte fixe côté serveur ; le code seul ne donne rien sans l'adresse autorisée en base.
if (isset($donnees['_mode']) && $donnees['_mode'] === 'acces') {
    $fichierQuotaAcces = sys_get_temp_dir() . '/carewatch_acces_' . gmdate('YmdH') . '.cnt';
    $compteAcces = 0;
    $fp = @fopen($fichierQuotaAcces, 'c+');
    if ($fp) {
        if (flock($fp, LOCK_EX)) { $compteAcces = (int) stream_get_contents($fp) + 1; ftruncate($fp, 0); rewind($fp); fwrite($fp, (string) $compteAcces); flock($fp, LOCK_UN); }
        fclose($fp);
    }
    if ($compteAcces > 20) { repondre(429, false, 'Trop de demandes, réessayez plus tard'); }

    $emailPersonne = trim((string) ($donnees['email'] ?? ''));
    if (!filter_var($emailPersonne, FILTER_VALIDATE_EMAIL) || preg_match('/[\r\n]/', $emailPersonne)) {
        repondre(400, false, 'Adresse e-mail invalide');
    }
    $nom   = preg_replace('/[\r\n]+/', ' ', mb_substr(trim((string) ($donnees['nom'] ?? '')), 0, 120));
    $code  = preg_replace('/[^A-Z0-9]/', '', strtoupper((string) ($donnees['code'] ?? '')));
    $role  = ($donnees['role'] ?? '') === 'admin' ? 'administrateur·rice' : 'modérateur·rice';
    if (strlen($code) < 6) { repondre(400, false, 'Code invalide'); }

    $corps  = "Bonjour" . ($nom !== '' ? ' ' . $nom : '') . ",\r\n\r\n";
    $corps .= "Un accès " . $role . " à l'espace de modération de CareWatch(TM) vous a été ouvert.\r\n\r\n";
    $corps .= "Votre code d'accès à usage unique : " . $code . "\r\n";
    $corps .= "Valable 14 jours.\r\n\r\n";
    $corps .= "Pour l'activer :\r\n";
    $corps .= "1. Ouvrez https://carewat.ch, entrez avec votre code d'invitation si la porte le demande.\r\n";
    $corps .= "2. Cliquez sur l'icône d'administration du bandeau, puis « Espace de modération sécurisé ».\r\n";
    $corps .= "3. Choisissez « Première connexion », saisissez cette adresse e-mail et le code ci-dessus.\r\n";
    $corps .= "4. Vous recevrez un lien de connexion, puis vous choisirez votre mot de passe et activerez\r\n";
    $corps .= "   le second facteur avec une application d'authentification.\r\n\r\n";
    $corps .= "Si vous n'attendiez pas cet accès, ignorez ce message et prévenez contact@carewat.ch.\r\n\r\n";
    $corps .= "L'équipe CareWatch(TM)\r\n";

    $sujetAcces = '=?UTF-8?B?' . base64_encode('Votre accès à l\'espace de modération CareWatch') . '?=';
    $entetesAcces  = "From: CareWatch <" . $SMTP['expediteur'] . ">\r\n";
    $entetesAcces .= "To: <" . $emailPersonne . ">\r\n";
    $entetesAcces .= "Reply-To: <" . $DESTINATAIRE . ">\r\n";
    $entetesAcces .= "Subject: " . $sujetAcces . "\r\n";
    $entetesAcces .= "Date: " . date('r') . "\r\n";
    $entetesAcces .= "Message-ID: <" . bin2hex(random_bytes(12)) . "@carewat.ch>\r\n";
    $entetesAcces .= "MIME-Version: 1.0\r\nContent-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: 8bit\r\nX-Mailer: CareWatch-notifier\r\n";

    $etape = '';
    $ok = smtp_envoyer($SMTP, $emailPersonne, $entetesAcces . "\r\n" . $corps, $etape);
    $entetesEquipe = str_replace("To: <" . $emailPersonne . ">", "To: <" . $DESTINATAIRE . ">", $entetesAcces);
    $entetesEquipe = preg_replace('/Subject: .*\r\n/', "Subject: " . '=?UTF-8?B?' . base64_encode('[CareWatch] Accès modération ouvert pour ' . $emailPersonne) . '?=' . "\r\n", $entetesEquipe);
    $etape2 = '';
    smtp_envoyer($SMTP, $DESTINATAIRE, $entetesEquipe . "\r\n" . "Accès " . $role . " ouvert pour " . $emailPersonne . ($nom !== '' ? ' (' . $nom . ')' : '') . ". Le code a été envoyé à la personne.\r\n", $etape2);
    if (!$ok) { repondre(500, false, 'Envoi impossible (SMTP : ' . $etape . ')'); }
    repondre(200, true, 'Code envoyé');
}

// 5. Construction du courriel (texte brut, une ligne par champ)
$sujet = isset($donnees['_subject']) ? trim((string) $donnees['_subject']) : 'Notification CareWatch';
$sujet = preg_replace('/[\r\n]+/', ' ', mb_substr($sujet, 0, 200));

$lignes = [];
foreach ($donnees as $cle => $valeur) {
    if (strpos($cle, '_') === 0) { continue; }          // _subject, _template, _captcha
    if (is_array($valeur)) { $valeur = json_encode($valeur, JSON_UNESCAPED_UNICODE); }
    $valeur = trim((string) $valeur);
    if ($valeur === '') { $valeur = '—'; }
    $lignes[] = str_pad(mb_substr($cle, 0, 40), 28) . ': ' . $valeur;
}
$corps  = "Nouvelle notification CareWatch\r\n";
$corps .= "Reçue le " . date('d.m.Y H:i:s') . " (heure serveur)\r\n";
$corps .= str_repeat('-', 60) . "\r\n";
$corps .= implode("\r\n", $lignes) . "\r\n";
$corps .= str_repeat('-', 60) . "\r\n";
$corps .= "Envoyé par api/notifier.php depuis l'hébergement Infomaniak de carewat.ch.\r\n";
$corps = str_replace(["\r\n", "\r", "\n"], "\n", $corps);
$corps = str_replace("\n", "\r\n", $corps);

$sujetEncode = '=?UTF-8?B?' . base64_encode($sujet) . '?=';
$entetes  = "From: CareWatch <" . $SMTP['expediteur'] . ">\r\n";
$entetes .= "To: <" . $DESTINATAIRE . ">\r\n";
$entetes .= "Reply-To: <" . $DESTINATAIRE . ">\r\n";
$entetes .= "Subject: " . $sujetEncode . "\r\n";
$entetes .= "Date: " . date('r') . "\r\n";
$entetes .= "Message-ID: <" . bin2hex(random_bytes(12)) . "@carewat.ch>\r\n";
$entetes .= "MIME-Version: 1.0\r\n";
$entetes .= "Content-Type: text/plain; charset=UTF-8\r\n";
$entetes .= "Content-Transfer-Encoding: 8bit\r\n";
$entetes .= "X-Mailer: CareWatch-notifier\r\n";

// 6. Envoi SMTP (465 = TLS implicite, 587 = STARTTLS), authentification LOGIN
function smtp_envoyer($cfg, $destinataire, $message, &$etape) {
    $port = (int) $cfg['port'];
    $prefixe = ($port === 465) ? 'ssl://' : 'tcp://';
    $ctx = stream_context_create(['ssl' => ['verify_peer' => true, 'verify_peer_name' => true, 'SNI_enabled' => true]]);
    $etape = 'connexion';
    $fp = @stream_socket_client($prefixe . $cfg['hote'] . ':' . $port, $errno, $errstr, 20, STREAM_CLIENT_CONNECT, $ctx);
    if (!$fp) { return false; }
    stream_set_timeout($fp, 20);

    $lire = function () use ($fp) {
        $code = null;
        while (($ligne = fgets($fp, 1024)) !== false) {
            $code = (int) substr($ligne, 0, 3);
            if (strlen($ligne) < 4 || $ligne[3] !== '-') { break; }
        }
        return $code;
    };
    $dire = function ($cmd, $attendu) use ($fp, $lire) {
        fwrite($fp, $cmd . "\r\n");
        return $lire() === $attendu;
    };

    $etape = 'accueil';      if ($lire() !== 220) { fclose($fp); return false; }
    $etape = 'ehlo';         if (!$dire('EHLO carewat.ch', 250)) { fclose($fp); return false; }
    if ($port !== 465) {
        $etape = 'starttls'; if (!$dire('STARTTLS', 220)) { fclose($fp); return false; }
        if (!stream_socket_enable_crypto($fp, true, STREAM_CRYPTO_METHOD_TLS_CLIENT)) { fclose($fp); return false; }
        $etape = 'ehlo-tls'; if (!$dire('EHLO carewat.ch', 250)) { fclose($fp); return false; }
    }
    $etape = 'auth';
    if (!$dire('AUTH LOGIN', 334)) { fclose($fp); return false; }
    if (!$dire(base64_encode($cfg['utilisateur']), 334)) { fclose($fp); return false; }
    if (!$dire(base64_encode($cfg['mot_de_passe']), 235)) { fclose($fp); return false; }
    $etape = 'expediteur';   if (!$dire('MAIL FROM:<' . $cfg['expediteur'] . '>', 250)) { fclose($fp); return false; }
    $etape = 'destinataire'; if (!$dire('RCPT TO:<' . $destinataire . '>', 250)) { fclose($fp); return false; }
    $etape = 'data';         if (!$dire('DATA', 354)) { fclose($fp); return false; }
    // dot-stuffing : une ligne commençant par « . » devient « .. »
    $message = preg_replace('/^\./m', '..', $message);
    $etape = 'contenu';
    if (!$dire($message . "\r\n.", 250)) { fclose($fp); return false; }
    $dire('QUIT', 221);
    fclose($fp);
    $etape = 'ok';
    return true;
}

$etape = '';
$ok = smtp_envoyer($SMTP, $DESTINATAIRE, $entetes . "\r\n" . $corps, $etape);
if (!$ok) {
    repondre(500, false, 'Envoi impossible (SMTP : ' . $etape . ')');
}
repondre(200, true, 'Envoyé');
