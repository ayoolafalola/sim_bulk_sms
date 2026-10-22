package app.sim_bulk_sms

import android.Manifest
import android.app.role.RoleManager
import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Build
import android.provider.ContactsContract
import android.provider.Telephony
import android.util.Log
import androidx.core.content.ContextCompat
import android.content.pm.PackageManager

/**
 * The phone's own SMS store (Telephony provider). As the default messaging app
 * we must write every incoming and outgoing text here, so the history is kept
 * if the user later switches to another messaging app. Nothing here deletes
 * data except the explicit delete calls the user triggers.
 */
object MessageStore {
    /**
     * Whether this is the default messaging app. Android 10+ manages it as a role; asking the
     * role manager is reliable, whereas Telephony.Sms.getDefaultSmsPackage can report null on
     * newer Android (seen on Android 16) even while we hold the role.
     */
    fun isDefault(ctx: Context): Boolean {
        if (Build.VERSION.SDK_INT >= 29) {
            val rm = ctx.getSystemService(RoleManager::class.java)
            if (rm != null && rm.isRoleAvailable(RoleManager.ROLE_SMS)) return rm.isRoleHeld(RoleManager.ROLE_SMS)
        }
        return Telephony.Sms.getDefaultSmsPackage(ctx) == ctx.packageName
    }

    private fun canReadContacts(ctx: Context) =
        ContextCompat.checkSelfPermission(ctx, Manifest.permission.READ_CONTACTS) == PackageManager.PERMISSION_GRANTED

    private val nameCache = HashMap<String, String?>()

    /** Display name from the phone's contacts, or null. */
    fun nameFor(ctx: Context, address: String): String? {
        if (!canReadContacts(ctx) || address.isBlank()) return null
        synchronized(nameCache) { if (nameCache.containsKey(address)) return nameCache[address] }
        val name = try {
            ctx.contentResolver.query(
                Uri.withAppendedPath(ContactsContract.PhoneLookup.CONTENT_FILTER_URI, Uri.encode(address)),
                arrayOf(ContactsContract.PhoneLookup.DISPLAY_NAME), null, null, null
            )?.use { c -> if (c.moveToFirst()) c.getString(0) else null }
        } catch (e: Exception) { null }
        synchronized(nameCache) { nameCache[address] = name }
        return name
    }

    /** Conversations, newest first: thread id, addresses, name, snippet, date, unread count. */
    fun conversations(ctx: Context): List<Map<String, Any?>> {
        val canonical = HashMap<String, String>()
        ctx.contentResolver.query(Uri.parse("content://mms-sms/canonical-addresses"), null, null, null, null)?.use { c ->
            val iId = c.getColumnIndex("_id"); val iAddr = c.getColumnIndex("address")
            while (c.moveToNext()) canonical[c.getString(iId)] = c.getString(iAddr) ?: ""
        }
        val unread = HashMap<Long, Int>()
        ctx.contentResolver.query(Telephony.Sms.CONTENT_URI, arrayOf(Telephony.Sms.THREAD_ID),
            "${Telephony.Sms.READ} = 0 AND ${Telephony.Sms.TYPE} = ${Telephony.Sms.MESSAGE_TYPE_INBOX}", null, null)?.use { c ->
            while (c.moveToNext()) { val t = c.getLong(0); unread[t] = (unread[t] ?: 0) + 1 }
        }
        val out = ArrayList<Map<String, Any?>>()
        ctx.contentResolver.query(Uri.parse("content://mms-sms/conversations?simple=true"),
            arrayOf("_id", "date", "recipient_ids", "snippet", "message_count"), null, null, "date DESC")?.use { c ->
            while (c.moveToNext()) {
                val thread = c.getLong(0)
                if (c.getInt(4) == 0) continue // empty thread
                val addresses = (c.getString(2) ?: "").split(" ").filter { it.isNotBlank() }.mapNotNull { canonical[it] }
                val name = if (addresses.size == 1) nameFor(ctx, addresses[0]) else
                    addresses.joinToString(", ") { nameFor(ctx, it) ?: it }
                out.add(mapOf(
                    "threadId" to thread, "addresses" to addresses, "name" to name,
                    "snippet" to (c.getString(3) ?: ""), "date" to c.getLong(1), "unread" to (unread[thread] ?: 0),
                ))
            }
        }
        return out
    }

    /** Messages of a thread, newest first (the UI reverses them). */
    fun messages(ctx: Context, threadId: Long, limit: Int): List<Map<String, Any?>> {
        val out = ArrayList<Map<String, Any?>>()
        ctx.contentResolver.query(Telephony.Sms.CONTENT_URI,
            arrayOf(Telephony.Sms._ID, Telephony.Sms.ADDRESS, Telephony.Sms.BODY, Telephony.Sms.DATE,
                Telephony.Sms.TYPE, Telephony.Sms.STATUS, Telephony.Sms.READ, Telephony.Sms.SUBSCRIPTION_ID),
            "${Telephony.Sms.THREAD_ID} = ?", arrayOf(threadId.toString()), "${Telephony.Sms.DATE} DESC LIMIT $limit")?.use { c ->
            while (c.moveToNext()) {
                out.add(mapOf(
                    "id" to c.getLong(0), "address" to (c.getString(1) ?: ""), "body" to (c.getString(2) ?: ""),
                    "date" to c.getLong(3), "type" to c.getInt(4), "status" to c.getInt(5), "read" to (c.getInt(6) == 1),
                    "subId" to c.getInt(7),
                ))
            }
        }
        return out
    }

