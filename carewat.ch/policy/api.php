<?php
// Filet de securite : toute erreur fatale est renvoyee en JSON (jamais une page HTML).
ini_set('display_errors', '0');
register_shutdown_function(function () {
    $e = error_get_last();
    if ($e && in_array($e['type'], [E_ERROR, E_PARSE, E_CORE_ERROR, E_COMPILE_ERROR], true)) {
        if (!headers_sent()) { http_response_code(500); header('Content-Type: application/json; charset=utf-8'); }
        echo json_encode(['error' => 'Erreur serveur PHP : ' . $e['message']]);
    }
});
/**
 * CareWatch Policy — Backend API v2.0
 * Convivens Lab · HEG-Genève (HES-SO) · David-Zacharie Issom
 * Déploiement : carewat.ch/policy/api.php
 */

// ── .env — remonte jusqu'à 6 niveaux ────────────────────────────────────────
function loadEnv(string $path): void {
    if (!file_exists($path)) return;
    foreach (file($path, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) as $line) {
        $line = trim($line);
        if ($line === '' || str_starts_with($line, '#') || !str_contains($line, '=')) continue;
        [$k, $v] = explode('=', $line, 2);
        $k = trim($k); $v = trim($v, " \t\n\r\"'");
        if ($k !== '' && !array_key_exists($k, $_ENV)) { $_ENV[$k] = $v; putenv("$k=$v"); }
    }
}
$_d = __DIR__;
for ($i = 0; $i < 6; $i++) {
    if (file_exists($_d . '/.env')) { loadEnv($_d . '/.env'); break; }
    $p = dirname($_d); if ($p === $_d) break; $_d = $p;
}

// Charger .env si présent (Infomaniak ne supporte pas les variables d'env serveur)
if (file_exists(__DIR__ . '/.env')) {
    foreach (file(__DIR__ . '/.env', FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) as $line) {
        if (str_starts_with(trim($line), '#')) continue;
        if (str_contains($line, '=')) [$k, $v] = explode('=', $line, 2);
        else continue;
        $_ENV[trim($k)] = trim($v);
    }
}
define('ANTHROPIC_API_KEY', $_ENV['ANTHROPIC_API_KEY'] ?? getenv('ANTHROPIC_API_KEY') ?? '');
define('CACHE_DIR', __DIR__ . '/cache/');
define('CACHE_TTL', 86400);

// ── CORS ─────────────────────────────────────────────────────────────────────
$origin = $_SERVER['HTTP_ORIGIN'] ?? '';
$allowed = ['https://carewat.ch','https://www.carewat.ch','http://localhost','http://127.0.0.1','null'];
header('Access-Control-Allow-Origin: ' . (in_array($origin, $allowed) ? $origin : 'https://carewat.ch'));
header('Access-Control-Allow-Methods: GET, POST, OPTIONS');
header('Access-Control-Allow-Headers: Content-Type, Authorization');
if ($_SERVER['REQUEST_METHOD'] === 'OPTIONS') { http_response_code(204); exit; }
header('Content-Type: application/json; charset=utf-8');

// ── COMMUNITY ENDPOINTS ───────────────────────────────────────────────────
// Ajout à api.php — actions: community_list, community_submit,
//                            community_vote, community_check, community_leaderboard

function community_db(): PDO {
    $dbPath = __DIR__ . '/community.sqlite';
    $pdo = new PDO('sqlite:' . $dbPath);
    $pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
    $pdo->exec("CREATE TABLE IF NOT EXISTS proposals (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        name        TEXT NOT NULL,
        pseudo      TEXT NOT NULL,
        canton      TEXT DEFAULT 'CH',
        cat         TEXT DEFAULT 'Santé',
        whatisit    TEXT DEFAULT '',
        impact      INTEGER DEFAULT 5,
        votes       INTEGER DEFAULT 0,
        icon        TEXT DEFAULT '💡',
        created_at  DATETIME DEFAULT (datetime('now'))
    )");
    return $pdo;
}

function community_normalize(string $s): string {
    $s = mb_strtolower(trim($s));
    $s = preg_replace('/[^a-z0-9àâäéèêëîïôùûüç\s]/u', ' ', $s);
    $s = preg_replace('/\s+/', ' ', $s);
    return $s;
}

function community_similar(string $a, string $b): float {
    $na = community_normalize($a);
    $nb = community_normalize($b);
    if (!$na || !$nb) return 0.0;
    similar_text($na, $nb, $pct);
    return $pct / 100;
}

