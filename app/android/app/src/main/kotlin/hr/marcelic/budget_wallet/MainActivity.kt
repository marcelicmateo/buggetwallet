package hr.marcelic.budget_wallet

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.pdf.PdfRenderer
import android.media.ExifInterface
import android.net.Uri
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.graphics.drawable.Icon
import android.hardware.display.DisplayManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.provider.CalendarContract
import android.provider.MediaStore
import android.view.WindowManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.time.LocalDate
import kotlin.concurrent.thread

/**
 * Small channels: `budget_wallet/calendar` (read-only calendar access, READ_CALENDAR only), `budget_wallet/widget` (the home-screen widget's
 * three words), `budget_wallet/shortcut` (the launcher shortcut's action), and `bw/secure` (FLAG_SECURE while the wallet key is shown), the time zone name (for reminders), and the bills helpers (no PDF package): `renderPdf` draws the pages of a
 * PDF with the platform's PdfRenderer, `toJpeg` sizes a picture down (both on a background thread) and `takePhoto` lets the
 * phone's own camera app take one full-size picture into the app's cache (returns its path; null when cancelled).
 */
class MainActivity : FlutterActivity() {
    private val main = Handler(Looper.getMainLooper())

    /** The `takePhoto` call that is waiting for the permission or for the camera app, and the file the camera writes. */
    private var photoResult: MethodChannel.Result? = null
    private var photoFile: File? = null

    /** The `requestPermission` call of the calendar channel that is waiting for the system dialog. */
    private var calendarResult: MethodChannel.Result? = null

