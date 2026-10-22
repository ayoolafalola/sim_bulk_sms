package app.sim_bulk_sms

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var bridge: SmsBridge? = null
    private var contacts: ContactsBridge? = null
    private var background: BackgroundBridge? = null
    private var messages: MessagesBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val b = SmsBridge(this, this); bridge = b
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(messenger, "app.sim_bulk_sms/sms_methods").setMethodCallHandler(b)
        EventChannel(messenger, "app.sim_bulk_sms/sms_events").setStreamHandler(b)
        val cb = ContactsBridge(this); contacts = cb
        MethodChannel(messenger, "app.sim_bulk_sms/contacts").setMethodCallHandler(cb)
        val bg = BackgroundBridge(this); background = bg
        MethodChannel(messenger, "app.sim_bulk_sms/background").setMethodCallHandler(bg)
        val mb = MessagesBridge(this); messages = mb
        MethodChannel(messenger, "app.sim_bulk_sms/messages").setMethodCallHandler(mb)
        EventChannel(messenger, "app.sim_bulk_sms/messages_events").setStreamHandler(MessagesEvents.handler)
        mb.onIntent(intent)
    }

    override fun onRequestPermissionsResult(code: Int, perms: Array<out String>, res: IntArray) {
        super.onRequestPermissionsResult(code, perms, res)
        bridge?.onPermissionsResult(code); contacts?.onPermissionsResult(code); background?.onPermissionsResult(code)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        messages?.onIntent(intent)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        messages?.onActivityResult(requestCode)
    }

    override fun onDestroy() { bridge?.dispose(); messages?.dispose(); contacts?.dispose(); super.onDestroy() }
}
