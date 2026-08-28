// Vinyl Curator archive site — archive filter + gallery lightbox. No dependencies.
(function () {
  'use strict';

  // Contact links: the address is assembled here from split parts so it
  // never appears whole in the raw HTML (keeps scrapers off it). Links on
  // the landing hero show the full address; footer links keep their label.
  Array.prototype.forEach.call(document.querySelectorAll('a.mail'), function (a) {
    var addr = a.getAttribute('data-u') + '@' + a.getAttribute('data-d');
    a.href = 'mailto:' + addr;
    if (a.textContent.trim() === 'email') a.textContent = addr;
  });

  // Compact one-sheet space savers: put the matrix sides on a single line, and
  // trim the variant chronology to two lines past "this copy" so the kept
  // sections land on one sheet instead of spilling and getting cut off. Both
  // are reversible (the on-screen toggle flips them back) and NEVER run on the
  // visitor's full page - the originals are cached on the node's dataset.
  var matrixPre = document.querySelector('.matrix pre');
  var chronPre = document.querySelector('.chronology pre');
  function compactText(on) {
    if (matrixPre) {
      if (matrixPre.dataset.full == null) matrixPre.dataset.full = matrixPre.textContent;
      matrixPre.textContent = on
        ? matrixPre.dataset.full.split('\n').map(function (s) { return s.trim(); })
            .filter(Boolean).join('     ')
        : matrixPre.dataset.full;
    }
    if (chronPre) {
      if (chronPre.dataset.full == null) chronPre.dataset.full = chronPre.textContent;
      var out = chronPre.dataset.full;
      if (on) {
        var lines = out.split('\n'), idx = -1;
        for (var i = 0; i < lines.length; i++) {
          if (/this copy/i.test(lines[i])) { idx = i; break; }
        }
        // keep everything up to and including two lines after "this copy";
        // if there is anything past that, drop it and mark the cut.
        if (idx >= 0 && lines.length > idx + 3) {
          var kept = lines.slice(0, idx + 3);
          kept[kept.length - 1] += ' ...';
          out = kept.join('\n');
        }
      }
      chronPre.textContent = out;
    }
  }

  // Compact print card: /albums/<slug>/?compact prints the one-sheet version
  // (forensics kept, research prose dropped - see the print block in
  // site.css). A query string rather than a control on the page, because the
  // printed card is an owner tool and the visitor's page must not change.
  // Harmless if a visitor lands on it: nothing differs on screen.
  if (/[?&](compact|print=compact)(&|=|$)/.test(location.search)) {
    document.body.classList.add('compact');
    compactText(true);
  }

  // ...or press "c" on an album page. Nothing on screen distinguishes the two
  // variants, so the toggle CONFIRMS itself - without that you would press the
  // key, see nothing happen, and print the wrong one.
  if (document.querySelector('.print-thanks')) {
    document.addEventListener('keydown', function (e) {
      if (e.key !== 'c' && e.key !== 'C') return;
      // Ctrl+C / Cmd+C is copy. Never steal it.
      if (e.ctrlKey || e.metaKey || e.altKey) return;
      var t = e.target || {};
      var tag = (t.tagName || '').toLowerCase();
      if (tag === 'input' || tag === 'textarea' || tag === 'select' || t.isContentEditable) return;
      var on = document.body.classList.toggle('compact');
      compactText(on);
      var note = document.getElementById('print-note');
      if (!note) {
        note = document.createElement('div');
        note.id = 'print-note';
        note.className = 'print-note';
        document.body.appendChild(note);
      }
      note.textContent = on ? 'Compact card - one sheet duplex' : 'Full card - two sheets duplex';
      note.classList.add('show');
      clearTimeout(note._t);
      note._t = setTimeout(function () { note.classList.remove('show'); }, 1800);
    });
  }

  // Print layout: the disclaimer belongs with the matrix, not with the
  // sign-off. It qualifies the identification and the condition assessment, so
  // it reads as a footnote to the evidence rather than as a second ending
  // competing with the closing note.
  //
  // CSS cannot reparent a node, and duplicating the wording in the template
  // would leave two copies to keep in step - the exact problem just removed
  // from the blurb. So it moves for the duration of the print and moves back
  // afterwards. If beforeprint never fires the disclaimer simply prints where
  // it always has, which is why .site-foot is hidden by a class the move sets
  // rather than unconditionally.
  var method = document.querySelector('.site-foot .method');
  var matrixSec = document.querySelector('.matrix');
  if (method && matrixSec && document.querySelector('.print-thanks')) {
    var home = method.parentNode, after = method.nextSibling;
    window.addEventListener('beforeprint', function () {
      matrixSec.parentNode.insertBefore(method, matrixSec.nextSibling);
      document.body.classList.add('method-moved');
    });
    window.addEventListener('afterprint', function () {
      home.insertBefore(method, after);
      document.body.classList.remove('method-moved');
    });
  }

  // Archive index: filter cards on artist / title / label / year / genre, plus
  // the streaming Tiled/List toggle and Order-by control (library pages only).
  var filter = document.getElementById('filter');
  var grid = document.getElementById('cards');
  if (filter && grid) {
    var cards = Array.prototype.slice.call(grid.querySelectorAll('.card'));
    var nomatch = document.getElementById('nomatch');
    var countEl = document.getElementById('count');
    var total = cards.length;

    // On the Available page each card sits in a wrapper with its listing link -
    // the sortable / hideable unit is the wrapper, not the bare card.
    function unit(c) { return c.closest('.card-wrap') || c; }

    function applyFilter() {
      var q = filter.value.trim().toLowerCase();
      var shown = 0;
      cards.forEach(function (c) {
        var hit = !q || (c.getAttribute('data-search') || '').indexOf(q) !== -1;
        unit(c).hidden = !hit;
        if (hit) shown++;
      });
      if (nomatch) nomatch.hidden = shown > 0;
      if (countEl) countEl.textContent = shown + ' of ' + total;
    }
    filter.addEventListener('input', applyFilter);

    // Tiled <-> List view.
    var viewBtns = Array.prototype.slice.call(document.querySelectorAll('.viewbar button'));
    viewBtns.forEach(function (b) {
      b.addEventListener('click', function () {
        grid.classList.toggle('is-list', b.getAttribute('data-view') === 'list');
        viewBtns.forEach(function (o) {
          o.setAttribute('aria-pressed', o === b ? 'true' : 'false');
        });
      });
    });

    // Order-by: re-sort the cards in place. Year parses the 4-digit key; every
    // other key falls back to artist then title so ties are stable.
    var order = document.getElementById('orderby');
    if (order) {
      var collator = new Intl.Collator(undefined, { sensitivity: 'base', numeric: true });
      var attr = function (el, k) { return el.getAttribute('data-' + k) || ''; };
      var sortBy = function (key) {
        cards.slice().sort(function (a, b) {
          if (key === 'year') {
            var d = (parseInt(attr(a, 'year'), 10) || 9999) - (parseInt(attr(b, 'year'), 10) || 9999);
            if (d) return d;
          } else {
            var c = collator.compare(attr(a, key), attr(b, key));
            if (c) return c;
          }
          var ca = collator.compare(attr(a, 'artist'), attr(b, 'artist'));
          return ca || collator.compare(attr(a, 'title'), attr(b, 'title'));
        }).forEach(function (c) { grid.appendChild(unit(c)); });
      };
      order.addEventListener('change', function () { sortBy(order.value); });
      // Match the control to what is shown: order by the default (Artist) once.
      sortBy(order.value);
    }
  }

  // Album page: click any gallery image to open the lightbox, then step
  // through every photo with the arrows, arrow keys, or a swipe.
  var gallery = document.querySelector('.gallery');
  if (gallery) {
    var thumbs = Array.prototype.slice.call(gallery.querySelectorAll('img'));
    var items = thumbs.map(function (img) {
      return {
        full: img.getAttribute('data-full') || img.getAttribute('src'),
        cap: img.getAttribute('data-caption') || img.alt || ''
      };
    });
    var cur = 0;
    var box = document.createElement('div');
    box.className = 'lightbox';
    box.hidden = true;
    box.innerHTML =
      '<button class="lb-btn lb-prev" aria-label="Previous photo">&#8249;</button>' +
      '<figure><img alt=""><figcaption><span class="lb-cap"></span>' +
      '<span class="lb-count"></span></figcaption></figure>' +
      '<button class="lb-btn lb-next" aria-label="Next photo">&#8250;</button>' +
      '<button class="lb-close" aria-label="Close">&#215;</button>';
    document.body.appendChild(box);
    var big = box.querySelector('figure img');
    var cap = box.querySelector('.lb-cap');
    var count = box.querySelector('.lb-count');

    function show(i) {
      cur = (i + items.length) % items.length;
      big.src = items[cur].full;
      big.alt = items[cur].cap;
      cap.textContent = items[cur].cap;
      count.textContent = (cur + 1) + ' / ' + items.length;
      box.hidden = false;
    }
    function close() { box.hidden = true; }

    gallery.addEventListener('click', function (e) {
      var img = e.target.closest('img');
      if (img) show(thumbs.indexOf(img));
    });
    box.querySelector('.lb-prev').addEventListener('click', function (e) {
      e.stopPropagation(); show(cur - 1);
    });
    box.querySelector('.lb-next').addEventListener('click', function (e) {
      e.stopPropagation(); show(cur + 1);
    });
    box.querySelector('.lb-close').addEventListener('click', function (e) {
      e.stopPropagation(); close();
    });
    big.addEventListener('click', function (e) {
      e.stopPropagation(); show(cur + 1);
    });
    box.addEventListener('click', close);
    document.addEventListener('keydown', function (e) {
      if (box.hidden) return;
      if (e.key === 'Escape') close();
      else if (e.key === 'ArrowLeft') show(cur - 1);
      else if (e.key === 'ArrowRight') show(cur + 1);
    });
    var touchX = null;
    box.addEventListener('touchstart', function (e) {
      touchX = e.changedTouches[0].clientX;
    }, { passive: true });
    box.addEventListener('touchend', function (e) {
      if (touchX === null) return;
      var dx = e.changedTouches[0].clientX - touchX;
      touchX = null;
      if (dx > 40) show(cur - 1);
      else if (dx < -40) show(cur + 1);
    }, { passive: true });
  }
})();

