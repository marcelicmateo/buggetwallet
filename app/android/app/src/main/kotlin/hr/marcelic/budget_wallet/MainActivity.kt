package hr.marcelic.budget_wallet

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** Adds a tiny channel so the app can ask for "All files access" (needed for the Syncthing folder). */
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "budget_wallet/storage").setMethodCallHandler { call, result ->
            when (call.method) {
                "hasAllFilesAccess" -> result.success(
                    Build.VERSION.SDK_INT < Build.VERSION_CODES.R || Environment.isExternalStorageManager()
                )
                "requestAllFilesAccess" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        val intent = Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION, Uri.parse("package:$packageName"))
                        try {
                            startActivity(intent)
                        } catch (e: Exception) {
                            startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
                        }
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }
}
