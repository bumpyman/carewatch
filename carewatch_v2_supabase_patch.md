# CareWatch v2.0 : correctif Supabase (version simplifiée)

Règle unique pour la partie B : ouvrir `index.html`, faire Ctrl+F sur la ligne indiquée en **Chercher**, puis coller le bloc **juste après** cette ligne (ou juste avant quand c'est précisé). Rien à supprimer, rien à remplacer.

---

## Partie A : SQL (Supabase > SQL Editor, à exécuter une fois)

```sql
alter table public.recits
  add column if not exists type text not null default 'signalement'
    check (type in ('signalement','positif')),
  add column if not exists source_professionnel text,
  add column if not exists motifs_percus jsonb,
  add column if not exists type_periode text,
  add column if not exists categories_positives jsonb,
  add column if not exists npa_coherent text;

alter table public.recits drop column if exists code_postal;
alter table public.recits drop column if exists email;

create or replace function public.soumettre_recit(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_numero text;
  v_code   text;
begin
  if length(coalesce(p->>'description','')) < 20 then
    raise exception 'Description trop courte';
  end if;
  v_numero := 'CW-' || to_char(now(), 'YYYY') || '-' || lpad(nextval('recit_numero_seq')::text, 5, '0');
  v_code   := public.cw_nouveau_code(10);
  insert into public.recits (
    numero, code_hash, type,
    role, source_professionnel, tranche_age, canton, etablissement_id, etablissement_nom,
    service, date_incident, type_periode, type_incident, motifs_percus, categories_positives,
    npa_coherent, description, impact, dms, dms_score, dms_max,
    a_cherche_aide, souhaite_en_parler,
    recevoir_resultats, recontact_echange, recontact_etude,
    publier_fiche, lecture_texte_complet, accepte_recontact_email
  ) values (
    v_numero, public.cw_hash(v_code), coalesce(p->>'type','signalement'),
    p->>'role', p->>'source_professionnel', p->>'tranche_age', p->>'canton',
    p->>'etablissement_id', p->>'etablissement_nom',
    p->>'service', nullif(p->>'date_incident','')::date, p->>'type_periode', p->>'type_incident',
    p->'motifs_percus', p->'categories_positives',
    p->>'npa_coherent', p->>'description', p->>'impact', p->'dms',
    nullif(p->>'dms_score','')::int, nullif(p->>'dms_max','')::int,
    coalesce((p->>'a_cherche_aide')::boolean, false),
    coalesce((p->>'souhaite_en_parler')::boolean, false),
    coalesce((p->>'recevoir_resultats')::boolean, false),
    coalesce((p->>'recontact_echange')::boolean, false),
    coalesce((p->>'recontact_etude')::boolean, false),
    coalesce((p->>'publier_fiche')::boolean, false),
    coalesce((p->>'lecture_texte_complet')::boolean, false),
    coalesce((p->>'accepte_recontact_email')::boolean, false)
  );
  insert into public.recits_journal (numero, action) values (v_numero, 'soumis');
  return jsonb_build_object('numero', v_numero, 'code', v_code);
end $$;

create or replace function public.lire_recit(p_numero text, p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_id uuid := public.cw_verifier(p_numero, p_code);
  r    public.recits;
begin
  if v_id is null then return null; end if;
  select * into r from public.recits where id = v_id;
  return jsonb_build_object(
    'numero', r.numero, 'type', r.type, 'statut', r.statut, 'cree_le', r.cree_le,
    'canton', r.canton, 'etablissement_nom', r.etablissement_nom, 'service', r.service,
    'date_incident', r.date_incident, 'type_incident', r.type_incident,
    'dms_score', r.dms_score, 'dms_max', r.dms_max,
    'recevoir_resultats', r.recevoir_resultats, 'recontact_echange', r.recontact_echange,
    'recontact_etude', r.recontact_etude, 'publier_fiche', r.publier_fiche,
    'lecture_texte_complet', r.lecture_texte_complet, 'accepte_recontact_email', r.accepte_recontact_email
  );
end $$;

create or replace function public.modifier_autorisations(p_numero text, p_code text, p jsonb)
returns boolean language plpgsql security definer set search_path = public as $$
declare
  v_id uuid := public.cw_verifier(p_numero, p_code);
begin
  if v_id is null then return false; end if;
  update public.recits set
    recevoir_resultats      = coalesce((p->>'recevoir_resultats')::boolean, false),
    recontact_echange       = coalesce((p->>'recontact_echange')::boolean, false),
    recontact_etude         = coalesce((p->>'recontact_etude')::boolean, false),
    publier_fiche           = coalesce((p->>'publier_fiche')::boolean, false),
    lecture_texte_complet   = coalesce((p->>'lecture_texte_complet')::boolean, false),
    accepte_recontact_email = coalesce((p->>'accepte_recontact_email')::boolean, false),
    modifie_le              = now()
  where id = v_id;
  insert into public.recits_journal (numero, action) values (upper(trim(p_numero)), 'autorisations_modifiees');
  return true;
end $$;

create or replace function public.retirer_recit(p_numero text, p_code text)
returns boolean language plpgsql security definer set search_path = public as $$
declare
  v_id uuid := public.cw_verifier(p_numero, p_code);
begin
  if v_id is null then return false; end if;
  update public.recits set
    statut = 'retire', retire_le = now(), modifie_le = now(),
    description = null, impact = null, dms = null, dms_score = null,
    motifs_percus = null, categories_positives = null,
    recevoir_resultats = false, recontact_echange = false, recontact_etude = false,
    publier_fiche = false, lecture_texte_complet = false, accepte_recontact_email = false
  where id = v_id;
  insert into public.recits_journal (numero, action) values (upper(trim(p_numero)), 'retire');
  return true;
end $$;

drop view if exists public.recits_publics;
create view public.recits_publics as
  select numero, type, to_char(cree_le, 'YYYY') as annee, tranche_age, canton,
         etablissement_nom, service, type_incident, dms_score, dms_max
  from public.recits
  where publier_fiche = true and statut = 'publie';
grant select on public.recits_publics to anon;
```

---

## Partie B : `index.html` (11 collages, une ligne d'ancrage chacun)

### 1. Charger Supabase

**Chercher :** `<script src="/vendor/babel.min.js"></script>`

**Coller après :**

```html
    <script src="/vendor/supabase.min.js"></script>
    <script>
        window.cwDb = supabase.createClient(
            'https://rujgfxlepfeonpjorlpg.supabase.co',
            'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJ1amdmeGxlcGZlb25wam9ybHBnIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODgzMTE2NjAsImV4cCI6MjEwMzg4NzY2MH0.koYVDo8tKlzmxzzW6bJJjlEdVwcd3hSTtJ-IQ0JL1JY'
        );
    </script>
```

Fichier à déposer dans `/vendor/` : télécharger `https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/dist/umd/supabase.js` et l'enregistrer sous le nom `supabase.min.js`.

### 2. Fonctions et composants partagés

**Chercher :** `const useApp = () => useContext(AppContext);`

**Coller après :**

```jsx
// ============================================
// SUPABASE : fonctions et composants partagés
// ============================================

const cwSoumettre = async (payload) => {
  try {
    const { data, error } = await window.cwDb.rpc('soumettre_recit', { p: payload });
    if (error) throw error;
    return data;
  } catch (e) {
    console.error('Base CareWatch :', e);
    return null;
  }
};

const cwDmsScore = (dms) => {
  const map = { 'Jamais': 0, 'Rarement': 1, 'Parfois': 2, 'Souvent': 3, 'Toujours': 4 };
  const entries = Object.values(dms || {});
  const total = entries.reduce((s, v) => s + (typeof v === 'string' ? (map[v] || 0) : (v?.score || 0)), 0);
  return { total, max: entries.length * 4 };
};

const AGE_RANGES = ['Moins de 18 ans', '18-24 ans', '25-34 ans', '35-44 ans', '45-54 ans', '55-64 ans', '65 ans et plus'];

const CwCheck = ({ id, checked, onChange, children }) => (
  <label htmlFor={id} className="flex items-start gap-3 p-3 rounded-lg bg-gray-50 cursor-pointer hover:bg-gray-100 transition-colors">
    <input type="checkbox" id={id} checked={!!checked} onChange={e => onChange(e.target.checked)} className="mt-1" />
    <span className="text-sm text-gray-700">{children}</span>
  </label>
);

function SuiviCheckboxes({ data, setData }) {
  const set = (k) => (v) => setData(prev => ({ ...prev, [k]: v }));
  const needsEmail = data.wantResults || data.contactExchange || data.contactStudy || data.acceptEmailContact;
  return (
    <>
      <Card className="p-4">
        <h3 className="font-medium mb-3 flex items-center gap-2"><Heart className="w-5 h-5 text-teal-600" /> Votre situation</h3>
        <div className="space-y-2">
          <CwCheck id="cwSoughtHelp" checked={data.soughtHelp} onChange={set('soughtHelp')}>J'ai cherché de l'aide ou un accompagnement après cet incident</CwCheck>
          <CwCheck id="cwWantsToTalk" checked={data.wantsToTalk} onChange={set('wantsToTalk')}>J'aimerais pouvoir en parler avec des personnes qui comprennent</CwCheck>
        </div>
        <Select label="Tranche d'âge (facultatif)" value={data.ageRange || ''} onChange={v => setData(prev => ({ ...prev, ageRange: v }))} options={AGE_RANGES} placeholder="Sélectionner..." className="mt-4" />
        <p className="text-xs text-gray-500 mt-1">Sert uniquement aux statistiques d'ensemble.</p>
      </Card>

      <Card className="p-4">
        <h3 className="font-medium mb-1 flex items-center gap-2"><Mail className="w-5 h-5 text-indigo-600" /> Suivi (facultatif)</h3>
        <p className="text-sm text-gray-600 mb-3">Chaque case est un choix libre. Vous pourrez le modifier à tout moment.</p>
        <div className="space-y-2">
          <CwCheck id="cwWantResults" checked={data.wantResults} onChange={set('wantResults')}>Recevoir par e-mail les résultats généraux de l'observatoire, une fois publiés (chiffres d'ensemble, aucun signalement individuel)</CwCheck>
          <CwCheck id="cwContactExchange" checked={data.contactExchange} onChange={set('contactExchange')}>Être recontacté·e pour un échange avec l'équipe CareWatch™ (questions, témoignage)</CwCheck>
          <CwCheck id="cwContactStudy" checked={data.contactStudy} onChange={set('contactStudy')}>Être recontacté·e pour participer à une étude sur l'équité des soins</CwCheck>
          <CwCheck id="cwPublishSummary" checked={data.publishSummary} onChange={set('publishSummary')}>Publier la fiche résumée (canton, année, tranche d'âge, service, type d'incident, score), sous un numéro, dans les données ouvertes</CwCheck>
          <CwCheck id="cwAllowFullRead" checked={data.allowFullRead} onChange={set('allowFullRead')}>Permettre aux membres de l'équipe, tenus au secret par contrat, de lire mon texte complet</CwCheck>
          <CwCheck id="cwAcceptEmail" checked={data.acceptEmailContact} onChange={set('acceptEmailContact')}>Accepter que l'équipe me recontacte par e-mail. Aucun suivi thérapeutique n'est proposé par ce biais.</CwCheck>
        </div>
        {needsEmail && (
          <div className="mt-3">
            <Input label="Adresse e-mail" type="email" value={data.email || ''} onChange={v => setData(prev => ({ ...prev, email: v }))} placeholder="votre@email.ch" />
            <p className="text-xs text-gray-600 mt-1 flex items-center gap-1"><Lock className="w-3 h-3 text-teal-600" /> Votre adresse est transmise à l'équipe par courriel et reste en dehors de la base de données.</p>
          </div>
        )}
        <div className="mt-4 p-3 bg-teal-50 rounded-lg border border-teal-100">
          <p className="text-sm text-teal-800">À la fin, vous recevrez le numéro de votre signalement et un code personnel. Ils vous permettent, à tout moment et sans compte, de retirer votre signalement ou de modifier vos autorisations dans « Mes témoignages », bloc « Gérer mon signalement ».</p>
        </div>
      </Card>
    </>
  );
}

function GererSignalement() {
  const [numero, setNumero] = useState('');
  const [code, setCode] = useState('');
  const [recit, setRecit] = useState(null);
  const [auth, setAuth] = useState({});
  const [msg, setMsg] = useState('');
  const [busy, setBusy] = useState(false);
  const KEYS = [
    ['recevoir_resultats', 'Recevoir les résultats généraux par e-mail'],
    ['recontact_echange', 'Être recontacté·e pour un échange avec l\'équipe'],
    ['recontact_etude', 'Être recontacté·e pour participer à une étude'],
    ['publier_fiche', 'Publier la fiche résumée dans les données ouvertes'],
    ['lecture_texte_complet', 'Permettre la lecture du texte complet par l\'équipe'],
    ['accepte_recontact_email', 'Accepter un recontact par e-mail'],
  ];
  const lire = async () => {
    setBusy(true); setMsg('');
    const { data, error } = await window.cwDb.rpc('lire_recit', { p_numero: numero, p_code: code });
    setBusy(false);
    if (error || !data) { setRecit(null); setMsg('Vérifiez le numéro et le code personnel, puis réessayez.'); return; }
    setRecit(data);
    setAuth(Object.fromEntries(KEYS.map(([k]) => [k, !!data[k]])));
  };
  const enregistrer = async () => {
    setBusy(true);
    const { data, error } = await window.cwDb.rpc('modifier_autorisations', { p_numero: numero, p_code: code, p: auth });
    setBusy(false);
    setMsg(data && !error ? 'Autorisations mises à jour.' : 'Réessayez dans un instant.');
  };
  const retirer = async () => {
    if (!window.confirm('Retirer définitivement ce signalement ? Le texte et les réponses seront effacés.')) return;
    setBusy(true);
    const { data, error } = await window.cwDb.rpc('retirer_recit', { p_numero: numero, p_code: code });
    setBusy(false);
    if (data && !error) { setRecit(null); setMsg('Signalement retiré. Merci de votre confiance.'); }
    else setMsg('Réessayez dans un instant.');
  };
  return (
    <Card className="p-5 mb-6 border-teal-200">
      <h3 className="font-semibold text-gray-900 mb-1 flex items-center gap-2"><Lock className="w-5 h-5 text-teal-600" /> Gérer mon signalement</h3>
      <p className="text-sm text-gray-600 mb-4">Avec le numéro et le code personnel reçus à la fin de votre signalement, vous pouvez consulter son état, modifier vos autorisations ou le retirer. Sans compte.</p>
      <div className="grid grid-cols-1 sm:grid-cols-2 gap-3 mb-3">
        <Input label="Numéro" value={numero} onChange={v => setNumero(v.toUpperCase())} placeholder="CW-2026-00012" />
        <Input label="Code personnel" value={code} onChange={v => setCode(v.toUpperCase())} placeholder="ABCD234EFG" />
      </div>
      <Button onClick={lire} disabled={busy || !numero || !code} icon={Search}>Consulter</Button>
      {msg && <p className="text-sm text-teal-700 mt-3">{msg}</p>}
      {recit && (
        <div className="mt-5 space-y-4">
          <div className="grid grid-cols-2 gap-3">
            <div className="bg-gray-50 rounded-xl p-3"><p className="text-sm text-gray-600">Statut</p><p className="font-medium capitalize">{recit.statut.replace('_', ' ')}</p></div>
            <div className="bg-gray-50 rounded-xl p-3"><p className="text-sm text-gray-600">Établissement</p><p className="font-medium">{recit.etablissement_nom || 'Non précisé'}</p></div>
          </div>
          <div>
            <p className="text-sm font-semibold text-gray-800 mb-2">Mes autorisations</p>
            <div className="space-y-2">
              {KEYS.map(([k, label]) => (
                <CwCheck key={k} id={'gerer-' + k} checked={auth[k]} onChange={v => setAuth({ ...auth, [k]: v })}>{label}</CwCheck>
              ))}
            </div>
          </div>
          <div className="flex flex-col sm:flex-row gap-3">
            <Button onClick={enregistrer} disabled={busy} className="flex-1" icon={Check}>Enregistrer mes autorisations</Button>
            <Button onClick={retirer} disabled={busy} variant="danger" className="flex-1" icon={Trash2}>Retirer mon signalement</Button>
          </div>
        </div>
      )}
    </Card>
  );
}
```

### 3. Cases à cocher dans le formulaire (deux endroits)

**Chercher :** `label="Informations complémentaires (optionnel)"` (le texte apparaît deux fois, pour les patient·e·s et pour les professionnel·le·s). À chaque fois, la ligne juste au-dessus est `<TextArea `.

**Coller avant cette ligne `<TextArea `, aux deux endroits :**

```jsx
            <SuiviCheckboxes data={data} setData={setData} />
```

### 4. Deux états dans NewReport

**Chercher :** `const [emailSent, setEmailSent] = useState(false);`

**Coller après :**

```jsx
  const [numero, setNumero] = useState(null);
  const [codePerso, setCodePerso] = useState(null);
```

### 5. Enregistrement en base (signalement)

**Chercher :** `// Envoi de l'email via FormSubmit (comme carewat.ch)`

**Coller avant cette ligne :**

```jsx
    // Enregistrement en base (Supabase), hors modification
    if (!isModification) {
      const institution = DB.institutions.find(i => i.id === data.institution);
      const { total: dmsTotal, max: dmsMax } = cwDmsScore(dms);
      const npaHint = getNpaHint(data.postalCode, data.canton);
      const db = await cwSoumettre({
        type: 'signalement',
        role: data.role || (isPro ? 'professionnel' : null),
        source_professionnel: data.source || null,
        tranche_age: data.ageRange || null,
        canton: data.canton,
        etablissement_id: data.institution,
        etablissement_nom: institution ? institution.fullName : null,
        service: data.service,
        date_incident: data.date || null,
        type_periode: data.dateType || null,
        type_incident: data.incidentType === 'Autre' ? (data.otherIncidentType || 'Autre') : data.incidentType,
        motifs_percus: data.grounds || [],
        npa_coherent: npaHint ? (npaHint.match ? 'oui' : 'non') : 'non_verifiable',
        description: data.description,
        impact: data.impact || null,
        dms, dms_score: dmsTotal, dms_max: dmsMax,
        a_cherche_aide: !!data.soughtHelp,
        souhaite_en_parler: !!data.wantsToTalk,
        recevoir_resultats: !!data.wantResults,
        recontact_echange: !!data.contactExchange,
        recontact_etude: !!data.contactStudy,
        publier_fiche: !!data.publishSummary,
        lecture_texte_complet: !!data.allowFullRead,
        accepte_recontact_email: !!data.acceptEmailContact,
      });
      if (db) { setNumero(db.numero); setCodePerso(db.code); newReport.numero = db.numero; }
    }
```

### 6. Contenu du courriel FormSubmit

**Chercher :** `recontact: reportData.wantContact ?`

**Coller après cette ligne :**

```jsx
          numero_base: reportData.numero || 'non enregistré en base',
          tranche_age: reportData.ageRange || 'Non précisée',
          situation_cherche_aide: reportData.soughtHelp ? 'Oui' : 'Non',
          situation_en_parler: reportData.wantsToTalk ? 'Oui' : 'Non',
          suivi_resultats: reportData.wantResults ? 'Oui' : 'Non',
          suivi_recontact_echange: reportData.contactExchange ? 'Oui' : 'Non',
          suivi_recontact_etude: reportData.contactStudy ? 'Oui' : 'Non',
          suivi_publier_fiche: reportData.publishSummary ? 'Oui' : 'Non',
          suivi_lecture_texte: reportData.allowFullRead ? 'Oui' : 'Non',
          suivi_accord_email: reportData.acceptEmailContact ? 'Oui' : 'Non',
          email_suivi: reportData.email || 'Non fourni',
```

### 7. Écran de confirmation (signalement)

**Chercher :** `text-3xl md:text-4xl font-mono font-bold text-center text-teal-600 tracking-wider`

**Coller après cette ligne (elle se termine par `{code}</p>`) :**

```jsx
                {numero && (
                  <div className="mt-3 pt-3 border-t border-teal-100 text-center">
                    <p className="text-xs text-gray-500">Numéro du signalement</p>
                    <p className="text-xl font-mono font-bold text-teal-600">{numero}</p>
                    <p className="text-xs text-gray-500 mt-2">Code personnel</p>
                    <p className="text-xl font-mono font-bold text-teal-600 tracking-wider">{codePerso}</p>
                    {(() => {
                      const inst = DB.institutions.find(i => i.id === data.institution);
                      const corps = ['Copie de mes réponses CareWatch', 'Numéro : ' + numero, 'Code personnel : ' + codePerso, 'Établissement : ' + (inst ? inst.fullName : ''), 'Service : ' + (data.service || ''), 'Type d\'incident : ' + (data.incidentType || ''), '', 'Description :', data.description || '', '', 'Impact :', data.impact || ''].join('\n');
                      return (
                        <a href={'mailto:?subject=' + encodeURIComponent('Copie de mon signalement CareWatch') + '&body=' + encodeURIComponent(corps)} className="mt-3 mx-auto flex items-center justify-center gap-2 px-4 py-2 rounded-lg border border-teal-300 text-teal-700 text-sm font-medium hover:bg-teal-50 transition-colors w-fit">
                          <Mail className="w-4 h-4" /> Recevoir une copie de mes réponses
                        </a>
                      );
                    })()}
                    <p className="text-xs text-gray-500 mt-1">Courriel préparé sur votre appareil, rien n'est conservé par l'observatoire.</p>
                  </div>
                )}
```

### 8. État dans PositiveReport

**Chercher :** `const [code, setCode] = useState('');`

**Coller après :**

```jsx
  const [dbRes, setDbRes] = useState(null);
```

### 9. Enregistrement en base (expérience positive)

**Chercher :** `const modif = isModification ? ' ⟳ MODIFICATION' : '';`

**Coller après :**

```jsx
    const db = isModification ? null : await cwSoumettre({
      type: 'positif',
      role: data.role || null,
      canton: data.canton,
      etablissement_id: data.institution,
      etablissement_nom: data.institutionName,
      date_incident: data.date || null,
      categories_positives: data.categories || [],
      npa_coherent: npaCheck ? (npaCheck.match ? 'oui' : 'non') : 'non_verifiable',
      description: data.description,
    });
    if (db) setDbRes(db);
```

### 10. Écran de confirmation (expérience positive)

**Chercher :** `<p className="text-2xl font-mono font-bold text-emerald-600">{code}</p>`

**Coller après :**

```jsx
              {dbRes && (
                <div className="mt-3 pt-3 border-t border-emerald-200">
                  <p className="text-xs text-gray-500">Numéro</p>
                  <p className="text-lg font-mono font-bold text-emerald-600">{dbRes.numero}</p>
                  <p className="text-xs text-gray-500 mt-1">Code personnel</p>
                  <p className="text-lg font-mono font-bold text-emerald-600 tracking-wider">{dbRes.code}</p>
                </div>
              )}
```

### 11. Bloc « Gérer mon signalement »

**Chercher :** `{reports.length === 0 ? (`

**Coller avant cette ligne :**

```jsx
      <GererSignalement />
```

---

## Partie C : vérification

1. Faire un signalement : l'écran final montre le code de suivi habituel, puis en dessous le numéro `CW-2026-000xx` et le code personnel. La ligne apparaît dans Supabase > Table Editor > recits.
2. Dans « Mes témoignages », bloc « Gérer mon signalement » : saisir numéro et code, modifier une case, enregistrer, vérifier la colonne dans Supabase.
3. Si la base est injoignable, le signalement passe quand même par FormSubmit et l'écran final montre seulement le code de suivi.
