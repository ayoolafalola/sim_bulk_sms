package app.sim_bulk_sms

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import android.provider.ContactsContract
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Read-only access to the phone's contacts: display name + phone number only.
 * One entry per phone number. Nothing is written to the system contacts.
 */
class ContactsBridge(private val activity: Activity) : MethodChannel.MethodCallHandler {
    private val main = Handler(Looper.getMainLooper())
    private var pendingPermissionResult: MethodChannel.Result? = null

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "hasPermission" -> result.success(granted())
            "requestPermission" -> requestPermission(result)
            "getPhoneContacts" -> load(result)
            else -> result.notImplemented()
        }
    }

    private fun granted() = ContextCompat.checkSelfPermission(activity, Manifest.permission.READ_CONTACTS) ==
        PackageManager.PERMISSION_GRANTED

    private fun requestPermission(result: MethodChannel.Result) {
        if (granted()) { result.success(true); return }
        pendingPermissionResult = result
        PermissionMemory.markAsked(activity, Manifest.permission.READ_CONTACTS)
        ActivityCompat.requestPermissions(activity, arrayOf(Manifest.permission.READ_CONTACTS), REQUEST_CODE)
    }

    /** Call from MainActivity.onRequestPermissionsResult. */
    fun onPermissionsResult(requestCode: Int) {
        if (requestCode != REQUEST_CODE) return
        pendingPermissionResult?.success(granted()); pendingPermissionResult = null
    }

    private fun load(result: MethodChannel.Result) {
        if (!granted()) { result.error("permission_denied", "READ_CONTACTS not granted", null); return }
        // Large address books can take a moment: query off the main thread.
        Thread {
            try {
                val out = ArrayList<Map<String, String>>()
                val cols = arrayOf(
                    ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME,
                    ContactsContract.CommonDataKinds.Phone.NUMBER)
                activity.contentResolver.query(
                    ContactsContract.CommonDataKinds.Phone.CONTENT_URI, cols, null, null,
                    "${ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME} COLLATE NOCASE ASC"
                )?.use { c ->
                    val iName = c.getColumnIndexOrThrow(cols[0])
                    val iNum = c.getColumnIndexOrThrow(cols[1])
                    while (c.moveToNext()) {
                        val num = c.getString(iNum)?.trim().orEmpty()
                        if (num.isEmpty()) continue
                        out.add(mapOf("name" to (c.getString(iName)?.trim().orEmpty()), "phone" to num))
                    }
                }
                main.post { result.success(out) }
            } catch (e: Exception) {
                main.post { result.error("read_failed", e.javaClass.simpleName, null) }
            }
        }.start()
    }

    companion object { private const val REQUEST_CODE = 7422 }
}
