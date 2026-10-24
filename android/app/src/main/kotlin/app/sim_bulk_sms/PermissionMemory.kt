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

    /**
     * The user chose this permission themselves. Android 13+ grants notifications to the default SMS app
     * automatically and takes them back when it stops being the default, so a grant seen only while default
     * isn't treated as the user's choice until confirmed (granted while not default, or set in Settings).
     */
    fun markConfirmed(ctx: Context, permission: String) =
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean("confirmed:$permission", true).apply()

    fun confirmed(ctx: Context, permission: String) =
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean("confirmed:$permission", false)

    /** Asked before, still not granted, and Android won't show the prompt again. */
    fun permanentlyDenied(activity: Activity, permission: String): Boolean =
        !granted(activity, permission) &&
            activity.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(permission, false) &&
            !ActivityCompat.shouldShowRequestPermissionRationale(activity, permission)
}
