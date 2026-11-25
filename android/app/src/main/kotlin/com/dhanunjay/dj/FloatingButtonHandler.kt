package com.dhanunjay.dj

import android.app.Activity
import android.app.Application
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlin.math.abs
import kotlin.math.max

/**
 * Channel: com.dhanunjay.dj/floatingbutton
 *
 * Floating DJ button — Android has no global hotkey, so this is the
 * Android equivalent: a small draggable blue circle with "DJ" text that
 * floats over other apps. Tapping it fires 'onHotkeyPressed' on the
 * HOTKEY channel (com.dhanunjay.dj/hotkey) — the same event the Windows
 * global hotkey feeds — so the Dart [HotkeyChannel.onHotkeyPressed] stream
 * just works, with no extra Dart wiring.
 *
 * Methods (this channel only manages visibility):
 * - showFloatingButton()            Show the button (see foreground rule).
 * - hideFloatingButton()            Hide it.
 * - setFloatingButtonVisible(bool)  Show/hide by flag.
 *
 * The button uses the SAME overlay window mechanism as the cursor overlay
 * (CursorOverlayHandler): a TYPE_APPLICATION_OVERLAY window, needing
 * "Display over other apps" (SYSTEM_ALERT_WINDOW). Without it every call
 * returns {ok: false, message: 'overlay permission not granted — allow
 * "Display over other apps" in Settings'}.
 *
 * Touch behaviour: the window is only as big as the button itself
 * (WRAP_CONTENT, ~56 dp), so touches anywhere else on screen pass
 * through to the app underneath — the button never blocks other touches.
 * Touch-drag moves it; a tap (down + up with < 10 dp of movement) fires
 * the hotkey event. The position is clamped to the screen.
 *
 * Foreground rule (implemented): the button is hidden while DJ's own app
 * is in the foreground — there is no point showing it over DJ itself.
 * Dart calls showFloatingButton() once (e.g. at startup); the handler
 * remembers the request and shows the button automatically whenever DJ
 * goes to the background, and hides it again when DJ comes back.
 * Tracked with Application.ActivityLifecycleCallbacks, so it works no
 * matter which DJ activity is on top.
 *
 * DJ blue: #0071E3.
 */
