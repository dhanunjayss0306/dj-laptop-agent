package com.dhanunjay.dj

import android.animation.ValueAnimator
import android.app.Activity
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PixelFormat
import android.graphics.RectF
import android.os.Build
import android.provider.Settings
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.sin

/**
 * Channel: com.dhanunjay.dj/cursor
 *
 * Fake cursor overlay — the same "Clicky" idea as on Windows, but on Android
 * the real touch pointer cannot be moved by an app, so DJ draws its own
 * cursor marker in an overlay window instead.
 *
 * Methods:
 * - showCursor(x, y, label)  Draws the marker at x,y (animates in from its
 *                             current spot, or appears at once if new).
 * - moveCursor(x, y, label)   Animates the marker to x,y, updates the label.
 * - hideCursor()              Removes the overlay (and clears annotations).
 * - annotate(annotations)     Draws circles, arrows, rects and text labels
 *                             on a full-screen overlay in DJ blue. Works
 *                             even when the cursor itself is hidden.
 * - clearAnnotations()        Clears all annotations; the cursor (if
 *                             showing) stays showing.
 *
 * The overlay NEVER intercepts touches: FLAG_NOT_TOUCHABLE |
 * FLAG_NOT_FOCUSABLE. It NEVER moves the real touch pointer — it is only a
 * drawing on top of the screen.
 *
 * Requires "Display over other apps" (SYSTEM_ALERT_WINDOW). If it is not
 * granted, every call returns {ok: false, message: 'overlay permission not
 * granted — allow "Display over other apps" in Settings'}.
 *
 * DJ blue: #0071E3. The marker is a blue pointer triangle with a white label
 * bubble next to it (label shown only when non-empty).
 */
