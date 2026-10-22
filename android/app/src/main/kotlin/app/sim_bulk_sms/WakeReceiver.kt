package app.sim_bulk_sms

import android.app.AlarmManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Scheduled wake-up, plus re-arming after reboot, app update or exact-alarm permission changes. */
class WakeReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        when (intent.action) {
            WakeScheduler.ACTION_WAKE -> SendService.startCheck(ctx)
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            AlarmManager.ACTION_SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED -> WakeScheduler.rearm(ctx)
        }
    }
}