function handle_community(string $action, array $get, ?array $post): array {

    if ($action === 'community_list') {
        $sort = $get['sort'] ?? 'date';
        $order = match($sort) {
            'impact' => 'impact DESC, votes DESC',
            'votes'  => 'votes DESC, impact DESC',
            default  => 'created_at DESC',
        };
        $pdo  = community_db();
        $rows = $pdo->query("SELECT * FROM proposals ORDER BY $order LIMIT 100")->fetchAll(PDO::FETCH_ASSOC);
        return ['items' => $rows];
    }

    if ($action === 'community_check') {
        $title = trim($get['title'] ?? '');
        if (strlen($title) < 3) return ['similar' => []];
        $pdo = community_db();
        $all = $pdo->query("SELECT id, name FROM proposals ORDER BY created_at DESC LIMIT 200")->fetchAll(PDO::FETCH_ASSOC);
        $similar = array_filter($all, fn($r) => community_similar($title, $r['name']) > 0.45);
        return ['similar' => array_values(array_slice($similar, 0, 3))];
    }

    if ($action === 'community_submit') {
        $data   = $post ?? [];
        $name   = trim($data['name']   ?? '');
        $pseudo = trim($data['pseudo'] ?? '');
        if (!$name || !$pseudo) return ['ok' => false, 'error' => 'Titre et pseudo obligatoires.'];
        if (mb_strlen($name) > 200)   return ['ok' => false, 'error' => 'Titre trop long (max 200 caractères).'];
        if (mb_strlen($pseudo) > 50)  return ['ok' => false, 'error' => 'Pseudo trop long (max 50 caractères).'];

        $pdo = community_db();

        // Anti-doublon
        $all = $pdo->query("SELECT name FROM proposals ORDER BY created_at DESC LIMIT 200")->fetchAll(PDO::FETCH_ASSOC);
        foreach ($all as $row) {
            if (community_similar($name, $row['name']) > 0.6) {
                return ['ok' => false, 'error' => 'Une proposition très similaire existe déjà : « ' . $row['name'] . ' »'];
            }
        }

        $canton  = substr(trim($data['canton']  ?? 'CH'), 0, 5);
        $cat     = substr(trim($data['cat']     ?? 'Santé'), 0, 30);
        $desc    = substr(trim($data['whatisit']?? ''), 0, 500);
        // Impact estimé selon la méthodologie CareWatch
        // Effets estimés par catégorie (delta sur indicateurs de santé publique)
        $cat_effects = [
            'Santé'         => ['renoncement'=>-2.0, 'esperance'=>0.4, 'mortEvit'=>-8,  'gini'=>-0.4],
            'Social'        => ['renoncement'=>-1.5, 'esperance'=>0.3, 'mortEvit'=>-5,  'gini'=>-0.5],
            'Fiscal'        => ['renoncement'=>-1.0, 'esperance'=>0.2, 'mortEvit'=>-3,  'gini'=>-0.3],
            'Travail'       => ['renoncement'=>-1.2, 'esperance'=>0.3, 'mortEvit'=>-4,  'gini'=>-0.3],
            'Logement'      => ['renoncement'=>-1.5, 'esperance'=>0.3, 'mortEvit'=>-4,  'gini'=>-0.4],
            'Environnement' => ['renoncement'=>-0.5, 'esperance'=>0.3, 'mortEvit'=>-3,  'gini'=>-0.2],
            'Mobilité'      => ['renoncement'=>-0.3, 'esperance'=>0.2, 'mortEvit'=>-2,  'gini'=>-0.1],
            'Éducation'     => ['renoncement'=>-0.8, 'esperance'=>0.3, 'mortEvit'=>-3,  'gini'=>-0.3],
        ];
        $fx = $cat_effects[$cat] ?? $cat_effects['Santé'];
        // Formule CareWatch : score = 50 + Δrenoncement×1.2 + Δesperance×5 + ΔmortEvit×0.22 + Δgini×4
        $score_delta = abs($fx['renoncement'])*1.2 + abs($fx['esperance'])*5
                     + abs($fx['mortEvit'])*0.22 + abs($fx['gini'])*4;
        // Bonus si description détaillée (proxy de qualité)
        $desc_bonus = strlen($desc) > 300 ? 1.0 : (strlen($desc) > 150 ? 0.5 : 0);
        $impact = min(9, max(3, round($score_delta + $desc_bonus)));

        // Icône par catégorie
        $icons = ['Santé'=>'🏥','Social'=>'🤝','Fiscal'=>'💰','Travail'=>'💼',
                  'Logement'=>'🏠','Environnement'=>'🌿','Mobilité'=>'🚆','Éducation'=>'📚'];
        $icon = $icons[$cat] ?? '💡';

        $stmt = $pdo->prepare("INSERT INTO proposals (name, pseudo, canton, cat, whatisit, impact, icon)
                               VALUES (:name, :pseudo, :canton, :cat, :whatisit, :impact, :icon)");
        $stmt->execute([':name'=>$name, ':pseudo'=>$pseudo, ':canton'=>$canton,
                        ':cat'=>$cat, ':whatisit'=>$desc, ':impact'=>$impact, ':icon'=>$icon]);
        return ['ok' => true, 'id' => $pdo->lastInsertId()];
    }

    if ($action === 'community_vote') {
        $id  = intval($get['id'] ?? 0);
        if (!$id) return ['error' => 'ID manquant'];
        $pdo = community_db();
        $pdo->exec("UPDATE proposals SET votes = votes + 1 WHERE id = $id");
        $votes = $pdo->query("SELECT votes FROM proposals WHERE id = $id")->fetchColumn();
        return ['ok' => true, 'votes' => intval($votes)];
    }

    if ($action === 'community_leaderboard') {
        $pdo = community_db();
        $rows = $pdo->query("
            SELECT pseudo,
                   COUNT(*) as count,
                   ROUND(AVG(impact), 1) as avg_impact,
                   SUM(votes) as total_votes,
                   ROUND(COUNT(*) * AVG(impact) + SUM(votes) * 0.5, 1) as score
            FROM proposals
            GROUP BY LOWER(pseudo)
            ORDER BY score DESC
            LIMIT 20
        ")->fetchAll(PDO::FETCH_ASSOC);
        return ['board' => $rows];
    }

    return ['error' => 'Action inconnue'];
}


$action = $_GET['action'] ?? 'ping';
try {
    $body = null;
    if ($_SERVER['REQUEST_METHOD'] === 'POST') {
        $body = json_decode(file_get_contents('php://input'), true);
    }
    switch ($action) {
        case 'ping':         ping(); break;
        case 'ai':           handleAI(); break;
        case 'swissvotes':   echo json_encode(fetchSwissvotes()); break;
        case 'parlament':    echo json_encode(fetchParlament($_GET['affair'] ?? '')); break;
        case 'ge_votations': echo json_encode(fetchGeVotations()); break;
        case 'cache_clear':  cacheClear(); break;
        case 'community_list':
        case 'community_check':
        case 'community_submit':
        case 'community_vote':
        case 'community_leaderboard':
            echo json_encode(handle_community($action, $_GET, $body)); break;
        default:
            http_response_code(404);
            echo json_encode(['error' => 'Unknown action']);
    }
} catch (Throwable $e) {
    http_response_code(500);
    echo json_encode(['error' => $e->getMessage()]);
}

// ── Ping / diagnostic ────────────────────────────────────────────────────────
function ping(): void {
    $envPath = ''; $d = __DIR__;
    for ($i = 0; $i < 6; $i++) {
        if (file_exists($d.'/.env')) { $envPath = $d.'/.env'; break; }
        $p = dirname($d); if ($p === $d) break; $d = $p;
    }
    echo json_encode([
        'status'   => 'ok', 'version' => '2.0', 'time' => date('c'),
        'key_set'  => ANTHROPIC_API_KEY !== '' ? 'yes' : 'no',
        'env_path' => $envPath ?: 'not found',
        'cache'    => is_writable(CACHE_DIR) ? 'writable' : 'not writable',
    ]);
}

// ── Anthropic proxy ───────────────────────────────────────────────────────────
function handleAI(): void {
    @set_time_limit(120);
    if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
        http_response_code(405); echo json_encode(['error'=>'POST required']); return;
    }
    $key = ANTHROPIC_API_KEY;
    if (empty($key)) {
        $auth = $_SERVER['HTTP_AUTHORIZATION'] ?? '';
        if (str_starts_with($auth, 'Bearer ')) $key = substr($auth, 7);
    }
    if (empty($key)) {
        http_response_code(401);
        echo json_encode(['error'=>'Créez .env avec ANTHROPIC_API_KEY=sk-ant-...']);
        return;
    }
    $payload = json_decode(file_get_contents('php://input'), true);
    if (!$payload) { http_response_code(400); echo json_encode(['error'=>'Invalid JSON']); return; }
    $payload['model']      = 'claude-opus-4-8';
    $payload['max_tokens'] = min((int)($payload['max_tokens'] ?? 1500), 4096);
    $ch = curl_init('https://api.anthropic.com/v1/messages');
    curl_setopt_array($ch, [
        CURLOPT_RETURNTRANSFER=>true, CURLOPT_POST=>true,
        CURLOPT_POSTFIELDS=>json_encode($payload),
        CURLOPT_HTTPHEADER=>['Content-Type: application/json','x-api-key: '.$key,'anthropic-version: 2023-06-01'],
        CURLOPT_TIMEOUT=>60, CURLOPT_SSL_VERIFYPEER=>true,
    ]);
    $resp = curl_exec($ch); $code = curl_getinfo($ch, CURLINFO_HTTP_CODE); $err = curl_error($ch);
    curl_close($ch);
    if ($err) { http_response_code(502); echo json_encode(['error'=>'cURL: '.$err]); return; }
    http_response_code($code); echo $resp;
}

// ── Swissvotes → format CareWatch ────────────────────────────────────────────
function fetchSwissvotes(): array {
    $cached = getCache('swissvotes');
    if ($cached) return $cached;

    $raw = httpGet('https://swissvotes.ch/votes.json?lang=fr&per_page=50&sort=date&order=desc');
    if (!$raw) return ['error'=>'Swissvotes unreachable','items'=>[]];

    $data = json_decode($raw, true);
    $votes = $data['votes'] ?? $data ?? [];
    $items = [];

    foreach (array_slice($votes, 0, 50) as $v) {
        $cw = svToCW($v);
        if ($cw) $items[] = $cw;
    }

    $result = ['source'=>'swissvotes.ch','fetched_at'=>date('c'),'items'=>$items];
    setCache('swissvotes', $result);
    return $result;
}

function svToCW(array $v): ?array {
    $anr   = $v['anr']           ?? null;
    $date  = $v['datum']         ?? $v['date'] ?? null;
    $name  = $v['titel_kurz_f']  ?? $v['titel_off_f'] ?? $v['title_fr'] ?? null;
    $pct   = $v['volkja_proz']   ?? null;
    $acc   = isset($v['annahme']) ? (bool)$v['annahme'] : ($pct > 50);
    $theme = $v['rechtsgebiet']  ?? '';
    $desc  = $v['kurzbeschreibung_f'] ?? $v['synopsis_f'] ?? '';

    if (!$anr || !$name) return null;

    $id   = 'sv_' . preg_replace('/[^a-z0-9]/', '_', strtolower((string)$anr));
    $year = $date ? (int)substr($date, 0, 4) : (int)date('Y');
    $era  = $year >= 2024 ? 'future' : ($year >= 2015 ? '2020s' : ($year >= 2010 ? '2010s' : ($year >= 2000 ? '2000s' : 'hist')));
    $dl   = ($acc ? 'Acceptée' : 'Rejetée') . ($date ? ' '.date('d.m.Y', strtotime($date)) : '') . ($pct ? ' · '.$pct.'% oui' : '');

    $cat = match(true) {
        str_contains($theme,'anté') || str_contains($theme,'ssurance') => 'Santé',
        str_contains($theme,'ocial') || str_contains($theme,'amille')  => 'Social',
        str_contains($theme,'ravail') || str_contains($theme,'mploi')  => 'Travail',
        str_contains($theme,'nvironnement') || str_contains($theme,'énergie') => 'Environnement',
        str_contains($theme,'iscal') || str_contains($theme,'mpôt')    => 'Fiscal',
        default => 'Social',
    };

    // Party positions from Swissvotes fields
    $pm = ['PS'=>['par_sthr_sp'],'Verts'=>['par_sthr_gps'],'PVL'=>['par_sthr_glp'],
           'Centre'=>['par_sthr_cvp','par_sthr_mitte'],'PLR'=>['par_sthr_fdp'],'UDC'=>['par_sthr_svp']];
    $pour = []; $contre = [];
    foreach ($pm as $party => $fields) {
        foreach ($fields as $f) {
            $val = $v[$f] ?? null;
            if ($val !== null) {
                if ((int)$val === 1) $pour[] = $party;
                elseif ((int)$val === 2) $contre[] = $party;
                break;
            }
        }
    }

    return [
        'id'=>$id,'lv'=>'federal','cat'=>$cat,'icon'=>'🗳️','year'=>$year,'era'=>$era,
        'dl'=>$dl,'commune'=>'','name'=>$name,'st'=>$acc?'acc':'rej','stl'=>($acc?'✓ ':'✗ ').$year,
        'whatisit'=>$desc,'desc'=>$desc,'data'=>$pct?'Résultat : '.$pct.'% oui.':'',
        'src'=>'swissvotes.ch · Chancellerie fédérale',
        'imp'=>4,'impL'=>'Données Swissvotes',
        'effects'=>['renoncement'=>0,'esperance'=>0,'mortEvit'=>0,'gini'=>0],
        'gains'=>[],'pertes'=>[],
        'groups'=>['precaires'=>5,'familles'=>5,'seniors'=>5,'migrants'=>5,'malades'=>5,'jeunes'=>5],
        '_parties'=>['pour'=>$pour,'contre'=>$contre],
    ];
}

// ── Parlament.ch → format CareWatch ─────────────────────────────────────────
function fetchParlament(string $affair = ''): array {
    $key = 'parlament_' . ($affair ?: 'recent');
    $cached = getCache($key);
    if ($cached) return $cached;

    // data.parlament.ch (nouvelle API officielle)
    $url = $affair
        ? "https://data.parlament.ch/api/v1/ratsvoten?AffairId=$affair&format=json&pageSize=200"
        : "https://data.parlament.ch/api/v1/ratsvoten?CouncilId=1&format=json&pageSize=50&orderBy=RegistrationDate+desc";

    $raw = httpGet($url);
    if (!$raw) return ['error'=>'Parlament.ch unreachable','items'=>[]];

    $data = json_decode($raw, true);
    $votes = $data['items'] ?? $data['d'] ?? $data['value'] ?? [];

    $affairs = [];
    foreach ($votes as $v) {
        $aid   = $v['IdAffair'] ?? $v['AffairId'] ?? null;
        $group = $v['NameFaction'] ?? $v['FactionName'] ?? 'Inconnu';
        $dec   = (int)($v['Decision'] ?? $v['Vote'] ?? 0);
        if (!$aid) continue;
        $affairs[$aid] ??= ['groups'=>[], 'title'=>$v['AffairTitle'] ?? $v['Title'] ?? ''];
        $affairs[$aid]['groups'][$group] ??= ['pour'=>0,'contre'=>0,'abs'=>0];
        match($dec) { 1=>$affairs[$aid]['groups'][$group]['pour']++,
                      2=>$affairs[$aid]['groups'][$group]['contre']++,
                      default=>$affairs[$aid]['groups'][$group]['abs']++ };
    }

    $items = [];
    foreach ($affairs as $aid => $aff) {
        $pour = array_keys(array_filter($aff['groups'], fn($g)=>$g['pour']>$g['contre']));
        $contre = array_keys(array_filter($aff['groups'], fn($g)=>$g['contre']>$g['pour']));
        $items[] = [
            'id'=>'parl_'.preg_replace('/[^a-z0-9]/', '_', strtolower((string)$aid)),
            'lv'=>'federal','cat'=>'Social','icon'=>'🏛️','year'=>(int)date('Y'),'era'=>'2020s',
            'dl'=>'Conseil national · '.date('Y'),'commune'=>'',
            'name'=>$aff['title']?:"Affaire parlementaire $aid",
            'st'=>count($pour)>count($contre)?'acc':'rej','stl'=>'CN '.date('Y'),
            'whatisit'=>"Vote du Conseil national sur l'affaire $aid.",
            'desc'=>'','data'=>'','src'=>'parlament.ch',
            'imp'=>3,'impL'=>'Vote CN',
            'effects'=>['renoncement'=>0,'esperance'=>0,'mortEvit'=>0,'gini'=>0],
            'gains'=>[],'pertes'=>[],
            'groups'=>['precaires'=>3,'familles'=>3,'seniors'=>3,'migrants'=>3,'malades'=>3,'jeunes'=>3],
            '_parties'=>['pour'=>$pour,'contre'=>$contre],
        ];
    }

    $result = ['source'=>'parlament.ch','fetched_at'=>date('c'),'items'=>$items];
    setCache($key, $result);
    return $result;
}

// ── GE votations → format CareWatch ─────────────────────────────────────────
function fetchGeVotations(): array {
    $cached = getCache('ge_votations');
    if ($cached) return $cached;

    $raw = httpGet('https://ckan.opendata.swiss/api/3/action/datastore_search?resource_id=5c94aa6e-f9d5-4b5f-abf6-f3e3e7e01a89&limit=50&sort=datum%20desc');
    $items = [];

    if ($raw) {
        $data = json_decode($raw, true);
        foreach ($data['result']['records'] ?? [] as $r) {
            $name = $r['kurzbeschreibung_f'] ?? $r['titel_f'] ?? null;
            if (!$name) continue;
            $date = $r['datum'] ?? date('Y');
            $year = (int)substr((string)$date, 0, 4);
            $acc  = isset($r['annahme']) ? (bool)$r['annahme'] : null;
            $pct  = $r['ja_proz_ge'] ?? $r['volkja_proz'] ?? null;
            $id   = 'ge_ov_'.preg_replace('/[^a-z0-9]/', '_', strtolower($r['anr'] ?? uniqid()));

            $items[] = [
                'id'=>$id,'lv'=>'cantonal','cat'=>'Social','icon'=>'🏛️',
                'year'=>$year,'era'=>$year>=2020?'2020s':($year>=2010?'2010s':'hist'),
                'commune'=>'Genève',
                'dl'=>($acc===null?'Votation':($acc?'Acceptée':'Rejetée')).' · GE · '.$date,
                'name'=>$name,'st'=>$acc?'acc':'rej','stl'=>($acc?'✓ ':'✗ ').$year,
                'whatisit'=>"Votation cantonale genevoise du $date.",'desc'=>'',
                'data'=>$pct?"GE : $pct% oui.":'','src'=>'opendata.swiss · Chancellerie GE',
                'imp'=>3,'impL'=>'Vote GE',
                'effects'=>['renoncement'=>0,'esperance'=>0,'mortEvit'=>0,'gini'=>0],
                'gains'=>[],'pertes'=>[],
                'groups'=>['precaires'=>4,'familles'=>4,'seniors'=>4,'migrants'=>4,'malades'=>4,'jeunes'=>4],
            ];
        }
    }

    $result = ['source'=>'opendata.swiss','fetched_at'=>date('c'),'items'=>$items];
    setCache('ge_votations', $result);
    return $result;
}

// ── Cache ─────────────────────────────────────────────────────────────────────
function ensureCache(): void {
    if (!is_dir(CACHE_DIR)) { mkdir(CACHE_DIR, 0755, true); file_put_contents(CACHE_DIR.'.htaccess',"Deny from all\n"); }
}
function cacheFile(string $k): string { return CACHE_DIR.preg_replace('/[^a-z0-9_]/', '_', $k).'.json'; }
function getCache(string $k): ?array {
    ensureCache(); $f = cacheFile($k);
    if (!file_exists($f) || time()-filemtime($f)>CACHE_TTL) return null;
    $d = file_get_contents($f); return $d ? json_decode($d, true) : null;
}
function setCache(string $k, array $d): void {
    ensureCache(); file_put_contents(cacheFile($k), json_encode($d, JSON_UNESCAPED_UNICODE|JSON_PRETTY_PRINT));
}
function cacheClear(): void {
    ensureCache();
    $token = $_GET['token'] ?? '';
    if (!hash_equals(hash('sha256', ANTHROPIC_API_KEY.date('Y-m-d')), $token)) {
        http_response_code(403); echo json_encode(['error'=>'Unauthorized']); return;
    }
    foreach (glob(CACHE_DIR.'*.json') as $f) unlink($f);
    echo json_encode(['status'=>'cache cleared']);
}

// ── HTTP ──────────────────────────────────────────────────────────────────────
function httpGet(string $url): ?string {
    $ch = curl_init($url);
    curl_setopt_array($ch, [
        CURLOPT_RETURNTRANSFER=>true, CURLOPT_TIMEOUT=>15, CURLOPT_FOLLOWLOCATION=>true,
        CURLOPT_SSL_VERIFYPEER=>true,
        CURLOPT_USERAGENT=>'CareWatch-Policy/2.0 (carewat.ch)',
        CURLOPT_HTTPHEADER=>['Accept: application/json'],
    ]);
    $data = curl_exec($ch); $code = curl_getinfo($ch, CURLINFO_HTTP_CODE); $err = curl_error($ch);
    curl_close($ch);
    return ($err || $code >= 400) ? null : ($data ?: null);
}
