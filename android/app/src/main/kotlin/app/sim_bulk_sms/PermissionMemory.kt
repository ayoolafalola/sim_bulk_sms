package app.sim_bulk_sms

import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat

/**
 * Remembers which runtime permissions the app has asked for, so it can tell
 * "never asked" from "refused for good" (Android stops showing the prompt after
 * repeated refusals; the user must then enable it in app settings).
 */
object PermissionMemory {
    private const val PREFS = "permission_memory"

    fun markAsked(ctx: Context, vararg permissions: String) {
        val e = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
        for (p in permissions) e.putBoolean(p, true)
        e.apply()
    }

    fun granted(ctx: Context, permission: String) =
        ContextCompat.checkSelfPermission(ctx, permission) == PackageManager.PERMISSION_GRANTED

    /** Asked before, still not granted, and Android won't show the prompt again. */
    fun permanentlyDenied(activity: Activity, permission: String): Boolean =
        !granted(activity, permission) &&
            activity.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(permission, false) &&
            !ActivityCompat.shouldShowRequestPermissionRationale(activity, permission)
}
