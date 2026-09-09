<?php
/**
 * CareWatch — veille automatique.
 *
 * Lit une liste de flux RSS/Atom (sources suisses de santé publique et d'équité),
 * garde titre, lien, date, source et un court résumé, et sert le tout en JSON.
 * Le résultat est mis en cache six heures dans api/cache/veille.json (dossier
 * interdit en lecture directe par .htaccess). Aucune base de données, aucun cron :
 * la première visite après expiration relance la lecture.
 *
 *   GET /api/actualites.php           → { genere_le, entrees: [...], sources: [...] }
 *   GET /api/actualites.php?etat=1    → idem, avec le détail des sources (utile pour vérifier les flux)
 *
 * Les entrées ne sont jamais recopiées intégralement : 300 caractères de résumé au plus.
 */

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: public, max-age=900');
if ($_SERVER['REQUEST_METHOD'] !== 'GET') { http_response_code(405); echo '{"erreur":"GET seulement"}'; exit; }

$TTL      = 6 * 3600;           // durée de vie du cache
$MAX      = 80;                 // entrées conservées au total
$PAR_SRC  = 20;                 // entrées par source
$TIMEOUT  = 8;                  // secondes par flux
$CACHE    = __DIR__ . '/cache/veille.json';
$LOCK     = __DIR__ . '/cache/veille.lock';

// Sources : pour chaque nom, plusieurs adresses candidates. La première qui
// fournit un flux valide est retenue ; une page HTML est fouillée à la recherche
// d'un <link rel="alternate" type="application/rss+xml"> ; les sites WordPress
// répondent souvent sur /feed/.
$SOURCES = [
  ['nom' => 'OFSP',            'urls' => ['https://www.bag.admin.ch/bag/fr/home/das-bag/aktuell/medienmitteilungen.html', 'https://www.bag.admin.ch/bag/fr/home/das-bag/aktuell/news.html', 'https://www.bag.admin.ch/bag/fr/home.html']],
  ['nom' => 'Obsan',           'urls' => ['https://www.obsan.admin.ch/fr/rss.xml', 'https://www.obsan.admin.ch/fr/publications', 'https://www.obsan.admin.ch/fr']],
  ['nom' => 'Revue Médicale Suisse', 'urls' => ['https://www.revmed.ch/rss', 'https://www.revmed.ch/rss.xml', 'https://www.revmed.ch/']],
  ['nom' => 'Unisanté',        'urls' => ['https://www.unisante.ch/fr/rss.xml', 'https://www.unisante.ch/fr/actualites', 'https://www.unisante.ch/fr']],
  ['nom' => 'HETSL',           'urls' => ['https://www.hetsl.ch/rss.xml', 'https://www.hetsl.ch/actualites', 'https://www.hetsl.ch/observatoire-des-precarites']],
  ['nom' => 'Commission fédérale contre le racisme', 'urls' => ['https://www.ekr.admin.ch/ekr/fr/home/aktuell.html', 'https://www.ekr.admin.ch/ekr/fr/home.html']],
  ['nom' => 'swimsa',          'urls' => ['https://swimsa.ch/feed/', 'https://swimsa.ch/fr/feed/', 'https://swimsa.ch/']],
];

// Essais en local : un fichier api/cache/sources_locales.json (jamais déployé) remplace la liste
$SRC_LOCALES = __DIR__ . '/cache/sources_locales.json';
if (is_file($SRC_LOCALES)) { $t = json_decode((string) file_get_contents($SRC_LOCALES), true); if (is_array($t) && $t) $SOURCES = $t; }

// ---------------------------------------------------------------------------
// Cache
// ---------------------------------------------------------------------------
$detail = isset($_GET['etat']);
$cache = null;
if (is_file($CACHE)) {
  $cache = json_decode((string) file_get_contents($CACHE), true);
  if (is_array($cache) && isset($cache['genere_ts']) && time() - (int) $cache['genere_ts'] < $TTL) {
    sortir($cache, $detail);
  }
}
// Un seul rafraîchissement à la fois : les autres visiteurs reçoivent l'ancien cache
$fp = @fopen($LOCK, 'c');
if ($fp && !flock($fp, LOCK_EX | LOCK_NB)) {
  if (is_array($cache)) sortir($cache, $detail);
  echo json_encode(['genere_le' => null, 'entrees' => [], 'sources' => []]); exit;
}

