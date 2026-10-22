package app.sim_bulk_sms

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Incoming picture/group messages (MMS) — required for the default messaging role.
 * Downloading and showing them comes in Part C; until then the user is told one arrived.
 */
class MmsReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        if (intent.action != "android.provider.Telephony.WAP_PUSH_DELIVER") return
        Notifications.result(ctx, "Picture message received",
            "Picture and group messages can't be shown yet in ${ctx.getString(R.string.app_name)}. " +
                "Switch to your previous messaging app to see it.")
    }
}