/* ============================================================
   Landing page film — drives the phone mock on the landing page.
   Ported from the design handoff (Homepage.dc.html): a 7-beat state
   machine with per-beat sub-state (shot / cropping / taps / said) that
   sets inline styles + text on [data-k] / [data-panel] / [data-step]
   hooks. Every other page has no #film, so this exits immediately.
   ============================================================ */
(function () {
  var film = document.getElementById('film');
  if (!film) return;

  var BEATS = [
    '01 · New album — two fields and a disc count',
    '02 · The checklist does the remembering',
    '03 · Shoot — the cover auto-crops',
    '04 · Tap the rim — the shape fits itself',
    '05 · Typing or dictating the matrix',
    '06 · Into your own Google Drive',
    '07 · Shared read-only — work begins'
  ];
  var NOTES = [
    'Label artist, album title, one disc or two. That is the entire setup — no account with us.',
    'Thirteen entries for a single LP — front and back cover, a typed grade for each, both labels, both disc faces, a typed grade per side, and the matrix for each side. Photo rows open the camera; ⌨ rows open a text screen. Optional entries carry a Skip.',
    'Take the photo and the app auto-crops the sleeve for you — an on-device model finds the four corners, no account and no connection needed. It hands you the frame to nudge: drag any corner or side, with a 3× magnifier under your fingertip. If it ever misses, you just tap the four corners yourself.',
    "Labels and full-disc LP shots are even quicker: take the photo, then tap five points anywhere around the disc's edge and the app fits the exact shape through them — no dragging — so it stays true even when the disc is shot at a slight angle.",
    'The matrix is typed, or simply read out loud character by character — dictation converts spoken symbol words as you say them. Dead-wax photos have their own four slots if you want them, but they are optional: the transcription is what the identification runs on.',
    'Straight into My Drive / Vinyl Curator / Artist_Album, updating in place if you re-shoot.',
    'You share that one folder, read-only. Nothing else in your Drive is visible, and you can revoke it any time.'
  ];
  var TITLES = ['New Album', 'Miles Davis — Kind of Blue', 'Take photo', 'Crop photo',
                '14 Side 1 Matrix/Runout', 'Save to Drive', 'Uploaded albums'];
  var DICT = ['CS 8163', 'CS 8163-A', 'CS 8163-A T', 'CS 8163-A T BG'];
  var TAPPOS = [[50, 2], [95, 27], [88, 82], [15, 86], [4, 40]];
  // Beat 3 (label/LP capture) holds longest: the 5 taps take ~2.6s to place,
  // then the fitted circle needs time to read before the film moves on.
  var HOLD = [1.5, 2.4, 2.3, 3.3, 2.3, 1.6, 1.9];
  var TAP_MS = 520;   // per-tap cadence on beat 3
  var BEAT_MS = 3000;

  function k(name) { return film.querySelector('[data-k="' + name + '"]'); }
  var panels = [].slice.call(film.querySelectorAll('[data-panel]'));
  var steps = [].slice.call(film.querySelectorAll('[data-step]'));
  var taps = [].slice.call(film.querySelectorAll('[data-k="tap"]'));
  var pips = [].slice.call(film.querySelectorAll('[data-k="pip"]'));
  var elTitle = k('title'), elBack = k('back'), elCap = k('caption'), elNote = k('note'),
      elCam = k('cam'), elReview = k('review'), elCrop = k('crop'), elAuto = k('autocrop'),
      elCoverMsg = k('coverMsg'), elShutter = k('shutter'), elList = k('list'),
      elCircle = k('circle'), elLine = k('line'), elPoly = k('poly'), elTapMsg = k('tapMsg'),
      elUndo = k('undo'), elSave = k('save'), elDict = k('dictated'),
      elUploaded = k('uploaded'), elProgress = k('progress');

  var still = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  var state = { beat: 0, shot: false, said: DICT.length - 1, taps: 5, cropping: false };
  var t, t2, t3, t4, started = false;

  function render() {
    var b = state.beat;
    panels.forEach(function (p) { p.style.opacity = (+p.getAttribute('data-panel') === b) ? '1' : '0'; });
    steps.forEach(function (s) {
      var on = (+s.getAttribute('data-step') === b);
      s.style.borderLeftColor = on ? '#d98b4a' : '#38332a';
      var eye = s.querySelector('[data-sk="eye"]'), ti = s.querySelector('[data-sk="title"]');
      if (eye) eye.style.color = on ? '#d98b4a' : '#a89d8d';
      if (ti) { ti.style.color = on ? '#ece7de' : '#a89d8d'; ti.style.fontWeight = on ? '600' : '400'; }
    });
    if (elTitle) elTitle.textContent = (b === 2 && !state.shot) ? 'Take photo' : TITLES[b];
    if (elBack) elBack.style.color = b === 0 ? '#9a9aa5' : '#ececf0';
    if (elCap) elCap.textContent = BEATS[b];
    if (elNote) elNote.textContent = NOTES[b];
    if (elList) elList.style.transform = (b === 1 && state.shot) ? 'translateY(-7.5rem)' : 'translateY(0rem)';
    // beat 2 — cover auto-crop + adjust
    if (elCam) elCam.style.opacity = (b === 2 && !state.shot) ? '1' : '0';
    if (elReview) elReview.style.opacity = (b === 2 && state.shot) ? '1' : '0';
    if (elCrop) elCrop.style.inset = (b === 2 && state.shot) ? '0px' : '-26px';
    if (elAuto) elAuto.style.opacity = state.cropping ? '1' : '0';
    if (elCoverMsg) elCoverMsg.style.opacity = state.cropping ? '0' : '1';
    if (elShutter) elShutter.style.background = state.shot ? '#fff' : 'rgba(255,255,255,.25)';
    // beat 3 — tap 5 points on the rim
    if (elCircle) elCircle.style.opacity = (b === 3 && state.shot) ? '1' : '0';
    taps.forEach(function (el) {
      el.style.opacity = (b === 3 && state.taps >= +el.getAttribute('data-n') && !state.shot) ? '1' : '0';
    });
    pips.forEach(function (el) {
      el.style.background = (state.taps >= +el.getAttribute('data-n')) ? '#f0a832' : '#3a3a42';
    });
    if (elPoly) elPoly.setAttribute('points', TAPPOS.slice(0, state.taps).map(function (p) { return p.join(','); }).join(' '));
    if (elLine) elLine.style.opacity = (b === 3 && state.taps >= 2 && !state.shot) ? '1' : '0';
    if (elUndo) elUndo.textContent = (b === 3 && state.shot) ? '↶ Retap' : '↶ Undo';
    if (elTapMsg) elTapMsg.textContent = (b === 3 && state.shot)
      ? 'Drag to fit the rim, then Save (deskews round) — or ○ Circle'
      : (state.taps === 0 ? '👆 Tap 5 points around the edge' : 'Tap the next edge point — ' + (5 - state.taps) + ' to go');
    if (elSave) {
      var done = (b === 3 && state.shot);
      elSave.style.borderColor = done ? '#f0a832' : '#2a2a31';
      elSave.style.background = done ? '#f0a832' : '#1b1b20';
      elSave.style.color = done ? '#191204' : '#6a6558';
    }
    if (elDict) elDict.textContent = DICT[state.said];
    if (elUploaded) elUploaded.textContent = (b >= 6) ? '14' : '9';
    if (elProgress) elProgress.style.width = (b >= 6) ? '100%' : '64%';
  }

  function schedule() {
    clearTimeout(t);
    if (still) return;
    t = setTimeout(function () { go((state.beat + 1) % 7); }, BEAT_MS * HOLD[state.beat]);
  }

  function go(i) {
    clearTimeout(t2); clearInterval(t3); clearTimeout(t4);
    state.beat = i;
    state.shot = false;
    state.said = (i === 4) ? 0 : DICT.length - 1;
    state.taps = (i === 3) ? 0 : 5;
    state.cropping = false;
    render();
    if (still) {
      // Static end-state for reduced motion: settle the animated beats.
      if (i === 1 || i === 2) state.shot = true;
      if (i === 3) { state.taps = 5; state.shot = true; }
      render();
      return;
    }
    if (i === 1) t2 = setTimeout(function () { state.shot = true; render(); }, 1600);
    if (i === 2) t2 = setTimeout(function () {
      state.shot = true; state.cropping = true; render();
      t4 = setTimeout(function () { state.cropping = false; render(); }, 850);
    }, 1200);
    if (i === 3) t3 = setInterval(function () {
      if (state.taps >= 5) { clearInterval(t3); state.shot = true; render(); return; }
      state.taps++; render();
    }, TAP_MS);
    if (i === 4) t3 = setInterval(function () {
      if (state.said >= DICT.length - 1) { clearInterval(t3); return; }
      state.said++; render();
    }, 750);
    schedule();
  }

  steps.forEach(function (s) {
    s.addEventListener('click', function () { go(+s.getAttribute('data-step')); });
  });

  render();
  if ('IntersectionObserver' in window) {
    new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        if (e.isIntersecting) { if (!started) { started = true; go(0); } }
        else { clearTimeout(t); clearTimeout(t2); clearInterval(t3); clearTimeout(t4); started = false; }
      });
    }, { threshold: 0.15 }).observe(film);
  } else {
    go(0);
  }
})();

