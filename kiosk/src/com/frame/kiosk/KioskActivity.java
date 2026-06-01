package com.frame.kiosk;

import android.app.Activity;
import android.app.ActivityManager;
import android.content.Context;
import android.content.Intent;
import android.os.Bundle;
import android.os.Handler;
import android.view.View;
import android.view.WindowManager;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.webkit.WebSettings;
import java.util.List;

public class KioskActivity extends Activity {

    private WebView webView;
    private boolean termuxStarted = false;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        // Keep screen on
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);

        // Hide system UI
        hideSystemUI();

        // Create WebView programmatically (no XML layout needed)
        webView = new WebView(this);
        setContentView(webView);

        // Configure WebView
        WebSettings settings = webView.getSettings();
        settings.setJavaScriptEnabled(true);
        settings.setDomStorageEnabled(true);
        settings.setCacheMode(WebSettings.LOAD_DEFAULT);
        settings.setMediaPlaybackRequiresUserGesture(false);

        // Stay in the WebView for all navigation
        webView.setWebViewClient(new WebViewClient());

        // Load slideshow
        webView.loadUrl("http://localhost:8080");

        // Start Termux in background after a short delay
        startTermuxDelayed();
    }

    private void startTermuxDelayed() {
        if (termuxStarted) return;
        termuxStarted = true;

        new Handler().postDelayed(new Runnable() {
            @Override
            public void run() {
                if (!isTermuxRunning()) {
                    // Launch Termux activity (it will run boot.sh via Termux:Boot)
                    Intent termux = new Intent();
                    termux.setClassName("com.termux", "com.termux.app.TermuxActivity");
                    termux.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                    try {
                        startActivity(termux);
                    } catch (Exception ignored) {}

                    // Bring ourselves back to front after Termux starts
                    new Handler().postDelayed(new Runnable() {
                        @Override
                        public void run() {
                            moveTaskToFront();
                        }
                    }, 3000);
                }
            }
        }, 5000); // Wait 5s after boot for system to settle
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
        // Disable back button in kiosk mode
    }
}
