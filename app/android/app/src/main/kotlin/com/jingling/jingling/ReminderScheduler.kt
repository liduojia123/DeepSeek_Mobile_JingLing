package com.jingling.jingling

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import org.json.JSONObject

/**
 * M7 提醒:把服务端下发的提醒排进系统精确闹钟。
 *
 * 为什么用 `setAlarmClock`:它是最强的一档 —— 不受 Doze 限制、状态栏显示闹钟图标,
 * 适合"到点必须响"。requestCode 取 `id.hashCode()`,所以同一个提醒重复排会**覆盖**,
 * 这让启动补排可以无脑重发(幂等)。
 *
 * 已知边界:用户在系统里「强行停止」本应用后,所有闹钟被系统清掉(重启能靠 BootReceiver 恢复)。
 */
object ReminderScheduler {
    private const val PREFS = "jingling_reminders"
    private const val KEY_ALARMS = "alarms"

    const val ACTION_FIRE = "com.jingling.jingling.REMINDER_FIRE"
    const val ACTION_SNOOZE = "com.jingling.jingling.REMINDER_SNOOZE"
    const val ACTION_DONE = "com.jingling.jingling.REMINDER_DONE"
    const val EXTRA_ID = "id"
    const val EXTRA_TEXT = "text"
    const val EXTRA_FIRE_AT = "fire_at_ms"

    const val SNOOZE_MINUTES = 10L

    data class Scheduled(val id: String, val text: String, val fireAtMs: Long)

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** 本地副本:补排/列表以它为准(服务端不知道闹钟有没有被系统清掉)。 */
    fun listScheduled(context: Context, nowMs: Long = System.currentTimeMillis()): List<Scheduled> {
        val raw = prefs(context).getString(KEY_ALARMS, null) ?: return emptyList()
        val json = runCatching { JSONObject(raw) }.getOrNull() ?: return emptyList()
        val out = mutableListOf<Scheduled>()
        for (id in json.keys()) {
            val item = json.optJSONObject(id) ?: continue
            val fireAt = item.optLong("fire_at_ms", 0L)
            if (fireAt <= nowMs) continue
            out += Scheduled(id, item.optString("text"), fireAt)
        }
        return out.sortedBy { it.fireAtMs }
    }

    fun canScheduleExact(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        val manager = context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager ?: return false
        return manager.canScheduleExactAlarms()
    }

    /** 排一个提醒;已存在同 id 的会被覆盖(幂等)。返回 false 表示缺少精确闹钟权限。 */
    fun schedule(context: Context, id: String, text: String, fireAtMs: Long): Boolean {
        if (!canScheduleExact(context)) return false
        val manager = context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager ?: return false

        val fire = PendingIntent.getBroadcast(
            context,
            id.hashCode(),
            Intent(context, ReminderReceiver::class.java).apply {
                action = ACTION_FIRE
                putExtra(EXTRA_ID, id)
                putExtra(EXTRA_TEXT, text)
                putExtra(EXTRA_FIRE_AT, fireAtMs)
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val show = PendingIntent.getActivity(
            context,
            id.hashCode(),
            Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        manager.setAlarmClock(AlarmManager.AlarmClockInfo(fireAtMs, show), fire)
        remember(context, id, text, fireAtMs)
        return true
    }

    fun cancel(context: Context, id: String) {
        val manager = context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager
        val fire = PendingIntent.getBroadcast(
            context,
            id.hashCode(),
            Intent(context, ReminderReceiver::class.java).apply { action = ACTION_FIRE },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        manager?.cancel(fire)
        fire.cancel()
        forget(context, id)
    }

    fun snooze(context: Context, id: String, text: String, minutes: Long = SNOOZE_MINUTES) {
        schedule(context, id, text, System.currentTimeMillis() + minutes * 60_000L)
    }

    /** 开机后按本地副本重建(只重建还没到点的)。 */
    fun rescheduleAll(context: Context) {
        for (item in listScheduled(context)) {
            schedule(context, item.id, item.text, item.fireAtMs)
        }
        // 清掉已过期的副本
        val alive = listScheduled(context).map { it.id }.toSet()
        val raw = prefs(context).getString(KEY_ALARMS, null) ?: return
        val json = runCatching { JSONObject(raw) }.getOrNull() ?: return
        val next = JSONObject()
        for (id in json.keys()) {
            if (id in alive) next.put(id, json.optJSONObject(id))
        }
        prefs(context).edit().putString(KEY_ALARMS, next.toString()).apply()
    }

    private fun remember(context: Context, id: String, text: String, fireAtMs: Long) {
        val raw = prefs(context).getString(KEY_ALARMS, null)
        val json = runCatching { raw?.let { JSONObject(it) } }.getOrNull() ?: JSONObject()
        json.put(
            id,
            JSONObject().apply {
                put("text", text)
                put("fire_at_ms", fireAtMs)
            },
        )
        prefs(context).edit().putString(KEY_ALARMS, json.toString()).apply()
    }

    private fun forget(context: Context, id: String) {
        val raw = prefs(context).getString(KEY_ALARMS, null) ?: return
        val json = runCatching { JSONObject(raw) }.getOrNull() ?: return
        json.remove(id)
        prefs(context).edit().putString(KEY_ALARMS, json.toString()).apply()
    }
}