class CursorOverlayHandler(private val activity: Activity) :
    MethodChannel.MethodCallHandler {

    companion object {
        private const val DJ_BLUE = "#0071E3"
        private const val ANIMATION_MS = 250L
        private const val OVERLAY_NOT_GRANTED =
            "overlay permission not granted — allow \"Display over other apps\" in Settings"
    }

    private val windowManager =
        activity.getSystemService(Context.WINDOW_SERVICE) as WindowManager
    private var cursorView: CursorView? = null
    private var params: WindowManager.LayoutParams? = null
    private var currentX = 0
    private var currentY = 0
    private var animator: ValueAnimator? = null

    // Annotations live in their own full-screen overlay window, separate
    // from the small cursor window, so they work even when the cursor is
    // hidden. The view reads this list at draw time; annotate() replaces
    // its contents and invalidates the view.
    private val annotations = mutableListOf<Annotation>()
    private var annotationView: AnnotationView? = null
    private var annotationParams: WindowManager.LayoutParams? = null

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "showCursor" -> {
                    val x = numberArg(call, "x") ?: 0
                    val y = numberArg(call, "y") ?: 0
                    val label = call.argument<String>("label") ?: ""
                    showCursor(x, y, label, result)
                }
                "moveCursor" -> {
                    val x = numberArg(call, "x") ?: 0
                    val y = numberArg(call, "y") ?: 0
                    val label = call.argument<String>("label") ?: ""
                    moveCursor(x, y, label, result)
                }
                "hideCursor" -> {
                    hideCursor()
                    result.success(mapOf("ok" to true, "message" to "cursor hidden"))
                }
                "annotate" -> {
                    val list = parseAnnotations(call)
                    annotate(list, result)
                }
                "clearAnnotations" -> {
                    clearAnnotations()
                    result.success(mapOf("ok" to true, "message" to "annotations cleared"))
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.success(mapOf("ok" to false, "message" to (e.message ?: "unknown error")))
        }
    }

    private fun numberArg(call: MethodCall, key: String): Int? =
        (call.argument<Number>(key))?.toInt()

    private fun overlayGranted(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            Settings.canDrawOverlays(activity)
        } else {
            true
        }

    private fun showCursor(x: Int, y: Int, label: String, result: MethodChannel.Result) {
        if (showAt(x, y, label)) {
            result.success(mapOf("ok" to true, "message" to "cursor shown"))
        } else {
            result.success(mapOf("ok" to false, "message" to OVERLAY_NOT_GRANTED))
        }
    }

    private fun moveCursor(x: Int, y: Int, label: String, result: MethodChannel.Result) {
        if (showAt(x, y, label)) {
            result.success(mapOf("ok" to true, "message" to "cursor moved"))
        } else {
            result.success(mapOf("ok" to false, "message" to OVERLAY_NOT_GRANTED))
        }
    }

    /**
     * Draws [list] on the full-screen annotation overlay, in DJ blue.
     * Replaces any annotations already shown; an empty list clears them.
     * Works even when the cursor itself is hidden — the annotation window
     * is independent of the cursor window. Returns false (via [result])
     * when the overlay permission is missing.
     */
    private fun annotate(list: List<Annotation>, result: MethodChannel.Result) {
        if (!overlayGranted()) {
            result.success(mapOf("ok" to false, "message" to OVERLAY_NOT_GRANTED))
            return
        }
        annotations.clear()
        annotations.addAll(list)
        if (annotations.isEmpty()) {
            removeAnnotationWindow()
        } else {
            ensureAnnotationWindow()
            annotationView?.invalidate()
        }
        result.success(mapOf("ok" to true, "message" to "annotations drawn"))
    }

    /** Clears all annotations. A showing cursor stays showing. */
    fun clearAnnotations() {
        annotations.clear()
        removeAnnotationWindow()
    }

    /** Parses the Dart annotate() list. Unknown shapes are skipped, never fatal. */
    private fun parseAnnotations(call: MethodCall): List<Annotation> {
        val raw = call.argument<List<*>>("annotations") ?: return emptyList()
        val out = mutableListOf<Annotation>()
        for (item in raw) {
            val map = item as? Map<*, *> ?: continue
            val type = map["type"] as? String ?: continue
            fun num(key: String): Int = (map[key] as? Number)?.toInt() ?: 0
            when (type) {
                "circle" -> out.add(
                    Annotation(type = type, x = num("x"), y = num("y"), r = num("r"))
                )
                "arrow" -> out.add(
                    Annotation(
                        type = type,
                        x1 = num("x1"), y1 = num("y1"),
                        x2 = num("x2"), y2 = num("y2")
                    )
                )
                "rect" -> out.add(
                    Annotation(type = type, x = num("x"), y = num("y"), w = num("w"), h = num("h"))
                )
                "text" -> out.add(
                    Annotation(
                        type = type,
                        x = num("x"), y = num("y"),
                        text = map["text"] as? String ?: ""
                    )
                )
                else -> { /* Unknown shape: ignore it. */ }
            }
        }
        return out
    }

    /** Adds the full-screen annotation window if it is not already showing. */
    private fun ensureAnnotationWindow() {
        if (annotationView != null) return
        val view = AnnotationView(activity, annotations)
        val layoutParams = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = 0
            y = 0
        }
        try {
            windowManager.addView(view, layoutParams)
            annotationView = view
            annotationParams = layoutParams
        } catch (_: Exception) {
            // Overlay permission revoked between the check and the add.
        }
    }

    private fun removeAnnotationWindow() {
        val view = annotationView
        if (view != null) {
            try {
                windowManager.removeView(view)
            } catch (_: Exception) {
                // Already removed; ignore.
            }
        }
        annotationView = null
        annotationParams = null
    }

    /**
     * Shows the marker at (x, y), or moves it there if it is already shown.
     * Shared by the channel methods and by InputChannelHandler.moveMouse(),
     * so the Clicky flow (move cursor, then tap) works on Android too.
     * Returns false when the overlay permission is missing.
     */
    fun showAt(x: Int, y: Int, label: String): Boolean {
        if (!overlayGranted()) return false
        if (cursorView == null) {
            val view = CursorView(activity)
            val layoutParams = WindowManager.LayoutParams(
                WindowManager.LayoutParams.WRAP_CONTENT,
                WindowManager.LayoutParams.WRAP_CONTENT,
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
                WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                    WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                    WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
                PixelFormat.TRANSLUCENT
            ).apply {
                gravity = Gravity.TOP or Gravity.START
                this.x = x
                this.y = y
            }
            windowManager.addView(view, layoutParams)
            cursorView = view
            params = layoutParams
            currentX = x
            currentY = y
        }
        cursorView?.setLabel(label)
        animateTo(x, y)
        return true
    }

    /** Slides the marker from its current spot to (x, y) over ~250 ms. */
    private fun animateTo(x: Int, y: Int) {
        val view = cursorView ?: return
        val layoutParams = params ?: return
        animator?.cancel()
        val fromX = currentX
        val fromY = currentY
        val anim = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = ANIMATION_MS
            addUpdateListener { valueAnimator ->
                val fraction = valueAnimator.animatedValue as Float
                currentX = (fromX + (x - fromX) * fraction).toInt()
                currentY = (fromY + (y - fromY) * fraction).toInt()
                layoutParams.x = currentX
                layoutParams.y = currentY
                try {
                    windowManager.updateViewLayout(view, layoutParams)
                } catch (_: Exception) {
                    // View was removed mid-animation; ignore.
                }
            }
        }
        animator = anim
        anim.start()
    }

    fun hideCursor() {
        animator?.cancel()
        animator = null
        clearAnnotations()
        val view = cursorView
        if (view != null) {
            try {
                windowManager.removeView(view)
            } catch (_: Exception) {
                // Already removed; ignore.
            }
        }
        cursorView = null
        params = null
    }
}

