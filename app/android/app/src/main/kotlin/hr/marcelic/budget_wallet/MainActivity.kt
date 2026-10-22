package hr.marcelic.budget_wallet

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** One tiny channel: the time zone name (for reminders). */
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "budget_wallet/timezone").setMethodCallHandler { call, result ->
            when (call.method) {
                "getTimeZone" -> result.success(java.util.TimeZone.getDefault().id)
                else -> result.notImplemented()
            }
        }
    }
}
