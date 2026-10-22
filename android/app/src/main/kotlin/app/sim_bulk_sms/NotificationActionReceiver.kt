package app.sim_bulk_sms

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.core.app.RemoteInput

/** "Reply" and "Mark as read" on an incoming-text notification; works with the app closed. */
class NotificationActionReceiver : BroadcastReceiver() {
    companion object {
        const val ACTION_REPLY = "app.sim_bulk_sms.NOTIFICATION_REPLY"
        const val ACTION_MARK_READ = "app.sim_bulk_sms.NOTIFICATION_MARK_READ"
    }

    override fun onReceive(ctx: Context, intent: Intent) {
        val thread = intent.getLongExtra(Notifications.EXTRA_THREAD, -1L)
        val address = intent.getStringExtra("address") ?: return
        val subId = intent.getIntExtra("subId", -1)
        val pending = goAsync()
        Thread {
            try {
                when (intent.action) {
                    ACTION_REPLY -> {
                        val text = RemoteInput.getResultsFromIntent(intent)?.getCharSequence(Notifications.KEY_REPLY)?.toString()
                        if (!text.isNullOrBlank() && MessageStore.isDefault(ctx)) {
                            OutgoingSms.send(ctx, address, text, if (subId >= 0) subId else null)
                        }
                        if (thread > 0) MessageStore.markRead(ctx, thread)
                    }
                    ACTION_MARK_READ -> if (thread > 0) MessageStore.markRead(ctx, thread)
                }
                if (thread > 0) Notifications.cancel(ctx, thread)
                MessagesEvents.changed()
            } finally {
                pending.finish()
            }
        }.start()
    }
}
