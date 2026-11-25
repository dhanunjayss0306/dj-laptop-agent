package com.dhanunjay.dj

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * DJ Android runner. Registers the six MethodChannels the Dart side calls.
 * Channel names are identical to the Windows side so one Dart implementation
 * (lib/platform/system_ops_channel.dart) serves both platforms.
 *
 * Channels:
 * - com.dhanunjay.dj/system  -> SystemChannelHandler (files, apps, trash, stats)
 * - com.dhanunjay.dj/screen  -> ScreenCaptureHandler (one-shot MediaProjection capture)
 * - com.dhanunjay.dj/cursor  -> CursorOverlayHandler (fake cursor overlay + annotations)
 * - com.dhanunjay.dj/floatingbutton -> FloatingButtonHandler (draggable DJ button;
 *   tap fires 'onHotkeyPressed' on the hotkey channel, like the Windows hotkey)
 * - com.dhanunjay.dj/input   -> InputChannelHandler (AccessibilityService real input)
 * - com.dhanunjay.dj/voice   -> VoiceChannelHandler (SpeechRecognizer STT + TTS)
 *
 * Handlers that need startActivityForResult (screen capture permission,
 * Storage Access Framework folder picker) register a one-shot callback here
 * via [registerActivityResultHandler]; MainActivity dispatches onActivityResult
 * to it. No commit, no push, no token is used anywhere in this runner.
 */
class MainActivity : FlutterActivity() {

    private val activityResultHandlers = mutableMapOf<Int, (Int, Intent?) -> Unit>()

    private lateinit var voiceHandler: VoiceChannelHandler
    private lateinit var cursorHandler: CursorOverlayHandler
    private lateinit var floatingButtonHandler: FloatingButtonHandler

    /** One-shot onActivityResult callback for [requestCode]. Removed after it fires. */
    fun registerActivityResultHandler(requestCode: Int, handler: (Int, Intent?) -> Unit) {
        activityResultHandlers[requestCode] = handler
    }

    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        val handler = activityResultHandlers.remove(requestCode)
        if (handler != null) {
            handler(resultCode, data)
        } else {
            super.onActivityResult(requestCode, resultCode, data)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        MethodChannel(messenger, "com.dhanunjay.dj/system")
            .setMethodCallHandler(SystemChannelHandler(this))

        MethodChannel(messenger, "com.dhanunjay.dj/screen")
            .setMethodCallHandler(ScreenCaptureHandler(this))

        cursorHandler = CursorOverlayHandler(this)
        MethodChannel(messenger, "com.dhanunjay.dj/cursor")
            .setMethodCallHandler(cursorHandler)

        floatingButtonHandler = FloatingButtonHandler(this, messenger)
        MethodChannel(messenger, "com.dhanunjay.dj/floatingbutton")
            .setMethodCallHandler(floatingButtonHandler)

        MethodChannel(messenger, "com.dhanunjay.dj/input")
            .setMethodCallHandler(InputChannelHandler(this, cursorHandler))

        voiceHandler = VoiceChannelHandler(this, messenger)
        MethodChannel(messenger, "com.dhanunjay.dj/voice")
            .setMethodCallHandler(voiceHandler)
    }

    override fun onDestroy() {
        if (::voiceHandler.isInitialized) voiceHandler.release()
        if (::cursorHandler.isInitialized) cursorHandler.hideCursor()
        if (::floatingButtonHandler.isInitialized) floatingButtonHandler.release()
        super.onDestroy()
    }
}
