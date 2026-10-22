package hr.marcelic.budget_wallet

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.pdf.PdfRenderer
import android.media.ExifInterface
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import kotlin.concurrent.thread

/**
 * Two tiny channels: the time zone name (for reminders), and the bills helpers (no PDF package): `renderPdf` draws the pages of a
 * PDF with the platform's PdfRenderer and `toJpeg` sizes a picture down. Both run on a background thread.
 */
class MainActivity : FlutterActivity() {
    private val main = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "budget_wallet/timezone").setMethodCallHandler { call, result ->
            when (call.method) {
                "getTimeZone" -> result.success(java.util.TimeZone.getDefault().id)
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
                else -> result.notImplemented()
            }
        }
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
