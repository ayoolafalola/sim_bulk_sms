package app.sim_bulk_sms.phonebook

import android.content.ContentProviderOperation
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.provider.ContactsContract
import android.provider.ContactsContract.RawContacts

/**
 * Adds Messages++ actions to contacts in the phone's own Contacts app:
 * "Text +234…" for each number, and "Chat +234…" for numbers whose owner can
 * get a Contacts++ chat. Opt-in (Settings › Show in my Contacts app).
 *
 * Every phone contact gets one Messages++ record, joined to it. Only
 * records under the Messages++ account are ever written or removed; the
 * phone's, SIM, Google and other apps' records are never changed.
 */
object PhonebookIntegration {
    /** Bumped when the rows' layout changes, so every record is rewritten. */
    private const val LAYOUT = "1"
    const val TEXT_MIME = "vnd.android.cursor.item/vnd.comeriver.messages.text"
    const val CHAT_MIME = "vnd.android.cursor.item/vnd.comeriver.messages.chat"

    data class Card(
        val key: String,
        val displayName: String,
        val numbers: List<String>,
        val chatNumbers: List<String>,
        val nativeContactId: Long?,
    ) {
        fun fingerprint(): String = listOf(LAYOUT, key, displayName, numbers.joinToString(","), chatNumbers.joinToString(","),
            nativeContactId?.toString().orEmpty()).joinToString("|").hashCode().toString()
    }

    data class Result(val written: Int, val removed: Int)

    fun synchronize(context: Context, cards: List<Card>): Result {
        if (!PhonebookAccount.ensure(context)) return Result(0, 0)
        val resolver = context.contentResolver
        val keep = cards.map { it.key }.toSet()
        val existing = records(context)
        var written = 0
        for (card in cards.distinctBy { it.key }) {
            if (card.key.isBlank() || card.numbers.isEmpty()) continue
            val fingerprint = card.fingerprint()
            val (rawId, stored) = existing[card.key] ?: (null to null)
            if (rawId != null && stored == fingerprint) continue
            try {
                val id = rawId ?: insert(context, card, fingerprint) ?: continue
                if (rawId != null) replaceData(context, rawId, card, fingerprint)
                joinToContact(context, id, card.nativeContactId)
                written++
            } catch (_: Exception) {
                // One odd contact never stops the rest.
            }
        }
        var removed = 0
        for ((key, value) in existing) {
            val rawId = value.first ?: continue
            if (key !in keep) {
                removed += resolver.delete(ContentUris.withAppendedId(RawContacts.CONTENT_URI, rawId).asSyncAdapter(), null, null)
            }
        }
        return Result(written, removed)
    }

    /** Turning it off: every Messages++ record and the account go. */
    fun removeAll(context: Context): Int {
        val removed = try {
            context.contentResolver.delete(
                RawContacts.CONTENT_URI.asSyncAdapter(),
                "${RawContacts.ACCOUNT_TYPE}=? AND ${RawContacts.ACCOUNT_NAME}=?",
                arrayOf(PhonebookAccount.TYPE, PhonebookAccount.NAME),
            )
        } catch (_: Exception) {
            0
        }
        PhonebookAccount.remove(context)
        return removed
    }

    private fun Uri.asSyncAdapter(): Uri = buildUpon()
        .appendQueryParameter(ContactsContract.CALLER_IS_SYNCADAPTER, "true")
        .appendQueryParameter(RawContacts.ACCOUNT_NAME, PhonebookAccount.NAME)
        .appendQueryParameter(RawContacts.ACCOUNT_TYPE, PhonebookAccount.TYPE)
        .build()

    private fun records(context: Context): Map<String, Pair<Long?, String?>> {
        val found = HashMap<String, Pair<Long?, String?>>()
        context.contentResolver.query(
            RawContacts.CONTENT_URI,
            arrayOf(RawContacts._ID, RawContacts.SYNC2, RawContacts.SOURCE_ID),
            "${RawContacts.ACCOUNT_TYPE}=? AND ${RawContacts.ACCOUNT_NAME}=? AND ${RawContacts.DELETED}=0",
            arrayOf(PhonebookAccount.TYPE, PhonebookAccount.NAME),
            null,
        )?.use { c ->
            while (c.moveToNext()) {
                val key = c.getString(2) ?: continue
                found[key] = c.getLong(0) to c.getString(1)
            }
        }
        return found
    }

    private fun insert(context: Context, card: Card, fingerprint: String): Long? {
        val ops = arrayListOf(
            ContentProviderOperation.newInsert(RawContacts.CONTENT_URI.asSyncAdapter())
                .withValue(RawContacts.ACCOUNT_TYPE, PhonebookAccount.TYPE)
                .withValue(RawContacts.ACCOUNT_NAME, PhonebookAccount.NAME)
                .withValue(RawContacts.SOURCE_ID, card.key)
                .withValue(RawContacts.SYNC2, fingerprint)
                .build(),
        )
        addData(ops, null, 0, card)
        val results = context.contentResolver.applyBatch(ContactsContract.AUTHORITY, ops)
        return results.firstOrNull()?.uri?.let { ContentUris.parseId(it) }
    }

