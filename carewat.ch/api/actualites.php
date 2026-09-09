<?php
/**
 * CareWatch — veille automatique.
 *
 * Lit des sources suisses de santé publique et d'équité, garde titre, lien, date,
 * source et un court résumé, et sert le tout en JSON. Deux types de sources :
 *   - flux RSS/Atom (avec découverte du flux depuis une page HTML si besoin) ;
 *   - page HTML listant des articles (sites sans flux) : les liens qui répondent
 *     au motif de la source sont relevés, la date retenue est celle du premier relevé.
 * Le résultat est mis en cache six heures dans api/cache/veille.json (dossier
 * interdit en lecture directe par .htaccess). Aucune base de données, aucun cron.
 *
 *   GET /api/actualites.php            → { genere_le, entrees: [...] }
 *   GET /api/actualites.php?etat=1     → idem, avec le détail des sources
 *   GET /api/actualites.php?sonde=URL  → liens trouvés dans une page (hôtes des sources seulement), pour régler les motifs
 *
 * Les entrées ne sont jamais recopiées intégralement : 300 caractères de résumé au plus.
 */

error_reporting(E_ALL & ~E_DEPRECATED & ~E_NOTICE);
ini_set('display_errors', '0');
header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: public, max-age=900');
if ($_SERVER['REQUEST_METHOD'] !== 'GET') { http_response_code(405); echo '{"erreur":"GET seulement"}'; exit; }

$TTL      = 6 * 3600;           // durée de vie du cache
$MAX      = 80;                 // entrées conservées au total
$PAR_SRC  = 20;                 // entrées par source
$AGE_MAX  = 730;                // jours : au-delà, l'entrée est ignorée
$TIMEOUT  = 8;                  // secondes par téléchargement
$CACHE    = __DIR__ . '/cache/veille.json';
$LOCK     = __DIR__ . '/cache/veille.lock';

// Sources.
//   type 'flux'  : urls = adresses candidates ; la première qui donne un flux RSS/Atom est retenue,
//                  une page HTML est fouillée (<link rel="alternate">, puis /feed/).
//   type 'html'  : url = page de liste ; motif = expression régulière sur l'adresse des liens à retenir ;
//                  exclure (facultatif) = expression régulière sur l'adresse des liens à ignorer.
//   ssl_lax      : le site présente une chaîne de certificats incomplète ; la vérification est relâchée
//                  pour cette lecture de titres publics.
$SOURCES = [
  ['nom' => 'OFSP', 'type' => 'flux', 'urls' => ['https://www.news.admin.ch/fr/rss?deptid=7', 'https://www.bag.admin.ch/bag/fr/home.rss', 'https://www.bag.admin.ch/bag/fr/home/das-bag/aktuell/medienmitteilungen.html', 'https://www.admin.ch/gov/fr/accueil/documentation/communiques.html']],
  ['nom' => 'Obsan', 'type' => 'flux', 'ssl_lax' => true, 'urls' => ['https://www.obsan.admin.ch/fr/rss.xml', 'https://www.obsan.admin.ch/fr/publications', 'https://www.obsan.admin.ch/fr']],
  ['nom' => 'Revue Médicale Suisse', 'type' => 'html', 'url' => 'https://www.revmed.ch/', 'motif' => '#revmed\.ch/(revue-medicale-suisse|actualite|actu|article)#i'],
  ['nom' => 'Unisanté', 'type' => 'html', 'url' => 'https://www.unisante.ch/fr/propos-dunisante/actualites', 'motif' => '#unisante\.ch/fr/propos-dunisante/actualites/.+#i'],
  ['nom' => 'HETSL', 'type' => 'flux', 'urls' => ['https://www.hetsl.ch/rss.xml']],
  ['nom' => 'Commission fédérale contre le racisme', 'type' => 'flux', 'urls' => ['https://www.news.admin.ch/fr/rss?deptid=7&orgid=', 'https://www.ekr.admin.ch/ekr/fr/home/aktuell.html', 'https://www.ekr.admin.ch/ekr/fr/home.html']],
  ['nom' => 'swimsa', 'type' => 'flux', 'urls' => ['https://swimsa.ch/feed/']],
];

// Essais en local : un fichier api/cache/sources_locales.json (jamais déployé) remplace la liste
$SRC_LOCALES = __DIR__ . '/cache/sources_locales.json';
if (is_file($SRC_LOCALES)) { $t = json_decode((string) file_get_contents($SRC_LOCALES), true); if (is_array($t) && $t) $SOURCES = $t; }

