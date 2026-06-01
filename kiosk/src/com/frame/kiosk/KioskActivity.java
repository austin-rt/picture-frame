package com.frame.kiosk;

import android.app.Activity;
import android.app.ActivityManager;
import android.content.Context;
import android.content.Intent;
import android.os.Bundle;
import android.os.Handler;
import android.view.MotionEvent;
import android.view.View;
import android.view.WindowManager;
import android.webkit.WebChromeClient;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.webkit.WebSettings;
import java.util.List;

public class KioskActivity extends Activity {

    private WebView webView;
    private boolean termuxStarted = false;
    private boolean pageLoaded = false;

    private float touchStartX, touchStartY;
    private long touchStartTime;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        hideSystemUI();

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
        });

        webView.setWebChromeClient(new WebChromeClient());
        webView.clearCache(true);
        webView.loadUrl("http://localhost:8080");
        startTermuxDelayed();
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
                if (dt < 1000 && Math.abs(dx) > 80 && Math.abs(dx) > Math.abs(dy)) {
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
