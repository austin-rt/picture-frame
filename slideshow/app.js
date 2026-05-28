(function () {
    "use strict";

    var DEFAULTS = {
        interval: 30,       // seconds
        fadeDuration: 1500,  // ms
        manifestPoll: 60000  // ms
    };

    var MANIFEST_URL = "manifest.json";
    var CONFIG_URL = "config.json";
    var PHOTO_BASE = "photos/";

    var imgA = document.getElementById("img-a");
    var imgB = document.getElementById("img-b");
    var clockEl = document.getElementById("clock");

    var photos = [];
    var queue = [];
    var front = imgA;
    var back = imgB;
    var transitioning = false;
    var intervalMs = DEFAULTS.interval * 1000;
    var fadeMs = DEFAULTS.fadeDuration;
    var slideTimer = null;

    // Query params override config.json
    var params = new URLSearchParams(window.location.search);

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
            back.style.transition = "none";
            back.style.opacity = 1;
            back.style.zIndex = 1;
            front.style.zIndex = 2;
            back.offsetHeight;

            front.style.transition = "opacity " + fadeMs + "ms ease-in-out";
            front.style.opacity = 0;

            setTimeout(function () {
                var tmp = front;
                front = back;
                back = tmp;
                front.style.zIndex = 2;
                back.style.zIndex = 1;
                transitioning = false;
            }, fadeMs + 100);
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

    function applyConfig(cfg) {
        // Query params take precedence over config.json
        var newInterval = params.has("interval")
            ? parseInt(params.get("interval"), 10)
            : (cfg.interval || DEFAULTS.interval);
        intervalMs = newInterval * 1000;

        fadeMs = params.has("fade")
            ? parseInt(params.get("fade"), 10)
            : (cfg.fadeDuration || DEFAULTS.fadeDuration);

        // Restart the slide timer with the new interval
        if (slideTimer) clearInterval(slideTimer);
        slideTimer = setInterval(advance, intervalMs);
    }

    function loadConfig() {
        fetch(CONFIG_URL + "?t=" + Date.now())
            .then(function (r) { return r.json(); })
            .then(function (cfg) { applyConfig(cfg); })
            .catch(function () { applyConfig({}); });
    }

    // --- Init ---
    loadConfig();
    loadManifest();
    setInterval(loadManifest, DEFAULTS.manifestPoll);
    updateClock();
    setInterval(updateClock, 10000);
})();
