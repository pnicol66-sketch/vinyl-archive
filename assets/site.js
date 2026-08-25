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

  // Archive index: filter cards on artist / title / label / year / genre.
  var filter = document.getElementById('filter');
  if (filter) {
    var cards = Array.prototype.slice.call(document.querySelectorAll('.card'));
    var nomatch = document.getElementById('nomatch');
    filter.addEventListener('input', function () {
      var q = filter.value.trim().toLowerCase();
      var shown = 0;
      cards.forEach(function (c) {
        var hit = !q || (c.getAttribute('data-search') || '').indexOf(q) !== -1;
        // On the Available page each card sits in a wrapper with its
        // listing link - hide the wrapper, not just the card.
        (c.closest('.card-wrap') || c).hidden = !hit;
        if (hit) shown++;
      });
      if (nomatch) nomatch.hidden = shown > 0;
    });
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
   Landing page film — append to assets/site.js
   Drives the phone mock on the landing page only; every other page
   has no #film, so this exits immediately.
   ============================================================ */
(function () {
  var film = document.getElementById('film');
  if (!film) return;

  var steps = [].slice.call(film.querySelectorAll('.lp-steps button'));
  var scrs = [].slice.call(film.querySelectorAll('.lp-scr'));
  var title = film.querySelector('.lp-apptitle');
  var back = film.querySelector('.lp-back');
  var caption = film.querySelector('.lp-caption');
  var note = film.querySelector('.lp-beatnote');
  var dict = film.querySelector('.lp-dict');

  var TITLES = ['New Album', 'Miles Davis — Kind of Blue', 'Take photo', 'Crop photo',
                '14 Side 1 Matrix/Runout', 'Save to Drive', 'Uploaded albums'];
  var CAPTIONS = [
    '01 · New album — two fields and a disc count',
    '02 · The checklist does the remembering',
    '03 · Shoot, then crop the cover',
    '04 · Label crops as a circle',
    '05 · Typing or dictating the matrix',
    '06 · Into your own Google Drive',
    '07 · Shared read-only — work begins'
  ];
  var NOTES = [
    'Label artist, album title, one disc or two. That is the entire setup — no account with us.',
    'Thirteen entries for a single LP — front and back cover, a typed grade for each, both labels, both disc faces, a typed grade per side, and the matrix for each side. Photo rows open the camera; ⌨ rows open a text screen. Optional entries carry a Skip.',
    'Torch, zoom and manual focus if you want them; otherwise just shoot. The sleeve outline is detected the moment the photo is taken — then drag a corner, a whole side, or the frame itself, with a 3× magnifier under your fingertip.',
    'Centre the label and fill the frame: the round outline is detected and cropped as a circle. Drag inside it to move, drag the ring to resize. ⟳ rotates the saved photo in 90° steps.',
    'The matrix is typed, or simply read out loud character by character — dictation converts spoken symbol words as you say them. Dead-wax photos have their own four slots if you want them, but they are optional: the transcription is what the identification runs on.',
    'Straight into My Drive / Vinyl Curator / Artist_Album, updating in place if you re-shoot.',
    'You share that one folder, read-only. Nothing else in your Drive is visible, and you can revoke it any time.'
  ];
  var SAID = ['CS 8163', 'CS 8163-A', 'CS 8163-A T', 'CS 8163-A T BG'];
  var HOLD = [1, 1.8, 1.7, 1.2, 1.7, 1.1, 1.3];
  var PHASE = { 1: 1600, 2: 1400, 3: 900 };   // ms into the beat when the second phase fires
  var BEAT = 3000;

  var still = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  var beat = -1, tNext, tPhase, tSay;

  function go(i, manual) {
    clearTimeout(tNext); clearTimeout(tPhase); clearInterval(tSay);
    beat = i;

    scrs.forEach(function (s, n) {
      if (n === i) { s.setAttribute('data-on', ''); } else { s.removeAttribute('data-on'); }
      s.removeAttribute('data-shot');
    });
    steps.forEach(function (b, n) {
      if (n === i) { b.setAttribute('aria-current', 'step'); } else { b.removeAttribute('aria-current'); }
    });

    title.textContent = TITLES[i];
    back.style.color = i === 0 ? '#9a9aa5' : '#ececf0';
    caption.textContent = CAPTIONS[i];
    note.textContent = NOTES[i];
    if (dict) dict.textContent = i === 4 ? SAID[0] : SAID[SAID.length - 1];

    if (PHASE[i]) {
      tPhase = setTimeout(function () { scrs[i].setAttribute('data-shot', ''); }, still ? 0 : PHASE[i]);
    }
    if (i === 4 && dict && !still) {
      var n = 0;
      tSay = setInterval(function () {
        n++;
        dict.textContent = SAID[n];
        if (n >= SAID.length - 1) clearInterval(tSay);
      }, 750);
    }
    if (!still || manual) {
      if (!still) tNext = setTimeout(function () { go((beat + 1) % scrs.length); }, BEAT * HOLD[i]);
    }
  }

  steps.forEach(function (b, n) {
    b.addEventListener('click', function () { go(n, true); });
  });

  // Only run while the film is actually on screen.
  if ('IntersectionObserver' in window) {
    new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        if (e.isIntersecting) { if (beat < 0) go(0); }
        else { clearTimeout(tNext); clearTimeout(tPhase); clearInterval(tSay); beat = -1; }
      });
    }, { threshold: 0.15 }).observe(film);
  } else {
    go(0);
  }
})();