    fun threadIdFor(ctx: Context, address: String): Long = Telephony.Threads.getOrCreateThreadId(ctx, address)

    fun markRead(ctx: Context, threadId: Long) {
        if (!isDefault(ctx)) return
        val v = ContentValues().apply { put(Telephony.Sms.READ, 1); put(Telephony.Sms.SEEN, 1) }
        try {
            ctx.contentResolver.update(Telephony.Sms.CONTENT_URI, v,
                "${Telephony.Sms.THREAD_ID} = ? AND ${Telephony.Sms.READ} = 0", arrayOf(threadId.toString()))
        } catch (e: Exception) { Log.w("SimBulkSms", "markRead failed: ${e.javaClass.simpleName}") }
    }

    fun markAllRead(ctx: Context) {
        if (!isDefault(ctx)) return
        val v = ContentValues().apply { put(Telephony.Sms.READ, 1); put(Telephony.Sms.SEEN, 1) }
        try { ctx.contentResolver.update(Telephony.Sms.CONTENT_URI, v, "${Telephony.Sms.READ} = 0", null) }
        catch (e: Exception) { Log.w("SimBulkSms", "markAllRead failed: ${e.javaClass.simpleName}") }
    }

    /** Deletes one text, only when the user asked to. Returns whether it was deleted. */
    fun deleteMessage(ctx: Context, id: Long): Boolean {
        if (!isDefault(ctx)) return false
        return try { ctx.contentResolver.delete(Uri.withAppendedPath(Telephony.Sms.CONTENT_URI, id.toString()), null, null) > 0 }
        catch (e: Exception) { false }
    }

    /** Deletes a whole conversation, only when the user asked to. */
    fun deleteThread(ctx: Context, threadId: Long): Boolean {
        if (!isDefault(ctx)) return false
        return try {
            ctx.contentResolver.delete(Uri.withAppendedPath(Telephony.Threads.CONTENT_URI, threadId.toString()), null, null) > 0
        } catch (e: Exception) { false }
    }

    /** Stores an incoming text. Returns its thread id, or null if it couldn't be stored. */
    fun insertIncoming(ctx: Context, address: String, body: String, sentAt: Long, subId: Int): Long? {
        val v = ContentValues().apply {
            put(Telephony.Sms.ADDRESS, address); put(Telephony.Sms.BODY, body)
            put(Telephony.Sms.DATE, System.currentTimeMillis()); put(Telephony.Sms.DATE_SENT, sentAt)
            put(Telephony.Sms.READ, 0); put(Telephony.Sms.SEEN, 0)
            put(Telephony.Sms.TYPE, Telephony.Sms.MESSAGE_TYPE_INBOX); put(Telephony.Sms.SUBSCRIPTION_ID, subId)
        }
        return try {
            ctx.contentResolver.insert(Telephony.Sms.Inbox.CONTENT_URI, v)
            threadIdFor(ctx, address)
        } catch (e: Exception) { Log.w("SimBulkSms", "insertIncoming failed: ${e.javaClass.simpleName}"); null }
    }

    /** Records an outgoing text as "sending" before it goes out; returns its row, or null when not default. */
    fun insertOutgoing(ctx: Context, address: String, body: String, subId: Int?): Uri? {
        if (!isDefault(ctx)) return null
        val v = ContentValues().apply {
            put(Telephony.Sms.ADDRESS, address); put(Telephony.Sms.BODY, body)
            put(Telephony.Sms.DATE, System.currentTimeMillis()); put(Telephony.Sms.READ, 1); put(Telephony.Sms.SEEN, 1)
            put(Telephony.Sms.TYPE, Telephony.Sms.MESSAGE_TYPE_OUTBOX)
            put(Telephony.Sms.STATUS, Telephony.Sms.STATUS_PENDING)
            if (subId != null) put(Telephony.Sms.SUBSCRIPTION_ID, subId)
        }
        return try { ctx.contentResolver.insert(Telephony.Sms.Outbox.CONTENT_URI, v) }
        catch (e: Exception) { Log.w("SimBulkSms", "insertOutgoing failed: ${e.javaClass.simpleName}"); null }
    }

    private fun update(ctx: Context, row: Uri, v: ContentValues) {
        try { ctx.contentResolver.update(row, v, null, null) }
        catch (e: Exception) { Log.w("SimBulkSms", "update failed: ${e.javaClass.simpleName}") }
    }

    fun markSent(ctx: Context, row: Uri) = update(ctx, row, ContentValues().apply {
        put(Telephony.Sms.TYPE, Telephony.Sms.MESSAGE_TYPE_SENT)
    })

    fun markFailed(ctx: Context, row: Uri, errorCode: Int) = update(ctx, row, ContentValues().apply {
        put(Telephony.Sms.TYPE, Telephony.Sms.MESSAGE_TYPE_FAILED); put(Telephony.Sms.ERROR_CODE, errorCode)
        put(Telephony.Sms.STATUS, Telephony.Sms.STATUS_FAILED)
    })

    fun markDelivered(ctx: Context, row: Uri) = update(ctx, row, ContentValues().apply {
        put(Telephony.Sms.STATUS, Telephony.Sms.STATUS_COMPLETE)
    })
}
