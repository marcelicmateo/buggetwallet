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
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
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
import kotlin.concurrent.thread

/**
 * Three tiny channels: `bw/secure` (FLAG_SECURE while the wallet key is shown), the time zone name (for reminders), and the bills helpers (no PDF package): `renderPdf` draws the pages of a
 * PDF with the platform's PdfRenderer, `toJpeg` sizes a picture down (both on a background thread) and `takePhoto` lets the
 * phone's own camera app take one full-size picture into the app's cache (returns its path; null when cancelled).
 */
class MainActivity : FlutterActivity() {
    private val main = Handler(Looper.getMainLooper())

    /** The `takePhoto` call that is waiting for the permission or for the camera app, and the file the camera writes. */
    private var photoResult: MethodChannel.Result? = null
    private var photoFile: File? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // A picture left behind when Android killed the app while the camera app was open (its path was lost with it).
        clearBillPhotos()
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
        if (requestCode == REQUEST_PERMISSION && photoResult != null) {
            if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) launchCamera() else finishPhoto(null, "permission")
            return
        }
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    companion object {
        private const val REQUEST_PHOTO = 7301
        private const val REQUEST_PERMISSION = 7302
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
