package app.sim_bulk_sms.phonebook

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.ContactsContract
import app.sim_bulk_sms.MainActivity

/**
 * "Text +234…" or "Chat +234…" tapped on a contact in the phone's Contacts
 * app. Opens Messages++ at that conversation (texts) or at the person's
 * Contacts++ chat, falling back to a text when they aren't on Contacts++.
 * Only our own records are trusted.
 */
class PhonebookActionActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val mime = intent.type.orEmpty()
        val row = intent.data?.takeIf { it.scheme == "content" && it.authority == ContactsContract.AUTHORITY }?.let { uri ->
            contentResolver.query(
                uri,
                arrayOf(ContactsContract.Data.DATA1, ContactsContract.Data.MIMETYPE, ContactsContract.Data.RAW_CONTACT_ID,
                    ContactsContract.Data.DISPLAY_NAME),
                null, null, null,
            )?.use {
                if (it.moveToFirst() && it.getString(1) == mime && isOurs(it.getLong(2))) it.getString(0) to it.getString(3) else null
            }
        }
        val number = row?.first
        if (!number.isNullOrBlank()) {
            val target = if (mime == PhonebookIntegration.CHAT_MIME) {
                Intent(this, MainActivity::class.java).setAction(Intent.ACTION_VIEW)
                    .putExtra(EXTRA_CHAT, true).putExtra(EXTRA_NAME, row.second)
                    .setData(Uri.fromParts("smsto", number, null))
            } else {
                Intent(this, MainActivity::class.java).setAction(Intent.ACTION_SENDTO).setData(Uri.fromParts("smsto", number, null))
            }
            startActivity(target.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP))
        }
        finish()
    }

    private fun isOurs(rawContactId: Long): Boolean = contentResolver.query(
        ContactsContract.RawContacts.CONTENT_URI,
        arrayOf(ContactsContract.RawContacts.ACCOUNT_TYPE),
        "${ContactsContract.RawContacts._ID}=?",
        arrayOf(rawContactId.toString()),
        null,
    )?.use { it.moveToFirst() && it.getString(0) == PhonebookAccount.TYPE } == true

    companion object {
        const val EXTRA_CHAT = "app.sim_bulk_sms.extra.CHAT"
        const val EXTRA_NAME = "app.sim_bulk_sms.extra.NAME"
    }
}
