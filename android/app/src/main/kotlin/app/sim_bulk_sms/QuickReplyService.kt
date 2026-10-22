package app.sim_bulk_sms

import android.app.Service
import android.content.Intent
import android.net.Uri
import android.os.IBinder

/**
 * "Reply with message" when declining a call (required for the default
 * messaging role). Sends the chosen text and records it in the message store.
 */
class QuickReplyService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == "android.intent.action.RESPOND_VIA_MESSAGE") {
            val address = recipient(intent.data)
            val text = intent.getStringExtra(Intent.EXTRA_TEXT) ?: intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
            if (!address.isNullOrBlank() && !text.isNullOrBlank() && MessageStore.isDefault(this)) {
                OutgoingSms.send(this, address, text)
            }
        }
        stopSelf(startId)
        return START_NOT_STICKY
    }

    companion object {
        /** The number in sms:/smsto:/mms:/mmsto: URIs (first one if several). */
        fun recipient(data: Uri?): String? =
            data?.schemeSpecificPart?.substringBefore('?')?.split(',', ';')?.firstOrNull()?.trim()
    }
}
