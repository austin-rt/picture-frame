(function () {
    "use strict";

    var DEFAULTS = {
        interval: 30,
        fadeDuration: 1500,
        manifestPoll: 60000
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

    var params = {};
    (function () {
        var qs = window.location.search.substring(1);
        if (!qs) return;
        var pairs = qs.split("&");
        for (var i = 0; i < pairs.length; i++) {
            var kv = pairs[i].split("=");
            params[decodeURIComponent(kv[0])] = decodeURIComponent(kv[1] || "");
        }
    })();

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

    function crossfade(url, duration, done) {
        var ms = duration || fadeMs;
        back.style.transition = "none";
        back.style.opacity = 1;
        back.style.zIndex = 1;
        front.style.zIndex = 2;
        back.style.backgroundImage = "url(" + url + ")";
        back.offsetHeight;

        front.style.transition = "opacity " + ms + "ms ease-in-out";
        front.style.opacity = 0;

        setTimeout(function () {
            var tmp = front;
            front = back;
            back = tmp;
            front.style.zIndex = 2;
            back.style.zIndex = 1;
            transitioning = false;
            if (done) done();
        }, ms + 100);
    }

    // --- History (circular) ---
    var history = [];
    var histIdx = -1;

    function advance() {
        if (transitioning) return;
        var photo = nextPhoto();
        if (!photo) return;
        history.unshift(photo);
        if (history.length > 50) history.pop();
        histIdx = -1;
        transitioning = true;
        crossfade(PHOTO_BASE + photo.filename, fadeMs);
    }

    function showPhoto(photo, done) {
        if (!photo) return;
        transitioning = true;
        crossfade(PHOTO_BASE + photo.filename, 250, done);
    }

    function goForward() {
        if (transitioning) return;
        if (histIdx > 0) {
            histIdx--;
            showPhoto(history[histIdx], resetTimer);
        } else if (histIdx === 0 && history.length > 1) {
            histIdx = history.length - 1;
            showPhoto(history[histIdx], resetTimer);
        } else {
            histIdx = -1;
            advance();
            resetTimer();
        }
    }

    function goBack() {
        if (transitioning) return;
        var target = (histIdx < 0) ? 1 : histIdx + 1;
        if (target < history.length) {
            histIdx = target;
            showPhoto(history[histIdx], resetTimer);
        } else if (history.length > 1) {
            histIdx = 0;
            showPhoto(history[histIdx], resetTimer);
        }
    }

    function resetTimer() {
        if (slideTimer) clearInterval(slideTimer);
        slideTimer = setInterval(advance, intervalMs);
    }

    function loadManifest() {
        fetch(MANIFEST_URL + "?t=" + Date.now())
            .then(function (r) { return r.json(); })
            .then(function (data) {
                if (Array.isArray(data) && data.length > 0) {
                    photos = data;
                    if (!front.style.backgroundImage) {
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
        var newInterval = ("interval" in params)
            ? parseInt(params["interval"], 10)
            : (cfg.interval || DEFAULTS.interval);
        intervalMs = newInterval * 1000;

        fadeMs = ("fade" in params)
            ? parseInt(params["fade"], 10)
            : (cfg.fadeDuration || DEFAULTS.fadeDuration);

        if (slideTimer) clearInterval(slideTimer);
        slideTimer = setInterval(advance, intervalMs);
    }

    function loadConfig() {
        fetch(CONFIG_URL + "?t=" + Date.now())
            .then(function (r) { return r.json(); })
            .then(function (cfg) { applyConfig(cfg); })
            .catch(function () { applyConfig({}); });
    }

    // Expose for native Java swipe injection
    window.swipeLeft = function () { goForward(); };
    window.swipeRight = function () { goBack(); };

    // --- Init ---
    loadConfig();
    loadManifest();
    setInterval(loadManifest, DEFAULTS.manifestPoll);
    updateClock();
    setInterval(updateClock, 10000);
})();
