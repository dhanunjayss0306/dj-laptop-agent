package com.dhanunjay.dj

import android.animation.ValueAnimator
import android.app.Activity
import android.app.Application
import android.content.Context
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.text.TextUtils
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.view.animation.AccelerateDecelerateInterpolator
import android.widget.LinearLayout
import android.widget.TextView
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlin.math.abs
import kotlin.math.max

/**
 * Channel: com.dhanunjay.dj/floatingbutton
 *
 * iOS-style Dynamic Island pill for Android: floats near the top cutout
 * over other apps. Tapping it fires 'onHotkeyPressed' on the hotkey
 * channel; calling setIslandState(state, text) expands it smoothly to
 * display live listening transcripts, thinking status, or streaming "fake
 * lyrics" captions with an '✕' cancel button ('onCancelPressed').
 */
class FloatingButtonHandler(
    private val activity: Activity,
    messenger: BinaryMessenger
) : MethodChannel.MethodCallHandler {

    companion object {
        private const val DJ_BLUE = "#0071E3"
        private const val IDLE_WIDTH_DP = 112f
        private const val IDLE_HEIGHT_DP = 36f
        private const val ACTIVE_WIDTH_DP = 310f
        private const val RESPONDING_HEIGHT_DP = 96f
        private const val ACTIVE_HEIGHT_DP = 48f
        private const val TAP_SLOP_DP = 10f
        private const val TOP_MARGIN_DP = 10f
        private const val OVERLAY_NOT_GRANTED =
            "overlay permission not granted — allow \"Display over other apps\" in Settings"
    }

    /** Tap target: the hotkey channel — a tap IS a hotkey press. */
    private val hotkeyChannel = MethodChannel(messenger, "com.dhanunjay.dj/hotkey")

    private val windowManager =
        activity.getSystemService(Context.WINDOW_SERVICE) as WindowManager
    private val density = activity.resources.displayMetrics.density

    private var islandView: LinearLayout? = null
    private var dotView: View? = null
    private var labelView: TextView? = null
    private var cancelView: TextView? = null
    private var params: WindowManager.LayoutParams? = null
    private var sizeAnimator: ValueAnimator? = null

    private var islandState = "idle"
    private var islandText = ""

    /** What Dart last asked for. The pill only shows while DJ is backgrounded. */
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
                "setIslandState" -> {
                    val state = call.argument<String>("state") ?: "idle"
                    val text = call.argument<String>("text") ?: ""
                    islandState = state
                    islandText = text
                    applyIslandState()
                    result.success(mapOf("ok" to true, "message" to "island updated"))
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

    private fun dp(value: Float): Int = (value * density).toInt()

    private fun updateVisibility() {
        if (requestedVisible && resumedActivities == 0) {
            if (islandView == null && overlayGranted()) {
                addButton()
            }
        } else {
            removeButton()
        }
    }

    private fun addButton() {
        val pill = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(12f), dp(6f), dp(12f), dp(6f))
            background = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                cornerRadius = dp(24f).toFloat()
                setColor(Color.parseColor("#111114"))
                setStroke(dp(1.2f), Color.parseColor(DJ_BLUE))
            }
        }

        val dot = View(activity).apply {
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(Color.parseColor(DJ_BLUE))
            }
        }
        val dotLp = LinearLayout.LayoutParams(dp(9f), dp(9f)).apply {
            marginEnd = dp(8f)
        }
        pill.addView(dot, dotLp)

        val label = TextView(activity).apply {
            text = "DJ"
            setTextColor(Color.WHITE)
            textSize = 13f
            typeface = Typeface.DEFAULT_BOLD
            maxLines = 3
            ellipsize = TextUtils.TruncateAt.END
        }
        val labelLp = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        pill.addView(label, labelLp)

        val cancel = TextView(activity).apply {
            text = "✕"
            setTextColor(Color.parseColor("#B0B0B8"))
            textSize = 13f
            setPadding(dp(8f), dp(2f), dp(2f), dp(2f))
            visibility = View.GONE
            setOnClickListener {
                try {
                    hotkeyChannel.invokeMethod("onCancelPressed", null)
                } catch (_: Exception) {}
            }
        }
        pill.addView(cancel)

        pill.setOnTouchListener(makeTouchListener())

        val metrics = activity.resources.displayMetrics
        val initW = dp(IDLE_WIDTH_DP)
        val initH = dp(IDLE_HEIGHT_DP)
        val layoutParams = WindowManager.LayoutParams(
            initW,
            initH,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = (metrics.widthPixels - initW) / 2
            y = dp(TOP_MARGIN_DP)
        }
        try {
            windowManager.addView(pill, layoutParams)
            islandView = pill
            dotView = dot
            labelView = label
            cancelView = cancel
            params = layoutParams
            applyIslandState()
        } catch (_: Exception) {
            // Overlay permission revoked between check and add.
        }
    }

    private fun applyIslandState() {
        val pill = islandView ?: return
        val label = labelView ?: return
        val dot = dotView ?: return
        val cancel = cancelView ?: return
        val layoutParams = params ?: return

        val isIdle = islandState == "idle" || islandState == "hidden"
        val dotColor = when (islandState) {
            "listening" -> "#22C55E"
            "thinking" -> "#A78BFA"
            "responding" -> DJ_BLUE
            else -> DJ_BLUE
        }
        (dot.background as? GradientDrawable)?.setColor(Color.parseColor(dotColor))
        cancel.visibility = if (isIdle) View.GONE else View.VISIBLE

        label.text = when {
            islandText.isNotBlank() -> islandText
            islandState == "listening" -> "Listening..."
            islandState == "thinking" -> "Thinking..."
            islandState == "responding" -> "DJ"
            else -> "DJ"
        }

        val targetW = dp(if (isIdle) IDLE_WIDTH_DP else ACTIVE_WIDTH_DP)
        val targetH = dp(
            when {
                isIdle -> IDLE_HEIGHT_DP
                islandState == "responding" && islandText.length > 48 -> RESPONDING_HEIGHT_DP
                else -> ACTIVE_HEIGHT_DP
            }
        )
        val startW = layoutParams.width
        val startH = layoutParams.height
        val centerX = layoutParams.x + startW / 2
        if (startW == targetW && startH == targetH) return

        sizeAnimator?.cancel()
        sizeAnimator = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = 220L
            interpolator = AccelerateDecelerateInterpolator()
            addUpdateListener { anim ->
                val f = anim.animatedValue as Float
                val w = (startW + (targetW - startW) * f).toInt()
                val h = (startH + (targetH - startH) * f).toInt()
                layoutParams.width = w
                layoutParams.height = h
                layoutParams.x = clampX(centerX - w / 2, w)
                try {
                    windowManager.updateViewLayout(pill, layoutParams)
                } catch (_: Exception) {}
            }
            start()
        }
    }

    private fun removeButton() {
        sizeAnimator?.cancel()
        sizeAnimator = null
        val view = islandView
        if (view != null) {
            try {
                windowManager.removeView(view)
            } catch (_: Exception) {
                // Already removed; ignore.
            }
        }
        islandView = null
        dotView = null
        labelView = null
        cancelView = null
        params = null
    }

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
                        val view = islandView
                        if (layoutParams != null && view != null) {
                            layoutParams.x = clampX(downParamsX + dx, layoutParams.width)
                            layoutParams.y = clampY(downParamsY + dy, layoutParams.height)
                            try {
                                windowManager.updateViewLayout(view, layoutParams)
                            } catch (_: Exception) {}
                        }
                    }
                    true
                }
                MotionEvent.ACTION_UP -> {
                    if (!moved) {
                        try {
                            hotkeyChannel.invokeMethod("onHotkeyPressed", null)
                        } catch (_: Exception) {}
                    }
                    true
                }
                MotionEvent.ACTION_CANCEL -> true
                else -> false
            }
        }
    }

    private fun clampX(x: Int, widthPx: Int): Int {
        val width = activity.resources.displayMetrics.widthPixels
        return x.coerceIn(0, max(0, width - widthPx))
    }

    private fun clampY(y: Int, heightPx: Int): Int {
        val height = activity.resources.displayMetrics.heightPixels
        return y.coerceIn(0, max(0, height - heightPx))
    }

    /** Removes the pill and stops tracking foreground state. Call from MainActivity.onDestroy. */
    fun release() {
        try {
            activity.application.unregisterActivityLifecycleCallbacks(lifecycleCallbacks)
        } catch (_: Exception) {}
        requestedVisible = false
        removeButton()
    }
}
