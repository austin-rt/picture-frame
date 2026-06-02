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
import java.io.IOException;
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
                if (PAGE_URL.equals(url)) {
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
                            webView.evaluateJavascript(
                                "window." + fn + " && window." + fn + "()", null);
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
            File f = new File("/data/data/com.termux/files/home/frame-data/delete_after_sync");
            if (!f.exists()) return false;
            try {
                BufferedReader br = new BufferedReader(new FileReader(f));
                String val = br.readLine();
                br.close();
                return "true".equals(val != null ? val.trim() : "");
            } catch (IOException e) { return false; }
        }

        @JavascriptInterface
        public void setDeleteAfterSync(boolean enabled) {
            try {
                File f = new File("/data/data/com.termux/files/home/frame-data/delete_after_sync");
                FileWriter fw = new FileWriter(f);
                fw.write(enabled ? "true" : "false");
                fw.close();
            } catch (IOException ignored) {}
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

        private File getLockedFile() {
            return new File("/data/data/com.termux/files/home/frame-data/locked.txt");
        }

        private Set<String> readLockedSet() {
            Set<String> set = new HashSet<String>();
            File f = getLockedFile();
            if (!f.exists()) return set;
            try {
                BufferedReader br = new BufferedReader(new FileReader(f));
                String line;
                while ((line = br.readLine()) != null) {
                    line = line.trim();
                    if (!line.isEmpty()) set.add(line);
                }
                br.close();
            } catch (IOException ignored) {}
            return set;
        }

        private void updateLockedFile(String filename, boolean add) {
            Set<String> locked = readLockedSet();
            if (add) locked.add(filename);
            else locked.remove(filename);
            try {
                FileWriter fw = new FileWriter(getLockedFile());
                for (String name : locked) {
                    fw.write(name + "\n");
                }
                fw.close();
            } catch (IOException ignored) {}
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

        // Step 2: Try full boot.sh via BOOT_COMPLETED (for sshd, sync, etc.)
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
        }, delayMs + 3000);
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
