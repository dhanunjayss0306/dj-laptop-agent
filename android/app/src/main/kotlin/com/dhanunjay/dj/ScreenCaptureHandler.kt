package com.dhanunjay.dj

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Channel: com.dhanunjay.dj/screen
 *
 * One method: captureScreen() -> {ok, png (Uint8List), width, height}.
 *
 * Uses MediaProjection: the system shows a one-time permission prompt
 * ("Start recording or casting with DJ?"). If the user declines, the call
 * returns {ok: false, message: 'screen capture permission not granted — allow
 * it in the prompt'}.
 *
 * Android 14+ rule: a foreground service of type mediaProjection must be
 * running BEFORE MediaProjection is created, so captureOnce() starts
 * MediaProjectionService first and stops it right after the capture.
 * Declared in the manifest with FOREGROUND_SERVICE_MEDIA_PROJECTION.
 *
 * v1 is one capture per call — no continuous streaming.
 */
class ScreenCaptureHandler(private val activity: MainActivity) :
    MethodChannel.MethodCallHandler {

    companion object {
        const val REQUEST_SCREEN_CAPTURE = 1001
        private const val CAPTURE_TIMEOUT_SECONDS = 4L
    }

    private var pendingResult: MethodChannel.Result? = null

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "captureScreen") {
            result.notImplemented()
            return
        }
        if (pendingResult != null) {
            result.success(
                mapOf("ok" to false, "message" to "a screen capture is already in progress")
            )
            return
        }
        pendingResult = result
        val manager = activity.getSystemService(Context.MEDIA_PROJECTION_SERVICE)
            as MediaProjectionManager
        activity.registerActivityResultHandler(REQUEST_SCREEN_CAPTURE) { resultCode, data ->
            if (resultCode != Activity.RESULT_OK || data == null) {
                finish(
                    mapOf(
                        "ok" to false,
                        "message" to "screen capture permission not granted — allow it in the prompt"
                    )
                )
                return@registerActivityResultHandler
            }
            captureOnce(manager, resultCode, data)
        }
        activity.startActivityForResult(manager.createScreenCaptureIntent(), REQUEST_SCREEN_CAPTURE)
    }

    /** Always replies on the UI thread and clears the pending result. */
    private fun finish(payload: Map<String, Any?>) {
        val pending = pendingResult
        pendingResult = null
        if (pending == null) return
        activity.runOnUiThread { pending.success(payload) }
    }

    private fun captureOnce(manager: MediaProjectionManager, resultCode: Int, data: Intent) {
        // Android 14+: the mediaProjection foreground service must be running
        // before getMediaProjection() is called.
        val serviceIntent = Intent(activity, MediaProjectionService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            activity.startForegroundService(serviceIntent)
        } else {
            activity.startService(serviceIntent)
        }

        Thread {
            var projection: MediaProjection? = null
            var virtualDisplay: VirtualDisplay? = null
            var imageReader: ImageReader? = null
            var handlerThread: HandlerThread? = null
            try {
                projection = manager.getMediaProjection(resultCode, data)
                // getMediaProjection() can return null (the system can
                // refuse the capture). Fail loudly here instead of
                // calling createVirtualDisplay on a null projection —
                // the catch below turns this into {"ok": false, ...}.
                val proj = projection
                    ?: throw IllegalStateException("could not create MediaProjection")
                val metrics = activity.resources.displayMetrics
                val width = metrics.widthPixels
                val height = metrics.heightPixels

                imageReader = ImageReader.newInstance(width, height, PixelFormat.RGBA_8888, 2)
                val latch = CountDownLatch(1)
                var bitmap: Bitmap? = null
                handlerThread = HandlerThread("dj-screen-capture").apply { start() }
                imageReader.setOnImageAvailableListener({ reader ->
                    val image = reader.acquireLatestImage()
                        ?: return@setOnImageAvailableListener
                    try {
                        bitmap = imageToBitmap(image, width, height)
                    } catch (_: Exception) {
                        // Keep waiting for the next frame.
                        return@setOnImageAvailableListener
                    } finally {
                        image.close()
                    }
                    latch.countDown()
                }, Handler(handlerThread.looper))

                virtualDisplay = proj.createVirtualDisplay(
                    "dj-capture",
                    width,
                    height,
                    metrics.densityDpi,
                    DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
                    imageReader.surface,
                    null,
                    null
                )

                val gotFrame = latch.await(CAPTURE_TIMEOUT_SECONDS, TimeUnit.SECONDS)
                val bmp = bitmap
                if (!gotFrame || bmp == null) {
                    finish(
                        mapOf(
                            "ok" to false,
                            "message" to "screen capture timed out — try again"
                        )
                    )
                } else {
                    val out = ByteArrayOutputStream()
                    bmp.compress(Bitmap.CompressFormat.PNG, 100, out)
                    bmp.recycle()
                    finish(
                        mapOf(
                            "ok" to true,
                            "png" to out.toByteArray(),
                            "width" to width,
                            "height" to height
                        )
                    )
                }
            } catch (e: Exception) {
                finish(
                    mapOf(
                        "ok" to false,
                        "message" to "screen capture failed: ${e.message}"
                    )
                )
            } finally {
                try {
                    handlerThread?.quitSafely()
                } catch (_: Exception) {
                }
                try {
                    virtualDisplay?.release()
                } catch (_: Exception) {
                }
                try {
                    imageReader?.close()
                } catch (_: Exception) {
                }
                try {
                    projection?.stop()
                } catch (_: Exception) {
                }
                activity.stopService(Intent(activity, MediaProjectionService::class.java))
            }
        }.start()
    }

    /**
     * Converts an ImageReader frame to a Bitmap. The row stride can be larger
     * than width * pixelStride, so the bitmap is created with the padded width
     * and then cropped to the real width.
     */
    private fun imageToBitmap(
        image: android.media.Image,
        width: Int,
        height: Int
    ): Bitmap {
        val plane = image.planes[0]
        val buffer = plane.buffer
        val pixelStride = plane.pixelStride
        val rowStride = plane.rowStride
        val rowPadding = rowStride - pixelStride * width
        val paddedWidth = width + rowPadding / pixelStride
        val bitmap = Bitmap.createBitmap(paddedWidth, height, Bitmap.Config.ARGB_8888)
        bitmap.copyPixelsFromBuffer(buffer)
        return if (paddedWidth == width) {
            bitmap
        } else {
            val cropped = Bitmap.createBitmap(bitmap, 0, 0, width, height)
            bitmap.recycle()
            cropped
        }
    }
}
