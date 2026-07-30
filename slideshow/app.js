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

    var settingsPanel = document.getElementById("settings-panel");
    var pauseLabel = document.getElementById("pause-label");
    var thumbStrip = document.getElementById("thumb-strip");

    var photos = [];
    var queue = [];
    var playOrder = "shuffle";
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
    var screenOff = false;
    var scheduleTurnedOff = false;
    var sleepTimerEnd = 0;
    var wakeTimeout = null;
    var scheduleData = {enabled: false, onHour: 7, onMin: 0, offHour: 22, offMin: 0};

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

    // "shuffle" plays a shuffled bag that refills once empty, so nothing repeats
    // until everything has been shown. "sequential" walks the manifest, which is
    // alphabetical by filename with photos and videos interleaved.
    function refillQueue() {
        if (playOrder === "sequential") {
            // nextPhoto() pops off the end, so reverse to play in manifest order.
            queue = photos.slice().reverse();
        } else {
            queue = shuffle(photos);
        }
    }

    function nextPhoto() {
        if (queue.length === 0) {
            if (photos.length === 0) return null;
            refillQueue();
        }
        return queue.pop();
    }

    function loadPlayOrder() {
        var v = "";
        if (window.Kiosk && window.Kiosk.getPlayOrder) {
            try { v = window.Kiosk.getPlayOrder() || ""; } catch (e) {}
        }
        if (!v) {
            try { v = localStorage.getItem("playOrder") || ""; } catch (e) {}
        }
        playOrder = (v === "sequential") ? "sequential" : "shuffle";
    }

    function savePlayOrder(v) {
        playOrder = (v === "sequential") ? "sequential" : "shuffle";
        if (window.Kiosk && window.Kiosk.setPlayOrder) {
            try { window.Kiosk.setPlayOrder(playOrder); } catch (e) {}
        }
        try { localStorage.setItem("playOrder", playOrder); } catch (e) {}
        // Drop the current bag so the new order takes effect on the next advance
        // instead of after the current pass finishes.
        queue = [];
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
        if (videoEl.readyState >= 3) onReady();
    }

    function onVideoEnded() {
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
        var savedInterval = null;
        var savedFade = null;
        try {
            savedInterval = localStorage.getItem("pf_interval");
            savedFade = localStorage.getItem("pf_fade");
        } catch (e) {}

        var newInterval = ("interval" in params)
            ? parseInt(params["interval"], 10)
            : savedInterval ? parseInt(savedInterval, 10)
            : (cfg.interval || DEFAULTS.interval);
        intervalMs = newInterval * 1000;

        fadeMs = ("fade" in params)
            ? parseInt(params["fade"], 10)
            : savedFade ? parseInt(savedFade, 10)
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

    window.swipeLeft = function () { goForward(); };
    window.swipeRight = function () { goBack(); };

    // --- Fav / Pause icons ---
    var favPath = document.querySelector(".fav-path");
    var pausePath = document.querySelector(".pause-path");
    var PLAY_D = "M8 5v14l11-7z";
    var PAUSE_D = "M6 19h4V5H6v14zm8-14v14h4V5h-4z";

    function isFav(filename) {
        if (window.Kiosk && window.Kiosk.isLocked) {
            try { return window.Kiosk.isLocked(filename); }
            catch (e) {}
        }
        try { return localStorage.getItem("fav_" + filename) === "1"; }
        catch (e) { return false; }
    }

    function setFav(filename, val) {
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
            favPath.setAttribute("fill", "#ff4444");
            favPath.setAttribute("stroke", "#ff4444");
        } else {
            favPath.setAttribute("fill", "none");
            favPath.setAttribute("stroke", "white");
        }
    }

    function updatePauseIcon() {
        if (!pausePath) return;
        pausePath.setAttribute("d", paused ? PLAY_D : PAUSE_D);
        if (pauseLabel) pauseLabel.textContent = paused ? "Play" : "Pause";
    }

    // --- Thumbnail strip ---
    function populateThumbs() {
        if (!thumbStrip) return;
        thumbStrip.innerHTML = "";
        var activeEl = null;
        for (var i = 0; i < photos.length; i++) {
            var item = photos[i];
            var el = document.createElement("div");
            var isActive = currentItem && item.filename === currentItem.filename;
            el.className = "thumb" + (isActive ? " active" : "");
            if (item.type === "video") {
                el.className += " thumb-video";
            } else {
                el.style.backgroundImage = "url(" + PHOTO_BASE + item.filename + ")";
            }
            el.setAttribute("data-filename", item.filename);
            thumbStrip.appendChild(el);
            if (isActive) activeEl = el;
        }
        // Scroll current photo into view
        if (activeEl) {
            var stripW = thumbStrip.offsetWidth;
            var elLeft = activeEl.offsetLeft;
            var elW = activeEl.offsetWidth;
            thumbStrip.scrollLeft = elLeft - (stripW / 2) + (elW / 2);
        }
    }

    function showThumbs() {
        if (!thumbStrip || videoPlaying) return;
        populateThumbs();
        thumbStrip.className = "open";
    }

    function hideThumbs() {
        if (thumbStrip) thumbStrip.className = "";
    }

    if (thumbStrip) {
        thumbStrip.addEventListener("click", function (e) {
            e.stopPropagation();
            var el = e.target;
            while (el && el !== thumbStrip && !el.getAttribute("data-filename")) {
                el = el.parentNode;
            }
            if (!el || el === thumbStrip) return;
            var fname = el.getAttribute("data-filename");
            // Find item in photos array
            var item = null;
            for (var i = 0; i < photos.length; i++) {
                if (photos[i].filename === fname) { item = photos[i]; break; }
            }
            if (!item) return;
            currentItem = item;
            history.unshift(item);
            if (history.length > 50) history.pop();
            histIdx = -1;
            updateFavIcon();
            showItem(currentItem, 250, resetTimer);
            populateThumbs();
            resetDrawerTimer();
        });
    }

    // --- Screen on/off ---
    function turnScreenOff() {
        if (screenOff) return;
        screenOff = true;
        if (window.Kiosk && window.Kiosk.screenOff) {
            try { window.Kiosk.screenOff(); } catch (e) {}
        }
        if (slideTimer) { clearInterval(slideTimer); slideTimer = null; }
        if (videoPlaying) videoEl.pause();
    }

    function turnScreenOn() {
        if (!screenOff) return;
        screenOff = false;
        if (window.Kiosk && window.Kiosk.screenOn) {
            try { window.Kiosk.screenOn(); } catch (e) {}
        }
        if (!paused) {
            if (videoPlaying) videoEl.play();
            resetTimer();
        }
    }

    function wakeTemporarily() {
        if (wakeTimeout) clearTimeout(wakeTimeout);
        turnScreenOn();
        scheduleTurnedOff = false;
        wakeTimeout = setTimeout(function () {
            wakeTimeout = null;
            if (sleepTimerEnd > 0 && sleepTimerEnd <= Date.now()) {
                turnScreenOff();
                return;
            }
            if (scheduleData.enabled && !isInScheduleWindow()) {
                scheduleTurnedOff = true;
                turnScreenOff();
            }
        }, 30000);
    }

    // --- Sleep timer ---
    function loadSleepTimer() {
        if (window.Kiosk && window.Kiosk.getSleepTimer) {
            try {
                var data = JSON.parse(window.Kiosk.getSleepTimer());
                if (data && data.end && data.end > Date.now()) {
                    sleepTimerEnd = data.end;
                }
            } catch (e) {}
        }
    }

    function saveSleepTimer() {
        if (window.Kiosk && window.Kiosk.setSleepTimer) {
            try {
                window.Kiosk.setSleepTimer(JSON.stringify({end: sleepTimerEnd}));
            } catch (e) {}
        }
    }

    function startSleepTimer(minutes) {
        if (minutes <= 0) {
            sleepTimerEnd = 0;
        } else {
            sleepTimerEnd = Date.now() + minutes * 60 * 1000;
        }
        saveSleepTimer();
        updateSleepUI();
    }

    function checkSleepTimer() {
        if (sleepTimerEnd <= 0) return;
        var remaining = sleepTimerEnd - Date.now();
        if (remaining <= 0) {
            sleepTimerEnd = 0;
            saveSleepTimer();
            turnScreenOff();
        }
        updateSleepUI();
    }

    function updateSleepUI() {
        var statusEl = document.getElementById("sleep-status");
        if (statusEl) {
            if (sleepTimerEnd <= 0) {
                statusEl.textContent = "";
            } else {
                var remaining = Math.max(0, sleepTimerEnd - Date.now());
                var totalMin = Math.ceil(remaining / 60000);
                var h = Math.floor(totalMin / 60);
                var m = totalMin % 60;
                statusEl.textContent = (h > 0 ? h + "h " : "") + m + "m remaining";
            }
        }
        var optEl = document.getElementById("sleep-options");
        if (optEl) {
            var btns = optEl.getElementsByTagName("button");
            for (var i = 0; i < btns.length; i++) {
                var val = parseInt(btns[i].getAttribute("data-val"), 10);
                btns[i].className = (sleepTimerEnd <= 0 && val === 0)
                    ? "settings-opt active" : "settings-opt";
            }
        }
    }

    // --- Schedule ---
    function loadSchedule() {
        scheduleData = {enabled: false, onHour: 7, onMin: 0, offHour: 22, offMin: 0};
        if (window.Kiosk && window.Kiosk.getSchedule) {
            try {
                var data = JSON.parse(window.Kiosk.getSchedule());
                if (data) {
                    scheduleData.enabled = !!data.enabled;
                    if (data.onHour !== undefined) scheduleData.onHour = data.onHour;
                    if (data.onMin !== undefined) scheduleData.onMin = data.onMin;
                    if (data.offHour !== undefined) scheduleData.offHour = data.offHour;
                    if (data.offMin !== undefined) scheduleData.offMin = data.offMin;
                }
            } catch (e) {}
        }
    }

    function saveSchedule() {
        if (window.Kiosk && window.Kiosk.setSchedule) {
            try {
                window.Kiosk.setSchedule(JSON.stringify(scheduleData));
            } catch (e) {}
        }
    }

    function isInScheduleWindow() {
        var now = new Date();
        var cur = now.getHours() * 60 + now.getMinutes();
        var on = scheduleData.onHour * 60 + scheduleData.onMin;
        var off = scheduleData.offHour * 60 + scheduleData.offMin;
        if (on <= off) {
            return cur >= on && cur < off;
        } else {
            return cur >= on || cur < off;
        }
    }

    function checkSchedule() {
        if (!scheduleData.enabled) return;
        if (sleepTimerEnd > 0 && sleepTimerEnd > Date.now()) return;
        if (wakeTimeout) return;
        var shouldBeOn = isInScheduleWindow();
        if (shouldBeOn && screenOff) {
            scheduleTurnedOff = false;
            turnScreenOn();
        } else if (!shouldBeOn && !screenOff) {
            scheduleTurnedOff = true;
            turnScreenOff();
        }
    }

    function formatTime12(hour, min) {
        var h = hour % 12 || 12;
        var ampm = hour >= 12 ? "PM" : "AM";
        return h + ":" + (min < 10 ? "0" : "") + min + " " + ampm;
    }

    function adjustTime(which, delta) {
        var hour, min;
        if (which === "on") {
            hour = scheduleData.onHour;
            min = scheduleData.onMin;
        } else {
            hour = scheduleData.offHour;
            min = scheduleData.offMin;
        }
        var total = hour * 60 + min + delta;
        total = ((total % 1440) + 1440) % 1440;
        hour = Math.floor(total / 60);
        min = total % 60;
        if (which === "on") {
            scheduleData.onHour = hour;
            scheduleData.onMin = min;
        } else {
            scheduleData.offHour = hour;
            scheduleData.offMin = min;
        }
        saveSchedule();
        updateScheduleUI();
    }

    function updateScheduleUI() {
        var toggle = document.getElementById("sched-toggle");
        var config = document.getElementById("sched-config");
        var onTime = document.getElementById("sched-on-time");
        var offTime = document.getElementById("sched-off-time");
        if (toggle) {
            toggle.textContent = scheduleData.enabled ? "On" : "Off";
            toggle.className = scheduleData.enabled
                ? "settings-toggle active" : "settings-toggle";
        }
        if (config) {
            config.className = scheduleData.enabled ? "" : "settings-hidden";
        }
        if (onTime) {
            onTime.textContent = formatTime12(scheduleData.onHour, scheduleData.onMin);
        }
        if (offTime) {
            offTime.textContent = formatTime12(scheduleData.offHour, scheduleData.offMin);
        }
    }

    // --- Drawer ---
    function toggleDrawer() {
        var isOpen = drawer.className.indexOf("open") !== -1;
        if (isOpen) {
            drawer.className = "";
            hideThumbs();
            if (drawerTimer) { clearTimeout(drawerTimer); drawerTimer = null; }
        } else {
            drawer.className = "open";
            updateFavIcon();
            showThumbs();
            if (drawerTimer) clearTimeout(drawerTimer);
            drawerTimer = setTimeout(function () {
                drawer.className = "";
                hideThumbs();
                drawerTimer = null;
            }, 5000);
        }
    }

    function resetDrawerTimer() {
        if (drawerTimer) clearTimeout(drawerTimer);
        if (drawer.className.indexOf("open") !== -1) {
            drawerTimer = setTimeout(function () {
                drawer.className = "";
                hideThumbs();
                drawerTimer = null;
            }, 5000);
        }
    }

    document.getElementById("frame").addEventListener("click", function (e) {
        if (screenOff) {
            wakeTemporarily();
            return;
        }
        if (e.target && e.target.closest && e.target.closest("#drawer")) return;
        if (e.target && e.target.closest && e.target.closest("#video-bar")) return;
        if (e.target && e.target.closest && e.target.closest("#settings-panel")) return;
        if (e.target && e.target.closest && e.target.closest("#thumb-strip")) return;
        toggleDrawer();
    });

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
            case "btn-settings":
                openSettings();
                break;
            case "btn-power":
                if (window.Kiosk) window.Kiosk.shutdown();
                break;
        }
    });

    // --- Settings panel ---
    function openSettings() {
        if (settingsPanel) settingsPanel.className = "open";
        drawer.className = "";
        hideThumbs();
        if (drawerTimer) { clearTimeout(drawerTimer); drawerTimer = null; }
        highlightCurrentSettings();
        updateBrightnessDisplay();
        updateDebugInfo();
        updateSleepUI();
        updateScheduleUI();
    }

    function closeSettings() {
        if (settingsPanel) settingsPanel.className = "";
    }

    function highlightCurrentSettings() {
        var i, val, btns;
        btns = document.getElementById("interval-options");
        if (btns) {
            var iBtns = btns.getElementsByTagName("button");
            for (i = 0; i < iBtns.length; i++) {
                val = parseInt(iBtns[i].getAttribute("data-val"), 10);
                iBtns[i].className = (val * 1000 === intervalMs)
                    ? "settings-opt active" : "settings-opt";
            }
        }
        btns = document.getElementById("fade-options");
        if (btns) {
            var fBtns = btns.getElementsByTagName("button");
            for (i = 0; i < fBtns.length; i++) {
                val = parseInt(fBtns[i].getAttribute("data-val"), 10);
                fBtns[i].className = (val === fadeMs)
                    ? "settings-opt active" : "settings-opt";
            }
        }
    }

    function updateBrightnessDisplay() {
        var el = document.getElementById("bright-value");
        if (!el) return;
        var pct = 80;
        if (window.Kiosk && window.Kiosk.getBrightness) {
            try { pct = Math.round(window.Kiosk.getBrightness() * 100); }
            catch (e) {}
        }
        el.textContent = pct + "%";
    }

    function formatUptime(totalSec) {
        var d = Math.floor(totalSec / 86400);
        var h = Math.floor((totalSec % 86400) / 3600);
        var m = Math.floor((totalSec % 3600) / 60);
        var parts = [];
        if (d > 0) parts.push(d + "d");
        if (h > 0) parts.push(h + "h");
        parts.push(m + "m");
        return parts.join(" ");
    }

    function updateDebugInfo() {
        var el = document.getElementById("debug-info");
        if (!el) return;
        var lines = [];
        lines.push("Photos: " + photos.length);
        if (currentItem) lines.push("Current: " + currentItem.filename);
        lines.push("Interval: " + (intervalMs / 1000) + "s | Fade: " + fadeMs + "ms");
        lines.push("Paused: " + (paused ? "yes" : "no"));

        if (window.Kiosk && window.Kiosk.getDeviceInfo) {
            try {
                var info = JSON.parse(window.Kiosk.getDeviceInfo());
                lines.push("Android " + info.android + " (SDK " + info.sdk + ")");
                lines.push("Model: " + info.model);
                if (info.storageFree !== undefined) {
                    lines.push("Storage: " + info.storageFree + " MB free / " + info.storageTotal + " MB");
                }
                if (info.uptime) {
                    lines.push("Uptime: " + formatUptime(info.uptime));
                }
            } catch (e) {}
        }
        el.innerHTML = lines.join("<br>");
    }

    // Settings: interval
    (function () {
        var el = document.getElementById("interval-options");
        if (!el) return;
        el.addEventListener("click", function (e) {
            var btn = e.target;
            if (!btn.getAttribute || !btn.getAttribute("data-val")) return;
            var val = parseInt(btn.getAttribute("data-val"), 10);
            intervalMs = val * 1000;
            resetTimer();
            highlightCurrentSettings();
            try { localStorage.setItem("pf_interval", val); } catch (ex) {}
        });
    })();

    // Settings: fade
    (function () {
        var el = document.getElementById("fade-options");
        if (!el) return;
        el.addEventListener("click", function (e) {
            var btn = e.target;
            if (!btn.getAttribute || !btn.getAttribute("data-val")) return;
            var val = parseInt(btn.getAttribute("data-val"), 10);
            fadeMs = val;
            highlightCurrentSettings();
            try { localStorage.setItem("pf_fade", val); } catch (ex) {}
        });
    })();

    // Settings: brightness
    (function () {
        var up = document.getElementById("bright-up");
        var dn = document.getElementById("bright-down");
        if (up) {
            up.addEventListener("click", function (e) {
                e.stopPropagation();
                if (window.Kiosk) window.Kiosk.brightnessUp();
                updateBrightnessDisplay();
            });
        }
        if (dn) {
            dn.addEventListener("click", function (e) {
                e.stopPropagation();
                if (window.Kiosk) window.Kiosk.brightnessDown();
                updateBrightnessDisplay();
            });
        }
    })();

    // --- Confirm modal ---
    var confirmModal = document.getElementById("confirm-modal");
    var confirmMsg = document.getElementById("confirm-msg");
    var confirmOk = document.getElementById("confirm-ok");
    var confirmCancel = document.getElementById("confirm-cancel");
    var confirmCallback = null;

    function showConfirm(msg, onConfirm) {
        if (confirmMsg) confirmMsg.textContent = msg;
        confirmCallback = onConfirm;
        if (confirmModal) confirmModal.className = "open";
    }

    function hideConfirm() {
        if (confirmModal) confirmModal.className = "";
        confirmCallback = null;
    }

    if (confirmOk) {
        confirmOk.addEventListener("click", function (e) {
            e.stopPropagation();
            if (confirmCallback) confirmCallback();
            hideConfirm();
        });
    }
    if (confirmCancel) {
        confirmCancel.addEventListener("click", function (e) {
            e.stopPropagation();
            hideConfirm();
        });
    }
    if (confirmModal) {
        confirmModal.addEventListener("click", function (e) {
            if (e.target === confirmModal) hideConfirm();
        });
    }

    // Settings: play order (shuffle vs manifest order)
    (function () {
        var btnShuffle = document.getElementById("order-shuffle");
        var btnSeq = document.getElementById("order-sequential");
        if (!btnShuffle || !btnSeq) return;

        function updateOrderToggle() {
            var seq = playOrder === "sequential";
            btnShuffle.className = seq ? "settings-opt" : "settings-opt active";
            btnSeq.className = seq ? "settings-opt active" : "settings-opt";
        }

        btnShuffle.addEventListener("click", function (e) {
            e.stopPropagation();
            savePlayOrder("shuffle");
            updateOrderToggle();
        });
        btnSeq.addEventListener("click", function (e) {
            e.stopPropagation();
            savePlayOrder("sequential");
            updateOrderToggle();
        });

        var origOpenOrder = openSettings;
        openSettings = function () {
            origOpenOrder();
            updateOrderToggle();
        };
    })();

    // Settings: delete from source toggle
    (function () {
        var btnOff = document.getElementById("del-src-off");
        var btnOn = document.getElementById("del-src-on");
        if (!btnOff || !btnOn) return;

        function updateDeleteToggle() {
            var enabled = false;
            if (window.Kiosk && window.Kiosk.getDeleteAfterSync) {
                try { enabled = window.Kiosk.getDeleteAfterSync(); } catch (e) {}
            }
            btnOff.className = enabled ? "settings-opt" : "settings-opt active";
            btnOn.className = enabled ? "settings-opt active" : "settings-opt";
        }

        btnOff.addEventListener("click", function (e) {
            e.stopPropagation();
            if (window.Kiosk && window.Kiosk.setDeleteAfterSync) {
                window.Kiosk.setDeleteAfterSync(false);
            }
            updateDeleteToggle();
        });
        btnOn.addEventListener("click", function (e) {
            e.stopPropagation();
            showConfirm(
                "Photos will be permanently deleted from Google Drive after syncing to the frame. Are you sure?",
                function () {
                    if (window.Kiosk && window.Kiosk.setDeleteAfterSync) {
                        window.Kiosk.setDeleteAfterSync(true);
                    }
                    updateDeleteToggle();
                }
            );
        });

        // Update on settings open
        var origOpen = openSettings;
        openSettings = function () {
            origOpen();
            updateDeleteToggle();
        };
    })();

    // Settings: system buttons
    (function () {
        var wifi = document.getElementById("sys-wifi");
        var reboot = document.getElementById("sys-reboot");
        var power = document.getElementById("sys-power");

        if (wifi) {
            wifi.addEventListener("click", function (e) {
                e.stopPropagation();
                if (window.Kiosk && window.Kiosk.openWifiSettings) {
                    window.Kiosk.openWifiSettings();
                }
            });
        }
        if (reboot) {
            reboot.addEventListener("click", function (e) {
                e.stopPropagation();
                if (window.Kiosk && window.Kiosk.reboot) {
                    window.Kiosk.reboot();
                }
            });
        }
        if (power) {
            power.addEventListener("click", function (e) {
                e.stopPropagation();
                if (window.Kiosk) window.Kiosk.shutdown();
            });
        }
    })();

    // Settings: sleep timer
    (function () {
        var el = document.getElementById("sleep-options");
        if (!el) return;
        el.addEventListener("click", function (e) {
            var btn = e.target;
            if (!btn.getAttribute || !btn.getAttribute("data-val")) return;
            e.stopPropagation();
            var val = parseInt(btn.getAttribute("data-val"), 10);
            startSleepTimer(val);
        });
    })();

    // Settings: schedule
    (function () {
        var toggle = document.getElementById("sched-toggle");
        if (toggle) {
            toggle.addEventListener("click", function (e) {
                e.stopPropagation();
                scheduleData.enabled = !scheduleData.enabled;
                if (!scheduleData.enabled && scheduleTurnedOff) {
                    scheduleTurnedOff = false;
                    if (screenOff) turnScreenOn();
                }
                saveSchedule();
                updateScheduleUI();
            });
        }
        var onDown = document.getElementById("sched-on-down");
        var onUp = document.getElementById("sched-on-up");
        var offDown = document.getElementById("sched-off-down");
        var offUp = document.getElementById("sched-off-up");
        if (onDown) onDown.addEventListener("click", function (e) {
            e.stopPropagation();
            adjustTime("on", -15);
        });
        if (onUp) onUp.addEventListener("click", function (e) {
            e.stopPropagation();
            adjustTime("on", 15);
        });
        if (offDown) offDown.addEventListener("click", function (e) {
            e.stopPropagation();
            adjustTime("off", -15);
        });
        if (offUp) offUp.addEventListener("click", function (e) {
            e.stopPropagation();
            adjustTime("off", 15);
        });
    })();

    // Settings: close
    (function () {
        var el = document.getElementById("settings-close");
        if (el) {
            el.addEventListener("click", function (e) {
                e.stopPropagation();
                closeSettings();
            });
        }
        if (settingsPanel) {
            settingsPanel.addEventListener("click", function (e) {
                if (e.target === settingsPanel) closeSettings();
            });
        }
    })();

    // --- Init ---
    loadConfig();
    loadPlayOrder();
    loadManifest();
    setInterval(loadManifest, DEFAULTS.manifestPoll);
    updateClock();
    setInterval(updateClock, 10000);

    loadSchedule();
    loadSleepTimer();
    if (window.Kiosk && window.Kiosk.isScreenOff) {
        try { screenOff = window.Kiosk.isScreenOff(); } catch (e) {}
    }
    setInterval(checkSleepTimer, 10000);
    setInterval(checkSchedule, 60000);
    checkSchedule();
})();
