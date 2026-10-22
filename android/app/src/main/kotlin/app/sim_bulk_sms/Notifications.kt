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
    private const val CH_MESSAGES = "messages"
    const val EXTRA_THREAD = "openThread"
    const val ONGOING_ID = 4201
    private var nextResultId = 5000

    fun ensureChannels(ctx: Context) {
        if (Build.VERSION.SDK_INT < 26) return
        val nm = ctx.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CH_SENDING, "Sending", NotificationManager.IMPORTANCE_LOW)
            .apply { description = "Shown while a campaign is being sent" })
        nm.createNotificationChannel(NotificationChannel(CH_MESSAGES, "Messages", NotificationManager.IMPORTANCE_HIGH)
            .apply { description = "Texts you receive" })
        nm.createNotificationChannel(NotificationChannel(CH_RESULTS, "Campaign results", NotificationManager.IMPORTANCE_DEFAULT)
            .apply { description = "When a send finishes or stops, or a scheduled campaign is due" })
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

    fun result(ctx: Context, title: String, text: String) {
        ensureChannels(ctx) // may be called from a receiver before the service ever ran
        post(ctx, nextResultId++,
        NotificationCompat.Builder(ctx, CH_RESULTS)
            .setSmallIcon(android.R.drawable.stat_notify_chat)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setAutoCancel(true)
            .setContentIntent(openApp(ctx))
            .build())
    }

    /** Stable id per conversation, so new texts update one notification. */
    fun messageId(threadId: Long) = 100_000 + (threadId % 1_000_000).toInt()

    /** An incoming text; tapping opens that conversation. */
    const val KEY_REPLY = "reply"

    /** Notification actions (Reply / Mark as read) for a conversation. */
    private fun action(ctx: Context, action: String, threadId: Long, address: String, subId: Int, mutable: Boolean): PendingIntent =
        PendingIntent.getBroadcast(
            ctx, messageId(threadId) * 4 + (if (action == NotificationActionReceiver.ACTION_REPLY) 1 else 2),
            android.content.Intent(ctx, NotificationActionReceiver::class.java).setAction(action)
                .putExtra(EXTRA_THREAD, threadId).putExtra("address", address).putExtra("subId", subId),
            PendingIntent.FLAG_UPDATE_CURRENT or
                (if (mutable && Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else PendingIntent.FLAG_IMMUTABLE))

    fun incoming(ctx: Context, threadId: Long, sender: String, body: String, address: String = sender, subId: Int = -1) {
        ensureChannels(ctx)
        val open = ctx.packageManager.getLaunchIntentForPackage(ctx.packageName)
            ?.putExtra(EXTRA_THREAD, threadId)
            ?.addFlags(android.content.Intent.FLAG_ACTIVITY_SINGLE_TOP)
        val pi = open?.let {
            PendingIntent.getActivity(ctx, messageId(threadId), it, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        }
        val me = androidx.core.app.Person.Builder().setName("You").build()
        val them = androidx.core.app.Person.Builder().setName(sender).build()
        post(ctx, messageId(threadId), NotificationCompat.Builder(ctx, CH_MESSAGES)
            .setSmallIcon(android.R.drawable.stat_notify_chat)
            .setStyle(NotificationCompat.MessagingStyle(me).addMessage(body, System.currentTimeMillis(), them))
            .setContentTitle(sender)
            .setContentText(body)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true)
            .setContentIntent(pi)
            .addAction(NotificationCompat.Action.Builder(android.R.drawable.ic_menu_send, "Reply",
                action(ctx, NotificationActionReceiver.ACTION_REPLY, threadId, address, subId, mutable = true))
                .addRemoteInput(androidx.core.app.RemoteInput.Builder(KEY_REPLY).setLabel("Reply").build())
                .setSemanticAction(NotificationCompat.Action.SEMANTIC_ACTION_REPLY)
                .setShowsUserInterface(false)
                .build())
            .addAction(NotificationCompat.Action.Builder(android.R.drawable.ic_menu_view, "Mark as read",
                action(ctx, NotificationActionReceiver.ACTION_MARK_READ, threadId, address, subId, mutable = false))
                .setSemanticAction(NotificationCompat.Action.SEMANTIC_ACTION_MARK_AS_READ)
                .setShowsUserInterface(false)
                .build())
            .build())
    }

    fun cancel(ctx: Context, threadId: Long) =
        runCatching { NotificationManagerCompat.from(ctx).cancel(messageId(threadId)) }

    private fun post(ctx: Context, id: Int, n: Notification) {
        // Without notification permission (Android 13+) this is silently skipped.
        try { NotificationManagerCompat.from(ctx).notify(id, n) } catch (e: SecurityException) { /* no notification permission */ }
    }
}