class FloatingButtonHandler(
    private val activity: Activity,
    messenger: BinaryMessenger
) : MethodChannel.MethodCallHandler {

    companion object {
        private const val DJ_BLUE = "#0071E3"
        private const val BUTTON_SIZE_DP = 56f
        private const val TAP_SLOP_DP = 10f
        private const val EDGE_MARGIN_DP = 16f
        private const val OVERLAY_NOT_GRANTED =
            "overlay permission not granted — allow \"Display over other apps\" in Settings"
    }

    /** Tap target: the hotkey channel — a tap IS a hotkey press. */
    private val hotkeyChannel = MethodChannel(messenger, "com.dhanunjay.dj/hotkey")

    private val windowManager =
        activity.getSystemService(Context.WINDOW_SERVICE) as WindowManager
    private val density = activity.resources.displayMetrics.density

    private var buttonView: View? = null
    private var params: WindowManager.LayoutParams? = null

    /** What Dart last asked for. The button only actually shows while DJ is backgrounded. */
    private var requestedVisible = false

    /** Number of DJ activities currently resumed (0 = DJ is in the background). */
    private var resumedActivities = 0

    private val lifecycleCallbacks = object : Application.ActivityLifecycleCallbacks {
        override fun onActivityResumed(resumed: Activity) {
            resumedActivities++
            updateVisibility()
        }

        override fun onActivityPaused(paused: Activity) {
            resumedActivities = max(0, resumedActivities - 1)
            updateVisibility()
        }

        override fun onActivityCreated(created: Activity, savedInstanceState: Bundle?) {}
        override fun onActivityStarted(started: Activity) {}
        override fun onActivityStopped(stopped: Activity) {}
        override fun onActivitySaveInstanceState(outStateActivity: Activity, outState: Bundle) {}
        override fun onActivityDestroyed(destroyed: Activity) {}
    }

    init {
        activity.application.registerActivityLifecycleCallbacks(lifecycleCallbacks)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "showFloatingButton" -> {
                    if (!overlayGranted()) {
                        result.success(mapOf("ok" to false, "message" to OVERLAY_NOT_GRANTED))
                        return
                    }
                    requestedVisible = true
                    updateVisibility()
                    val message = if (resumedActivities == 0) {
                        "floating button shown"
                    } else {
                        "floating button will show when DJ is in the background"
                    }
                    result.success(mapOf("ok" to true, "message" to message))
                }
                "hideFloatingButton" -> {
                    requestedVisible = false
                    removeButton()
                    result.success(mapOf("ok" to true, "message" to "floating button hidden"))
                }
                "setFloatingButtonVisible" -> {
                    val visible = call.argument<Boolean>("visible") ?: false
                    if (!visible) {
                        requestedVisible = false
                        removeButton()
                        result.success(
                            mapOf("ok" to true, "message" to "floating button hidden")
                        )
                    } else if (!overlayGranted()) {
                        result.success(mapOf("ok" to false, "message" to OVERLAY_NOT_GRANTED))
                    } else {
                        requestedVisible = true
                        updateVisibility()
                        result.success(mapOf("ok" to true, "message" to "floating button shown"))
                    }
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.success(mapOf("ok" to false, "message" to (e.message ?: "unknown error")))
        }
    }

    private fun overlayGranted(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            Settings.canDrawOverlays(activity)
        } else {
            true
        }

    /**
     * Adds the button if DJ is backgrounded and it was requested, removes
     * it otherwise. Called on every show/hide request and on every
     * foreground/background transition.
     */
    private fun updateVisibility() {
        if (requestedVisible && resumedActivities == 0) {
            if (buttonView == null && overlayGranted()) {
                addButton()
            }
        } else {
            removeButton()
        }
    }

    private fun addButton() {
        val view = FloatingButtonView(activity)
        view.setOnTouchListener(makeTouchListener())
        val metrics = activity.resources.displayMetrics
        val sizePx = (BUTTON_SIZE_DP * density).toInt()
        val marginPx = (EDGE_MARGIN_DP * density).toInt()
        val layoutParams = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            // TouchABLE on purpose (its own small area only) but never
            // focusable, so it cannot steal the keyboard or focus.
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            // Default spot: right edge, about a third down the screen.
            x = metrics.widthPixels - sizePx - marginPx
            y = metrics.heightPixels / 3
        }
        try {
            windowManager.addView(view, layoutParams)
            buttonView = view
            params = layoutParams
        } catch (_: Exception) {
            // Overlay permission revoked between the check and the add.
        }
    }

    private fun removeButton() {
        val view = buttonView
        if (view != null) {
            try {
                windowManager.removeView(view)
            } catch (_: Exception) {
                // Already removed; ignore.
            }
        }
        buttonView = null
        params = null
    }

    /** Drag moves the button; a tap (no real movement) fires the hotkey event. */
    private fun makeTouchListener(): View.OnTouchListener {
        var downRawX = 0f
        var downRawY = 0f
        var downParamsX = 0
        var downParamsY = 0
        var moved = false
        val slopPx = TAP_SLOP_DP * density
        return View.OnTouchListener { _, event ->
            when (event.action) {
                MotionEvent.ACTION_DOWN -> {
                    downRawX = event.rawX
                    downRawY = event.rawY
                    downParamsX = params?.x ?: 0
                    downParamsY = params?.y ?: 0
                    moved = false
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = (event.rawX - downRawX).toInt()
                    val dy = (event.rawY - downRawY).toInt()
                    if (!moved && (abs(dx) > slopPx || abs(dy) > slopPx)) {
                        moved = true
                    }
                    if (moved) {
                        val layoutParams = params
                        val view = buttonView
                        if (layoutParams != null && view != null) {
                            layoutParams.x = clampX(downParamsX + dx)
                            layoutParams.y = clampY(downParamsY + dy)
                            try {
                                windowManager.updateViewLayout(view, layoutParams)
                            } catch (_: Exception) {
                                // View was removed mid-drag; ignore.
                            }
                        }
                    }
                    true
                }
                MotionEvent.ACTION_UP -> {
                    if (!moved) {
                        // Tap: fire the hotkey event Dart already listens for.
                        try {
                            hotkeyChannel.invokeMethod("onHotkeyPressed", null)
                        } catch (_: Exception) {
                            // Dart side not listening (yet); nothing to do.
                        }
                    }
                    true
                }
                MotionEvent.ACTION_CANCEL -> true
                else -> false
            }
        }
    }

    private fun clampX(x: Int): Int {
        val width = activity.resources.displayMetrics.widthPixels
        val sizePx = (BUTTON_SIZE_DP * density).toInt()
        return x.coerceIn(0, max(0, width - sizePx))
    }

    private fun clampY(y: Int): Int {
        val height = activity.resources.displayMetrics.heightPixels
        val sizePx = (BUTTON_SIZE_DP * density).toInt()
        return y.coerceIn(0, max(0, height - sizePx))
    }

    /** Removes the button and stops tracking the foreground state. Call from MainActivity.onDestroy. */
    fun release() {
        try {
            activity.application.unregisterActivityLifecycleCallbacks(lifecycleCallbacks)
        } catch (_: Exception) {
            // Never registered or already unregistered; ignore.
        }
        requestedVisible = false
        removeButton()
    }
}

/** Blue circle with white "DJ" text. The view is exactly button-sized, so only its own area is touchable. */
private class FloatingButtonView(context: Context) : View(context) {

    private val density = context.resources.displayMetrics.density
    private val circlePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.parseColor("#0071E3")
        style = Paint.Style.FILL
    }
    private val outlinePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        style = Paint.Style.STROKE
        strokeWidth = 2f * density
    }
    private val textPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        textSize = 20f * density
        typeface = Typeface.DEFAULT_BOLD
        textAlign = Paint.Align.CENTER
    }

    private fun dp(value: Float): Float = value * density

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        setMeasuredDimension(dp(56f).toInt(), dp(56f).toInt())
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val cx = width / 2f
        val cy = height / 2f
        val radius = minOf(width, height) / 2f - dp(1f)
        canvas.drawCircle(cx, cy, radius, circlePaint)
        canvas.drawCircle(cx, cy, radius, outlinePaint)
        val textY = cy - (textPaint.descent() + textPaint.ascent()) / 2f
        canvas.drawText("DJ", cx, textY, textPaint)
    }
}
