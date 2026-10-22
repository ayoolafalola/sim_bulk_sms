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
 * Read-only access to the phone's contacts: the full sync snapshot ([ContactsSync]),
 * a simple name + number list, and opening a contact in the phone's Contacts app to edit.
 * Nothing is written to the system contacts by this app.
 */
class ContactsBridge(private val activity: Activity) : MethodChannel.MethodCallHandler {
    private val main = Handler(Looper.getMainLooper())
    private var pendingPermissionResult: MethodChannel.Result? = null

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "hasPermission" -> result.success(granted())
            "requestPermission" -> requestPermission(result)
            "getPhoneContacts" -> load(result)
            "syncContacts" -> {
                if (!granted()) { result.error("permission_denied", "READ_CONTACTS not granted", null); return }
                val since = call.argument<Number>("since")?.toLong() ?: 0L
                Thread {
                    try { val snap = ContactsSync.snapshot(activity, since); main.post { result.success(snap) } }
                    catch (e: Exception) { main.post { result.error("read_failed", e.javaClass.simpleName, null) } }
                }.start()
            }
            "editContact" -> {
                // Edits happen in the phone's Contacts app (no write permission needed); sync brings them back.
                val id = call.argument<Number>("contactId")?.toLong() ?: -1L
                val lookup = call.argument<String>("lookupKey")
                val uri = if (lookup != null) ContactsContract.Contacts.getLookupUri(id, lookup)
                          else android.content.ContentUris.withAppendedId(ContactsContract.Contacts.CONTENT_URI, id)
                try {
                    activity.startActivity(android.content.Intent(android.content.Intent.ACTION_EDIT, uri)
                        .putExtra("finishActivityOnSaveCompleted", true))
                    result.success(true)
                } catch (e: Exception) { result.success(false) }
            }
            else -> result.notImplemented()
        }
    }

    /** Tells the app screen the phone's contacts changed (it then syncs the changes). */
    private val observer = object : android.database.ContentObserver(main) {
        override fun onChange(selfChange: Boolean) = MessagesEvents.emit(mapOf("type" to "contacts"))
    }

    init { watch() }

    private fun watch() {
        if (granted()) runCatching {
            activity.contentResolver.registerContentObserver(ContactsContract.Contacts.CONTENT_URI, true, observer)
        }
    }

    fun dispose() = runCatching { activity.contentResolver.unregisterContentObserver(observer) }

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
        dispose(); watch()
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
