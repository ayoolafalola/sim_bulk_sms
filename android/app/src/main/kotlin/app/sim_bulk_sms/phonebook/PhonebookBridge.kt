package app.sim_bulk_sms.phonebook

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * `app.sim_bulk_sms/phonebook`: Messages++ actions in the phone's Contacts
 * app (opt-in, needs WRITE_CONTACTS) and Direct Share people.
 */
class PhonebookBridge(private val activity: Activity) : MethodChannel.MethodCallHandler {
    private val worker = Executors.newSingleThreadExecutor()
    private var pendingPermission: MethodChannel.Result? = null

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "canWrite" -> result.success(canWrite())
            "requestWrite" -> requestWrite(result)
            "synchronize" -> {
                if (!canWrite()) { result.error("permission_denied", "WRITE_CONTACTS not granted", null); return }
                val cards = PhonebookIntegration.parseCards(call.argument<List<Any?>>("cards"))
                // Contacts writes are slow: never on the main thread.
                worker.execute {
                    val out = runCatching { PhonebookIntegration.synchronize(activity.applicationContext, cards) }
                    activity.runOnUiThread {
                        out.fold(
                            { result.success(mapOf("written" to it.written, "removed" to it.removed)) },
                            { result.error("failed", it.message, null) },
                        )
                    }
                }
            }
            "removeAll" -> worker.execute {
                val removed = runCatching { PhonebookIntegration.removeAll(activity.applicationContext) }.getOrDefault(0)
                activity.runOnUiThread { result.success(removed) }
            }
            "publishShareTargets" -> {
                val people = (call.argument<List<Any?>>("people") ?: emptyList()).filterIsInstance<Map<*, *>>()
                result.success(DirectShare.publish(activity.applicationContext, people))
            }
            else -> result.notImplemented()
        }
    }

    private fun canWrite() = ContextCompat.checkSelfPermission(activity, Manifest.permission.WRITE_CONTACTS) ==
        PackageManager.PERMISSION_GRANTED && ContextCompat.checkSelfPermission(activity, Manifest.permission.READ_CONTACTS) ==
        PackageManager.PERMISSION_GRANTED

    private fun requestWrite(result: MethodChannel.Result) {
        if (canWrite()) { result.success(true); return }
        pendingPermission = result
        ActivityCompat.requestPermissions(activity,
            arrayOf(Manifest.permission.READ_CONTACTS, Manifest.permission.WRITE_CONTACTS), REQUEST_CODE)
    }

    fun onPermissionsResult(requestCode: Int) {
        if (requestCode != REQUEST_CODE) return
        pendingPermission?.success(canWrite()); pendingPermission = null
    }

    fun dispose() = worker.shutdown()

    companion object { private const val REQUEST_CODE = 7521 }
}
