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
    var videoEl = document.getElementById("video-player");
    var clockEl = document.getElementById("clock");

    var photos = [];
    var queue = [];
    var front = imgA;
    var back = imgB;
    var transitioning = false;
    var videoPlaying = false;
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

    // --- Video ---
    function stopVideo() {
        if (!videoPlaying) return;
        videoEl.pause();
        videoEl.style.opacity = 0;
        videoEl.style.zIndex = 0;
        videoEl.removeAttribute("src");
        videoPlaying = false;
    }

    function playVideo(item, duration, done) {
        var ms = duration || fadeMs;
        var url = PHOTO_BASE + item.filename;

        videoEl.style.transition = "none";
        videoEl.style.opacity = 0;
        videoEl.style.zIndex = 3;
        videoEl.src = url;
        videoEl.load();

        var started = false;
        var onReady = function () {
            if (started) return;
            started = true;
            videoEl.removeEventListener("canplay", onReady);

            // Fade in video, fade out current photo
            front.style.transition = "opacity " + ms + "ms ease-in-out";
            front.style.opacity = 0;
            videoEl.offsetHeight;
            videoEl.style.transition = "opacity " + ms + "ms ease-in-out";
            videoEl.style.opacity = 1;
            videoEl.play();
            videoPlaying = true;

            setTimeout(function () {
                transitioning = false;
                if (done) done();
            }, ms + 100);
        };

        videoEl.addEventListener("canplay", onReady);
        // Fallback if canplay already fired
        if (videoEl.readyState >= 3) onReady();
    }

    function onVideoEnded() {
        // Video finished — advance to next item
        stopVideo();
        advance();
        resetTimer();
    }

    videoEl.addEventListener("ended", onVideoEnded);

    // --- History (circular) ---
    var history = [];
    var histIdx = -1;

    function showItem(item, duration, done) {
        if (!item) return;
        transitioning = true;
        if (item.type === "video") {
            stopVideo();
            playVideo(item, duration, done);
        } else {
            stopVideo();
            crossfade(PHOTO_BASE + item.filename, duration, done);
        }
    }

    function advance() {
        if (transitioning) return;
        var item = nextPhoto();
        if (!item) return;
        history.unshift(item);
        if (history.length > 50) history.pop();
        histIdx = -1;
        transitioning = true;
        if (item.type === "video") {
            stopVideo();
            playVideo(item, fadeMs);
        } else {
            stopVideo();
            crossfade(PHOTO_BASE + item.filename, fadeMs);
        }
    }

    function goForward() {
        if (transitioning) return;
        stopVideo();
        if (histIdx > 0) {
            histIdx--;
            showItem(history[histIdx], 250, resetTimer);
        } else if (histIdx === 0 && history.length > 1) {
            histIdx = history.length - 1;
            showItem(history[histIdx], 250, resetTimer);
        } else {
            histIdx = -1;
            advance();
            resetTimer();
        }
    }

    function goBack() {
        if (transitioning) return;
        stopVideo();
        var target = (histIdx < 0) ? 1 : histIdx + 1;
        if (target < history.length) {
            histIdx = target;
            showItem(history[histIdx], 250, resetTimer);
        } else if (history.length > 1) {
            histIdx = 0;
            showItem(history[histIdx], 250, resetTimer);
        }
    }

    function resetTimer() {
        if (slideTimer) clearInterval(slideTimer);
        slideTimer = setInterval(function () {
            if (!videoPlaying) advance();
        }, intervalMs);
    }

    function loadManifest() {
        fetch(MANIFEST_URL + "?t=" + Date.now())
            .then(function (r) { return r.json(); })
            .then(function (data) {
                if (Array.isArray(data) && data.length > 0) {
                    // Default type to "photo" for backwards compatibility
                    for (var i = 0; i < data.length; i++) {
                        if (!data[i].type) data[i].type = "photo";
                    }
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
        slideTimer = setInterval(function () {
            if (!videoPlaying) advance();
        }, intervalMs);
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
