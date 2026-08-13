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

  // Album page: click any gallery image to open it full-size.
  var gallery = document.querySelector('.gallery');
  if (gallery) {
    var box = document.createElement('div');
    box.className = 'lightbox';
    box.hidden = true;
    var big = document.createElement('img');
    big.alt = '';
    box.appendChild(big);
    document.body.appendChild(box);
    gallery.addEventListener('click', function (e) {
      var img = e.target.closest('img');
      if (!img) return;
      big.src = img.getAttribute('data-full') || img.src;
      big.alt = img.alt || '';
      box.hidden = false;
    });
    box.addEventListener('click', function () { box.hidden = true; });
    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape') box.hidden = true;
    });
  }
})();
