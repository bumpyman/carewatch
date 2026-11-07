/* CareWatch : moteur de traduction.
   Le site est écrit en français. Ce moteur remplace, dans la page affichée, chaque texte français connu
   (texte, placeholder, title, aria-label, alt) par sa traduction, lue dans /i18n/<langue>.json.
   Un texte inconnu reste en français. Les noeuds d'origine sont mémorisés pour pouvoir revenir au français. */
(function () {
  'use strict';
  var LANGUES = ['fr', 'de', 'it', 'rm', 'en'];
  var NOMS = { fr: 'Français', de: 'Deutsch', it: 'Italiano', rm: 'Rumantsch', en: 'English' };
  var CLE = 'cw_lang';
  var ATTRS = ['placeholder', 'title', 'aria-label', 'alt'];
  var LOCALES = { fr: 'fr-CH', de: 'de-CH', it: 'it-CH', rm: 'rm-CH', en: 'en-GB' };

  var dico = {};            // texte français normalisé -> traduction
  var motifs = [];          // gabarits avec {0}, {1}... : { re, cles, tr }
  var langue = 'fr';
  var nodes = new Map();    // noeud texte -> { fr, tr }
  var attrs = new WeakMap(); // élément -> { nom: { fr, tr } }
  var observateur = null;
  var ecouteurs = [];
  var cache = {};

  function stock(cle) { try { return window.localStorage.getItem(cle); } catch (e) { return null; } }
  function range(cle, v) { try { window.localStorage.setItem(cle, v); } catch (e) {} }
  function norm(s) { return s.replace(/\s+/g, ' ').trim(); }
  function canon(s) { return s.replace(/[ \u00A0]+([:;?!])/g, '$1'); }
  function echapper(s) { return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); }

  function compiler(donnees) {
    dico = {}; motifs = [];
    Object.keys(donnees).forEach(function (fr0) {
      var fr = canon(fr0);
      var tr = donnees[fr0];
      if (typeof tr !== 'string' || !tr) return;
      if (/\{\d+\}/.test(fr)) {
        var cles = [];
        var morceaux = fr.split(/(\{\d+\})/);
        var re = morceaux.map(function (m) {
          var k = /^\{(\d+)\}$/.exec(m);
          if (k) { cles.push(k[1]); return '(.*?)'; }
          return echapper(m);
        }).join('');
        motifs.push({ re: new RegExp('^' + re + '$'), cles: cles, tr: tr, taille: fr.length });
      } else {
        dico[fr] = tr;
      }
    });
    motifs.sort(function (a, b) { return b.taille - a.taille; });
  }

  // Marques françaises du pluriel ou du féminin collées à un mot : s, x, e, es, ·e. L'anglais garde le pluriel, les autres langues les effacent.
  function suffixe(v) {
    if (/^(e|es|·e|·e·s|\(s\)|\(e\))$/.test(v)) return '';
    if (/^(s|x)$/.test(v)) return langue === 'en' ? 's' : '';
    return t(v);
  }

  // Cherche la traduction d'un texte normalisé : entrée exacte, puis gabarit à {0}.
  function chercher(coeur) {
    var res = dico[coeur];
    if (res !== undefined) return res;
    for (var i = 0; i < motifs.length; i++) {
      var m = motifs[i].re.exec(coeur);
      if (m) {
        var valeurs = {};
        motifs[i].cles.forEach(function (k, j) { valeurs[k] = suffixe(m[j + 1]); });
        return motifs[i].tr.replace(/\{(\d+)\}/g, function (_, k) { return valeurs[k] !== undefined ? valeurs[k] : ''; });
      }
    }
    return undefined;
  }

  // Traduit un texte français. Rend le texte inchangé si inconnu.
  function t(fr) {
    if (langue === 'fr' || typeof fr !== 'string') return fr;
    var debut = fr.match(/^\s*/)[0], fin = fr.match(/\s*$/)[0];
    var coeur = canon(norm(fr));
    if (!coeur) return fr;
    var res = chercher(coeur);
    if (res === undefined && /[.!?] \S/.test(coeur)) {
      // message composé de plusieurs phrases connues : on traduit phrase par phrase
      var phrases = coeur.split(/(?<=[.!?]) /), connu = 0;
      var tr = phrases.map(function (p) { var r = chercher(p); if (r !== undefined) { connu++; return r; } return p; });
      if (connu) res = tr.join(' ');
    }
    if (res === undefined) return fr;
    return debut + res + fin;
  }

  function ignore(el) {
    if (!el) return true;
    var tag = el.nodeName;
    if (tag === 'SCRIPT' || tag === 'STYLE' || tag === 'NOSCRIPT' || tag === 'TEXTAREA' || false) return true;
    return !!(el.closest && el.closest('[data-no-i18n], [translate="no"]'));
  }

  // Typographie suisse du texte français : pas d'espace avant : ; ? !
  function typoFr(s) {
    return s.replace(/[ \u00A0]+([:;?!])/g, '$1');
  }

  function traduireTexte(n) {
    if (!n.nodeValue || !n.parentNode || ignore(n.parentNode)) return;
    var rec = nodes.get(n);
    var courant = n.nodeValue;
    if (rec && courant === rec.tr) { // déjà traduit par nous
      if (langue === 'fr') { n.nodeValue = typoFr(rec.fr); nodes.delete(n); }
      else { var nv = t(rec.fr); if (nv !== courant) n.nodeValue = nv, rec.tr = nv; }
      return;
    }
    // nouveau texte (jamais vu, ou remplacé par l'application)
    if (langue === 'fr') {
      if (rec) nodes.delete(n);
      var typo = typoFr(courant);
      if (typo !== courant) n.nodeValue = typo;
      return;
    }
    var tr = t(courant);
    if (tr !== courant) { nodes.set(n, { fr: courant, tr: tr }); n.nodeValue = tr; }
    else if (rec) nodes.delete(n);
  }

  function traduireAttrs(el) {
    if (!el.getAttribute || ignore(el)) return;
    ATTRS.forEach(function (nom) {
      var v = el.getAttribute(nom);
      if (v === null) return;
      var tous = attrs.get(el), rec = tous && tous[nom];
      if (rec && v === rec.tr) {
        if (langue === 'fr') { el.setAttribute(nom, typoFr(rec.fr)); delete tous[nom]; }
        else { var nv = t(rec.fr); if (nv !== v) { el.setAttribute(nom, nv); rec.tr = nv; } }
        return;
      }
      if (langue === 'fr') { if (rec) delete tous[nom]; var tv = typoFr(v); if (tv !== v) el.setAttribute(nom, tv); return; }
      var tr = t(v);
      if (tr !== v) {
        if (!tous) { tous = {}; attrs.set(el, tous); }
        tous[nom] = { fr: v, tr: tr };
        el.setAttribute(nom, tr);
      }
    });
  }

  function parcourir(racine) {
    if (!racine) return;
    if (racine.nodeType === 3) { traduireTexte(racine); return; }
    if (racine.nodeType !== 1 && racine.nodeType !== 9 && racine.nodeType !== 11) return;
    if (racine.nodeType === 1) { if (ignore(racine)) return; traduireAttrs(racine); }
    var w = document.createTreeWalker(racine, 1 | 4, null);
    var n;
    while ((n = w.nextNode())) {
      if (n.nodeType === 3) traduireTexte(n);
      else traduireAttrs(n);
    }
  }

  function observer() {
    if (observateur || !window.MutationObserver) return;
    observateur = new MutationObserver(function (muts) {
      for (var i = 0; i < muts.length; i++) {
        var m = muts[i];
        if (m.type === 'characterData') traduireTexte(m.target);
        else if (m.type === 'attributes') traduireAttrs(m.target);
        else for (var j = 0; j < m.addedNodes.length; j++) parcourir(m.addedNodes[j]);
      }
      titre();
    });
    observateur.observe(document.documentElement, { childList: true, subtree: true, characterData: true, attributes: true, attributeFilter: ATTRS });
  }

  var titreFr = null, titreTr = null;
  function titre() {
    var cur = document.title;
    if (langue === 'fr') { if (titreFr !== null && cur === titreTr) document.title = titreFr; titreFr = titreTr = null; return; }
    if (titreFr !== null && cur === titreTr) return;
    var tr = t(cur);
    // le titre est de la forme « Page · CareWatch™ »
    if (tr === cur && cur.indexOf(' · ') > -1) tr = cur.split(' · ').map(t).join(' · ');
    if (tr !== cur) { titreFr = cur; titreTr = tr; document.title = tr; }
  }

  function charger(l, fin) {
    if (l === 'fr') { fin({}); return; }
    if (cache[l]) { fin(cache[l]); return; }
    var req = new XMLHttpRequest();
    req.open('GET', '/i18n/' + l + '.json?v=' + (window.CW_I18N_VERSION || '1'), true);
    req.onload = function () {
      var d = {};
      try { d = JSON.parse(req.responseText); } catch (e) { d = {}; }
      cache[l] = d; fin(d);
    };
    req.onerror = function () { fin({}); };
    req.send();
  }

  function appliquer(l) {
    langue = l;
    document.documentElement.lang = l;
    window.cwLangue = l;
    window.cwLocale = LOCALES[l] || 'fr-CH';
    parcourir(document.documentElement);
    titre();
    ecouteurs.forEach(function (f) { try { f(l); } catch (e) {} });
    try { window.dispatchEvent(new CustomEvent('cw-lang', { detail: l })); } catch (e) {}
  }

  function definir(l) {
    if (LANGUES.indexOf(l) < 0) l = 'fr';
    range(CLE, l);
    charger(l, function (d) { compiler(d); appliquer(l); });
  }

  function initiale() {
    var url = (window.location.search.match(/[?&]lang=([a-z]{2})/) || [])[1];
    if (url && LANGUES.indexOf(url) > -1) return url;
    var s = stock(CLE);
    if (s && LANGUES.indexOf(s) > -1) return s;
    var navs = (navigator.languages && navigator.languages.length ? navigator.languages : [navigator.language || 'fr']);
    for (var i = 0; i < navs.length; i++) {
      var c = String(navs[i]).slice(0, 2).toLowerCase();
      if (LANGUES.indexOf(c) > -1) return c;
    }
    return 'fr';
  }

  window.cwI18n = {
    langues: LANGUES, noms: NOMS,
    get: function () { return langue; },
    set: definir,
    t: t,
    surChangement: function (f) { ecouteurs.push(f); return function () { ecouteurs = ecouteurs.filter(function (x) { return x !== f; }); }; },
    // diagnostic : textes visibles qui ne sont pas traduits
    manquants: function () {
      var out = {}, w = document.createTreeWalker(document.body, 4, null), n;
      while ((n = w.nextNode())) {
        if (!n.parentNode || ignore(n.parentNode) || nodes.has(n)) continue;
        var c = canon(norm(n.nodeValue));
        if (c && /[A-Za-zÀ-ÿ]{3,}/.test(c) && (!dico[c] || dico[c] === c)) out[c] = (out[c] || 0) + 1;
      }
      return out;
    },
  };
  window.cwT = t;
  window.cwLangue = 'fr';
  window.cwLocale = 'fr-CH';

  // Les fenêtres natives (alert, confirm, prompt) passent aussi par la traduction
  ['alert', 'confirm', 'prompt'].forEach(function (nom) {
    var orig = window[nom];
    if (typeof orig !== 'function') return;
    window[nom] = function (msg) { var a = Array.prototype.slice.call(arguments); a[0] = t(String(msg)); return orig.apply(window, a); };
  });

  function demarrer() {
    observer();
    var l = initiale();
    if (l !== 'fr') definir(l); else { document.documentElement.lang = 'fr'; parcourir(document.documentElement); }
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', demarrer); else demarrer();
})();
