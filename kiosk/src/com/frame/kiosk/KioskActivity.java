package com.frame.kiosk;

import android.app.Activity;
import android.app.ActivityManager;
import android.content.Context;
import android.content.Intent;
import android.os.Bundle;
import android.os.Handler;
import android.util.DisplayMetrics;
import android.util.Log;
import android.view.MotionEvent;
import android.view.View;
import android.view.WindowManager;
import android.webkit.JavascriptInterface;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.webkit.WebSettings;
import java.io.BufferedReader;
import java.io.File;
import java.io.FileReader;
import java.io.FileWriter;
import java.io.InputStreamReader;
import java.io.IOException;
import java.io.OutputStream;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import android.provider.Settings;
import android.os.StatFs;
import android.os.Environment;
import android.os.SystemClock;

public class KioskActivity extends Activity {

    private static final String TAG = "KioskActivity";
    private static final String PAGE_URL = "http://localhost:8080";
    private static final int INITIAL_WAIT_MS = 20000;
    private static final int RETRY_DELAY_MS = 5000;

    private static final String TERMUX_PREFIX = "/data/data/com.termux/files/usr";
    private static final String TERMUX_HOME = "/data/data/com.termux/files/home";

    /** Root-launched boot.sh, with the Termux env `su` would otherwise strip. */
    private static final String ROOT_BOOT_CMD =
        "export PREFIX=" + TERMUX_PREFIX + "; "
        + "export HOME=" + TERMUX_HOME + "; "
        + "export TMPDIR=$PREFIX/tmp; "
        + "export PATH=$PREFIX/bin:$PREFIX/bin/applets:/system/bin:/system/xbin; "
        + "export LD_LIBRARY_PATH=$PREFIX/lib; "
        + "export SSL_CERT_FILE=$PREFIX/etc/tls/cert.pem; "
        + "/system/bin/setsid $PREFIX/bin/bash $HOME/.termux/boot/boot.sh "
        + ">> $HOME/frame-data/kiosk-boot.log 2>&1 < /dev/null &";

    private WebView webView;
    private Handler handler;
    private boolean termuxStarted = false;
    private boolean pageLoaded = false;
    private boolean initialWaitDone = false;
    private int retryCount = 0;
    private boolean bouncingTermux = false;

    private float touchStartX, touchStartY;
    private long touchStartTime;
    private float currentBrightness = 0.8f;
    private static final float BRIGHTNESS_MIN = 0.02f;
    private static final float BRIGHTNESS_MAX = 1.0f;
    private static final float BRIGHTNESS_STEP = 0.1f;
    private int screenWidth;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        Log.i(TAG, "onCreate");

        DisplayMetrics dm = new DisplayMetrics();
        getWindowManager().getDefaultDisplay().getMetrics(dm);
        screenWidth = dm.widthPixels;

        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        WindowManager.LayoutParams lp = getWindow().getAttributes();
        lp.screenBrightness = currentBrightness;
        getWindow().setAttributes(lp);
        hideSystemUI();

        handler = new Handler();
        webView = new WebView(this);
        setContentView(webView);

        WebSettings settings = webView.getSettings();
        settings.setJavaScriptEnabled(true);
        settings.setDomStorageEnabled(true);
        settings.setCacheMode(WebSettings.LOAD_DEFAULT);
        settings.setMediaPlaybackRequiresUserGesture(false);
        settings.setSupportZoom(false);
        settings.setBuiltInZoomControls(false);

        webView.setOverScrollMode(View.OVER_SCROLL_NEVER);
        webView.setVerticalScrollBarEnabled(false);
        webView.setHorizontalScrollBarEnabled(false);

