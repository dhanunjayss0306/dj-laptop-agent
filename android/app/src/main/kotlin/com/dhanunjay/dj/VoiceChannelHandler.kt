package com.dhanunjay.dj

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.Bundle
import android.util.Base64
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.speech.tts.TextToSpeech
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

/**
 * Channel: com.dhanunjay.dj/voice
 *
 * Voice input and output with Android's built-in engines — free, no model
 * download, no API key. Both work offline when the device has its on-device
 * recognizer / voice pack (modern Android phones, including the Galaxy S24 FE,
 * do); if the device falls back to a server recognizer, that is the OS's own
 * behaviour, not a DJ cloud call.
 *
 * STT — SpeechRecognizer (method startListening / stopListening):
 * - Language en-IN, device default as fallback (see buildListenIntent).
 * - Partial results stream back as channel events: onPartialResult {text}.
 * - The final result arrives as onFinalResult {text}; errors as
 *   onSpeechError {error, message}; lifecycle as onListeningStarted /
 *   onListeningStopped. The startListening() call itself returns {ok, message}
 *   only — results come through those events.
 * - Needs RECORD_AUDIO. If it is not granted yet, startListening() asks for
 *   it and returns {ok: false, message: 'microphone permission requested —
 *   call startListening again once it is granted'}.
 *
 * TTS — TextToSpeech (method speak / stopSpeaking, alias stopSpeak):
 * - speak(text) speaks with the system TTS voice, offline when a voice pack
 *   is installed. Language en-IN first, device default as fallback.
 *
 * Cloud streaming STT (AssemblyAI etc.) is a Cloud-layer option only and is
 * NOT part of Core — nothing here calls any network speech service.
 */
