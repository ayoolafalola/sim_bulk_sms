package app.sim_bulk_sms

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** App-screen side of background sending: start the service, set the wake-up, and the setup checklist. */
class BackgroundBridge(private val activity: Activity) : MethodChannel.MethodCallHandler {
    private var pendingNotificationResult: MethodChannel.Result? = null

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startSend" -> result.success(SendService.startSend(activity,
                call.argument<Int>("campaignId")!!, call.argument<Int>("subscriptionId")))
            "checkNow" -> result.success(SendService.startCheck(activity))
            "scheduleWake" -> result.success(WakeScheduler.schedule(activity, call.argument<Number>("at")?.toLong()))
            "status" -> result.success(mapOf(
                "notifications" to NotificationManagerCompat.from(activity).areNotificationsEnabled(),
                "exactAlarms" to WakeScheduler.canExact(activity),
                "batteryUnrestricted" to activity.getSystemService(PowerManager::class.java)
                    .isIgnoringBatteryOptimizations(activity.packageName),
                "serviceRunning" to SendService.isRunning,
                "telephony" to activity.packageManager.hasSystemFeature(PackageManager.FEATURE_TELEPHONY),
                "sms" to PermissionMemory.granted(activity, Manifest.permission.SEND_SMS),
                "smsPermanentlyDenied" to PermissionMemory.permanentlyDenied(activity, Manifest.permission.SEND_SMS),
                "contacts" to PermissionMemory.granted(activity, Manifest.permission.READ_CONTACTS),
                "contactsPermanentlyDenied" to PermissionMemory.permanentlyDenied(activity, Manifest.permission.READ_CONTACTS),
                "notificationsPermanentlyDenied" to (Build.VERSION.SDK_INT >= 33 &&
                    PermissionMemory.permanentlyDenied(activity, Manifest.permission.POST_NOTIFICATIONS))))
            "requestNotifications" -> requestNotifications(result)
            "openNotificationSettings" -> open(result, Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                .putExtra(Settings.EXTRA_APP_PACKAGE, activity.packageName))
            "openExactAlarmSettings" -> if (Build.VERSION.SDK_INT >= 31)
                open(result, Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM, pkgUri())) else result.success(true)
            "openBatterySettings" -> open(result, Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, pkgUri()),
                fallback = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
            "openAppSettings" -> open(result, Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, pkgUri()))
            else -> result.notImplemented()
        }
    }

    private fun pkgUri() = Uri.parse("package:${activity.packageName}")

    private fun open(result: MethodChannel.Result, i: Intent, fallback: Intent? = null) {
        try { activity.startActivity(i); result.success(true) } catch (e: Exception) {
            try { if (fallback != null) { activity.startActivity(fallback); result.success(true) } else result.success(false) }
            catch (e2: Exception) { result.success(false) }
        }
    }

    private fun requestNotifications(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < 33 || ContextCompat.checkSelfPermission(activity, Manifest.permission.POST_NOTIFICATIONS)
                == PackageManager.PERMISSION_GRANTED) {
            result.success(NotificationManagerCompat.from(activity).areNotificationsEnabled()); return
        }
        pendingNotificationResult = result
        PermissionMemory.markAsked(activity, Manifest.permission.POST_NOTIFICATIONS)
        ActivityCompat.requestPermissions(activity, arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQUEST_CODE)
    }

    fun onPermissionsResult(requestCode: Int) {
        if (requestCode != REQUEST_CODE) return
        pendingNotificationResult?.success(NotificationManagerCompat.from(activity).areNotificationsEnabled())
        pendingNotificationResult = null
    }

    companion object { private const val REQUEST_CODE = 7423 }
}