        webView.setWebViewClient(new WebViewClient() {
            @Override
            public void onPageFinished(WebView view, String url) {
                super.onPageFinished(view, url);
                if (url != null && (url.equals(PAGE_URL) || url.equals(PAGE_URL + "/"))) {
                    Log.i(TAG, "Page loaded successfully");
                    pageLoaded = true;
                    retryCount = 0;
                }
            }

            @Override
            public void onReceivedError(WebView view, int errorCode,
                    String description, String failingUrl) {
                super.onReceivedError(view, errorCode, description, failingUrl);
                if (!initialWaitDone) return;
                pageLoaded = false;
                retryCount++;
                Log.w(TAG, "Page load error #" + retryCount
                    + ": " + description + " (" + errorCode + ")");

                if (retryCount <= 2) {
                    // First failures: retry invisible boot trigger
                    Log.i(TAG, "Retrying Termux boot (invisible)");
                    webView.loadDataWithBaseURL(null,
                        countdownHtml(15, "Starting services\u2026"),
                        "text/html", "utf-8", null);
                    triggerTermuxBoot(500);
                    handler.postDelayed(new Runnable() {
                        @Override
                        public void run() {
                            Log.i(TAG, "Retrying page load");
                            webView.loadUrl(PAGE_URL);
                        }
                    }, 15000);
                } else if (retryCount == 3) {
                    // Third failure: bounce TermuxActivity as last resort
                    // (.profile auto-starts boot.sh)
                    Log.i(TAG, "Bouncing TermuxActivity as fallback");
                    webView.loadDataWithBaseURL(null,
                        countdownHtml(15, "Starting services\u2026"),
                        "text/html", "utf-8", null);
                    bounceTermux(500);
                    handler.postDelayed(new Runnable() {
                        @Override
                        public void run() {
                            webView.loadUrl(PAGE_URL);
                        }
                    }, 15000);
                } else {
                    // Keep retrying
                    final int secs = RETRY_DELAY_MS / 1000;
                    webView.loadDataWithBaseURL(null,
                        countdownHtml(secs,
                            "Retrying (" + retryCount + ")\u2026"),
                        "text/html", "utf-8", null);
                    handler.postDelayed(new Runnable() {
                        @Override
                        public void run() {
                            webView.loadUrl(PAGE_URL);
                        }
                    }, RETRY_DELAY_MS);
                }
            }
        });

