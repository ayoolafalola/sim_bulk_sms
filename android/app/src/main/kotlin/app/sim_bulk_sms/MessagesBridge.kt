package app.sim_bulk_sms

import android.app.Activity
import android.app.NotificationManager
import android.app.role.RoleManager
import android.content.Intent
import android.database.ContentObserver
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.provider.Telephony
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** App-screen side of the inbox: read conversations, send, mark read, become the default messaging app. */
class MessagesBridge(private val activity: Activity) : MethodChannel.MethodCallHandler {
    private val main = Handler(Looper.getMainLooper())
    private var pendingRole: MethodChannel.Result? = null
    /** What the app was opened for: a notification's thread, or another app's "send SMS to". */
    private var launch: Map<String, Any?>? = null

    private val observer = object : ContentObserver(main) {
        override fun onChange(selfChange: Boolean) = MessagesEvents.changed()
    }

    init {
        try {
            activity.contentResolver.registerContentObserver(Uri.parse("content://mms-sms/"), true, observer)
        } catch (e: Exception) { /* no READ_SMS yet: the inbox refreshes on resume instead */ }
    }

    fun dispose() = runCatching { activity.contentResolver.unregisterContentObserver(observer) }

    private fun <T> background(result: MethodChannel.Result, work: () -> T) {
        Thread {
            try { val v = work(); main.post { result.success(v) } }
            catch (e: SecurityException) { main.post { result.error("not_default", "Not the default messaging app", null) } }
            catch (e: Exception) { main.post { result.error("failed", e.javaClass.simpleName, null) } }
        }.start()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isDefault" -> result.success(MessageStore.isDefault(activity))
            "requestDefault" -> requestDefault(result)
            "openDefaultAppsSettings" -> {
                try { activity.startActivity(Intent(Settings.ACTION_MANAGE_DEFAULT_APPS_SETTINGS)); result.success(true) }
                catch (e: Exception) { result.success(false) }
            }
            "conversations" -> background(result) { MessageStore.conversations(activity) }
            "messages" -> background(result) {
                MessageStore.messages(activity, call.argument<Number>("threadId")!!.toLong(), call.argument<Int>("limit") ?: 200)
            }
            "threadIdFor" -> background(result) { MessageStore.threadIdFor(activity, call.argument<String>("address")!!) }
            "markRead" -> {
                val thread = call.argument<Number>("threadId")!!.toLong()
                activity.getSystemService(NotificationManager::class.java).cancel(Notifications.messageId(thread))
                background(result) { MessageStore.markRead(activity, thread); true }
            }
            "send" -> background(result) {
                MessageStore.isDefault(activity) &&
                    OutgoingSms.send(activity, call.argument<String>("address")!!, call.argument<String>("body")!!,
                        call.argument<Int>("subId"))
            }
            "markAllRead" -> {
                activity.getSystemService(NotificationManager::class.java).cancelAll()
                background(result) { MessageStore.markAllRead(activity); true }
            }
            "deleteMessage" -> background(result) { MessageStore.deleteMessage(activity, call.argument<Number>("id")!!.toLong()) }
            "deleteThread" -> {
                val thread = call.argument<Number>("threadId")!!.toLong()
                Notifications.cancel(activity, thread)
                background(result) { MessageStore.deleteThread(activity, thread) }
            }
            "takeLaunch" -> { result.success(launch); launch = null }
            else -> result.notImplemented()
        }
    }

    private fun requestDefault(result: MethodChannel.Result) {
        if (MessageStore.isDefault(activity)) { result.success(true); return }
        val intent = if (Build.VERSION.SDK_INT >= 29) {
            val rm = activity.getSystemService(RoleManager::class.java)
            if (!rm.isRoleAvailable(RoleManager.ROLE_SMS)) { result.success(false); return }
            rm.createRequestRoleIntent(RoleManager.ROLE_SMS)
        } else {
            Intent(Telephony.Sms.Intents.ACTION_CHANGE_DEFAULT)
                .putExtra(Telephony.Sms.Intents.EXTRA_PACKAGE_NAME, activity.packageName)
        }
        pendingRole = result
        activity.startActivityForResult(intent, REQUEST_ROLE)
    }

    /** Call from MainActivity.onActivityResult. */
    fun onActivityResult(requestCode: Int) {
        if (requestCode != REQUEST_ROLE) return
        val now = MessageStore.isDefault(activity)
        pendingRole?.success(now); pendingRole = null
        if (now) {
            runCatching { activity.contentResolver.registerContentObserver(Uri.parse("content://mms-sms/"), true, observer) }
        }
        MessagesEvents.changed()
    }

    /** Call with the launch intent and every new intent. */
    fun onIntent(intent: Intent?) {
        intent ?: return
        val thread = intent.getLongExtra(Notifications.EXTRA_THREAD, -1L)
        val data = intent.data
        launch = when {
            thread > 0 -> mapOf("threadId" to thread)
            (intent.action == Intent.ACTION_SENDTO || intent.action == Intent.ACTION_SEND || intent.action == Intent.ACTION_VIEW) &&
                data != null && data.scheme in setOf("sms", "smsto", "mms", "mmsto") ->
                mapOf("address" to QuickReplyService.recipient(data),
                    "body" to (intent.getStringExtra("sms_body") ?: intent.getStringExtra(Intent.EXTRA_TEXT)))
            else -> return
        }
        MessagesEvents.emit(mapOf("type" to "launch"))
    }

    companion object { private const val REQUEST_ROLE = 7424 }
}
