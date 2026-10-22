package app.sim_bulk_sms

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.telephony.SmsManager
import android.util.Log

/**
 * Personal texts (replies, quick replies, new messages): written to the phone's
 * message store as "sending", then updated by [SmsStatusReceiver] when Android
 * reports sent / failed / delivered, even if the app has been closed meanwhile.
 * Campaign messages go through [SmsBridge], which also records them in the store.
 */
object OutgoingSms {
    const val ACTION_SENT = "app.sim_bulk_sms.PERSONAL_SENT"
    const val ACTION_DELIVERED = "app.sim_bulk_sms.PERSONAL_DELIVERED"

    fun manager(ctx: Context, subId: Int?): SmsManager {
        val base = if (Build.VERSION.SDK_INT >= 31) ctx.getSystemService(SmsManager::class.java)
                   else @Suppress("DEPRECATION") SmsManager.getDefault()
        if (subId == null || subId < 0) return base
        return if (Build.VERSION.SDK_INT >= 31) base.createForSubscriptionId(subId)
               else @Suppress("DEPRECATION") SmsManager.getSmsManagerForSubscriptionId(subId)
    }

    /** Sends [body] to [address]. Returns false if it couldn't be handed to Android. */
    fun send(ctx: Context, address: String, body: String, subId: Int? = null): Boolean {
        val row = MessageStore.insertOutgoing(ctx, address, body, subId)
        return try {
            val mgr = manager(ctx, subId)
            val parts = mgr.divideMessage(body)
            fun pi(action: String, part: Int): PendingIntent = PendingIntent.getBroadcast(
                ctx, 0,
                Intent(ctx, SmsStatusReceiver::class.java).setAction(action)
                    .setData(Uri.parse("smsrow://${row?.lastPathSegment ?: "none"}/$part/${System.nanoTime()}"))
                    .putExtra("row", row?.toString()),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            val sent = ArrayList((parts.indices).map { pi(ACTION_SENT, it) })
            val delivered = ArrayList((parts.indices).map { pi(ACTION_DELIVERED, it) })
            if (parts.size == 1) mgr.sendTextMessage(address, null, body, sent[0], delivered[0])
            else mgr.sendMultipartTextMessage(address, null, parts, sent, delivered)
            true
        } catch (e: Exception) {
            Log.w("SimBulkSms", "Personal send failed: ${e.javaClass.simpleName}")
            row?.let { MessageStore.markFailed(ctx, it, -1) }
            false
        }
    }
}

/** Updates a personal text's row in the message store from Android's send/delivery reports. */
class SmsStatusReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        val row = intent.getStringExtra("row")?.let { Uri.parse(it) } ?: return
        when (intent.action) {
            OutgoingSms.ACTION_SENT ->
                if (resultCode == Activity.RESULT_OK) MessageStore.markSent(ctx, row) else MessageStore.markFailed(ctx, row, resultCode)
            OutgoingSms.ACTION_DELIVERED -> if (resultCode == Activity.RESULT_OK) MessageStore.markDelivered(ctx, row)
        }
        MessagesEvents.changed()
    }
}
