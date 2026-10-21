package app.sim_bulk_sms

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var bridge: SmsBridge? = null
    private var contacts: ContactsBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val b = SmsBridge(this); bridge = b
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(messenger, "app.sim_bulk_sms/sms_methods").setMethodCallHandler(b)
        EventChannel(messenger, "app.sim_bulk_sms/sms_events").setStreamHandler(b)
        val cb = ContactsBridge(this); contacts = cb
        MethodChannel(messenger, "app.sim_bulk_sms/contacts").setMethodCallHandler(cb)
    }

    override fun onRequestPermissionsResult(code: Int, perms: Array<out String>, res: IntArray) {
        super.onRequestPermissionsResult(code, perms, res)
        bridge?.onPermissionsResult(code); contacts?.onPermissionsResult(code)
    }

    override fun onDestroy() { bridge?.dispose(); super.onDestroy() }
}
