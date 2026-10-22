package app.sim_bulk_sms

import android.Manifest
import android.app.Activity
import android.app.PendingIntent
import android.content.*
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.telephony.SmsManager
import android.telephony.SubscriptionManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ConcurrentHashMap

/**
 * Direct SIM sending via SmsManager. Never reports success before a platform callback.
 * Phone numbers and bodies are never logged.
 *
 * Used by the app screen (with [activity], so it can ask for permissions) and by
 * [SendService]'s background engine (no activity: permission requests are refused).
 * Each instance only reports callbacks for the attempts it sent.
 */
class SmsBridge(context: Context, private val activity: Activity? = null) :
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private val ctx: Context = context.applicationContext
    private val main = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null
    private var pendingPermissionResult: MethodChannel.Result? = null

    private data class Op(val recipientId: Int, val parts: Int, var sentOk: Int = 0,
                          var delivered: Int = 0, var failed: Boolean = false, var finished: Boolean = false)
    private val ops = ConcurrentHashMap<Int, Op>() // attemptId -> aggregate state

    private val ACTION_SENT = "app.sim_bulk_sms.SMS_SENT"
    private val ACTION_DELIVERED = "app.sim_bulk_sms.SMS_DELIVERED"

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context, i: Intent) {
            val attemptId = i.getIntExtra("attemptId", -1)
            val op = ops[attemptId] ?: return // unknown/finished attempt (e.g. after process death): ignore
            synchronized(op) {
                if (i.action == ACTION_SENT) {
                    if (resultCode == Activity.RESULT_OK) {
                        op.sentOk++
                        if (op.sentOk == op.parts && !op.failed && !op.finished) {
                            emit("sendSucceeded", op.recipientId, attemptId)
                        }
                    } else if (!op.failed) {
                        op.failed = true; op.finished = true
                        emit("sendFailed", op.recipientId, attemptId, mapError(resultCode), "SMS send failed")
                    }
                } else if (i.action == ACTION_DELIVERED && resultCode == Activity.RESULT_OK) {
                    op.delivered++
                    if (op.delivered == op.parts) {
                        emit("deliveryReported", op.recipientId, attemptId); op.finished = true; ops.remove(attemptId)
                    }
                }
            }
        }
    }

    init {
        // The PendingIntents carry a smsattempt:// data URI (to keep them unique), and an
        // IntentFilter without a matching data scheme rejects intents that have data.
        val f = IntentFilter().apply {
            addAction(ACTION_SENT); addAction(ACTION_DELIVERED); addDataScheme("smsattempt")
        }
        ContextCompat.registerReceiver(ctx, receiver, f, ContextCompat.RECEIVER_NOT_EXPORTED)
    }

    fun dispose() { runCatching { ctx.unregisterReceiver(receiver) } }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getCapabilities" -> result.success(mapOf(
                "hasTelephony" to ctx.packageManager.hasSystemFeature(PackageManager.FEATURE_TELEPHONY),
                "sendSmsGranted" to has(Manifest.permission.SEND_SMS),
                "activeSubscriptions" to subscriptions().size))
            "requestPermissions" -> requestPermissions(result)
            "getSubscriptions" -> result.success(subscriptions())
            "openComposer" -> openComposer(call, result)
            "sendTextMessage", "sendMultipartTextMessage" -> send(call, result)
            else -> result.notImplemented()
        }
    }

    private fun has(p: String) = ContextCompat.checkSelfPermission(ctx, p) == PackageManager.PERMISSION_GRANTED

    private fun requestPermissions(result: MethodChannel.Result) {
        val needed = listOf(Manifest.permission.SEND_SMS, Manifest.permission.READ_PHONE_STATE).filter { !has(it) }
        if (needed.isEmpty()) { result.success(true); return }
        val a = activity ?: run { result.success(false); return } // background: can't prompt
        pendingPermissionResult = result
        PermissionMemory.markAsked(a, *needed.toTypedArray())
        ActivityCompat.requestPermissions(a, needed.toTypedArray(), 7421)
    }

    /** Call from MainActivity.onRequestPermissionsResult. */
    fun onPermissionsResult(requestCode: Int) {
        if (requestCode != 7421) return
        pendingPermissionResult?.success(has(Manifest.permission.SEND_SMS)); pendingPermissionResult = null
        emit("permissionChanged", 0, 0)
    }

    private fun subscriptions(): List<Map<String, Any?>> {
        if (!has(Manifest.permission.READ_PHONE_STATE)) return emptyList()
        return try {
            val sm = ctx.getSystemService(SubscriptionManager::class.java)
            sm.activeSubscriptionInfoList.orEmpty().map {
                mapOf("id" to it.subscriptionId, "slot" to it.simSlotIndex,
                      "label" to it.displayName?.toString(), "carrier" to it.carrierName?.toString())
            } // phone number deliberately not read
        } catch (e: SecurityException) { emptyList() }
    }

    private fun manager(subId: Int?): SmsManager {
        val base = if (Build.VERSION.SDK_INT >= 31) ctx.getSystemService(SmsManager::class.java)
                   else @Suppress("DEPRECATION") SmsManager.getDefault()
        if (subId == null) return base
        return if (Build.VERSION.SDK_INT >= 31) base.createForSubscriptionId(subId)
               else @Suppress("DEPRECATION") SmsManager.getSmsManagerForSubscriptionId(subId)
    }

    private fun pi(action: String, attemptId: Int, part: Int): PendingIntent {
        // Unique data URI => PendingIntents never collide (extras are ignored by equality).
        val i = Intent(action).setPackage(ctx.packageName)
            .setData(Uri.parse("smsattempt://$attemptId/$part/${action.substringAfterLast('.')}"))
            .putExtra("attemptId", attemptId)
        return PendingIntent.getBroadcast(ctx, 0, i, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
    }

    private fun send(call: MethodCall, result: MethodChannel.Result) {
        val recipientId = call.argument<Int>("recipientId")!!
        val attemptId = call.argument<Int>("attemptId")!!
        val phone = call.argument<String>("phone")!!
        val body = call.argument<String>("body")!!
        val subId = call.argument<Int>("subscriptionId")
        if (!has(Manifest.permission.SEND_SMS)) { result.error("permission_denied", "SEND_SMS not granted", null); return }
        if (ops.containsKey(attemptId)) { result.error("duplicate_attempt", "Attempt already in flight", null); return }
        if (subId != null && subscriptions().none { it["id"] == subId }) {
            result.error("subscription_unavailable", "Selected SIM is unavailable; reselect a SIM", null); return
        }
        try {
            val mgr = manager(subId)
            val parts = mgr.divideMessage(body)
            ops[attemptId] = Op(recipientId, parts.size)
            val sent = ArrayList<PendingIntent?>(); val deliv = ArrayList<PendingIntent?>()
            for (p in parts.indices) { sent.add(pi(ACTION_SENT, attemptId, p)); deliv.add(pi(ACTION_DELIVERED, attemptId, p)) }
            emit("sendStarted", recipientId, attemptId)
            if (parts.size == 1) mgr.sendTextMessage(phone, null, body, sent[0], deliv[0])
            else mgr.sendMultipartTextMessage(phone, null, parts, sent, deliv)
            result.success(null) // accepted by API only; outcome arrives via callbacks
        } catch (e: SecurityException) {
            ops.remove(attemptId); result.error("permission_denied", "Security exception", null)
        } catch (e: IllegalArgumentException) {
            ops.remove(attemptId); result.error("invalid_argument", "Invalid recipient or message", null)
        } catch (e: Exception) {
            ops.remove(attemptId); result.error("send_exception", e.javaClass.simpleName, null)
        }
    }

    /**
     * Fallback when direct sending isn't allowed: opens the default Messages app
     * with the number and text filled in. The user taps Send there; Android does
     * not report whether they did, so the app asks afterwards. Returns false if
     * no Messages app can handle it. Needs no SMS permission.
     */
    private fun openComposer(call: MethodCall, result: MethodChannel.Result) {
        val a = activity ?: run { result.success(false); return }
        val phone = call.argument<String>("phone") ?: run { result.success(false); return }
        val i = Intent(Intent.ACTION_SENDTO, Uri.parse("smsto:" + Uri.encode(phone)))
            .putExtra("sms_body", call.argument<String>("body") ?: "")
        try {
            a.startActivity(i); result.success(true)
        } catch (e: ActivityNotFoundException) {
            result.success(false)
        }
    }

    private fun mapError(code: Int) = when (code) {
        SmsManager.RESULT_ERROR_GENERIC_FAILURE -> "generic_failure"
        SmsManager.RESULT_ERROR_NO_SERVICE -> "no_service"
        SmsManager.RESULT_ERROR_NULL_PDU -> "null_pdu"
        SmsManager.RESULT_ERROR_RADIO_OFF -> "radio_off"
        else -> "error_$code"
    }

    private fun emit(type: String, recipientId: Int, attemptId: Int, code: String? = null, msg: String? = null) {
        main.post { sink?.success(mapOf("type" to type, "recipientId" to recipientId,
            "attemptId" to attemptId, "errorCode" to code, "errorMessage" to msg)) }
    }

    override fun onListen(args: Any?, events: EventChannel.EventSink?) { sink = events }
    override fun onCancel(args: Any?) { sink = null }
}
