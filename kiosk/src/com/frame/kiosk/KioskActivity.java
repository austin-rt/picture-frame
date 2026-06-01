package com.frame.kiosk;

import android.app.Activity;
import android.app.ActivityManager;
import android.content.Context;
import android.content.Intent;
import android.os.Bundle;
import android.os.Handler;
import android.util.DisplayMetrics;
import android.view.MotionEvent;
import android.view.View;
import android.view.WindowManager;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.webkit.WebSettings;
import java.util.List;

public class KioskActivity extends Activity {

    private static final String PAGE_URL = "http://localhost:8080";
    private static final int INITIAL_WAIT_MS = 15000;
    private static final int RETRY_DELAY_MS = 5000;

    private WebView webView;
    private Handler handler;
    private boolean termuxStarted = false;
    private boolean pageLoaded = false;
    private boolean initialWaitDone = false;

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
        settings.setCacheMode(WebSettings.LOAD_NO_CACHE);
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
                pageLoaded = true;
            }

            @Override
            public void onReceivedError(WebView view, int errorCode,
                    String description, String failingUrl) {
                super.onReceivedError(view, errorCode, description, failingUrl);
                if (!initialWaitDone) return;
                pageLoaded = false;
                final int secs = RETRY_DELAY_MS / 1000;
                webView.loadDataWithBaseURL(null,
                    countdownHtml(secs, "Retrying\u2026"),
                    "text/html", "utf-8", null);
                handler.postDelayed(new Runnable() {
                    @Override
                    public void run() {
                        webView.loadUrl(PAGE_URL);
                    }
                }, RETRY_DELAY_MS);
            }
        });

        webView.setWebChromeClient(new WebChromeClient());
        webView.clearCache(true);
        webView.setBackgroundColor(0xFF000000);
        startTermuxDelayed();
        showCountdown(INITIAL_WAIT_MS / 1000);
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
                if (dt > 1000) break;

                boolean inLeftEdge = touchStartX < screenWidth / 6;
                boolean inRightEdge = touchStartX > screenWidth * 5 / 6;

                if ((inLeftEdge || inRightEdge)
                        && Math.abs(dy) > 60 && Math.abs(dy) > Math.abs(dx)) {
                    // Vertical swipe in edge zone: brightness
                    if (dy < 0) {
                        adjustBrightness(BRIGHTNESS_STEP);
                    } else {
                        adjustBrightness(-BRIGHTNESS_STEP);
                    }
                } else if (Math.abs(dx) > 80 && Math.abs(dx) > Math.abs(dy)) {
                    // Horizontal swipe: next/prev
                    if (pageLoaded) {
                        String fn = (dx < 0) ? "swipeLeft" : "swipeRight";
                        webView.evaluateJavascript(
                            "window." + fn + " && window." + fn + "()", null);
                    }
                }
                break;
        }
        return true;
    }

    private void adjustBrightness(float delta) {
        currentBrightness = Math.max(BRIGHTNESS_MIN,
            Math.min(BRIGHTNESS_MAX, currentBrightness + delta));
        WindowManager.LayoutParams lp = getWindow().getAttributes();
        lp.screenBrightness = currentBrightness;
        getWindow().setAttributes(lp);
    }

    private String countdownHtml(int seconds, String message) {
        return "<html><body style='background:#000;color:#fff;font-family:sans-serif;"
            + "display:flex;align-items:center;justify-content:center;height:100vh;"
            + "margin:0'>"
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
            + "<div style='color:#666;font-size:16px;margin-top:24px;position:absolute;"
            + "bottom:40px'>" + message + "</div>"
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
                webView.loadUrl(PAGE_URL);
            }
        }, seconds * 1000);
    }

    private void startTermuxDelayed() {
        if (termuxStarted) return;
        termuxStarted = true;

        new Handler().postDelayed(new Runnable() {
            @Override
            public void run() {
                if (!isTermuxRunning()) {
                    Intent termux = new Intent();
                    termux.setClassName("com.termux", "com.termux.app.TermuxActivity");
                    termux.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                    try {
                        startActivity(termux);
                    } catch (Exception ignored) {}

                    new Handler().postDelayed(new Runnable() {
                        @Override
                        public void run() {
                            moveTaskToFront();
                        }
                    }, 3000);
                }
            }
        }, 5000);
    }

    private void moveTaskToFront() {
        ActivityManager am = (ActivityManager) getSystemService(Context.ACTIVITY_SERVICE);
        if (am != null) {
            List<ActivityManager.AppTask> tasks = am.getAppTasks();
            if (tasks != null && !tasks.isEmpty()) {
                tasks.get(0).moveToFront();
            }
        }
    }

    private boolean isTermuxRunning() {
        ActivityManager am = (ActivityManager) getSystemService(Context.ACTIVITY_SERVICE);
        if (am != null) {
            List<ActivityManager.RunningAppProcessInfo> procs = am.getRunningAppProcesses();
            if (procs != null) {
                for (ActivityManager.RunningAppProcessInfo proc : procs) {
                    if ("com.termux".equals(proc.processName)) return true;
                }
            }
        }
        return false;
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
