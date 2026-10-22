package app.sim_bulk_sms

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat

/** Ongoing "sending" notification for the foreground service, and result notifications. */
object Notifications {
    private const val CH_SENDING = "sending"
    private const val CH_RESULTS = "results"
    const val ONGOING_ID = 4201
    private var nextResultId = 5000

    fun ensureChannels(ctx: Context) {
        if (Build.VERSION.SDK_INT < 26) return
        val nm = ctx.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CH_SENDING, "Sending", NotificationManager.IMPORTANCE_LOW)
            .apply { description = "Shown while a campaign is being sent" })
        nm.createNotificationChannel(NotificationChannel(CH_RESULTS, "Campaign results", NotificationManager.IMPORTANCE_DEFAULT)
            .apply { description = "When a scheduled or background send finishes or stops" })
    }

    private fun openApp(ctx: Context): PendingIntent? {
        val i = ctx.packageManager.getLaunchIntentForPackage(ctx.packageName) ?: return null
        return PendingIntent.getActivity(ctx, 0, i, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
    }

    fun ongoing(ctx: Context, title: String, text: String?, done: Int, total: Int): Notification =
        NotificationCompat.Builder(ctx, CH_SENDING)
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setContentTitle(title)
            .setContentText(text)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setProgress(total, done, total == 0)
            .setContentIntent(openApp(ctx))
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .build()

    fun updateOngoing(ctx: Context, title: String, text: String?, done: Int, total: Int) =
        post(ctx, ONGOING_ID, ongoing(ctx, title, text, done, total))

    fun result(ctx: Context, title: String, text: String) = post(ctx, nextResultId++,
        NotificationCompat.Builder(ctx, CH_RESULTS)
            .setSmallIcon(android.R.drawable.stat_notify_chat)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setAutoCancel(true)
            .setContentIntent(openApp(ctx))
            .build())

    private fun post(ctx: Context, id: Int, n: Notification) {
        // Without notification permission (Android 13+) this is silently skipped.
        try { NotificationManagerCompat.from(ctx).notify(id, n) } catch (e: SecurityException) { /* no notification permission */ }
    }
}
