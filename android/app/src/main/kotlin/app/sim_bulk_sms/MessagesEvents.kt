package app.sim_bulk_sms

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel

/** Tells the app screen that the message store changed (new text, status update). */
object MessagesEvents {
    private val main = Handler(Looper.getMainLooper())
    @Volatile private var sink: EventChannel.EventSink? = null

    val handler = object : EventChannel.StreamHandler {
        override fun onListen(args: Any?, events: EventChannel.EventSink?) { sink = events }
        override fun onCancel(args: Any?) { sink = null }
    }

    fun changed() = emit(mapOf("type" to "changed"))

    fun emit(event: Map<String, Any?>) { main.post { sink?.success(event) } }
}
