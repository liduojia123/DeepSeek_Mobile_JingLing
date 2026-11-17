package com.jingling.jingling

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * 开机后重建闹钟。Android 重启会清掉所有 AlarmManager 闹钟,
 * 靠本地副本(ReminderScheduler 的 SharedPreferences)把它们排回去。
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED && intent.action != Intent.ACTION_MY_PACKAGE_REPLACED) {
            return
        }
        runCatching { ReminderScheduler.rescheduleAll(context) }
    }
}