/**
 * Draws the marker. The view's top-left corner sits exactly on the target
 * point, so the pointer tip is at the view origin and the label bubble sits
 * to its right. The view itself is transparent and never receives touches.
 */
private class CursorView(context: Context) : View(context) {

    private val density = context.resources.displayMetrics.density
    private val bluePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.parseColor("#0071E3")
        style = Paint.Style.FILL
    }
    private val outlinePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        style = Paint.Style.STROKE
        strokeWidth = 1.5f * density
    }
    private val bubblePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        style = Paint.Style.FILL
    }
    private val bubbleStrokePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.parseColor("#0071E3")
        style = Paint.Style.STROKE
        strokeWidth = 2f * density
    }
    private val textPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.parseColor("#1D1D1F")
        textSize = 14f * density
    }

    private var label: String = ""

    fun setLabel(newLabel: String) {
        if (label != newLabel) {
            label = newLabel
            invalidate()
        }
    }

    private fun dp(value: Float): Float = value * density

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        // Wide enough for a short label bubble next to the pointer.
        setMeasuredDimension(dp(420f).toInt(), dp(90f).toInt())
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        // Pointer triangle, tip at the view origin (the target point).
        val pointer = Path().apply {
            moveTo(0f, 0f)
            lineTo(0f, dp(26f))
            lineTo(dp(7f), dp(19f))
            lineTo(dp(12f), dp(30f))
            lineTo(dp(16f), dp(28f))
            lineTo(dp(11f), dp(17f))
            lineTo(dp(20f), dp(17f))
            close()
        }
        canvas.drawPath(pointer, bluePaint)
        canvas.drawPath(pointer, outlinePaint)

        if (label.isNotEmpty()) {
            val textWidth = textPaint.measureText(label)
            val bubbleHeight = dp(32f)
            val bubbleWidth = textWidth + dp(24f)
            val bubbleLeft = dp(28f)
            // Clamp the bubble inside the view so long labels do not clip.
            val maxLeft = measuredWidth - bubbleWidth - dp(4f)
            val left = minOf(bubbleLeft, maxLeft)
            val bubble = RectF(left, dp(2f), left + bubbleWidth, dp(2f) + bubbleHeight)
            canvas.drawRoundRect(bubble, dp(16f), dp(16f), bubblePaint)
            canvas.drawRoundRect(bubble, dp(16f), dp(16f), bubbleStrokePaint)
            val textY = dp(2f) + bubbleHeight / 2f -
                (textPaint.descent() + textPaint.ascent()) / 2f
            canvas.drawText(label, left + dp(12f), textY, textPaint)
        }
    }
}

/**
 * One annotation, matching the maps Dart sends in CursorChannel.annotate():
 * - circle: {type: 'circle', x, y, r}              outline circle
 * - arrow:  {type: 'arrow', x1, y1, x2, y2}        line + arrowhead
 * - rect:   {type: 'rect', x, y, w, h}             translucent fill + border
 * - text:   {type: 'text', x, y, text}             label bubble
 * Coordinates are screen pixels; (0, 0) is the top-left of the screen,
 * because the annotation window itself sits at the screen origin.
 */