/* ============================================================
   Catalogue page — the "build the book" laptop film.
   Drives #cat-film on the catalogue page only; exits elsewhere.
   ============================================================ */
(function () {
  var film = document.getElementById('cat-film');
  if (!film) return;

  var scrs = [].slice.call(film.querySelectorAll('.scr'));
  var steps = [].slice.call(document.querySelectorAll('.cat-step'));
  var caption = document.getElementById('cat-caption');
  var genBar = document.getElementById('cat-genbar');
  var genLine = document.getElementById('cat-genline');

  var CAPTIONS = [
    '01 · Vinyl Curator ▸ Create catalogue book…',
    '02 · Layout, records, prices and order',
    '03 · Laid out plate by plate',
    '04 · A print-ready PDF, saved to your Drive'
  ];
  var GEN = [
    ['Reading 16 records…', '18%'],
    ['Placing photos · plate 4 of 12', '46%'],
    ['Typesetting · plate 9 of 12', '78%'],
    ['Writing PDF…', '96%']
  ];

  var still = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  var beat = -1, tNext, tGen;

  function go(i) {
    clearTimeout(tNext); clearInterval(tGen);
    beat = i;
    scrs.forEach(function (s, n) {
      if (n === i) { s.setAttribute('data-on', ''); } else { s.removeAttribute('data-on'); }
    });
    steps.forEach(function (b, n) {
      if (n === i) { b.setAttribute('aria-current', 'step'); } else { b.removeAttribute('aria-current'); }
    });
    if (caption) caption.textContent = CAPTIONS[i];
    if (i === 2) {
      var g = 0;
      if (genBar) genBar.style.width = GEN[0][1];
      if (genLine) genLine.textContent = GEN[0][0];
      if (!still) {
        tGen = setInterval(function () {
          g++;
          if (g >= GEN.length) { clearInterval(tGen); return; }
          if (genBar) genBar.style.width = GEN[g][1];
          if (genLine) genLine.textContent = GEN[g][0];
        }, 800);
      }
    }
    if (!still) {
      tNext = setTimeout(function () { go((beat + 1) % scrs.length); }, i === 2 ? 3600 : 3000);
    }
  }

  steps.forEach(function (b, n) {
    b.addEventListener('click', function () { go(n); });
  });

  if ('IntersectionObserver' in window) {
    new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        if (e.isIntersecting) { if (beat < 0) go(0); }
        else { clearTimeout(tNext); clearInterval(tGen); beat = -1; }
      });
    }, { threshold: 0.2 }).observe(film);
  } else {
    go(0);
  }
})();