// ---------------------------------------------------------------------------
// Sonde : liens d'une page, pour régler les motifs (hôtes des sources seulement)
// ---------------------------------------------------------------------------
if (isset($_GET['sonde'])) {
  $u = (string) $_GET['sonde'];
  $h = parse_url($u, PHP_URL_HOST);
  $hotes = [];
  foreach ($SOURCES as $src) foreach (array_merge($src['urls'] ?? [], isset($src['url']) ? [$src['url']] : []) as $x) $hotes[] = parse_url($x, PHP_URL_HOST);
  if (!$h || !in_array($h, $hotes, true) || !preg_match('#^https?://#i', $u)) { http_response_code(400); echo '{"erreur":"hôte non autorisé"}'; exit; }
  [$corps, $type, $e] = telecharger($u, $TIMEOUT, true);
  if ($corps === null) { echo json_encode(['erreur' => $e]); exit; }
  $liens = extraireLiens($corps, $u);
  echo json_encode(['type' => $type, 'octets' => strlen($corps), 'flux_annonces' => decouvrirFlux($corps, $u), 'liens' => array_slice($liens, 0, 150)], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
  exit;
}

// ---------------------------------------------------------------------------
// Cache
// ---------------------------------------------------------------------------
$detail = isset($_GET['etat']);
$cache = null;
if (is_file($CACHE)) {
  $cache = json_decode((string) file_get_contents($CACHE), true);
  if (is_array($cache) && isset($cache['genere_ts']) && time() - (int) $cache['genere_ts'] < $TTL && !isset($_GET['rafraichir'])) {
    sortir($cache, $detail);
  }
}
// Un seul rafraîchissement à la fois : les autres visiteurs reçoivent l'ancien cache
$fp = @fopen($LOCK, 'c');
if ($fp && !flock($fp, LOCK_EX | LOCK_NB)) {
  if (is_array($cache)) sortir($cache, $detail);
  echo json_encode(['genere_le' => null, 'entrees' => [], 'sources' => []]); exit;
}
// Dates de premier relevé des pages HTML (mémoire du cache précédent)
$premierReleve = [];
if (is_array($cache)) foreach ($cache['entrees'] ?? [] as $e) if (!empty($e['lien']) && !empty($e['date'])) $premierReleve[$e['lien']] = $e['date'];

// ---------------------------------------------------------------------------
// Lecture des sources
// ---------------------------------------------------------------------------
$entrees = []; $etatSources = [];
$limite = date('Y-m-d', time() - $AGE_MAX * 86400);
foreach ($SOURCES as $src) {
  $ok = false; $err = ''; $urlUtilisee = ''; $n = 0; $items = null;
  $lax = !empty($src['ssl_lax']);
  if (($src['type'] ?? 'flux') === 'html') {
    [$corps, , $e] = telecharger($src['url'], $TIMEOUT, $lax);
    if ($corps === null) { $err = $e; }
    else {
      $items = [];
      foreach (extraireLiens($corps, $src['url']) as $l) {
        if (!preg_match($src['motif'], $l['href'])) continue;
        if (!empty($src['exclure']) && preg_match($src['exclure'], $l['href'])) continue;
        if (longueur($l['texte']) < 25) continue;
        $items[] = entree($l['texte'], $l['href'], $premierReleve[$l['href']] ?? date('Y-m-d'), '');
      }
      if (count($items) === 0) { $err = 'aucun lien ne répond au motif'; $items = null; }
      else $urlUtilisee = $src['url'];
    }
  } else {
    foreach ($src['urls'] as $u) {
      [$corps, $type, $e] = telecharger($u, $TIMEOUT, $lax);
      if ($corps === null) { $err = $e; continue; }
      $items = analyserFlux($corps);
      if ($items === null && (stripos($type, 'html') !== false || preg_match('/<html/i', substr($corps, 0, 3000)))) {
        foreach (decouvrirFlux($corps, $u) as $c) {
          [$corps2, , $e2] = telecharger($c, $TIMEOUT, $lax);
          if ($corps2 === null) { $err = $e2; continue; }
          $items = analyserFlux($corps2);
          if ($items !== null) { $u = $c; break; }
        }
      }
      if ($items === null) { $err = 'aucun flux RSS ou Atom reconnu'; continue; }
      $urlUtilisee = $u; break;
    }
  }
  if (is_array($items)) {
    $items = array_values(array_filter($items, fn($it) => $it['date'] === '' || $it['date'] >= $limite));
    $items = array_slice($items, 0, $PAR_SRC);
    foreach ($items as $it) { $it['source'] = $src['nom']; $entrees[] = $it; }
    $ok = count($items) > 0; $n = count($items); if ($ok) $err = ''; elseif ($err === '') $err = 'flux vide ou trop ancien';
  }
  $etatSources[] = ['nom' => $src['nom'], 'ok' => $ok, 'n' => $n, 'url' => $urlUtilisee, 'erreur' => $err];
}

// Dédoublonnage par lien, tri par date décroissante, plafond global
$vus = []; $uniques = [];
foreach ($entrees as $e) { $k = $e['lien']; if ($k === '' || isset($vus[$k])) continue; $vus[$k] = true; $uniques[] = $e; }
usort($uniques, fn($a, $b) => strcmp($b['date'] ?? '', $a['date'] ?? ''));
$uniques = array_slice($uniques, 0, $MAX);

$resultat = ['genere_le' => date('c'), 'genere_ts' => time(), 'entrees' => $uniques, 'sources' => $etatSources];
// Si tout a échoué, on garde l'ancien cache plutôt qu'une liste vide
if (count($uniques) === 0 && is_array($cache) && !empty($cache['entrees'])) {
  $resultat['entrees'] = $cache['entrees'];
}
if (!is_dir(dirname($CACHE))) @mkdir(dirname($CACHE), 0755, true);
@file_put_contents($CACHE, json_encode($resultat, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES), LOCK_EX);
if ($fp) { flock($fp, LOCK_UN); fclose($fp); }
sortir($resultat, $detail);

// ---------------------------------------------------------------------------
// Fonctions
// ---------------------------------------------------------------------------
function longueur(string $t): int { return function_exists('mb_strlen') ? mb_strlen($t) : strlen($t); }

function sortir(array $r, bool $detail): void {
  $sortie = ['genere_le' => $r['genere_le'] ?? null, 'entrees' => $r['entrees'] ?? []];
  if ($detail) $sortie['sources'] = $r['sources'] ?? [];
  echo json_encode($sortie, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
  exit;
}

function telecharger(string $url, int $timeout, bool $sslLax = false): array {
  $ua = 'Mozilla/5.0 (compatible; CareWatch veille; +https://carewat.ch)';
  $accept = 'application/rss+xml, application/atom+xml, application/xml, text/xml, text/html;q=0.8, */*;q=0.5';
  if (!function_exists('curl_init')) {                    // sans extension curl : flux PHP
    $ctx = stream_context_create([
      'http' => ['timeout' => $timeout, 'follow_location' => 1, 'max_redirects' => 5, 'user_agent' => $ua, 'header' => "Accept: $accept\r\n", 'ignore_errors' => true],
      'ssl'  => $sslLax ? ['verify_peer' => false, 'verify_peer_name' => false] : [],
    ]);
    $corps = @file_get_contents($url, false, $ctx);
    $code = 0; $type = '';
    foreach ($http_response_header ?? [] as $h) { if (preg_match('#^HTTP/\S+\s+(\d+)#', $h, $m)) $code = (int) $m[1]; if (stripos($h, 'content-type:') === 0) $type = trim(substr($h, 13)); }
    if ($corps === false || $corps === '' || $code >= 400) return [null, $type, $code ? "HTTP $code" : 'connexion impossible'];
    return [$corps, $type, ''];
  }
  $ch = curl_init($url);
  $opts = [
    CURLOPT_RETURNTRANSFER => true, CURLOPT_FOLLOWLOCATION => true, CURLOPT_MAXREDIRS => 5,
    CURLOPT_TIMEOUT => $timeout, CURLOPT_CONNECTTIMEOUT => 5, CURLOPT_ENCODING => '',
    CURLOPT_USERAGENT => $ua, CURLOPT_HTTPHEADER => ['Accept: ' . $accept, 'Accept-Language: fr-CH,fr;q=0.9,de;q=0.5'],
  ];
  if ($sslLax) { $opts[CURLOPT_SSL_VERIFYPEER] = false; $opts[CURLOPT_SSL_VERIFYHOST] = 0; }
  curl_setopt_array($ch, $opts);
  $corps = curl_exec($ch);
  $code = (int) curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
  $type = (string) curl_getinfo($ch, CURLINFO_CONTENT_TYPE);
  $err  = curl_error($ch);
  if ($corps === false || $code >= 400 || $corps === '') return [null, $type, $err ?: "HTTP $code"];
  return [$corps, $type, ''];
}

/** Retourne une liste d'entrées, ou null si le document n'est ni RSS ni Atom. */
function analyserFlux(string $xml): ?array {
  if (!preg_match('/<(rss|feed|rdf:RDF)[\s>]/i', substr($xml, 0, 4000))) return null;
  libxml_use_internal_errors(true);
  $doc = simplexml_load_string($xml, 'SimpleXMLElement', LIBXML_NOCDATA | LIBXML_NONET);
  if ($doc === false) return null;
  $out = [];
  $ns = $doc->getNamespaces(true);
  $dcNs = $ns['dc'] ?? 'http://purl.org/dc/elements/1.1/';
  if (isset($doc->channel->item)) {                       // RSS 2.0
    foreach ($doc->channel->item as $it) {
      $dc = $it->children($dcNs);
      $out[] = entree((string) $it->title, (string) $it->link, (string) ($it->pubDate ?: $dc->date), (string) ($it->description ?: ''));
    }
  } elseif (isset($doc->entry)) {                        // Atom
    foreach ($doc->entry as $it) {
      $lien = '';
      foreach ($it->link as $l) { $rel = (string) $l['rel']; if ($rel === '' || $rel === 'alternate') { $lien = (string) $l['href']; break; } }
      $out[] = entree((string) $it->title, $lien, (string) ($it->published ?: $it->updated), (string) ($it->summary ?: $it->content));
    }
  } elseif (isset($doc->item)) {                         // RSS 1.0 (RDF)
    foreach ($doc->item as $it) {
      $dc = $it->children($dcNs);
      $out[] = entree((string) $it->title, (string) $it->link, (string) $dc->date, (string) $it->description);
    }
  } else return null;
  return array_values(array_filter($out, fn($e) => $e['titre'] !== '' && $e['lien'] !== ''));
}

function entree(string $titre, string $lien, string $date, string $resume): array {
  $ts = $date !== '' ? strtotime($date) : false;
  $texte = trim(html_entity_decode(strip_tags($resume), ENT_QUOTES | ENT_HTML5, 'UTF-8'));
  $texte = preg_replace('/\s+/u', ' ', $texte);
  if (longueur($texte) > 300) $texte = rtrim(function_exists('mb_substr') ? mb_substr($texte, 0, 297) : substr($texte, 0, 297)) . '…';
  $t = trim(html_entity_decode(strip_tags($titre), ENT_QUOTES | ENT_HTML5, 'UTF-8'));
  $t = preg_replace('/\s+/u', ' ', $t);
  return ['titre' => $t, 'lien' => trim($lien), 'date' => $ts ? date('Y-m-d', $ts) : '', 'resume' => $texte];
}

/** Adresses de flux annoncées dans une page HTML, puis /feed/ en dernier recours. */
function decouvrirFlux(string $html, string $base): array {
  $c = [];
  if (preg_match_all('/<link[^>]+>/i', substr($html, 0, 300000), $m)) {
    foreach ($m[0] as $tag) {
      if (!preg_match('/type=["\']application\/(rss|atom)\+xml["\']/i', $tag)) continue;
      if (preg_match('/href=["\']([^"\']+)["\']/i', $tag, $h)) $c[] = absolu(html_entity_decode($h[1]), $base);
    }
  }
  // liens visibles vers un flux
  if (preg_match_all('/<a[^>]+href=["\']([^"\']*(?:rss|feed|atom)[^"\']*)["\']/i', $html, $m2)) foreach ($m2[1] as $h) $c[] = absolu(html_entity_decode($h), $base);
  $c[] = rtrim($base, '/') . '/feed/';
  $p = parse_url($base);
  if (!empty($p['host'])) $c[] = $p['scheme'] . '://' . $p['host'] . (isset($p['port']) ? ':' . $p['port'] : '') . '/feed/';
  return array_values(array_unique($c));
}

/** Tous les liens d'une page : [{href absolu, texte}]. */
function extraireLiens(string $html, string $base): array {
  $out = [];
  if (!preg_match_all('/<a\b([^>]*)>(.*?)<\/a>/is', $html, $m, PREG_SET_ORDER)) return $out;
  foreach ($m as $a) {
    if (!preg_match('/href=["\']([^"\'#]+)["\']/i', $a[1], $h)) continue;
    $href = html_entity_decode($h[1]);
    if (preg_match('/^(javascript:|mailto:|tel:)/i', $href)) continue;
    $texte = trim(preg_replace('/\s+/u', ' ', html_entity_decode(strip_tags($a[2]), ENT_QUOTES | ENT_HTML5, 'UTF-8')));
    $out[] = ['href' => absolu($href, $base), 'texte' => $texte];
  }
  return $out;
}

function absolu(string $href, string $base): string {
  if (preg_match('#^https?://#i', $href)) return $href;
  $p = parse_url($base);
  $racine = ($p['scheme'] ?? 'https') . '://' . ($p['host'] ?? '') . (isset($p['port']) ? ':' . $p['port'] : '');
  if (str_starts_with($href, '//')) return ($p['scheme'] ?? 'https') . ':' . $href;
  if (str_starts_with($href, '/')) return $racine . $href;
  return rtrim(dirname($base), '/') . '/' . $href;
}