private data class Annotation(
    val type: String,
    val x: Int = 0,
    val y: Int = 0,
    val r: Int = 0,
    val x1: Int = 0,
    val y1: Int = 0,
    val x2: Int = 0,
    val y2: Int = 0,
    val w: Int = 0,
    val h: Int = 0,
    val text: String = ""
)

/**
 * Full-screen transparent view that draws the annotations. It never
 * receives touches (the window is FLAG_NOT_TOUCHABLE) and never moves the
 * real pointer — it is only drawing on top of the screen, in DJ blue.
 */
private class AnnotationView(
    context: Context,
    private val annotations: List<Annotation>
) : View(context) {

    private val density = context.resources.displayMetrics.density
    private val strokePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.parseColor("#0071E3")
        style = Paint.Style.STROKE
        strokeWidth = 3f * density
        strokeCap = Paint.Cap.ROUND
    }
    private val fillPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.parseColor("#0071E3")
        alpha = 40 // ~16% opaque translucent blue fill for rects.
        style = Paint.Style.FILL
    }
    private val bubblePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        style = Paint.Style.FILL
    }
    private val bubbleStrokePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.parseColor("#0071E3")
        style = Paint.Style.STROKE
        strokeWidth = 2f * density
    }
    private val textPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.parseColor("#1D1D1F")
        textSize = 14f * density
    }

    private fun dp(value: Float): Float = value * density

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        for (annotation in annotations) {
            when (annotation.type) {
                "circle" -> canvas.drawCircle(
                    annotation.x.toFloat(),
                    annotation.y.toFloat(),
                    annotation.r.toFloat(),
                    strokePaint
                )
                "arrow" -> drawArrow(canvas, annotation)
                "rect" -> {
                    val rect = RectF(
                        annotation.x.toFloat(),
                        annotation.y.toFloat(),
                        (annotation.x + annotation.w).toFloat(),
                        (annotation.y + annotation.h).toFloat()
                    )
                    canvas.drawRect(rect, fillPaint)
                    canvas.drawRect(rect, strokePaint)
                }
                "text" -> drawTextBubble(canvas, annotation)
            }
        }
    }

    /** Line from (x1, y1) to (x2, y2) plus a two-stroke arrowhead at the tip. */
    private fun drawArrow(canvas: Canvas, annotation: Annotation) {
        val x1 = annotation.x1.toFloat()
        val y1 = annotation.y1.toFloat()
        val x2 = annotation.x2.toFloat()
        val y2 = annotation.y2.toFloat()
        canvas.drawLine(x1, y1, x2, y2, strokePaint)
        val angle = atan2(y2 - y1, x2 - x1)
        val headLength = dp(16f)
        val spread = Math.toRadians(25.0)
        for (side in listOf(angle + spread, angle - spread)) {
            canvas.drawLine(
                x2,
                y2,
                (x2 - headLength * cos(side).toFloat()),
                (y2 - headLength * sin(side).toFloat()),
                strokePaint
            )
        }
    }

    /** White label bubble with a blue border, anchored at (x, y), clamped on-screen. */
    private fun drawTextBubble(canvas: Canvas, annotation: Annotation) {
        if (annotation.text.isEmpty()) return
        val textWidth = textPaint.measureText(annotation.text)
        val bubbleHeight = dp(32f)
        val bubbleWidth = textWidth + dp(24f)
        // Clamp the bubble inside the view so long labels do not clip.
        val left = minOf(
            annotation.x.toFloat(),
            width - bubbleWidth - dp(4f)
        ).coerceAtLeast(dp(4f))
        val top = annotation.y.toFloat().coerceAtLeast(dp(4f))
        val bubble = RectF(left, top, left + bubbleWidth, top + bubbleHeight)
        canvas.drawRoundRect(bubble, dp(16f), dp(16f), bubblePaint)
        canvas.drawRoundRect(bubble, dp(16f), dp(16f), bubbleStrokePaint)
        val textY = top + bubbleHeight / 2f -
            (textPaint.descent() + textPaint.ascent()) / 2f
        canvas.drawText(annotation.text, left + dp(12f), textY, textPaint)
    }
}
