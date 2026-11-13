package app.sim_bulk_sms.phonebook

import android.accounts.AbstractAccountAuthenticator
import android.accounts.Account
import android.accounts.AccountAuthenticatorResponse
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.IBinder

/** Required by Android for an app's contacts account. There's nothing to sign in to. */
private class PhonebookAuthenticator(context: Context) : AbstractAccountAuthenticator(context) {
    override fun editProperties(response: AccountAuthenticatorResponse?, accountType: String?) = Bundle()
    override fun addAccount(
        response: AccountAuthenticatorResponse?, accountType: String?, authTokenType: String?,
        requiredFeatures: Array<out String>?, options: Bundle?,
    ) = Bundle().apply { putString("errorMessage", "Turn this on in Messages++ › Settings.") }
    override fun confirmCredentials(response: AccountAuthenticatorResponse?, account: Account?, options: Bundle?) =
        Bundle().apply { putBoolean("booleanResult", true) }
    override fun getAuthToken(
        response: AccountAuthenticatorResponse?, account: Account?, authTokenType: String?, options: Bundle?,
    ): Bundle = Bundle().apply { putString("errorMessage", "Messages++ has no sign-in here.") }
    override fun getAuthTokenLabel(authTokenType: String?) = "Messages++"
    override fun updateCredentials(
        response: AccountAuthenticatorResponse?, account: Account?, authTokenType: String?, options: Bundle?,
    ) = Bundle()
    override fun hasFeatures(response: AccountAuthenticatorResponse?, account: Account?, features: Array<out String>?) =
        Bundle().apply { putBoolean("booleanResult", false) }
}

class PhonebookAuthenticatorService : Service() {
    private lateinit var authenticator: PhonebookAuthenticator
    override fun onCreate() { authenticator = PhonebookAuthenticator(this) }
    override fun onBind(intent: Intent?): IBinder = authenticator.iBinder
}
