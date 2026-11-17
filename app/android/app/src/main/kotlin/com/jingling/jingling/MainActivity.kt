package com.jingling.jingling

import android.Manifest
import android.app.NotificationManager
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * 原生能力入口:
 *  - `jingling/installer`:M6+ OTA 把 APK 交给系统安装器;
 *  - `jingling/wait`:M3.6 等待期前台服务 + 结果通知;
 *  - `jingling/reminders`:M7 提醒(精确闹钟)。
 */
class MainActivity : FlutterActivity() {
    private val installerChannel = "jingling/installer"
    private val waitChannel = "jingling/wait"
    private val remindersChannel = "jingling/reminders"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, installerChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "canInstall" -> result.success(canRequestInstall())
                    "installApk" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrEmpty()) {
                            result.error("bad_args", "缺少 apk 路径", null)
                            return@setMethodCallHandler
                        }
                        try {
                            installApk(File(path))
                            result.success(true)
                        } catch (error: Exception) {
                            result.error("install_failed", error.message, null)
                        }
                    }
                    "openInstallPermission" -> {
                        openInstallPermission()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, waitChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        val title = call.argument<String>("title") ?: "鲸灵"
                        val text = call.argument<String>("text") ?: "正在等电脑上的结果…"
                        if (!canNotify()) {
                            // 没有通知权限:前台服务启动后通知不可见,不如不启动,避免用户困惑
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        WaitService.start(applicationContext, title, text)
                        result.success(true)
                    }
                    "update" -> {
                        val title = call.argument<String>("title") ?: "鲸灵"
                        val text = call.argument<String>("text") ?: "正在等电脑上的结果…"
                        WaitService.update(applicationContext, title, text)
                        result.success(true)
                    }
                    "stop" -> {
                        WaitService.stop(applicationContext)
                        result.success(true)
                    }
                    "notifyResult" -> {
                        val title = call.argument<String>("title") ?: "鲸灵"
                        val text = call.argument<String>("text") ?: ""
                        if (canNotify()) {
                            postResultNotification(title, text)
                        }
                        result.success(true)
                    }
                    "canNotify" -> result.success(canNotify())
                    "requestPermission" -> {
                        result.success(requestNotificationPermission())
                    }
                    "openNotificationSettings" -> {
                        openNotificationSettings()
                        result.success(true)
                    }
                    "isIgnoringBatteryOptimizations" -> {
                        result.success(isIgnoringBatteryOptimizations())
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, remindersChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "canScheduleExact" -> result.success(ReminderScheduler.canScheduleExact(this))
                    "openExactAlarmSettings" -> {
                        openExactAlarmSettings()
                        result.success(true)
                    }
                    "listScheduled" -> {
                        val items = ReminderScheduler.listScheduled(this).map {
                            mapOf("id" to it.id, "text" to it.text, "fireAtMs" to it.fireAtMs)
                        }
                        result.success(items)
                    }
                    "schedule" -> {
                        val id = call.argument<String>("id")
                        val fireAtMs = call.argument<Number>("fireAtMs")?.toLong()
                        if (id.isNullOrEmpty() || fireAtMs == null) {
                            result.error("bad_args", "缺少 id 或 fireAtMs", null)
                            return@setMethodCallHandler
                        }
                        val text = call.argument<String>("text") ?: "提醒"
                        if (!ReminderScheduler.canScheduleExact(this)) {
                            result.error("exact_alarm_denied", "缺少精确闹钟权限", null)
                            return@setMethodCallHandler
                        }
                        val ok = ReminderScheduler.schedule(this, id, text, fireAtMs)
                        result.success(ok)
                    }
                    "cancel" -> {
                        val id = call.argument<String>("id")
                        if (id.isNullOrEmpty()) {
                            result.error("bad_args", "缺少 id", null)
                            return@setMethodCallHandler
                        }
                        ReminderScheduler.cancel(this, id)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun openExactAlarmSettings() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return
        val intent = Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM).apply {
            data = Uri.parse("package:$packageName")
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        runCatching { startActivity(intent) }
    }

    // ---------- 通知权限 ----------

    private fun canNotify(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            return ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) ==
                PackageManager.PERMISSION_GRANTED
        }
        return NotificationManagerCompat.from(this).areNotificationsEnabled()
    }

    /** Android 13+ 需要运行时权限;更早版本只需要渠道未被关闭。 */
    private fun requestNotificationPermission(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && !canNotify()) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQUEST_NOTIFICATIONS)
            return false
        }
        return canNotify()
    }

    private fun postResultNotification(title: String, text: String) {
        WaitService.ensureChannels(this)
        val openIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val pending = android.app.PendingIntent.getActivity(
            this,
            0,
            openIntent,
            android.app.PendingIntent.FLAG_UPDATE_CURRENT or android.app.PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = NotificationCompat.Builder(this, WaitService.CHANNEL_RESULT)
            .setSmallIcon(android.R.drawable.stat_notify_chat)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setContentIntent(pending)
            .build()
        NotificationManagerCompat.from(this).notify(WaitService.NOTIFICATION_ID_RESULT, notification)
    }

    private fun openNotificationSettings() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val intent = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
            putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(intent)
    }

    private fun isIgnoringBatteryOptimizations(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        val power = getSystemService(PowerManager::class.java) ?: return true
        return power.isIgnoringBatteryOptimizations(packageName)
    }

    // ---------- OTA 安装 ----------

    private fun canRequestInstall(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return true
        return packageManager.canRequestPackageInstalls()
    }

    private fun openInstallPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val intent = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES).apply {
            data = Uri.parse("package:$packageName")
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(intent)
    }

    private fun installApk(file: File) {
        if (!file.exists()) throw IllegalStateException("APK 文件不存在:${file.absolutePath}")
        val uri: Uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(intent)
    }

    companion object {
        private const val REQUEST_NOTIFICATIONS = 4101
    }
}