// ---------------------------------------------------------------------------
// Lecture des sources
// ---------------------------------------------------------------------------
$entrees = []; $etatSources = [];
foreach ($SOURCES as $src) {
  $ok = false; $err = ''; $urlUtilisee = ''; $n = 0;
  foreach ($src['urls'] as $u) {
    [$corps, $type, $e] = telecharger($u, $TIMEOUT);
    if ($corps === null) { $err = $e; continue; }
    $items = analyserFlux($corps);
    if ($items === null && stripos($type, 'html') !== false || $items === null && preg_match('/<html/i', substr($corps, 0, 2000))) {
      // Page HTML : chercher un flux annoncé dans l'en-tête, sinon tenter /feed/
      $candidats = decouvrirFlux($corps, $u);
      foreach ($candidats as $c) {
        [$corps2, , $e2] = telecharger($c, $TIMEOUT);
        if ($corps2 === null) { $err = $e2; continue; }
        $items = analyserFlux($corps2);
        if ($items !== null) { $u = $c; break; }
      }
    }
    if ($items === null) { $err = 'aucun flux RSS ou Atom reconnu'; continue; }
    $items = array_slice($items, 0, $PAR_SRC);
    foreach ($items as $it) { $it['source'] = $src['nom']; $entrees[] = $it; }
    $ok = true; $urlUtilisee = $u; $n = count($items); $err = '';
    break;
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
  $resultat['sources'] = $etatSources;
}
if (!is_dir(dirname($CACHE))) @mkdir(dirname($CACHE), 0755, true);
@file_put_contents($CACHE, json_encode($resultat, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES), LOCK_EX);
if ($fp) { flock($fp, LOCK_UN); fclose($fp); }
sortir($resultat, $detail);

// ---------------------------------------------------------------------------
// Fonctions
// ---------------------------------------------------------------------------
function sortir(array $r, bool $detail): void {
  $sortie = ['genere_le' => $r['genere_le'] ?? null, 'entrees' => $r['entrees'] ?? []];
  if ($detail) $sortie['sources'] = $r['sources'] ?? [];
  echo json_encode($sortie, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
  exit;
}

function telecharger(string $url, int $timeout): array {
  if (!function_exists('curl_init')) {                    // sans extension curl : flux PHP
    $ctx = stream_context_create(['http' => ['timeout' => $timeout, 'follow_location' => 1, 'max_redirects' => 5, 'user_agent' => 'CareWatch veille (+https://carewat.ch)', 'header' => "Accept: application/rss+xml, application/atom+xml, application/xml, text/xml, text/html;q=0.8\r\n", 'ignore_errors' => true]]);
    $corps = @file_get_contents($url, false, $ctx);
    $entetes = $http_response_header ?? [];
    $code = 0; $type = '';
    foreach ($entetes as $h) { if (preg_match('#^HTTP/\S+\s+(\d+)#', $h, $m)) $code = (int) $m[1]; if (stripos($h, 'content-type:') === 0) $type = trim(substr($h, 13)); }
    if ($corps === false || $corps === '' || $code >= 400) return [null, $type, $code ? "HTTP $code" : 'connexion impossible'];
    return [$corps, $type, ''];
  }
  $ch = curl_init($url);
  curl_setopt_array($ch, [
    CURLOPT_RETURNTRANSFER => true, CURLOPT_FOLLOWLOCATION => true, CURLOPT_MAXREDIRS => 5,
    CURLOPT_TIMEOUT => $timeout, CURLOPT_CONNECTTIMEOUT => 5,
    CURLOPT_USERAGENT => 'CareWatch veille (+https://carewat.ch)',
    CURLOPT_HTTPHEADER => ['Accept: application/rss+xml, application/atom+xml, application/xml, text/xml, text/html;q=0.8'],
  ]);
  $corps = curl_exec($ch);
  $code = (int) curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
  $type = (string) curl_getinfo($ch, CURLINFO_CONTENT_TYPE);
  $err  = curl_error($ch);
  curl_close($ch);
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
  if (isset($doc->channel->item)) {                       // RSS 2.0
    foreach ($doc->channel->item as $it) {
      $dc = $it->children($ns['dc'] ?? 'http://purl.org/dc/elements/1.1/');
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
      $dc = $it->children($ns['dc'] ?? 'http://purl.org/dc/elements/1.1/');
      $out[] = entree((string) $it->title, (string) $it->link, (string) $dc->date, (string) $it->description);
    }
  } else return null;
  return array_values(array_filter($out, fn($e) => $e['titre'] !== '' && $e['lien'] !== ''));
}

function entree(string $titre, string $lien, string $date, string $resume): array {
  $ts = $date !== '' ? strtotime($date) : false;
  $texte = trim(html_entity_decode(strip_tags($resume), ENT_QUOTES | ENT_HTML5, 'UTF-8'));
  $texte = preg_replace('/\s+/u', ' ', $texte);
  $lg = function_exists('mb_strlen') ? mb_strlen($texte) : strlen($texte);
  if ($lg > 300) $texte = rtrim(function_exists('mb_substr') ? mb_substr($texte, 0, 297) : substr($texte, 0, 297)) . '…';
  return [
    'titre'  => trim(html_entity_decode(strip_tags($titre), ENT_QUOTES | ENT_HTML5, 'UTF-8')),
    'lien'   => trim($lien),
    'date'   => $ts ? date('Y-m-d', $ts) : '',
    'resume' => $texte,
  ];
}

/** Adresses de flux annoncées dans une page HTML, puis /feed/ en dernier recours. */
function decouvrirFlux(string $html, string $base): array {
  $c = [];
  if (preg_match_all('/<link[^>]+>/i', substr($html, 0, 200000), $m)) {
    foreach ($m[0] as $tag) {
      if (!preg_match('/type=["\']application\/(rss|atom)\+xml["\']/i', $tag)) continue;
      if (preg_match('/href=["\']([^"\']+)["\']/i', $tag, $h)) $c[] = absolu($h[1], $base);
    }
  }
  $c[] = rtrim($base, '/') . '/feed/';
  $p = parse_url($base);
  if (!empty($p['host'])) $c[] = $p['scheme'] . '://' . $p['host'] . (isset($p['port']) ? ':' . $p['port'] : '') . '/feed/';
  return array_values(array_unique($c));
}

function absolu(string $href, string $base): string {
  if (preg_match('#^https?://#i', $href)) return $href;
  $p = parse_url($base);
  $racine = ($p['scheme'] ?? 'https') . '://' . ($p['host'] ?? '') . (isset($p['port']) ? ':' . $p['port'] : '');
  if (str_starts_with($href, '//')) return ($p['scheme'] ?? 'https') . ':' . $href;
  if (str_starts_with($href, '/')) return $racine . $href;
  return rtrim(dirname($base), '/') . '/' . $href;
}
