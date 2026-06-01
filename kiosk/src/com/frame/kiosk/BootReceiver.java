package com.frame.kiosk;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

public class BootReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        // Nothing here — Termux launch is handled by KioskActivity.onResume()
        // This receiver just keeps us registered for BOOT_COMPLETED
    }
}
