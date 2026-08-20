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

  // Compact print card: /albums/<slug>/?compact prints the one-sheet version
  // (forensics kept, research prose dropped - see the print block in
  // site.css). A query string rather than a control on the page, because the
  // printed card is an owner tool and the visitor's page must not change.
  // Harmless if a visitor lands on it: nothing differs on screen.
  if (/[?&](compact|print=compact)(&|=|$)/.test(location.search)) {
    document.body.classList.add('compact');
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

  // Archive index: filter cards on artist / title / label / year.
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