    /** The launcher shortcut's action (`bw.action` extra) that started or reached the app and was not handed to Dart yet. */
    private var initialAction: String? = null
    private var shortcutChannel: MethodChannel? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Not again after the system re-created the activity or brought it back from the recent-apps list.
        if (savedInstanceState == null && (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) == 0) takeAction(intent)
        // A picture left behind when Android killed the app while the camera app was open (its path was lost with it).
        clearBillPhotos()
        publishShortcut()
        preferSixtyHertz()
    }

    /**
     * Asks for a 60 Hz display mode (the app's frame budget is 16.7 ms, so a 90/120 Hz panel only costs battery and heat). API 23+: the
     * mode with the current size and 60 Hz is preferred (the system may still pick another when another window or setting needs it);
     * if the panel has none, `preferredRefreshRate` is a hint. Nothing is logged: a failure just leaves the system's choice.
     * Called again when the display changes (a resolution switch, a folded phone opened), only when the request would differ.
     */
    private fun preferSixtyHertz() {
        try {
            if (Build.VERSION.SDK_INT < 23) return
            @Suppress("DEPRECATION")
            val display = if (Build.VERSION.SDK_INT >= 30) this.display else windowManager.defaultDisplay
            val current = display?.mode ?: return
            val sixty = display.supportedModes.firstOrNull {
                it.physicalWidth == current.physicalWidth && it.physicalHeight == current.physicalHeight &&
                    Math.abs(it.refreshRate - 60f) < 1f
            }
            val params = window.attributes
            if (sixty != null) {
                if (params.preferredDisplayModeId == sixty.modeId) return
                params.preferredDisplayModeId = sixty.modeId
            } else {
                if (params.preferredRefreshRate == 60f) return
                params.preferredRefreshRate = 60f
            }
            window.attributes = params
        } catch (e: Throwable) {
            // A display that cannot be asked: the system's refresh rate stays.
        }
    }

    private val displayListener = object : DisplayManager.DisplayListener {
        override fun onDisplayAdded(displayId: Int) {}
        override fun onDisplayRemoved(displayId: Int) {}
        override fun onDisplayChanged(displayId: Int) = preferSixtyHertz()
    }

    override fun onResume() {
        super.onResume()
        preferSixtyHertz()
        try {
            getSystemService(DisplayManager::class.java)?.registerDisplayListener(displayListener, main)
        } catch (e: Throwable) {
            // No display service: the preference stays as it was set.
        }
    }

    override fun onPause() {
        try {
            getSystemService(DisplayManager::class.java)?.unregisterDisplayListener(displayListener)
        } catch (e: Throwable) {
        }
        super.onPause()
    }

    /**
     * The launcher shortcut "Add expense", published as a dynamic one (API 25+) so its intent keeps our flags: a static shortcut starts
     * with NEW_TASK + CLEAR_TASK and would kill a running app. With SINGLE_TOP (and singleTask) a running app gets [onNewIntent].
     * The intent has its own action, so the share plugin never sees it as a shared item.
     */
    private fun publishShortcut() {
        if (Build.VERSION.SDK_INT < 25) return
        try {
            val manager = getSystemService(ShortcutManager::class.java) ?: return
            val intent = Intent(this, MainActivity::class.java).apply {
                action = ACTION_ADD_EXPENSE
                putExtra(ACTION_EXTRA, "addExpense")
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            }
            val info = ShortcutInfo.Builder(this, "add_expense")
                .setShortLabel(getString(R.string.shortcut_add_short))
                .setLongLabel(getString(R.string.shortcut_add_long))
                .setIcon(Icon.createWithResource(this, R.drawable.ic_shortcut_add))
                .setIntent(intent)
                .build()
            manager.dynamicShortcuts = listOf(info)
        } catch (e: Throwable) {
            // A launcher without shortcut support: the app works without it.
        }
    }

    /** Moves the shortcut action out of [intent] (so a later re-delivery of the same intent does not repeat it). */
    private fun takeAction(intent: Intent?): String? {
        // Only our own action counts; any other intent (the share plugin's SEND and VIEW ones included) is left as it is.
        if (intent == null || intent.action != ACTION_ADD_EXPENSE || intent.getStringExtra(ACTION_EXTRA) != "addExpense") return null
        intent.removeExtra(ACTION_EXTRA)
        intent.action = null
        initialAction = "addExpense"
        return initialAction
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        // The app is already running (singleTask): tell Dart at once; it is kept for getInitialAction when Dart is not listening yet.
        if (takeAction(intent) != null) {
            val action = initialAction
            val channel = shortcutChannel
            if (action != null && channel != null) {
                initialAction = null
                channel.invokeMethod("action", action)
            }
        }
    }

    /** Deletes every file in `cache/bill_photos` (only the camera writes there; Dart reads and deletes each picture at once). */
    private fun clearBillPhotos() {
        try {
            File(cacheDir, "bill_photos").listFiles()?.forEach { it.delete() }
        } catch (e: SecurityException) {
            // Our own cache folder: not expected; the next call tries again.
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "budget_wallet/timezone").setMethodCallHandler { call, result ->
            when (call.method) {
                "getTimeZone" -> result.success(java.util.TimeZone.getDefault().id)
                else -> result.notImplemented()
            }
        }
        // `setSecure(bool)`: FLAG_SECURE on the window while the wallet key is on screen (no screenshots, screen recording or
        // thumbnail in the recent-apps list). The Dart side switches it on when the key sheet opens and off when it closes.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "bw/secure").setMethodCallHandler { call, result ->
            when (call.method) {
                "setSecure" -> {
                    val on = call.arguments as? Boolean ?: call.argument<Boolean>("secure")
                    if (on == null) {
                        result.error("args", "setSecure needs a bool", null)
                    } else {
                        if (on) window.addFlags(WindowManager.LayoutParams.FLAG_SECURE) else window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        result.success(null)
                    }
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "budget_wallet/calendar").setMethodCallHandler { call, result ->
            when (call.method) {
                "hasPermission" -> result.success(hasCalendarPermission())
                "requestPermission" -> requestCalendarPermission(result)
                "calendars" -> background(result) { calendars() }
                "events" -> {
                    val ids = call.argument<List<String>>("ids")
                    val from = call.argument<String>("from")
                    val to = call.argument<String>("to")
                    if (ids == null || from == null || to == null) {
                        result.error("args", "events needs ids, from and to", null)
                    } else {
                        background(result) { events(ids, from, to) }
                    }
                }
                else -> result.notImplemented()
            }
        }
        // `update({amount, status, date})` and `clear()`: the home-screen widget. Three words, nothing else.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "budget_wallet/widget").setMethodCallHandler { call, result ->
            when (call.method) {
                "update" -> {
                    val amount = call.argument<String>("amount")
                    val status = call.argument<String>("status")
                    val date = call.argument<String>("date")
                    val until = call.argument<String>("until")
                    if (amount == null || status == null || date == null) {
                        result.error("args", "update needs amount, status and date", null)
                    } else {
                        try {
                            SafeTodayWidget.update(applicationContext, amount, status, date, until)
                            result.success(null)
                        } catch (e: Throwable) {
                            result.error("failed", e.javaClass.simpleName, null)
                        }
                    }
                }
                "clear" -> {
                    try {
                        SafeTodayWidget.clear(applicationContext)
                        result.success(null)
                    } catch (e: Throwable) {
                        result.error("failed", e.javaClass.simpleName, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
        // `getInitialAction()`: the launcher shortcut that started the app (once); later ones arrive as an `action` call to Dart.
        shortcutChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "budget_wallet/shortcut").also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "getInitialAction" -> {
                        val action = initialAction
                        initialAction = null
                        result.success(action)
                    }
                    else -> result.notImplemented()
                }
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "budget_wallet/bills").setMethodCallHandler { call, result ->
            when (call.method) {
                "renderPdf" -> {
                    val bytes = call.argument<ByteArray>("bytes")
                    val dpi = call.argument<Int>("dpi") ?: 200
                    val maxPages = call.argument<Int>("maxPages") ?: 5
                    if (bytes == null) {
                        result.error("args", "no bytes", null)
                    } else {
                        background(result) { renderPdf(bytes, dpi, maxPages) }
                    }
                }
                "toJpeg" -> {
                    val bytes = call.argument<ByteArray>("bytes")
                    val maxSide = call.argument<Int>("maxSide") ?: 2560
                    if (bytes == null) {
                        result.error("args", "no bytes", null)
                    } else {
                        background(result) { toJpeg(bytes, maxSide) }
                    }
                }
                "takePhoto" -> takePhoto(result)
                else -> result.notImplemented()
            }
        }
    }

    /**
     * ACTION_IMAGE_CAPTURE throws a SecurityException when CAMERA is declared in the manifest but not granted, so the permission is
     * asked first (Scan bill has normally asked already). The picture goes to a FileProvider uri under the app's cache.
     */
    private fun takePhoto(result: MethodChannel.Result) {
        if (photoResult != null) {
            result.error("busy", "photo already open", null)
            return
        }
        photoResult = result
        clearBillPhotos() // nothing is waiting for an older picture now
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
            launchCamera()
        } else {
            ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.CAMERA), REQUEST_PERMISSION)
        }
    }

    private fun launchCamera() {
        val result = photoResult ?: return
        try {
            val dir = File(cacheDir, "bill_photos").apply { mkdirs() }
            val file = File.createTempFile("photo", ".jpg", dir)
            photoFile = file
            val uri: Uri = FileProvider.getUriForFile(this, "$packageName.billphotos", file)
            val intent = Intent(MediaStore.ACTION_IMAGE_CAPTURE).apply {
                putExtra(MediaStore.EXTRA_OUTPUT, uri)
                addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_READ_URI_PERMISSION)
                clipData = android.content.ClipData.newRawUri("", uri)
            }
            @Suppress("DEPRECATION")
            startActivityForResult(intent, REQUEST_PHOTO)
        } catch (e: Throwable) {
            finishPhoto(null, e.javaClass.simpleName)
        }
    }

    /** Answers the waiting `takePhoto` call once: [path] on success, null when cancelled, an error code when it failed. */
    private fun finishPhoto(path: String?, error: String? = null) {
        val result = photoResult ?: return
        photoResult = null
        if (path == null) {
            photoFile?.delete()
        }
        photoFile = null
        if (error != null) result.error(error, null, null) else result.success(path)
    }

    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == REQUEST_PHOTO) {
            val file = photoFile
            if (resultCode == RESULT_OK && file != null && file.length() > 0) finishPhoto(file.absolutePath) else finishPhoto(null)
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        if (requestCode == REQUEST_CALENDAR) {
            val waiting = calendarResult
            calendarResult = null
            waiting?.success(grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED)
            return
        }
        if (requestCode == REQUEST_PERMISSION && photoResult != null) {
            if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) launchCamera() else finishPhoto(null, "permission")
            return
        }
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    companion object {
        private const val REQUEST_PHOTO = 7301
        private const val REQUEST_PERMISSION = 7302
        private const val REQUEST_CALENDAR = 7303
        private const val ACTION_EXTRA = "bw.action"
        private const val ACTION_ADD_EXPENSE = "hr.marcelic.budget_wallet.ADD_EXPENSE"

        /** The Julian day number the calendar provider uses for `Instances.START_DAY` (1 Jan 1970 = 2440588). */
        private const val JULIAN_EPOCH = 2440588L
    }

    private fun hasCalendarPermission() =
        ContextCompat.checkSelfPermission(this, Manifest.permission.READ_CALENDAR) == PackageManager.PERMISSION_GRANTED

    /** Asks for READ_CALENDAR only (the app never writes events); true when allowed. */
    private fun requestCalendarPermission(result: MethodChannel.Result) {
        if (hasCalendarPermission()) {
            result.success(true)
            return
        }
        if (calendarResult != null) {
            result.error("busy", "permission already asked", null)
            return
        }
        calendarResult = result
        ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.READ_CALENDAR), REQUEST_CALENDAR)
    }

    /** The visible calendars of the phone: id, name, account and colour. Read only. */
    private fun calendars(): List<Map<String, Any?>> {
        val out = ArrayList<Map<String, Any?>>()
        val projection = arrayOf(
            CalendarContract.Calendars._ID,
            CalendarContract.Calendars.CALENDAR_DISPLAY_NAME,
            CalendarContract.Calendars.ACCOUNT_NAME,
            CalendarContract.Calendars.CALENDAR_COLOR,
            CalendarContract.Calendars.VISIBLE
        )
        contentResolver.query(CalendarContract.Calendars.CONTENT_URI, projection, null, null, CalendarContract.Calendars.CALENDAR_DISPLAY_NAME)
            ?.use { c ->
                while (c.moveToNext()) {
                    if (c.getInt(4) == 0) continue
                    out.add(mapOf("id" to c.getLong(0).toString(), "name" to (c.getString(1) ?: ""), "account" to c.getString(2), "color" to c.getInt(3)))
                }
            }
        return out
    }

    /**
     * Every occurrence that starts on a day from [from] to [to] (inclusive `YYYY-MM-DD`) in the calendars [ids]. Instances.CONTENT_BY_DAY_URI
     * expands recurring events and gives each occurrence's start day as a Julian day (all-day events by their own date, not shifted by
     * the time zone). `date` is that day; `status` is the provider's (2 = cancelled). At most 5000 rows.
     */
    private fun events(ids: List<String>, from: String, to: String): List<Map<String, Any?>> {
        val out = ArrayList<Map<String, Any?>>()
        if (ids.isEmpty()) return out
        val startDay = LocalDate.parse(from).toEpochDay() + JULIAN_EPOCH
        val endDay = LocalDate.parse(to).toEpochDay() + JULIAN_EPOCH
        val uri = CalendarContract.Instances.CONTENT_BY_DAY_URI.buildUpon().appendPath(startDay.toString()).appendPath(endDay.toString()).build()
        val projection = arrayOf(
            CalendarContract.Instances.EVENT_ID,
            CalendarContract.Instances.CALENDAR_ID,
            CalendarContract.Instances.TITLE,
            CalendarContract.Instances.DESCRIPTION,
            CalendarContract.Instances.ALL_DAY,
            CalendarContract.Instances.STATUS,
            CalendarContract.Instances.START_DAY
        )
        val selection = "${CalendarContract.Instances.CALENDAR_ID} IN (${ids.joinToString(",") { "?" }})"
        contentResolver.query(uri, projection, selection, ids.toTypedArray(), CalendarContract.Instances.BEGIN)?.use { c ->
            while (c.moveToNext() && out.size < 5000) {
                val day = c.getLong(6)
                if (day < startDay || day > endDay) continue
                out.add(
                    mapOf(
                        "id" to c.getLong(0).toString(),
                        "calendarId" to c.getLong(1).toString(),
                        "title" to (c.getString(2) ?: ""),
                        "notes" to c.getString(3),
                        "allDay" to (c.getInt(4) == 1),
                        "status" to c.getInt(5),
                        "date" to LocalDate.ofEpochDay(day - JULIAN_EPOCH).toString()
                    )
                )
            }
        }
        return out
    }

    /** Runs [work] off the main thread and answers on it; any failure becomes an error with the exception type only. */
    private fun background(result: MethodChannel.Result, work: () -> Any?) {
        thread {
            try {
                val value = work()
                main.post { result.success(value) }
            } catch (e: Throwable) {
                main.post { result.error("failed", e.javaClass.simpleName, null) }
            }
        }
    }

    /** Up to [maxPages] pages as PNG at [dpi] (a point is 1/72 inch), longest side capped so a big sheet cannot exhaust memory. */
    private fun renderPdf(bytes: ByteArray, dpi: Int, maxPages: Int): List<ByteArray> {
        val file = File.createTempFile("bill", ".pdf", cacheDir)
        try {
            file.writeBytes(bytes)
            val fd = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
            val renderer = PdfRenderer(fd)
            try {
                val out = ArrayList<ByteArray>()
                val count = minOf(renderer.pageCount, maxPages)
                for (i in 0 until count) {
                    val page = renderer.openPage(i)
                    try {
                        var w = (page.width * dpi / 72.0).toInt().coerceAtLeast(1)
                        var h = (page.height * dpi / 72.0).toInt().coerceAtLeast(1)
                        val longest = maxOf(w, h)
                        if (longest > 3200) {
                            val k = 3200.0 / longest
                            w = (w * k).toInt().coerceAtLeast(1)
                            h = (h * k).toInt().coerceAtLeast(1)
                        }
                        val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
                        Canvas(bmp).drawColor(Color.WHITE)
                        page.render(bmp, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                        val png = ByteArrayOutputStream()
                        bmp.compress(Bitmap.CompressFormat.PNG, 100, png)
                        bmp.recycle()
                        out.add(png.toByteArray())
                    } finally {
                        page.close()
                    }
                }
                return out
            } finally {
                renderer.close()
                fd.close()
            }
        } finally {
            file.delete()
        }
    }

    /** The picture as a JPEG (quality 85) whose longest side is at most [maxSide], turned upright by its EXIF orientation. */
    private fun toJpeg(bytes: ByteArray, maxSide: Int): ByteArray? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= maxSide) sample *= 2
        var bmp = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, BitmapFactory.Options().apply { inSampleSize = sample }) ?: return null
        val longest = maxOf(bmp.width, bmp.height)
        if (longest > maxSide) {
            val k = maxSide.toDouble() / longest
            val scaled = Bitmap.createScaledBitmap(bmp, (bmp.width * k).toInt().coerceAtLeast(1), (bmp.height * k).toInt().coerceAtLeast(1), true)
            if (scaled != bmp) bmp.recycle()
            bmp = scaled
        }
        val degrees = try {
            when (ExifInterface(ByteArrayInputStream(bytes)).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)) {
                ExifInterface.ORIENTATION_ROTATE_90 -> 90f
                ExifInterface.ORIENTATION_ROTATE_180 -> 180f
                ExifInterface.ORIENTATION_ROTATE_270 -> 270f
                else -> 0f
            }
        } catch (e: Exception) {
            0f
        }
        if (degrees != 0f) {
            val turned = Bitmap.createBitmap(bmp, 0, 0, bmp.width, bmp.height, Matrix().apply { postRotate(degrees) }, true)
            if (turned != bmp) bmp.recycle()
            bmp = turned
        }
        val jpg = ByteArrayOutputStream()
        // A picture with transparency (PNG) gets a white background, JPEG has none.
        val flat = Bitmap.createBitmap(bmp.width, bmp.height, Bitmap.Config.ARGB_8888)
        Canvas(flat).apply {
            drawColor(Color.WHITE)
            drawBitmap(bmp, 0f, 0f, null)
        }
        flat.compress(Bitmap.CompressFormat.JPEG, 85, jpg)
        bmp.recycle()
        flat.recycle()
        return jpg.toByteArray()
    }
}
