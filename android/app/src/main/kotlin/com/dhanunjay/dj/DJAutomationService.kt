package com.dhanunjay.dj

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.graphics.Path
import android.os.Bundle
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

/**
 * DJAutomationService — real input on Android, like Tapr (HeyClickyMobile).
 *
 * The user must enable it by hand in Settings -> Accessibility -> DJ.
 * Declared in AndroidManifest.xml with BIND_ACCESSIBILITY_SERVICE and
 * configured in res/xml/accessibility_service_config.xml.
 *
 * SAFETY — these rules are enforced here, not only on the Dart side:
 * 1. The service NEVER acts on its own. It only runs a gesture / key / type
 *    when the Dart side explicitly calls it through the input channel, while
 *    a DJ task is in progress. There is no watcher, no auto-trigger, no
 *    background loop in this service.
 * 2. typeText() NEVER types into a password field: if the focused node
 *    isPassword(), the call is refused and nothing is typed.
 * 3. The service never reads screen contents for any other purpose and never
 *    sends anything anywhere — it only performs the one requested action.
 *
 * All work happens through the static [instance] set in onServiceConnected();
 * InputChannelHandler checks [isConnected] first and reports a clear
 * "not enabled" message when the service is off.
 */
class DJAutomationService : AccessibilityService() {

    companion object {
        var instance: DJAutomationService? = null
            private set

        val isConnected: Boolean
            get() = instance != null
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // DJ does not listen to screen events. It only acts on explicit calls.
    }

    override fun onInterrupt() {
        // Nothing to clean up — gestures are one-shot.
    }

    override fun onDestroy() {
        instance = null
        super.onDestroy()
    }

    /** Single tap at (x, y). Gesture callbacks report success / cancellation. */
    fun tap(x: Int, y: Int, callback: (Boolean, String?) -> Unit) {
        val path = Path().apply { moveTo(x.toFloat(), y.toFloat()) }
        val gesture = GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path, 0L, 80L))
            .build()
        dispatchGesture(gesture, gestureCallback(callback), null)
    }

    /** Swipe from (x1, y1) to (x2, y2) over [durationMs] (default 300 ms). */
    fun swipe(x1: Int, y1: Int, x2: Int, y2: Int, durationMs: Long, callback: (Boolean, String?) -> Unit) {
        val path = Path().apply {
            moveTo(x1.toFloat(), y1.toFloat())
            lineTo(x2.toFloat(), y2.toFloat())
        }
        val gesture = GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path, 0L, durationMs))
            .build()
        dispatchGesture(gesture, gestureCallback(callback), null)
    }

    /**
     * Types [text] into the currently focused editable field via ACTION_SET_TEXT.
     * Returns {ok, message}. Refuses when the focused node is a password field,
     * when nothing is focused, or when the focused node is not editable.
     */
    fun typeText(text: String): Map<String, Any?> {
        val root = rootInActiveWindow
            ?: return mapOf("ok" to false, "message" to "no active window to type into")
        val node = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
            ?: root.findFocus(AccessibilityNodeInfo.FOCUS_ACCESSIBILITY)
            ?: return mapOf("ok" to false, "message" to "no text field is focused")
        // SAFETY: never type passwords.
        if (node.isPassword) {
            return mapOf("ok" to false, "message" to "refusing to type into a password field")
        }
        if (!node.isEditable) {
            return mapOf("ok" to false, "message" to "the focused field is not editable")
        }
        val args = Bundle().apply {
            putCharSequence(
                AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,
                text
            )
        }
        val done = node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
        return if (done) {
            mapOf("ok" to true, "message" to "typed text")
        } else {
            mapOf("ok" to false, "message" to "could not type into the focused field")
        }
    }

    /**
     * System keys. [key] is one of: back, home, recents, notifications,
     * quickSettings. Returns false for anything else.
     */
    fun pressKey(key: String): Boolean {
        val action = when (key.lowercase()) {
            "back", "escape", "esc" -> GLOBAL_ACTION_BACK
            "home" -> GLOBAL_ACTION_HOME
            "recents", "alt+tab", "alttab" -> GLOBAL_ACTION_RECENTS
            "notifications" -> GLOBAL_ACTION_NOTIFICATIONS
            "quicksettings", "quick_settings" -> GLOBAL_ACTION_QUICK_SETTINGS
            // NOTE: Android's AccessibilityService cannot inject arbitrary
            // keys (Enter, Tab, Ctrl+C, ...). Those return false here; the
            // Dart side should use typeText() for text entry instead.
            else -> return false
        }
        return performGlobalAction(action)
    }

    private fun gestureCallback(callback: (Boolean, String?) -> Unit) =
        object : GestureResultCallback() {
            override fun onCompleted(gestureDescription: GestureDescription?) {
                callback(true, null)
            }

            override fun onCancelled(gestureDescription: GestureDescription?) {
                callback(false, "gesture was cancelled")
            }
        }
}
