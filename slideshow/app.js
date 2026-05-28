(function () {
    "use strict";

    var INTERVAL = 30000;
    var MANIFEST_POLL = 60000;
    var MANIFEST_URL = "manifest.json";
    var PHOTO_BASE = "photos/";
    var FADE_MS = 1500;

    var imgA = document.getElementById("img-a");
    var imgB = document.getElementById("img-b");
    var clockEl = document.getElementById("clock");

    var photos = [];
    var queue = [];
    var front = imgA;  // currently visible, on top
    var back = imgB;   // behind, used for loading next image
    var transitioning = false;

    var params = new URLSearchParams(window.location.search);
    if (params.has("interval")) {
        INTERVAL = parseInt(params.get("interval"), 10) * 1000 || INTERVAL;
    }

    // Init layering
    front.style.zIndex = 2;
    front.style.opacity = 1;
    back.style.zIndex = 1;
    back.style.opacity = 1;

    function shuffle(arr) {
        var a = arr.slice();
        for (var i = a.length - 1; i > 0; i--) {
            var j = Math.floor(Math.random() * (i + 1));
            var tmp = a[i];
            a[i] = a[j];
            a[j] = tmp;
        }
        return a;
    }

    function nextPhoto() {
        if (queue.length === 0) {
            if (photos.length === 0) return null;
            queue = shuffle(photos);
        }
        return queue.pop();
    }

    function advance() {
        if (transitioning) return;
        var photo = nextPhoto();
        if (!photo) return;

        back.onload = function () {
            transitioning = true;

            // back is behind front, fully opaque but hidden — load is done
            // Now set back to opaque with no transition (it's invisible behind front)
            back.style.transition = "none";
            back.style.opacity = 1;
            back.style.zIndex = 1;
            front.style.zIndex = 2;
            back.offsetHeight; // force reflow

            // Fade front out — reveals back behind it
            front.style.transition = "opacity " + FADE_MS + "ms ease-in-out";
            front.style.opacity = 0;

            setTimeout(function () {
                // Swap: back becomes the new front
                var tmp = front;
                front = back;
                back = tmp;
                front.style.zIndex = 2;
                back.style.zIndex = 1;
                transitioning = false;
            }, FADE_MS + 100);
        };
        back.onerror = function () {
            setTimeout(advance, 100);
        };
        back.src = PHOTO_BASE + photo.filename;
    }

    function loadManifest() {
        fetch(MANIFEST_URL + "?t=" + Date.now())
            .then(function (r) { return r.json(); })
            .then(function (data) {
                if (Array.isArray(data) && data.length > 0) {
                    photos = data;
                    if (!front.src || front.src === window.location.href) {
                        advance();
                    }
                }
            })
            .catch(function () {});
    }

    function updateClock() {
        var now = new Date();
        var h = now.getHours();
        var m = now.getMinutes();
        var ampm = h >= 12 ? "PM" : "AM";
        h = h % 12 || 12;
        clockEl.textContent = h + ":" + (m < 10 ? "0" : "") + m + " " + ampm;
    }

    loadManifest();
    setInterval(advance, INTERVAL);
    setInterval(loadManifest, MANIFEST_POLL);
    updateClock();
    setInterval(updateClock, 10000);
})();