    private fun replaceData(context: Context, rawId: Long, card: Card, fingerprint: String) {
        val resolver = context.contentResolver
        resolver.update(
            ContentUris.withAppendedId(RawContacts.CONTENT_URI, rawId).asSyncAdapter(),
            ContentValues().apply { put(RawContacts.SYNC2, fingerprint) }, null, null,
        )
        resolver.delete(ContactsContract.Data.CONTENT_URI.asSyncAdapter(), "${ContactsContract.Data.RAW_CONTACT_ID}=?", arrayOf(rawId.toString()))
        val ops = arrayListOf<ContentProviderOperation>()
        addData(ops, rawId, null, card)
        if (ops.isNotEmpty()) resolver.applyBatch(ContactsContract.AUTHORITY, ops)
    }

    private fun addData(ops: ArrayList<ContentProviderOperation>, rawId: Long?, backReference: Int?, card: Card) {
        fun row(mime: String): ContentProviderOperation.Builder {
            val b = ContentProviderOperation.newInsert(ContactsContract.Data.CONTENT_URI.asSyncAdapter())
                .withValue(ContactsContract.Data.MIMETYPE, mime)
            return if (rawId != null) b.withValue(ContactsContract.Data.RAW_CONTACT_ID, rawId)
            else b.withValueBackReference(ContactsContract.Data.RAW_CONTACT_ID, backReference!!)
        }
        // The same name as the contact it joins, so it never shows on its own.
        ops += row(ContactsContract.CommonDataKinds.StructuredName.CONTENT_ITEM_TYPE)
            .withValue(ContactsContract.CommonDataKinds.StructuredName.DISPLAY_NAME, card.displayName)
            .build()
        for (number in card.numbers.distinct()) {
            ops += row(TEXT_MIME)
                .withValue(ContactsContract.Data.DATA1, number)
                .withValue(ContactsContract.Data.DATA2, "Text $number")
                .withValue(ContactsContract.Data.DATA3, "Text $number")
                .build()
        }
        for (number in card.chatNumbers.distinct()) {
            ops += row(CHAT_MIME)
                .withValue(ContactsContract.Data.DATA1, number)
                .withValue(ContactsContract.Data.DATA2, "Chat $number")
                .withValue(ContactsContract.Data.DATA3, "Chat $number (Contacts++)")
                .build()
        }
    }

    /** Joins the record to the phone's own contact, so it adds actions to it. */
    private fun joinToContact(context: Context, ownRawId: Long, contactId: Long?) {
        if (contactId == null) return
        val targets = mutableListOf<Long>()
        context.contentResolver.query(
            RawContacts.CONTENT_URI,
            arrayOf(RawContacts._ID, RawContacts.ACCOUNT_TYPE),
            "${RawContacts.CONTACT_ID}=? AND ${RawContacts.DELETED}=0",
            arrayOf(contactId.toString()),
            null,
        )?.use { c ->
            while (c.moveToNext()) if (c.getLong(0) != ownRawId && c.getString(1) != PhonebookAccount.TYPE) targets += c.getLong(0)
        }
        if (targets.isEmpty()) return
        val ops = ArrayList<ContentProviderOperation>()
        for (target in targets) {
            ops += ContentProviderOperation.newUpdate(ContactsContract.AggregationExceptions.CONTENT_URI)
                .withValue(ContactsContract.AggregationExceptions.TYPE, ContactsContract.AggregationExceptions.TYPE_KEEP_TOGETHER)
                .withValue(ContactsContract.AggregationExceptions.RAW_CONTACT_ID1, ownRawId)
                .withValue(ContactsContract.AggregationExceptions.RAW_CONTACT_ID2, target)
                .build()
        }
        context.contentResolver.applyBatch(ContactsContract.AUTHORITY, ops)
    }

    fun parseCards(arguments: Any?): List<Card> {
        val values = arguments as? List<*> ?: return emptyList()
        return values.mapNotNull { raw ->
            val item = raw as? Map<*, *> ?: return@mapNotNull null
            val key = item["key"]?.toString()?.trim().orEmpty()
            if (key.isEmpty()) return@mapNotNull null
            fun list(name: String) = (item[name] as? List<*>)?.mapNotNull { it?.toString()?.trim()?.takeIf(String::isNotEmpty) } ?: emptyList()
            Card(
                key = key,
                displayName = item["display_name"]?.toString()?.trim().takeUnless { it.isNullOrEmpty() } ?: "Contact",
                numbers = list("numbers"),
                chatNumbers = list("chat_numbers"),
                nativeContactId = item["native_id"]?.toString()?.toLongOrNull(),
            )
        }
    }
}
