package com.jingling.jingling

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

/**
 * 等待期前台服务:只在"手机把任务送进电脑、正在等结果"时运行。
 *
 * 作用有两个:
 *  1. 把进程留在前台,让 Dart 侧的会话 SSE 继续收事件(Android 后台不保活);
 *  2. 通知栏常驻一条「正在等电脑」,用户随时知道还在跑。
 *
 * 这一轮结束就 stopSelf(),不做常驻后台。
 */
class WaitService : Service() {
    companion object {
        const val CHANNEL_WAIT = "jingling_wait"
        const val CHANNEL_RESULT = "jingling_result"
        const val NOTIFICATION_ID_WAIT = 4101
        const val NOTIFICATION_ID_RESULT = 4102
        const val ACTION_START = "com.jingling.jingling.WAIT_START"
        const val ACTION_UPDATE = "com.jingling.jingling.WAIT_UPDATE"
        const val ACTION_STOP = "com.jingling.jingling.WAIT_STOP"
        const val EXTRA_TITLE = "title"
        const val EXTRA_TEXT = "text"

        @Volatile
        var running: Boolean = false
            private set

        /** 两个通知渠道都要在发通知前建好(重复创建是幂等的)。 */
        fun ensureChannels(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val manager = context.getSystemService(NotificationManager::class.java) ?: return
            if (manager.getNotificationChannel(CHANNEL_WAIT) == null) {
                manager.createNotificationChannel(
                    NotificationChannel(CHANNEL_WAIT, "等待电脑结果", NotificationManager.IMPORTANCE_LOW).apply {
                        description = "手机派了任务、正在等电脑上的结果时常驻显示"
                        setShowBadge(false)
                    },
                )
            }
            if (manager.getNotificationChannel(CHANNEL_RESULT) == null) {
                manager.createNotificationChannel(
                    NotificationChannel(CHANNEL_RESULT, "电脑上的结果", NotificationManager.IMPORTANCE_DEFAULT).apply {
                        description = "任务跑完 / 出错 / 电脑断线时提醒"
                    },
                )
            }
        }

        fun start(context: Context, title: String, text: String) {
            val intent = Intent(context, WaitService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_TITLE, title)
                putExtra(EXTRA_TEXT, text)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun update(context: Context, title: String, text: String) {
            if (!running) return
            context.startService(
                Intent(context, WaitService::class.java).apply {
                    action = ACTION_UPDATE
                    putExtra(EXTRA_TITLE, title)
                    putExtra(EXTRA_TEXT, text)
                },
            )
        }

        fun stop(context: Context) {
            // 用 stopService 而不是再发一个 START 意图:App 在后台时 startService 会被限制,
            // stopService 对已在运行的前台服务没有这个限制。
            if (!running) return
            context.stopService(Intent(context, WaitService::class.java))
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        ensureChannels(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopForegroundNow()
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_UPDATE -> {
                if (running) {
                    notifyWaiting(intent.getStringExtra(EXTRA_TITLE) ?: "鲸灵", intent.getStringExtra(EXTRA_TEXT) ?: "正在等电脑上的结果…")
                }
                return START_NOT_STICKY
            }
            else -> {
                val title = intent?.getStringExtra(EXTRA_TITLE) ?: "鲸灵"
                val text = intent?.getStringExtra(EXTRA_TEXT) ?: "正在等电脑上的结果…"
                startForegroundCompat(title, text)
                running = true
                return START_NOT_STICKY
            }
        }
    }

    override fun onDestroy() {
        running = false
        // stopService 路径下系统不一定会自动清掉前台通知,这里主动收掉
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
        } catch (_: Exception) {
            // 服务已不在前台时忽略
        }
        super.onDestroy()
    }

    private fun startForegroundCompat(title: String, text: String) {
        val notification = buildNotification(title, text)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID_WAIT, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(NOTIFICATION_ID_WAIT, notification)
        }
    }

    private fun notifyWaiting(title: String, text: String) {
        val manager = getSystemService(NotificationManager::class.java) ?: return
        manager.notify(NOTIFICATION_ID_WAIT, buildNotification(title, text))
    }

    private fun stopForegroundNow() {
        running = false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }

    private fun buildNotification(title: String, text: String): Notification {
        val openIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val openPending = PendingIntent.getActivity(
            this,
            0,
            openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val stopPending = PendingIntent.getService(
            this,
            1,
            Intent(this, WaitService::class.java).apply { action = ACTION_STOP },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Builder(this, CHANNEL_WAIT)
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setContentTitle(title)
            .setContentText(text)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setContentIntent(openPending)
            .addAction(0, "结束等待", stopPending)
            .build()
    }
}
