package com.jingling.jingling

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat

/**
 * M7 闹钟到点:发一条提醒通知(有声音),带「稍后 10 分钟」「完成」。
 *
 * 不在这里联网:ack(排好了/响过了/取消了)由 Dart 侧在 App 下次前台时补做,
 * 原生只负责"到点一定响"。
 */
class ReminderReceiver : BroadcastReceiver() {
    companion object {
        const val CHANNEL_ID = "jingling_reminder"
        const val NOTIFICATION_ID = 4201

        fun ensureChannel(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val manager = context.getSystemService(NotificationManager::class.java) ?: return
            if (manager.getNotificationChannel(CHANNEL_ID) == null) {
                manager.createNotificationChannel(
                    NotificationChannel(CHANNEL_ID, "提醒", NotificationManager.IMPORTANCE_HIGH).apply {
                        description = "到点提醒(由「提醒我…」创建)"
                    },
                )
            }
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.getStringExtra(ReminderScheduler.EXTRA_ID) ?: return
        val text = intent.getStringExtra(ReminderScheduler.EXTRA_TEXT) ?: "提醒"
        val fireAtMs = intent.getLongExtra(ReminderScheduler.EXTRA_FIRE_AT, 0L)

        when (intent.action) {
            ReminderScheduler.ACTION_SNOOZE -> {
                ReminderScheduler.snooze(context, id, text)
                NotificationManagerCompat.from(context).cancel(NOTIFICATION_ID)
                return
            }
            ReminderScheduler.ACTION_DONE -> {
                ReminderScheduler.cancel(context, id)
                NotificationManagerCompat.from(context).cancel(NOTIFICATION_ID)
                return
            }
        }

        // 到点:发通知
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            NotificationManagerCompat.from(context).areNotificationsEnabled().not()
        ) {
            return
        }
        ensureChannel(context)

        val open = PendingIntent.getActivity(
            context,
            0,
            Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val snooze = PendingIntent.getBroadcast(
            context,
            id.hashCode() + 1,
            Intent(context, ReminderReceiver::class.java).apply {
                action = ReminderScheduler.ACTION_SNOOZE
                putExtra(ReminderScheduler.EXTRA_ID, id)
                putExtra(ReminderScheduler.EXTRA_TEXT, text)
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val done = PendingIntent.getBroadcast(
            context,
            id.hashCode() + 2,
            Intent(context, ReminderReceiver::class.java).apply {
                action = ReminderScheduler.ACTION_DONE
                putExtra(ReminderScheduler.EXTRA_ID, id)
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
            .setContentTitle("鲸灵提醒")
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_REMINDER)
            .setAutoCancel(true)
            .setWhen(fireAtMs)
            .setContentIntent(open)
            .addAction(0, "稍后 10 分钟", snooze)
            .addAction(0, "完成", done)
            .build()

        runCatching {
            NotificationManagerCompat.from(context).notify(NOTIFICATION_ID, notification)
        }
        // 响过就从本地副本里摘掉(服务端靠 ack 对齐)
        ReminderScheduler.cancel(context, id)
    }
}
