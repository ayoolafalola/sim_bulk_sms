package app.sim_bulk_sms

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log

/**
 * One exact alarm: the earliest upcoming scheduled run or limit resume (computed in Dart).
 * The time is also stored so it can be re-armed after a reboot or app update.
 * Without exact-alarm permission no alarm is set: an inexact alarm could not
 * start the foreground service from the background, so runs fall back to
 * starting while the app is open.
 */
object WakeScheduler {
    const val ACTION_WAKE = "app.sim_bulk_sms.WAKE"
    private const val PREFS = "background_wake"
    private const val KEY_AT = "at"

    fun canExact(ctx: Context): Boolean {
        if (Build.VERSION.SDK_INT < 31) return true
        return ctx.getSystemService(AlarmManager::class.java).canScheduleExactAlarms()
    }

    /** Sets (or clears, when [at] is null) the wake-up. Returns whether it is exact. */
    fun schedule(ctx: Context, at: Long?): Boolean {
        val prefs = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (at == null) prefs.edit().remove(KEY_AT).apply() else prefs.edit().putLong(KEY_AT, at).apply()
        val am = ctx.getSystemService(AlarmManager::class.java)
        val pi = pendingIntent(ctx)
        am.cancel(pi)
        val exact = canExact(ctx)
        if (at != null && exact) {
            try {
                am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi)
            } catch (e: SecurityException) {
                Log.w("SimBulkSms", "Exact alarm refused")
                return false
            }
        }
        return exact
    }

    /** After reboot/update/permission change: run now if the time passed, else set the alarm again. */
    fun rearm(ctx: Context) {
        val at = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getLong(KEY_AT, -1L)
        if (at < 0) return
        if (at <= System.currentTimeMillis()) wakeNow(ctx) else schedule(ctx, at)
    }

    /**
     * The wake-up time has come. Direct build: start the send service, which runs
     * due schedules. Store build (no background sending): remind the user to open
     * the app, where the run is prepared for sending through the Messages app.
     */
    fun wakeNow(ctx: Context) {
        if (BuildConfig.STORE_BUILD) {
            Notifications.result(ctx, "A scheduled campaign is due",
                "Open ${ctx.getString(R.string.app_name)} to send it through your Messages app.")
        } else {
            SendService.startCheck(ctx)
        }
    }

    private fun pendingIntent(ctx: Context): PendingIntent = PendingIntent.getBroadcast(
        ctx, 1, Intent(ctx, WakeReceiver::class.java).setAction(ACTION_WAKE),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
}
