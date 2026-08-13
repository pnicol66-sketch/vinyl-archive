// Vinyl Curator archive site — archive filter + gallery lightbox. No dependencies.
(function () {
  'use strict';

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
        c.hidden = !hit;
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
