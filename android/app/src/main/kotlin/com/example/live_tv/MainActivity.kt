package com.nk.live_tv

import android.app.Activity
import android.content.Intent
import android.speech.RecognizerIntent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.nk.live_tv/speech"
    private val SPEECH_REQUEST_CODE = 0x50EE

    private var pendingResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "startSpeechRecognition") {
                if (pendingResult != null) {
                    result.error("BUSY", "Speech recognition already active", null)
                    return@setMethodCallHandler
                }
                pendingResult = result
                val prompt = call.argument<String>("prompt") ?: "Speak channel name (e.g. Aaj Tak, Star Sports)..."
                val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                    putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                    putExtra(RecognizerIntent.EXTRA_PROMPT, prompt)
                }
                try {
                    startActivityForResult(intent, SPEECH_REQUEST_CODE)
                } catch (e: Exception) {
                    pendingResult = null
                    result.error("UNAVAILABLE", "Speech recognition not available: ${e.message}", null)
                }
            } else {
                result.notImplemented()
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == SPEECH_REQUEST_CODE) {
            val res = pendingResult
            pendingResult = null
            if (resultCode == Activity.RESULT_OK && data != null) {
                val matches = data.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)
                if (!matches.isNullOrEmpty()) {
                    res?.success(matches[0])
                } else {
                    res?.success("")
                }
            } else {
                // Cancelled or no speech detected
                res?.success("")
            }
        }
    }
}
