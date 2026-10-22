package app.sim_bulk_sms

import android.content.Context
import android.provider.ContactsContract
import android.provider.ContactsContract.CommonDataKinds.Email
import android.provider.ContactsContract.CommonDataKinds.Event
import android.provider.ContactsContract.CommonDataKinds.Note
import android.provider.ContactsContract.CommonDataKinds.Organization
import android.provider.ContactsContract.CommonDataKinds.Phone
import android.provider.ContactsContract.CommonDataKinds.StructuredName
import android.provider.ContactsContract.CommonDataKinds.StructuredPostal
import android.provider.ContactsContract.Data

/**
 * Reads the phone's contacts in the phone's own format: every number and email
 * (with labels and the default marked), dates (birthday…), company, address and
 * notes. Read-only. With [since] > 0 only contacts changed after that time are
 * returned, plus the ids of contacts deleted since then.
 */
object ContactsSync {
    private val kinds = arrayOf(
        Phone.CONTENT_ITEM_TYPE, Email.CONTENT_ITEM_TYPE, Event.CONTENT_ITEM_TYPE, StructuredName.CONTENT_ITEM_TYPE,
        Organization.CONTENT_ITEM_TYPE, StructuredPostal.CONTENT_ITEM_TYPE, Note.CONTENT_ITEM_TYPE,
    )

    fun snapshot(ctx: Context, since: Long): Map<String, Any?> {
        val now = System.currentTimeMillis()
        val r = ctx.contentResolver
        val res = ctx.resources

        // Which contacts to read: all, or those changed since the last sync.
        val changed: List<Long>? = if (since <= 0) null else {
            val ids = ArrayList<Long>()
            r.query(ContactsContract.Contacts.CONTENT_URI, arrayOf(ContactsContract.Contacts._ID),
                "${ContactsContract.Contacts.CONTACT_LAST_UPDATED_TIMESTAMP} > ?", arrayOf(since.toString()), null)?.use { c ->
                while (c.moveToNext()) ids.add(c.getLong(0))
            }
            ids
        }

        val byId = LinkedHashMap<Long, MutableMap<String, Any?>>()
        fun entry(id: Long, lookup: String?, display: String?) = byId.getOrPut(id) {
            mutableMapOf("contactId" to id, "lookupKey" to lookup, "name" to (display ?: ""),
                "phones" to ArrayList<Map<String, Any?>>(), "emails" to ArrayList<Map<String, Any?>>(),
                "dates" to ArrayList<Map<String, Any?>>())
        }

        fun read(selection: String, args: Array<String>) {
            r.query(Data.CONTENT_URI,
                arrayOf(Data.CONTACT_ID, Data.LOOKUP_KEY, Data.DISPLAY_NAME, Data.MIMETYPE, Data.IS_SUPER_PRIMARY,
                    Data.DATA1, Data.DATA2, Data.DATA3, Data.DATA4, Data.DATA5),
                selection, args, "${Data.CONTACT_ID} ASC")?.use { c ->
                while (c.moveToNext()) {
                    val e = entry(c.getLong(0), c.getString(1), c.getString(2))
                    val d1 = c.getString(5)
                    val type = c.getInt(6)
                    val custom = c.getString(7)
                    val primary = c.getInt(4) == 1
                    @Suppress("UNCHECKED_CAST")
                    when (c.getString(3)) {
                        Phone.CONTENT_ITEM_TYPE -> if (!d1.isNullOrBlank()) (e["phones"] as ArrayList<Map<String, Any?>>).add(mapOf(
                            "value" to d1, "type" to type, "primary" to primary,
                            "label" to Phone.getTypeLabel(res, type, custom).toString()))
                        Email.CONTENT_ITEM_TYPE -> if (!d1.isNullOrBlank()) (e["emails"] as ArrayList<Map<String, Any?>>).add(mapOf(
                            "value" to d1.trim(), "type" to type, "primary" to primary,
                            "label" to Email.getTypeLabel(res, type, custom).toString()))
                        Event.CONTENT_ITEM_TYPE -> if (!d1.isNullOrBlank()) (e["dates"] as ArrayList<Map<String, Any?>>).add(mapOf(
                            "value" to d1, "kind" to when (type) {
                                Event.TYPE_BIRTHDAY -> "birthday"; Event.TYPE_ANNIVERSARY -> "anniversary"; else -> "other"
                            }, "label" to Event.getTypeResource(type).let { res.getString(it) }))
                        StructuredName.CONTENT_ITEM_TYPE -> {
                            e["given"] = c.getString(6) // DATA2 = GIVEN_NAME
                            e["family"] = c.getString(7) // DATA3 = FAMILY_NAME
                        }
                        Organization.CONTENT_ITEM_TYPE -> {
                            if (!d1.isNullOrBlank()) e["organization"] = d1
                            c.getString(8)?.let { if (it.isNotBlank()) e["jobTitle"] = it } // DATA4 = TITLE
                        }
                        StructuredPostal.CONTENT_ITEM_TYPE -> if (e["address"] == null && !d1.isNullOrBlank()) e["address"] = d1
                        Note.CONTENT_ITEM_TYPE -> if (!d1.isNullOrBlank()) e["note"] = d1
                    }
                }
            }
        }

        val kindSel = "${Data.MIMETYPE} IN (${kinds.joinToString(",") { "?" }})"
        if (changed == null) {
            read(kindSel, kinds)
        } else {
            for (chunk in changed.chunked(400)) {
                read("$kindSel AND ${Data.CONTACT_ID} IN (${chunk.joinToString(",")})", kinds)
            }
        }

        val deleted = ArrayList<Long>()
        if (since > 0) {
            r.query(ContactsContract.DeletedContacts.CONTENT_URI, arrayOf(ContactsContract.DeletedContacts.CONTACT_ID),
                "${ContactsContract.DeletedContacts.CONTACT_DELETED_TIMESTAMP} > ?", arrayOf(since.toString()), null)?.use { c ->
                while (c.moveToNext()) deleted.add(c.getLong(0))
            }
        }
        return mapOf("contacts" to byId.values.toList(), "deleted" to deleted, "now" to now, "full" to (since <= 0))
    }
}
