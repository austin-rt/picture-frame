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
    var drawer = document.getElementById("drawer");

    var videoBarEl = document.getElementById("video-bar");
    var videoBarFill = document.getElementById("video-bar-fill");
    var videoTimeEl = document.getElementById("video-time");

    var photos = [];
    var queue = [];
    var front = imgA;
    var back = imgB;
    var transitioning = false;
    var videoPlaying = false;
    var paused = false;
    var intervalMs = DEFAULTS.interval * 1000;
    var fadeMs = DEFAULTS.fadeDuration;
    var slideTimer = null;
    var drawerTimer = null;
    var currentItem = null;

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
        hideVideoBar();
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
            showVideoBar();

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

    // --- Video progress bar ---
    function formatTime(sec) {
        if (!sec || !isFinite(sec)) return "0:00";
        var s = Math.floor(sec);
        var m = Math.floor(s / 60);
        s = s % 60;
        return m + ":" + (s < 10 ? "0" : "") + s;
    }

    function showVideoBar() {
        if (videoBarEl) videoBarEl.className = "active";
    }

    function hideVideoBar() {
        if (videoBarEl) videoBarEl.className = "";
        if (videoBarFill) videoBarFill.style.width = "0%";
        if (videoTimeEl) videoTimeEl.textContent = "";
    }

    videoEl.addEventListener("timeupdate", function () {
        if (!videoPlaying || !videoBarFill) return;
        var cur = videoEl.currentTime || 0;
        var dur = videoEl.duration || 0;
        if (dur > 0) {
            videoBarFill.style.width = ((cur / dur) * 100) + "%";
        }
        if (videoTimeEl) {
            videoTimeEl.textContent = formatTime(cur) + " / " + formatTime(dur);
        }
    });

    // Tap on progress bar to seek
    if (videoBarEl) {
        videoBarEl.addEventListener("click", function (e) {
            e.stopPropagation();
            if (!videoPlaying) return;
            var dur = videoEl.duration || 0;
            if (dur <= 0) return;
            var rect = videoBarEl.getBoundingClientRect();
            var x = e.clientX - rect.left;
            var pct = x / rect.width;
            videoEl.currentTime = pct * dur;
        });
    }

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
        currentItem = item;
        history.unshift(item);
        if (history.length > 50) history.pop();
        histIdx = -1;
        transitioning = true;
        updateFavIcon();
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
            currentItem = history[histIdx];
            updateFavIcon();
            showItem(currentItem, 250, resetTimer);
        } else if (histIdx === 0 && history.length > 1) {
            histIdx = history.length - 1;
            currentItem = history[histIdx];
            updateFavIcon();
            showItem(currentItem, 250, resetTimer);
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
            currentItem = history[histIdx];
            updateFavIcon();
            showItem(currentItem, 250, resetTimer);
        } else if (history.length > 1) {
            histIdx = 0;
            currentItem = history[histIdx];
            updateFavIcon();
            showItem(currentItem, 250, resetTimer);
        }
    }

    function resetTimer() {
        if (slideTimer) clearInterval(slideTimer);
        if (paused) return;
        slideTimer = setInterval(function () {
            if (!videoPlaying && !paused) advance();
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

    // --- Drawer controls ---
    var favPath = document.getElementById("fav-path");
    var pausePath = document.getElementById("pause-path");
    var PLAY_D = "M8 5v14l11-7z";
    var PAUSE_D = "M6 19h4V5H6v14zm8-14v14h4V5h-4z";

    function isFav(filename) {
        // Check Kiosk bridge first (persisted to file for sync.sh), fall back to localStorage
        if (window.Kiosk && window.Kiosk.isLocked) {
            try { return window.Kiosk.isLocked(filename); }
            catch (e) {}
        }
        try { return localStorage.getItem("fav_" + filename) === "1"; }
        catch (e) { return false; }
    }

    function setFav(filename, val) {
        // Persist via Kiosk bridge (writes locked.txt for sync.sh) and localStorage
        if (window.Kiosk) {
            try {
                if (val) window.Kiosk.lockItem(filename);
                else window.Kiosk.unlockItem(filename);
            } catch (e) {}
        }
        try {
            if (val) localStorage.setItem("fav_" + filename, "1");
            else localStorage.removeItem("fav_" + filename);
        } catch (e) {}
    }

    function updateFavIcon() {
        if (!currentItem || !favPath) return;
        if (isFav(currentItem.filename)) {
            favPath.setAttribute("fill", "white");
        } else {
            favPath.setAttribute("fill", "none");
        }
    }

    function updatePauseIcon() {
        if (!pausePath) return;
        pausePath.setAttribute("d", paused ? PLAY_D : PAUSE_D);
    }

    function toggleDrawer() {
        var isOpen = drawer.className.indexOf("open") !== -1;
        if (isOpen) {
            drawer.className = "";
            if (drawerTimer) { clearTimeout(drawerTimer); drawerTimer = null; }
        } else {
            drawer.className = "open";
            updateFavIcon();
            // Auto-close after 5s
            if (drawerTimer) clearTimeout(drawerTimer);
            drawerTimer = setTimeout(function () {
                drawer.className = "";
                drawerTimer = null;
            }, 5000);
        }
    }

    function resetDrawerTimer() {
        if (drawerTimer) clearTimeout(drawerTimer);
        if (drawer.className.indexOf("open") !== -1) {
            drawerTimer = setTimeout(function () {
                drawer.className = "";
                drawerTimer = null;
            }, 5000);
        }
    }

    // Tap on frame area toggles drawer
    document.getElementById("frame").addEventListener("click", function (e) {
        if (e.target && e.target.closest && e.target.closest("#drawer")) return;
        if (e.target && e.target.closest && e.target.closest("#video-bar")) return;
        toggleDrawer();
    });

    // Drawer button handlers
    drawer.addEventListener("click", function (e) {
        e.stopPropagation();
        var btn = e.target;
        while (btn && btn !== drawer && !btn.id) btn = btn.parentNode;
        if (!btn || !btn.id) return;
        resetDrawerTimer();

        switch (btn.id) {
            case "btn-fav":
                if (currentItem) {
                    setFav(currentItem.filename, !isFav(currentItem.filename));
                    updateFavIcon();
                }
                break;
            case "btn-prev":
                goBack();
                break;
            case "btn-next":
                goForward();
                break;
            case "btn-pause":
                paused = !paused;
                updatePauseIcon();
                if (paused) {
                    if (slideTimer) { clearInterval(slideTimer); slideTimer = null; }
                    if (videoPlaying) videoEl.pause();
                } else {
                    if (videoPlaying) videoEl.play();
                    resetTimer();
                }
                break;
            case "btn-bright-up":
                if (window.Kiosk) window.Kiosk.brightnessUp();
                break;
            case "btn-bright-down":
                if (window.Kiosk) window.Kiosk.brightnessDown();
                break;
            case "btn-power":
                if (window.Kiosk) window.Kiosk.shutdown();
                break;
        }
    });

    // --- Init ---
    loadConfig();
    loadManifest();
    setInterval(loadManifest, DEFAULTS.manifestPoll);
    updateClock();
    setInterval(updateClock, 10000);
})();
