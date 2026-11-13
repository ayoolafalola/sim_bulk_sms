package app.sim_bulk_sms.phonebook

import android.accounts.Account
import android.app.Service
import android.content.AbstractThreadedSyncAdapter
import android.content.ContentProviderClient
import android.content.Context
import android.content.Intent
import android.content.SyncResult
import android.os.Bundle
import android.os.IBinder

/**
 * Android only shows an account's custom contact actions when the account
 * has a sync adapter declaring its CONTACTS_STRUCTURE. The records are
 * written by the app (PhonebookIntegration), so syncing does nothing.
 */
private class PhonebookSyncAdapter(context: Context) : AbstractThreadedSyncAdapter(context, true, false) {
    override fun onPerformSync(account: Account, extras: Bundle, authority: String, provider: ContentProviderClient, syncResult: SyncResult) = Unit
}

class PhonebookSyncService : Service() {
    private lateinit var adapter: PhonebookSyncAdapter
    override fun onCreate() { adapter = PhonebookSyncAdapter(this) }
    override fun onBind(intent: Intent?): IBinder = adapter.syncAdapterBinder
}