class VoiceChannelHandler(
    private val activity: Activity,
    messenger: BinaryMessenger
) : MethodChannel.MethodCallHandler {

    companion object {
        private const val REQUEST_RECORD_AUDIO = 2001
    }

    /** Same channel, used to push speech events back to Dart. */
    private val eventChannel = MethodChannel(messenger, "com.dhanunjay.dj/voice")

    private var recognizer: SpeechRecognizer? = null
    private var listening = false

    private var tts: TextToSpeech? = null
    private var ttsReady = false
    private var pendingSpeak: String? = null
    private var activeTrack: AudioTrack? = null

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "startListening" -> startListening(result)
                "stopListening" -> {
                    recognizer?.stopListening()
                    listening = false
                    result.success(mapOf("ok" to true, "message" to "stopped listening"))
                }
                "speak" -> {
                    val text = call.argument<String>("text") ?: ""
                    if (text.isEmpty()) {
                        result.success(mapOf("ok" to false, "message" to "nothing to speak"))
                    } else {
                        speak(text)
                        result.success(mapOf("ok" to true, "message" to "speaking"))
                    }
                }
                "playAudio" -> {
                    val b64 = call.argument<String>("wavBase64") ?: ""
                    if (b64.isEmpty()) {
                        result.success(mapOf("ok" to false, "message" to "empty audio"))
                    } else {
                        playWavBase64(b64)
                        result.success(mapOf("ok" to true, "message" to "playing"))
                    }
                }
                "stopSpeaking", "stopSpeak" -> {
                    tts?.stop()
                    stopActiveTrack()
                    result.success(mapOf("ok" to true, "message" to "stopped speaking"))
                }
                // Whisper sidecar methods exist on the Windows voice channel
                // only. On Android STT is the built-in SpeechRecognizer
                // (startListening), so these fail plainly instead of
                // throwing MissingPluginException.
                "startWhisper", "transcribe", "whisperStatus" -> {
                    result.success(
                        mapOf(
                            "ok" to false,
                            "message" to "whisper sidecar is Windows-only — on Android use startListening (built-in SpeechRecognizer)"
                        )
                    )
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.success(mapOf("ok" to false, "message" to (e.message ?: "unknown error")))
        }
    }

    // -------------------------------------------------------------------- STT

    private fun startListening(result: MethodChannel.Result) {
        if (listening) {
            return result.success(mapOf("ok" to true, "message" to "already listening"))
        }
        if (ContextCompat.checkSelfPermission(activity, Manifest.permission.RECORD_AUDIO)
            != PackageManager.PERMISSION_GRANTED
        ) {
            ActivityCompat.requestPermissions(
                activity,
                arrayOf(Manifest.permission.RECORD_AUDIO),
                REQUEST_RECORD_AUDIO
            )
            return result.success(
                mapOf(
                    "ok" to false,
                    "message" to "microphone permission requested — call startListening again once it is granted"
                )
            )
        }
        if (!SpeechRecognizer.isRecognitionAvailable(activity)) {
            return result.success(
                mapOf(
                    "ok" to false,
                    "message" to "speech recognition is not available on this device"
                )
            )
        }
        val recognizer = SpeechRecognizer.createSpeechRecognizer(activity).also {
            this.recognizer = it
        }
        recognizer.setRecognitionListener(object : RecognitionListener {
            override fun onReadyForSpeech(params: Bundle?) {
                listening = true
                sendEvent("onListeningStarted", emptyMap())
            }

            override fun onBeginningOfSpeech() = Unit
            override fun onRmsChanged(rmsdB: Float) {
                val norm = ((rmsdB + 2f) / 12f).coerceIn(0f, 1f).toDouble()
                sendEvent("onAudioLevel", mapOf("level" to norm))
            }
            override fun onBufferReceived(buffer: ByteArray?) = Unit
            override fun onEndOfSpeech() {
                listening = false
                sendEvent("onListeningStopped", emptyMap())
            }

            override fun onError(error: Int) {
                listening = false
                sendEvent(
                    "onSpeechError",
                    mapOf("error" to error, "message" to speechErrorMessage(error))
                )
            }

            override fun onResults(results: Bundle?) {
                listening = false
                val text = bestResult(results)
                sendEvent("onFinalResult", mapOf("text" to text))
            }

            override fun onPartialResults(partialResults: Bundle?) {
                val text = bestResult(partialResults)
                if (text.isNotEmpty()) {
                    sendEvent("onPartialResult", mapOf("text" to text))
                }
            }

            override fun onEvent(eventType: Int, params: Bundle?) = Unit
        })
        recognizer.startListening(buildListenIntent())
        result.success(mapOf("ok" to true, "message" to "listening"))
    }

    private fun buildListenIntent(): Intent =
        Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(
                RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                RecognizerIntent.LANGUAGE_MODEL_FREE_FORM
            )
            // en-IN first; the recognizer falls back to the device default
            // language when en-IN is unavailable.
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, "en-IN")
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 3)
            putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, activity.packageName)
        }

    private fun bestResult(results: Bundle?): String {
        val list = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
        return list?.firstOrNull() ?: ""
    }

    private fun speechErrorMessage(error: Int): String = when (error) {
        SpeechRecognizer.ERROR_AUDIO -> "audio recording error"
        SpeechRecognizer.ERROR_CLIENT -> "client error"
        SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "microphone permission missing"
        SpeechRecognizer.ERROR_NETWORK -> "network error"
        SpeechRecognizer.ERROR_NETWORK_TIMEOUT -> "network timed out"
        SpeechRecognizer.ERROR_NO_MATCH -> "no speech recognised"
        SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> "recognizer is busy"
        SpeechRecognizer.ERROR_SERVER -> "recognition server error"
        SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "no speech heard"
        else -> "recognition error ($error)"
    }

    private fun sendEvent(method: String, args: Map<String, Any?>) {
        activity.runOnUiThread {
            try {
                eventChannel.invokeMethod(method, args)
            } catch (_: Exception) {
                // Dart side is gone; nothing to do.
            }
        }
    }

    // -------------------------------------------------------------------- TTS

    private fun speak(text: String) {
        if (tts == null) {
            tts = TextToSpeech(activity.applicationContext) { status ->
                if (status == TextToSpeech.SUCCESS) {
                    ttsReady = true
                    applyTtsLanguage()
                    pendingSpeak?.let { pending ->
                        pendingSpeak = null
                        doSpeak(pending)
                    }
                }
            }
        }
        if (ttsReady) {
            doSpeak(text)
        } else {
            // TTS is still initialising; speak as soon as it is ready.
            pendingSpeak = text
        }
    }

    private fun applyTtsLanguage() {
        val engine = tts ?: return
        // en-IN first, device default as fallback.
        val indian = engine.setLanguage(Locale("en", "IN"))
        if (indian == TextToSpeech.LANG_MISSING_DATA ||
            indian == TextToSpeech.LANG_NOT_SUPPORTED
        ) {
            engine.setLanguage(Locale.getDefault())
        }
    }

    private fun doSpeak(text: String) {
        tts?.speak(
            text,
            TextToSpeech.QUEUE_FLUSH,
            null,
            "dj-utterance-${System.currentTimeMillis()}"
        )
    }

    private fun stopActiveTrack() {
        val track = activeTrack
        activeTrack = null
        if (track != null) {
            try {
                track.pause()
                track.flush()
                track.stop()
            } catch (_: Exception) {}
            try {
                track.release()
            } catch (_: Exception) {}
        }
    }

    private fun playWavBase64(b64: String) {
        stopActiveTrack()
        val raw = Base64.decode(b64, Base64.DEFAULT)
        if (raw.size <= 44) return
        val pcm = raw.copyOfRange(44, raw.size)
        val track = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ASSISTANT)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build()
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(16000)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .build()
            )
            .setTransferMode(AudioTrack.MODE_STATIC)
            .setBufferSizeInBytes(pcm.size)
            .build()
        activeTrack = track
        track.write(pcm, 0, pcm.size)
        track.play()
    }

    /** Called from MainActivity.onDestroy(). Releases the recognizer and TTS. */
    fun release() {
        stopActiveTrack()
        try {
            recognizer?.cancel()
        } catch (_: Exception) {
        }
        try {
            recognizer?.destroy()
        } catch (_: Exception) {
        }
        recognizer = null
        try {
            tts?.stop()
        } catch (_: Exception) {
        }
        try {
            tts?.shutdown()
        } catch (_: Exception) {
        }
        tts = null
        listening = false
    }
}
