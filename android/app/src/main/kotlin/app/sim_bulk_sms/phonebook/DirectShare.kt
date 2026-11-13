package app.sim_bulk_sms.phonebook

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.core.app.Person
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import app.sim_bulk_sms.MainActivity
import app.sim_bulk_sms.R

/**
 * Recent conversations as people in the share sheet (Direct Share) and in
 * the launcher's long-press menu. Picking one opens Messages++ with the
 * shared text in that conversation; nothing is sent until the person taps Send.
 */
object DirectShare {
    const val CATEGORY = "com.comeriver.messages.category.SHARE_TARGET"
    const val PREFIX = "person:"

    fun publish(context: Context, people: List<Map<*, *>>): Int {
        val max = ShortcutManagerCompat.getMaxShortcutCountPerActivity(context).coerceAtMost(8)
        val shortcuts = people.mapNotNull { p ->
            val number = p["phone"]?.toString()?.takeIf { it.isNotBlank() } ?: return@mapNotNull null
            val name = p["name"]?.toString()?.takeIf { it.isNotBlank() } ?: number
            val person = Person.Builder().setName(name).setKey(number).setImportant(true).build()
            ShortcutInfoCompat.Builder(context, PREFIX + number)
                .setShortLabel(name.take(25))
                .setLongLabel(name)
                .setIcon(IconCompat.createWithResource(context, R.drawable.ic_contact_text))
                .setPerson(person)
                .setLongLived(true)
                .setCategories(setOf(CATEGORY))
                .setIntent(Intent(context, MainActivity::class.java).setAction(Intent.ACTION_SENDTO)
                    .setData(Uri.fromParts("smsto", number, null)))
                .build()
        }.take(max)
        return try {
            ShortcutManagerCompat.removeAllDynamicShortcuts(context)
            shortcuts.forEach { ShortcutManagerCompat.pushDynamicShortcut(context, it) }
            shortcuts.size
        } catch (_: Exception) {
            0
        }
    }

    /** The number behind a Direct Share pick ("person:+234…"), if any. */
    fun numberFrom(shortcutId: String?): String? = shortcutId?.takeIf { it.startsWith(PREFIX) }?.removePrefix(PREFIX)
}