        webView.setWebChromeClient(new WebChromeClient());
        webView.addJavascriptInterface(new KioskBridge(), "Kiosk");
        webView.clearCache(true);
        webView.setBackgroundColor(0xFF000000);
        startTermux();
        showCountdown(INITIAL_WAIT_MS / 1000);
    }

    @Override
    protected void onStop() {
        super.onStop();
        if (bouncingTermux) {
            bouncingTermux = false;
            Log.i(TAG, "onStop: bouncing back from Termux");
            handler.post(new Runnable() {
                @Override
                public void run() {
                    bringToFront();
                }
            });
        }
    }

    @Override
    public boolean dispatchTouchEvent(MotionEvent event) {
        switch (event.getAction()) {
            case MotionEvent.ACTION_DOWN:
                touchStartX = event.getRawX();
                touchStartY = event.getRawY();
                touchStartTime = System.currentTimeMillis();
                break;
            case MotionEvent.ACTION_UP:
                float dx = event.getRawX() - touchStartX;
                float dy = event.getRawY() - touchStartY;
                long dt = System.currentTimeMillis() - touchStartTime;
                if (dt < 1000) {
                    boolean inLeftEdge = touchStartX < screenWidth / 6;
                    boolean inRightEdge = touchStartX > screenWidth * 5 / 6;

                    if ((inLeftEdge || inRightEdge)
                            && Math.abs(dy) > 60 && Math.abs(dy) > Math.abs(dx)) {
                        adjustBrightness(dy < 0 ? BRIGHTNESS_STEP : -BRIGHTNESS_STEP);
                    } else if (Math.abs(dx) > 80 && Math.abs(dx) > Math.abs(dy)) {
                        if (pageLoaded) {
                            String fn = (dx < 0) ? "swipeLeft" : "swipeRight";
                            webView.loadUrl(
                                "javascript:void(window." + fn + " && window." + fn + "())");
                        }
                    }
                }
                break;
        }
        return super.dispatchTouchEvent(event);
    }

    private void adjustBrightness(float delta) {
        currentBrightness = Math.max(BRIGHTNESS_MIN,
            Math.min(BRIGHTNESS_MAX, currentBrightness + delta));
        WindowManager.LayoutParams lp = getWindow().getAttributes();
        lp.screenBrightness = currentBrightness;
        getWindow().setAttributes(lp);
    }

    private class KioskBridge {
        @JavascriptInterface
        public void setBrightness(float value) {
            final float clamped = Math.max(BRIGHTNESS_MIN,
                Math.min(BRIGHTNESS_MAX, value));
            currentBrightness = clamped;
            runOnUiThread(new Runnable() {
                @Override
                public void run() {
                    WindowManager.LayoutParams lp = getWindow().getAttributes();
                    lp.screenBrightness = clamped;
                    getWindow().setAttributes(lp);
                }
            });
        }

        @JavascriptInterface
        public float getBrightness() {
            return currentBrightness;
        }

        @JavascriptInterface
        public void brightnessUp() {
            setBrightness(currentBrightness + BRIGHTNESS_STEP);
        }

        @JavascriptInterface
        public void brightnessDown() {
            setBrightness(currentBrightness - BRIGHTNESS_STEP);
        }

        @JavascriptInterface
        public void shutdown() {
            try {
                Runtime.getRuntime().exec(new String[]{"su", "-c", "reboot", "-p"});
            } catch (IOException ignored) {}
        }

        @JavascriptInterface
        public void reboot() {
            try {
                Runtime.getRuntime().exec(new String[]{"su", "-c", "reboot"});
            } catch (IOException ignored) {}
        }

        @JavascriptInterface
        public void openWifiSettings() {
            runOnUiThread(new Runnable() {
                @Override
                public void run() {
                    try {
                        Intent wifi = new Intent(Settings.ACTION_WIFI_SETTINGS);
                        wifi.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                        startActivity(wifi);
                        handler.postDelayed(new Runnable() {
                            @Override
                            public void run() {
                                bringToFront();
                            }
                        }, 30000);
                    } catch (Exception ignored) {}
                }
            });
        }

        @JavascriptInterface
        public String getDeviceInfo() {
            StringBuilder sb = new StringBuilder();
            sb.append("{");
            sb.append("\"android\":\"").append(android.os.Build.VERSION.RELEASE).append("\",");
            sb.append("\"model\":\"").append(android.os.Build.MODEL).append("\",");
            sb.append("\"sdk\":").append(android.os.Build.VERSION.SDK_INT).append(",");
            try {
                StatFs stat = new StatFs(Environment.getDataDirectory().getPath());
                long free = stat.getAvailableBlocksLong() * stat.getBlockSizeLong();
                long total = stat.getBlockCountLong() * stat.getBlockSizeLong();
                sb.append("\"storageFree\":").append(free / (1024 * 1024)).append(",");
                sb.append("\"storageTotal\":").append(total / (1024 * 1024)).append(",");
            } catch (Exception e) {}
            sb.append("\"uptime\":").append(android.os.SystemClock.elapsedRealtime() / 1000);
            sb.append("}");
            return sb.toString();
        }

        @JavascriptInterface
        public boolean getDeleteAfterSync() {
            return "true".equals(rootRead(FRAME_DATA + "delete_after_sync").trim());
        }

        @JavascriptInterface
        public void setDeleteAfterSync(boolean enabled) {
            rootWrite(FRAME_DATA + "delete_after_sync", enabled ? "true" : "false");
        }

        @JavascriptInterface
        public void lockItem(String filename) {
            updateLockedFile(filename, true);
        }

        @JavascriptInterface
        public void unlockItem(String filename) {
            updateLockedFile(filename, false);
        }

        @JavascriptInterface
        public boolean isLocked(String filename) {
            Set<String> locked = readLockedSet();
            return locked.contains(filename);
        }

        private String getLockedFile() {
            return FRAME_DATA + "locked.txt";
        }

        private Set<String> readLockedSet() {
            Set<String> set = new HashSet<String>();
            String body = rootRead(getLockedFile());
            for (String line : body.split("\n")) {
                line = line.trim();
                if (!line.isEmpty()) set.add(line);
            }
            return set;
        }

        private void updateLockedFile(String filename, boolean add) {
            Set<String> locked = readLockedSet();
            if (add) locked.add(filename);
            else locked.remove(filename);
            StringBuilder sb = new StringBuilder();
            for (String name : locked) {
                sb.append(name).append("\n");
            }
            rootWrite(getLockedFile(), sb.toString());
        }

        // --- Screen on/off via sysfs backlight ---

        private static final String BL_PATH = "/sys/class/backlight/rk28_bl/brightness";
        private static final String FRAME_DATA = "/data/data/com.termux/files/home/frame-data/";
        private int savedBrightness = -1;

        private String shellRead(String cmd) {
            try {
                Process p = Runtime.getRuntime().exec(new String[]{"su", "-c", cmd});
                BufferedReader br = new BufferedReader(new InputStreamReader(p.getInputStream()));
                String line = br.readLine();
                br.close();
                p.waitFor();
                return line != null ? line.trim() : "";
            } catch (Exception e) { return ""; }
        }

        private void shellWrite(String cmd) {
            try {
                Runtime.getRuntime().exec(new String[]{"su", "-c", cmd});
            } catch (Exception ignored) {}
        }

        @JavascriptInterface
        public void screenOff() {
            String cur = shellRead("cat " + BL_PATH);
            int val = 204;
            try { val = Integer.parseInt(cur); } catch (Exception e) {}
            if (val > 0) {
                savedBrightness = val;
                rootWrite(FRAME_DATA + "saved_brightness", String.valueOf(val));
            }
            shellWrite("echo 0 > " + BL_PATH);
        }

        @JavascriptInterface
        public void screenOn() {
            int val = savedBrightness;
            if (val <= 0) {
                try {
                    val = Integer.parseInt(rootRead(FRAME_DATA + "saved_brightness").trim());
                } catch (Exception e) {}
            }
            if (val <= 0) val = 204;
            shellWrite("echo " + val + " > " + BL_PATH);
        }

        @JavascriptInterface
        public boolean isScreenOff() {
            String cur = shellRead("cat " + BL_PATH);
            return "0".equals(cur);
        }

        @JavascriptInterface
        public String getSchedule() {
            return readFileContents(FRAME_DATA + "schedule.json");
        }

        @JavascriptInterface
        public void setSchedule(String json) {
            writeFileContents(FRAME_DATA + "schedule.json", json);
        }

        // Slide interval and fade were localStorage-only. WebView buffers that in
        // memory and flushes lazily, so on a power cut (this frame's normal way of
        // going down) a just-changed value was lost. Mirroring them to disk here
        // makes them survive.
        @JavascriptInterface
        public String getSlideInterval() {
            return rootRead(FRAME_DATA + "slide_interval").trim();
        }

        @JavascriptInterface
        public void setSlideInterval(String seconds) {
            rootWrite(FRAME_DATA + "slide_interval", seconds);
        }

        @JavascriptInterface
        public String getFadeDuration() {
            return rootRead(FRAME_DATA + "fade_duration").trim();
        }

        @JavascriptInterface
        public void setFadeDuration(String ms) {
            rootWrite(FRAME_DATA + "fade_duration", ms);
        }

        @JavascriptInterface
        public String getPlayOrder() {
            return rootRead(FRAME_DATA + "play_order").trim();
        }

        @JavascriptInterface
        public void setPlayOrder(String order) {
            rootWrite(FRAME_DATA + "play_order",
                "sequential".equals(order) ? "sequential" : "shuffle");
        }

        @JavascriptInterface
        public String getSleepTimer() {
            return readFileContents(FRAME_DATA + "sleep_timer.json");
        }

        @JavascriptInterface
        public void setSleepTimer(String json) {
            writeFileContents(FRAME_DATA + "sleep_timer.json", json);
        }

        private String readFileContents(String path) {
            return rootRead(path);
        }

        private void writeFileContents(String path, String content) {
            rootWrite(path, content);
        }

        /**
         * Read a file as root, returning "" if it doesn't exist or can't be read.
         *
         * This MUST go through su. Everything this bridge persists lives under
         * /data/data/com.termux/files/home, which is mode 700 owned by the Termux
         * uid (u0_a32) — and this app runs as a different uid (u0_a34). Plain
         * java.io could not even traverse into that directory, so every read
         * returned empty and every write was silently swallowed by
         * `catch (IOException ignored)`. That is why favoriting a photo appeared
         * to do nothing: locked.txt was never created.
         */
        private String rootRead(String path) {
            try {
                Process p = Runtime.getRuntime().exec(new String[]{
                    "su", "-c", "cat '" + path + "' 2>/dev/null"
                });
                BufferedReader br = new BufferedReader(
                    new InputStreamReader(p.getInputStream()));
                StringBuilder sb = new StringBuilder();
                String line;
                while ((line = br.readLine()) != null) {
                    sb.append(line).append("\n");
                }
                br.close();
                p.waitFor();
                return sb.toString();
            } catch (Exception e) { return ""; }
        }

        /**
         * Write a file as root. Content goes over the process's stdin rather than
         * being interpolated into the command, so filenames with quotes or spaces
         * can't break the shell. Chmod 644 afterwards so the sync scripts can read
         * it back whether they run as root or as the Termux user.
         */
        private void rootWrite(String path, String content) {
            try {
                // sync(1) flushes the write to disk. This frame has no battery and
                // gets killed by yanking the cord, so without it a setting written
                // seconds earlier can still be sitting in the page cache and is lost
                // on the next power cut.
                Process p = Runtime.getRuntime().exec(new String[]{
                    "su", "-c",
                    "cat > '" + path + "' && chmod 644 '" + path + "' && sync"
                });
                OutputStream os = p.getOutputStream();
                os.write(content.getBytes("UTF-8"));
                os.flush();
                os.close();
                p.waitFor();
            } catch (Exception ignored) {}
        }
    }

    private String countdownHtml(int seconds, String message) {
        return "<html><body style='background:#000;color:#fff;font-family:sans-serif;"
            + "display:flex;flex-direction:column;align-items:center;"
            + "justify-content:center;height:100vh;margin:0'>"
            + "<div style='text-align:center;position:relative;width:120px;height:120px'>"
            + "<svg width='120' height='120' style='transform:rotate(-90deg)'>"
            + "<circle cx='60' cy='60' r='54' fill='none' stroke='#222' stroke-width='6'/>"
            + "<circle id='ring' cx='60' cy='60' r='54' fill='none' stroke='#fff'"
            + " stroke-width='6' stroke-linecap='round'"
            + " stroke-dasharray='339.292' stroke-dashoffset='0'/>"
            + "</svg>"
            + "<div style='position:absolute;top:0;left:0;width:120px;height:120px;"
            + "display:flex;align-items:center;justify-content:center;"
            + "font-size:36px;font-weight:300' id='n'>" + seconds + "</div>"
            + "</div>"
            + "<div style='color:#666;font-size:36px;font-weight:300;"
            + "margin-top:24px'>" + message + "</div>"
            + "<script>var t=" + seconds + ",n=t,r=document.getElementById('ring'),"
            + "e=document.getElementById('n'),d=339.292;"
            + "setInterval(function(){n-=0.05;if(n<0)n=0;"
            + "e.textContent=Math.ceil(n);"
            + "r.setAttribute('stroke-dashoffset',d*(1-n/t));},50);</script>"
            + "</body></html>";
    }

    private void showCountdown(final int seconds) {
        webView.loadDataWithBaseURL(null,
            countdownHtml(seconds, "Loading slideshow\u2026"),
            "text/html", "utf-8", null);
        handler.postDelayed(new Runnable() {
            @Override
            public void run() {
                initialWaitDone = true;
                Log.i(TAG, "Initial wait done, loading page");
                webView.loadUrl(PAGE_URL);
            }
        }, seconds * 1000);
    }

    /**
     * Starts Termux services invisibly during the countdown.
     * On a normal power cycle, Termux:Boot receives the system's
     * BOOT_COMPLETED automatically. This method is a safety net for
     * when Termux is in Android's stopped state (after force-stop).
     */
    private void startTermux() {
        if (termuxStarted) return;
        termuxStarted = true;
        Log.i(TAG, "Starting Termux boot sequence");
        triggerTermuxBoot(2000);
    }

    /**
     * Invisible Termux boot — two-pronged approach, all via root, no UI:
     *
     * 1. Directly start busybox httpd as root to serve the slideshow.
     *    This is instant and doesn't depend on Termux being un-stopped.
     *    When boot.sh eventually runs, it kills this root httpd and
     *    starts its own — seamless handoff.
     *
     * 2. Send BOOT_COMPLETED as root to trigger the full boot.sh
     *    (sshd, sync, tailscale). This may or may not work depending
     *    on whether Termux:Boot is in stopped state, but the httpd
     *    from step 1 guarantees the slideshow loads regardless.
     */
    private void triggerTermuxBoot(int delayMs) {
        // Step 1: Start httpd directly as root — guaranteed to work
        handler.postDelayed(new Runnable() {
            @Override
            public void run() {
                try {
                    String slideshow = "/data/data/com.termux/files/home/frame-data/slideshow";
                    String busybox = "/data/data/com.termux/files/usr/bin/busybox";
                    Runtime.getRuntime().exec(new String[]{
                        "su", "-c",
                        "cd " + slideshow + " && "
                        + busybox + " httpd -f -p 8080 &"
                    });
                    Log.i(TAG, "Root httpd started");
                } catch (Exception e) {
                    Log.w(TAG, "Root httpd failed: " + e.getMessage());
                }
            }
        }, delayMs);

        // Step 2: Run boot.sh directly as root — this is what actually brings up
        // sshd, tailscaled and the sync loop. Previously we only broadcast
        // BOOT_COMPLETED to Termux:Boot, which frequently never fires because
        // Android leaves the app in "stopped" state after a cold boot. When that
        // happened the slideshow still worked (step 1) but the frame was
        // unreachable — no ssh, no Tailscale, and no photo sync at all.
        //
        // The env below is mandatory, not belt-and-braces: `su` strips it, and
        // without LD_LIBRARY_PATH the Termux bash won't even link
        // ("CANNOT LINK EXECUTABLE: library libandroid-support.so not found").
        // setsid detaches it so it outlives the short-lived su shell.
        handler.postDelayed(new Runnable() {
            @Override
            public void run() {
                try {
                    Runtime.getRuntime().exec(new String[]{"su", "-c", ROOT_BOOT_CMD});
                    Log.i(TAG, "Root boot.sh launched");
                } catch (Exception e) {
                    Log.w(TAG, "Root boot.sh failed: " + e.getMessage());
                }
            }
        }, delayMs + 3000);

        // Step 3: Also poke Termux:Boot. Harmless if step 2 already succeeded
        // (boot.sh kills stale services before restarting them), and covers the
        // case where Termux:Boot is healthy and would run boot.sh as the Termux
        // user — which is the better outcome, since then sshd can authenticate
        // as a normal user instead of root.
        handler.postDelayed(new Runnable() {
            @Override
            public void run() {
                try {
                    Runtime.getRuntime().exec(new String[]{
                        "su", "-c",
                        "am broadcast -a android.intent.action.BOOT_COMPLETED -p com.termux.boot"
                    });
                    Log.i(TAG, "Root BOOT_COMPLETED broadcast sent");
                } catch (Exception e) {
                    Log.w(TAG, "Root broadcast failed: " + e.getMessage());
                }
            }
        }, delayMs + 8000);
    }

    /**
     * Last-resort fallback: briefly launch TermuxActivity to trigger
     * ~/.profile → boot.sh. The bouncingTermux flag makes onStop()
     * immediately bring kiosk back.
     */
    private void bounceTermux(int delayMs) {
        handler.postDelayed(new Runnable() {
            @Override
            public void run() {
                Log.i(TAG, "Bouncing TermuxActivity (last resort)");
                bouncingTermux = true;
                Intent termux = new Intent();
                termux.setClassName("com.termux", "com.termux.app.TermuxActivity");
                termux.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK
                    | Intent.FLAG_ACTIVITY_NO_ANIMATION);
                try {
                    startActivity(termux);
                } catch (Exception e) {
                    Log.e(TAG, "TermuxActivity failed: " + e.getMessage());
                    bouncingTermux = false;
                }
            }
        }, delayMs);
    }

    private void bringToFront() {
        ActivityManager am = (ActivityManager) getSystemService(Context.ACTIVITY_SERVICE);
        if (am != null) {
            List<ActivityManager.AppTask> tasks = am.getAppTasks();
            if (tasks != null && !tasks.isEmpty()) {
                tasks.get(0).moveToFront();
            }
        }
    }

    @Override
    public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        if (hasFocus) {
            hideSystemUI();
        }
    }

    private void hideSystemUI() {
        getWindow().getDecorView().setSystemUiVisibility(
            View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
            | View.SYSTEM_UI_FLAG_FULLSCREEN
            | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
            | View.SYSTEM_UI_FLAG_LAYOUT_STABLE
            | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
            | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
        );
    }

    @Override
    public void onBackPressed() {
    }
}
