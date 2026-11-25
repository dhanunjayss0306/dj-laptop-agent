package com.dhanunjay.dj

import android.accessibilityservice.AccessibilityServiceInfo
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.provider.Settings
import android.view.accessibility.AccessibilityManager
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Channel: com.dhanunjay.dj/input
 *
 * Real input via DJAutomationService (Android AccessibilityService).
 *
 * Methods:
 * - tap(x, y)                        Tap at screen coordinates.
 * - swipe(x1, y1, x2, y2, durationMs) Swipe; durationMs optional, default 300.
 * - moveMouse(x, y)                  Android has no real mouse pointer to
 *                                    move, so this moves the FAKE cursor
 *                                    overlay to (x, y) and remembers the spot
 *                                    for click(). Needs the overlay permission.
 * - click(button)                    Taps at the last moveMouse() spot
 *                                    ('left' only; other buttons are not
 *                                    available on a touchscreen).
 * - typeText(text)                   ACTION_SET_TEXT on the focused field.
 *                                    Refused on password fields (see service).
 * - pressKey(key)                    back | escape | home | recents | alt+tab |
 *                                    notifications | quickSettings. Arbitrary
 *                                    keys (Enter, Tab, Ctrl+C, ...) cannot be
 *                                    injected on Android and return ok:false.
 * - isAccessibilityEnabled()         {ok, enabled} — true when the DJ service
 *                                    is switched on in Accessibility settings.
 * - openAccessibilitySettings()      Deep-links to Settings -> Accessibility
 *                                    so the user can enable DJ by hand.
 *
 * Every action method first checks that the service is connected. If the user
 * has not enabled it yet, the call returns:
 * {ok: false, message: 'DJ accessibility service is not enabled — enable it
 * in Settings → Accessibility → DJ'}.
 * The Dart side should then call openAccessibilitySettings() and explain the
 * one-time setup to the user.
 */
class InputChannelHandler(
    private val activity: Activity,
    private val cursorHandler: CursorOverlayHandler
) : MethodChannel.MethodCallHandler {

    companion object {
        const val SERVICE_NOT_ENABLED =
            "DJ accessibility service is not enabled — enable it in Settings → Accessibility → DJ"
    }

    /** Last spot moveMouse() put the fake cursor on; click() taps here. */
    private var lastMouseX: Int? = null
    private var lastMouseY: Int? = null

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "tap" -> {
                    val service = requireService(result) ?: return
                    val x = numberArg(call, "x") ?: 0
                    val y = numberArg(call, "y") ?: 0
                    service.tap(x, y) { ok, error ->
                        activity.runOnUiThread {
                            result.success(
                                mapOf(
                                    "ok" to ok,
                                    "message" to if (ok) "tapped ($x, $y)" else (error ?: "tap failed")
                                )
                            )
                        }
                    }
                }
                "swipe" -> {
                    val service = requireService(result) ?: return
                    val x1 = numberArg(call, "x1") ?: 0
                    val y1 = numberArg(call, "y1") ?: 0
                    val x2 = numberArg(call, "x2") ?: 0
                    val y2 = numberArg(call, "y2") ?: 0
                    val durationMs = (numberArg(call, "durationMs") ?: 300).toLong()
                    service.swipe(x1, y1, x2, y2, durationMs) { ok, error ->
                        activity.runOnUiThread {
                            result.success(
                                mapOf(
                                    "ok" to ok,
                                    "message" to if (ok) "swiped ($x1, $y1) to ($x2, $y2)" else (error ?: "swipe failed")
                                )
                            )
                        }
                    }
                }
                "typeText" -> {
                    val service = requireService(result) ?: return
                    val text = call.argument<String>("text") ?: ""
                    if (text.isEmpty()) {
                        return result.success(
                            mapOf("ok" to false, "message" to "nothing to type")
                        )
                    }
                    result.success(service.typeText(text))
                }
                "moveMouse" -> {
                    // No real pointer on Android: move the fake cursor overlay
                    // instead, and remember the spot for click().
                    val x = numberArg(call, "x") ?: 0
                    val y = numberArg(call, "y") ?: 0
                    val shown = cursorHandler.showAt(x, y, "")
                    if (shown) {
                        lastMouseX = x
                        lastMouseY = y
                        result.success(
                            mapOf("ok" to true, "message" to "cursor moved to ($x, $y)")
                        )
                    } else {
                        result.success(
                            mapOf(
                                "ok" to false,
                                "message" to "overlay permission not granted — allow \"Display over other apps\" in Settings"
                            )
                        )
                    }
                }
                "click" -> {
                    val service = requireService(result) ?: return
                    val button = (call.argument<String>("button") ?: "left").lowercase()
                    if (button != "left") {
                        return result.success(
                            mapOf(
                                "ok" to false,
                                "message" to "only a left tap is available on a touchscreen"
                            )
                        )
                    }
                    val x = lastMouseX
                    val y = lastMouseY
                    if (x == null || y == null) {
                        return result.success(
                            mapOf(
                                "ok" to false,
                                "message" to "move the cursor first (moveMouse) so DJ knows where to tap"
                            )
                        )
                    }
                    service.tap(x, y) { ok, error ->
                        activity.runOnUiThread {
                            result.success(
                                mapOf(
                                    "ok" to ok,
                                    "message" to if (ok) "tapped ($x, $y)" else (error ?: "tap failed")
                                )
                            )
                        }
                    }
                }
                "pressKey" -> {
                    val service = requireService(result) ?: return
                    val key = (call.argument<String>("key") ?: "").trim()
                    if (key.isEmpty()) {
                        return result.success(
                            mapOf("ok" to false, "message" to "no key given")
                        )
                    }
                    val done = service.pressKey(key)
                    result.success(
                        mapOf(
                            "ok" to done,
                            "message" to if (done) {
                                "pressed $key"
                            } else {
                                "key '$key' is not available on Android — supported: back, escape, home, recents, alt+tab, notifications, quickSettings"
                            }
                        )
                    )
                }
                "isAccessibilityEnabled" -> {
                    result.success(
                        mapOf("ok" to true, "enabled" to isServiceEnabled())
                    )
                }
                "openAccessibilitySettings" -> {
                    val intent = Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).apply {
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                    activity.startActivity(intent)
                    result.success(
                        mapOf(
                            "ok" to true,
                            "message" to "opened Accessibility settings — turn on DJ"
                        )
                    )
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.success(mapOf("ok" to false, "message" to (e.message ?: "unknown error")))
        }
    }

    private fun numberArg(call: MethodCall, key: String): Int? =
        (call.argument<Number>(key))?.toInt()

    /** Returns the live service, or replies with the not-enabled message. */
    private fun requireService(result: MethodChannel.Result): DJAutomationService? {
        val service = DJAutomationService.instance
        if (service == null) {
            result.success(mapOf("ok" to false, "message" to SERVICE_NOT_ENABLED))
            return null
        }
        return service
    }

    /**
     * True when the DJ service is switched on. The live connection is the
     * strongest signal; the system settings list covers the case where the
     * service is enabled but this process has not (re)connected yet.
     */
    private fun isServiceEnabled(): Boolean {
        if (DJAutomationService.isConnected) return true
        val am = activity.getSystemService(Context.ACCESSIBILITY_SERVICE) as AccessibilityManager
        val enabled = am.getEnabledAccessibilityServiceList(
            AccessibilityServiceInfo.FEEDBACK_GENERIC
        )
        val serviceClass = DJAutomationService::class.java.name
        if (enabled.any { it.resolveInfo.serviceInfo.name == serviceClass }) return true
        // Fallback: the raw secure-settings list.
        val list = Settings.Secure.getString(
            activity.contentResolver,
            Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
        ) ?: return false
        return list.contains(serviceClass)
    }
}
