package app.sim_bulk_sms

import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.util.Log
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ConcurrentLinkedQueue

/**
 * Foreground service that does all Android sending: manual sends and scheduled
 * runs. It hosts a headless Flutter engine running `backgroundMain` (Dart),
 * which uses the same queue, state machine and scheduler as the app screen.
 * Jobs requested while it runs are queued; Dart takes them one at a time and
 * asks to finish when the queue is empty.
 */
class SendService : Service() {
    companion object {
        private const val EXTRA_CAMPAIGN = "campaignId"
        private const val EXTRA_SUB = "subscriptionId"
        private const val MAX_RUN_MS = 3L * 60 * 60 * 1000 // safety stop if Dart never finishes

        @Volatile var isRunning = false
            private set

        fun startSend(ctx: Context, campaignId: Int, subscriptionId: Int?) = start(ctx,
            Intent(ctx, SendService::class.java).putExtra(EXTRA_CAMPAIGN, campaignId)
                .putExtra(EXTRA_SUB, subscriptionId ?: -1))

        fun startCheck(ctx: Context) = start(ctx, Intent(ctx, SendService::class.java))

        private fun start(ctx: Context, i: Intent): Boolean = try {
            ContextCompat.startForegroundService(ctx, i); true
        } catch (e: Exception) {
            // e.g. ForegroundServiceStartNotAllowedException when not allowed from the background
            Log.w("SimBulkSms", "Could not start SendService: ${e.javaClass.simpleName}"); false
        }
    }

    private val main = Handler(Looper.getMainLooper())
    private val jobs = ConcurrentLinkedQueue<Map<String, Any?>>()
    private var engine: FlutterEngine? = null
    private var sms: SmsBridge? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private val watchdog = Runnable { Log.w("SimBulkSms", "SendService watchdog stop"); shutdown() }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Notifications.ensureChannels(this)
        ServiceCompat.startForeground(this, Notifications.ONGOING_ID,
            Notifications.ongoing(this, "SIM Bulk SMS", "Preparing to send…", 0, 0),
            if (Build.VERSION.SDK_INT >= 34) ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE else 0)
        isRunning = true
        val cid = intent?.getIntExtra(EXTRA_CAMPAIGN, -1) ?: -1
        jobs.add(if (cid > 0) {
            val sub = intent?.getIntExtra(EXTRA_SUB, -1) ?: -1
            mapOf("campaignId" to cid, "subscriptionId" to (if (sub >= 0) sub else null))
        } else {
            mapOf("check" to true)
        })
        if (engine == null) startEngine()
        return START_NOT_STICKY
    }

    private fun startEngine() {
        wakeLock = getSystemService(PowerManager::class.java)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "SimBulkSms:send").apply { acquire(MAX_RUN_MS) }
        main.postDelayed(watchdog, MAX_RUN_MS)

        val loader = FlutterInjector.instance().flutterLoader()
        loader.startInitialization(applicationContext)
        loader.ensureInitializationComplete(applicationContext, null)
        val e = FlutterEngine(applicationContext) // registers plugins (sqflite) automatically
        val messenger = e.dartExecutor.binaryMessenger
        val b = SmsBridge(this)
        sms = b
        MethodChannel(messenger, "app.sim_bulk_sms/sms_methods").setMethodCallHandler(b)
        EventChannel(messenger, "app.sim_bulk_sms/sms_events").setStreamHandler(b)
        MethodChannel(messenger, "app.sim_bulk_sms/background_service").setMethodCallHandler { call, result ->
            when (call.method) {
                "takeJob" -> result.success(jobs.poll())
                "progress" -> {
                    Notifications.updateOngoing(this, call.argument<String>("title") ?: "SIM Bulk SMS",
                        call.argument<String>("text"), call.argument<Int>("done") ?: 0, call.argument<Int>("total") ?: 0)
                    result.success(null)
                }
                "notifyResult" -> {
                    Notifications.result(this, call.argument<String>("title") ?: "SIM Bulk SMS", call.argument<String>("text") ?: "")
                    result.success(null)
                }
                "scheduleWake" -> result.success(WakeScheduler.schedule(this, call.argument<Number>("at")?.toLong()))
                "finish" -> if (jobs.isEmpty()) { result.success(true); main.post { shutdown() } } else result.success(false)
                else -> result.notImplemented()
            }
        }
        engine = e
        e.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint(
            loader.findAppBundlePath(), "package:sim_bulk_sms/background/background_main.dart", "backgroundMain"))
    }

    private fun shutdown() {
        main.removeCallbacks(watchdog)
        sms?.dispose(); sms = null
        engine?.destroy(); engine = null
        wakeLock?.let { if (it.isHeld) it.release() }; wakeLock = null
        isRunning = false
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        if (engine != null) shutdown()
        isRunning = false
        super.onDestroy()
    }
}
