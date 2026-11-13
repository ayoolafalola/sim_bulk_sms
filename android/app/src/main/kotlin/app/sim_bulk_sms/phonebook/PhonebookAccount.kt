package app.sim_bulk_sms.phonebook

import android.accounts.Account
import android.accounts.AccountManager
import android.content.ContentResolver
import android.content.Context
import android.provider.ContactsContract

/** The "Messages++" account that carries Messages++ actions in the Contacts app. */
object PhonebookAccount {
    const val TYPE = "com.comeriver.messages"
    const val NAME = "Messages++"

    fun ensure(context: Context): Boolean = try {
        val manager = AccountManager.get(context)
        val account = manager.getAccountsByType(TYPE).firstOrNull() ?: Account(NAME, TYPE).also {
            if (!manager.addAccountExplicitly(it, null, null)) return false
        }
        ContentResolver.setIsSyncable(account, ContactsContract.AUTHORITY, 1)
        // The app writes the records itself; Android never needs to sync this account.
        ContentResolver.setSyncAutomatically(account, ContactsContract.AUTHORITY, false)
        true
    } catch (_: SecurityException) {
        false
    } catch (_: RuntimeException) {
        false
    }

    fun remove(context: Context): Boolean = try {
        val manager = AccountManager.get(context)
        manager.getAccountsByType(TYPE).forEach { manager.removeAccountExplicitly(it) }
        true
    } catch (_: Exception) {
        false
    }
}
