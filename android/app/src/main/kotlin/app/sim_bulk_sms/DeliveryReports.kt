package app.sim_bulk_sms

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.telephony.SmsMessage
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.CopyOnWriteArraySet

/** What a carrier's delivery report says about one part of a text. */
enum class DeliveryOutcome { DELIVERED, PENDING, FAILED }

object DeliveryStatus {
    /**
     * Reads the status in the report's PDU. A report that can't be read counts
     * as delivered, as Android's own Messages app does.
     */
    fun of(intent: Intent): DeliveryOutcome {
        val pdu = intent.getByteArrayExtra("pdu") ?: return DeliveryOutcome.DELIVERED
        val format = intent.getStringExtra("format") ?: "3gpp"
        val message = try {
            if (Build.VERSION.SDK_INT >= 23) SmsMessage.createFromPdu(pdu, format)
            else @Suppress("DEPRECATION") SmsMessage.createFromPdu(pdu)
        } catch (e: Exception) { null } ?: return DeliveryOutcome.DELIVERED
        return classify(message.status, format)
    }

    /**
     * 3GPP (GSM/UMTS/LTE) TP-Status: 0-31 done, 32-63 the network is still
     * trying, 64 and above it gave up. 3GPP2 (CDMA): the error class sits in
     * bits 24-25: 0 no error, 2 temporary, 3 permanent.
     */
    fun classify(status: Int, format: String): DeliveryOutcome =
        if (format == "3gpp2") when ((status shr 24) and 0x03) {
            0 -> DeliveryOutcome.DELIVERED
            3 -> DeliveryOutcome.FAILED
            else -> DeliveryOutcome.PENDING
        } else when {
            status < 0x20 -> DeliveryOutcome.DELIVERED
            status < 0x40 -> DeliveryOutcome.PENDING
            else -> DeliveryOutcome.FAILED
        }
}

/**
 * Delivery reports for campaign texts. Carriers can take minutes or hours, long
 * after the send service has stopped, so reports go to [CampaignDeliveryReceiver]
 * (which Android can wake at any time) and are kept here until the app or the
 * send service is running to record them. Holds ids only: no numbers or text.
 */
object CampaignDeliveryReports {
    private const val PREFS = "campaign_delivery_reports"
    private const val KEEP_MS = 14L * 24 * 60 * 60 * 1000
    private val listeners = CopyOnWriteArraySet<() -> Unit>()

    /** A finished attempt: every part delivered, or one part not delivered. */
    data class Finished(val attemptId: Int, val recipientId: Int, val delivered: Boolean)

    fun listen(listener: () -> Unit) { listeners.add(listener) }
    fun unlisten(listener: () -> Unit) { listeners.remove(listener) }
    fun changed() = listeners.forEach { it() }

    @Synchronized
    fun record(ctx: Context, attemptId: Int, recipientId: Int, part: Int, parts: Int, outcome: DeliveryOutcome) {
        if (outcome == DeliveryOutcome.PENDING) return // another report follows
        val prefs = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val key = attemptId.toString()
        val entry = prefs.getString(key, null)?.let { JSONObject(it) } ?: JSONObject()
            .put("recipient", recipientId).put("parts", parts.coerceAtLeast(1))
            .put("delivered", JSONArray()).put("at", System.currentTimeMillis())
        if (entry.optString("result").isNotEmpty()) return // already decided
        if (outcome == DeliveryOutcome.FAILED) {
            entry.put("result", "failed")
        } else {
            val delivered = entry.getJSONArray("delivered")
            if ((0 until delivered.length()).none { delivered.getInt(it) == part }) delivered.put(part)
            if (delivered.length() >= entry.getInt("parts")) entry.put("result", "delivered")
        }
        val edit = prefs.edit().putString(key, entry.toString())
        // Parts whose report never came: forget them after two weeks.
        val now = System.currentTimeMillis()
        for ((k, v) in prefs.all) {
            val at = (v as? String)?.let { runCatching { JSONObject(it).optLong("at") }.getOrNull() } ?: continue
            if (k != key && now - at > KEEP_MS) edit.remove(k)
        }
        edit.apply()
    }

    /** Removes and returns the finished attempts. */
    @Synchronized
    fun takeFinished(ctx: Context): List<Finished> {
        val prefs = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val out = mutableListOf<Finished>()
        val edit = prefs.edit()
        for ((k, v) in prefs.all) {
            val entry = (v as? String)?.let { runCatching { JSONObject(it) }.getOrNull() } ?: continue
            val result = entry.optString("result")
            if (result.isEmpty()) continue
            val attemptId = k.toIntOrNull() ?: run { edit.remove(k); null } ?: continue
            out.add(Finished(attemptId, entry.optInt("recipient"), result == "delivered"))
            edit.remove(k)
        }
        edit.commit()
        return out
    }
}

/** Receives campaign delivery reports, even with the app closed. */
class CampaignDeliveryReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        if (resultCode != Activity.RESULT_OK) return
        val attemptId = intent.getIntExtra("attemptId", -1).takeIf { it >= 0 } ?: return
        val outcome = DeliveryStatus.of(intent)
        intent.getStringExtra("row")?.let { Uri.parse(it) }?.let { row ->
            when (outcome) {
                DeliveryOutcome.DELIVERED -> MessageStore.markDelivered(ctx, row)
                DeliveryOutcome.FAILED -> MessageStore.markNotDelivered(ctx, row)
                DeliveryOutcome.PENDING -> {}
            }
        }
        CampaignDeliveryReports.record(ctx, attemptId, intent.getIntExtra("recipientId", 0),
            intent.getIntExtra("part", 0), intent.getIntExtra("parts", 1), outcome)
        CampaignDeliveryReports.changed()
        MessagesEvents.changed()
    }
}
