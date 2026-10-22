package app.sim_bulk_sms

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Telephony

/**
 * Incoming texts (only delivered to the default messaging app). Each sender's
 * parts are joined, stored in the phone's message store and notified.
 * Android already drops texts from numbers on the phone's blocked list.
 */
class SmsDeliverReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_DELIVER_ACTION) return
        val parts = Telephony.Sms.Intents.getMessagesFromIntent(intent) ?: return
        val subId = intent.getIntExtra("subscription", intent.getIntExtra("android.telephony.extra.SUBSCRIPTION_INDEX", -1))
        val pending = goAsync() // provider writes off the main thread
        Thread {
            try {
                parts.groupBy { it.displayOriginatingAddress ?: it.originatingAddress ?: "" }.forEach { (address, msgs) ->
                    val body = msgs.joinToString("") { it.displayMessageBody ?: it.messageBody ?: "" }
                    val sentAt = msgs.first().timestampMillis
                    val thread = MessageStore.insertIncoming(ctx, address, body, sentAt, subId)
                    if (thread != null) {
                        Notifications.incoming(ctx, thread, MessageStore.nameFor(ctx, address) ?: address, body, address, subId)
                    }
                }
                MessagesEvents.changed()
            } finally {
                pending.finish()
            }
        }.start()
    }
}
