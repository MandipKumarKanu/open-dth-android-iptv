package com.nk.live_tv

import android.app.Activity
import android.content.Intent
import android.speech.RecognizerIntent
import androidx.media3.common.C
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.exoplayer.ExoPlayer
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.videoplayer.VideoPlayerPlugin

class MainActivity: FlutterActivity() {
    private val SPEECH_CHANNEL = "com.nk.live_tv/speech"
    private val AUDIO_CHANNEL = "com.nk.live_tv/audio_tracks"
    private val SPEECH_REQUEST_CODE = 0x50EE

    private var pendingResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // 1. Voice Search Method Channel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SPEECH_CHANNEL).setMethodCallHandler { call, result ->
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

        // 2. Multi-Audio Track Switching Method Channel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, AUDIO_CHANNEL).setMethodCallHandler { call, result ->
            val playerId = (call.argument<Number>("playerId"))?.toLong()
            val exoPlayer = getExoPlayer(playerId)

            when (call.method) {
                "getAudioTracks" -> {
                    if (exoPlayer == null) {
                        android.util.Log.w("MainActivity", "getAudioTracks: ExoPlayer not found for playerId=$playerId")
                        result.success(emptyList<Map<String, Any?>>())
                        return@setMethodCallHandler
                    }
                    try {
                        val tracksList = mutableListOf<Map<String, Any?>>()
                        val tracks = exoPlayer.currentTracks
                        android.util.Log.d("MainActivity", "getAudioTracks: total groups=${tracks.groups.size}")
                        for (groupIndex in 0 until tracks.groups.size) {
                            val group = tracks.groups[groupIndex]
                            android.util.Log.d("MainActivity", "  group $groupIndex: type=${group.type}, len=${group.length}")
                            if (group.type == C.TRACK_TYPE_AUDIO) {
                                for (trackIndex in 0 until group.length) {
                                    val format = group.getTrackFormat(trackIndex)
                                    val isSelected = group.isTrackSelected(trackIndex)
                                    val isSupported = group.isTrackSupported(trackIndex)
                                    android.util.Log.d("MainActivity", "    audio track $trackIndex: id=${format.id}, lang=${format.language}, label=${format.label}, sel=$isSelected, sup=$isSupported")
                                    val trackMap = hashMapOf<String, Any?>(
                                        "groupIndex" to groupIndex,
                                        "trackIndex" to trackIndex,
                                        "id" to (format.id ?: ""),
                                        "label" to (format.label ?: ""),
                                        "language" to (format.language ?: ""),
                                        "bitrate" to format.bitrate,
                                        "channelCount" to format.channelCount,
                                        "sampleRate" to format.sampleRate,
                                        "isSelected" to isSelected,
                                        "isSupported" to isSupported
                                    )
                                    tracksList.add(trackMap)
                                }
                            }
                        }
                        android.util.Log.d("MainActivity", "getAudioTracks: returning ${tracksList.size} tracks")
                        result.success(tracksList)
                    } catch (e: Exception) {
                        android.util.Log.e("MainActivity", "getAudioTracks error: ${e.message}", e)
                        result.error("TRACK_ERROR", "Failed to get audio tracks: ${e.message}", null)
                    }
                }
                "selectAudioTrack" -> {
                    if (exoPlayer == null) {
                        result.error("NOT_FOUND", "ExoPlayer instance not found", null)
                        return@setMethodCallHandler
                    }
                    val groupIndex = call.argument<Int>("groupIndex") ?: -1
                    val trackIndex = call.argument<Int>("trackIndex") ?: -1
                    try {
                        val tracks = exoPlayer.currentTracks
                        if (groupIndex in 0 until tracks.groups.size) {
                            val group = tracks.groups[groupIndex]
                            if (trackIndex in 0 until group.length) {
                                val override = TrackSelectionOverride(group.mediaTrackGroup, trackIndex)
                                exoPlayer.trackSelectionParameters = exoPlayer.trackSelectionParameters
                                    .buildUpon()
                                    .clearOverridesOfType(C.TRACK_TYPE_AUDIO)
                                    .addOverride(override)
                                    .build()
                                result.success(true)
                                return@setMethodCallHandler
                            }
                        }
                        result.error("INVALID_INDEX", "Group ($groupIndex) or Track ($trackIndex) out of bounds", null)
                    } catch (e: Exception) {
                        result.error("OVERRIDE_ERROR", "Failed to set audio track: ${e.message}", null)
                    }
                }
                "setPreferredAudioLanguage" -> {
                    if (exoPlayer == null) {
                        result.error("NOT_FOUND", "ExoPlayer instance not found", null)
                        return@setMethodCallHandler
                    }
                    val language = call.argument<String>("language") ?: ""
                    try {
                        exoPlayer.trackSelectionParameters = exoPlayer.trackSelectionParameters
                            .buildUpon()
                            .clearOverridesOfType(C.TRACK_TYPE_AUDIO)
                            .setPreferredAudioLanguage(language.ifEmpty { null })
                            .build()
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("LANGUAGE_ERROR", "Failed to set preferred language: ${e.message}", null)
                    }
                }
                "resetAudioTrack" -> {
                    if (exoPlayer == null) {
                        result.error("NOT_FOUND", "ExoPlayer instance not found", null)
                        return@setMethodCallHandler
                    }
                    try {
                        exoPlayer.trackSelectionParameters = exoPlayer.trackSelectionParameters
                            .buildUpon()
                            .clearOverridesOfType(C.TRACK_TYPE_AUDIO)
                            .build()
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("RESET_ERROR", "Failed to reset audio track: ${e.message}", null)
                    }
                }
                "enableLiveBufferWindow" -> {
                    if (exoPlayer == null) {
                        result.error("NOT_FOUND", "ExoPlayer not found", null)
                        return@setMethodCallHandler
                    }
                    val bufferOffsetMs = (call.argument<Number>("offsetMs"))?.toLong() ?: 18000L
                    try {
                        // Lock playback speed to 1.0f so ExoPlayer never speeds up to live edge and depletes buffer
                        exoPlayer.playbackParameters = androidx.media3.common.PlaybackParameters(1.0f)

                        val currentPos = exoPlayer.currentPosition
                        val liveOffset = exoPlayer.currentLiveOffset

                        var shifted = false
                        // If live stream has enough time window, seek back bufferOffsetMs to establish safety buffer
                        if (currentPos > bufferOffsetMs + 4000L) {
                            exoPlayer.seekTo(currentPos - bufferOffsetMs)
                            shifted = true
                        }

                        val info = hashMapOf<String, Any?>(
                            "isLive" to exoPlayer.isCurrentMediaItemLive,
                            "currentPos" to currentPos,
                            "liveOffset" to liveOffset,
                            "totalBuffered" to exoPlayer.totalBufferedDuration,
                            "shifted" to shifted
                        )
                        result.success(info)
                    } catch (e: Exception) {
                        result.error("BUFFER_CONFIG_ERROR", "Failed to configure live buffer: ${e.message}", null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun getExoPlayer(playerId: Long?): ExoPlayer? {
        return try {
            val engine = flutterEngine ?: return null
            val plugin = engine.plugins.get(VideoPlayerPlugin::class.java) as? VideoPlayerPlugin ?: return null
            val field = VideoPlayerPlugin::class.java.getDeclaredField("videoPlayers")
            field.isAccessible = true
            val players = field.get(plugin) as? android.util.LongSparseArray<*> ?: return null

            var playerObj: Any? = null
            if (playerId != null && playerId >= 0) {
                playerObj = players.get(playerId)
            }
            if (playerObj == null && players.size() > 0) {
                // In Live TV, fallback to the latest active player
                playerObj = players.valueAt(players.size() - 1)
            }
            if (playerObj == null) {
                android.util.Log.w("MainActivity", "getExoPlayer: playerObj is null (players size=${players.size()})")
                return null
            }

            // 1. Try public getExoPlayer method
            try {
                val getExoMethod = playerObj.javaClass.getMethod("getExoPlayer")
                val ep = getExoMethod.invoke(playerObj) as? ExoPlayer
                if (ep != null) return ep
            } catch (_: Exception) {}

            // 2. Try any zero-arg method returning an ExoPlayer / Player
            for (m in playerObj.javaClass.methods) {
                if (ExoPlayer::class.java.isAssignableFrom(m.returnType) && m.parameterTypes.isEmpty()) {
                    try {
                        m.isAccessible = true
                        val ep = m.invoke(playerObj) as? ExoPlayer
                        if (ep != null) {
                            android.util.Log.d("MainActivity", "Found ExoPlayer via method ${m.name}")
                            return ep
                        }
                    } catch (_: Exception) {}
                }
            }

            // 3. Try any declared field of type ExoPlayer (across class hierarchy)
            var cls: Class<*>? = playerObj.javaClass
            while (cls != null && cls != Any::class.java) {
                for (f in cls.declaredFields) {
                    if (ExoPlayer::class.java.isAssignableFrom(f.type)) {
                        try {
                            f.isAccessible = true
                            val ep = f.get(playerObj) as? ExoPlayer
                            if (ep != null) {
                                android.util.Log.d("MainActivity", "Found ExoPlayer via field ${f.name} in ${cls.simpleName}")
                                return ep
                            }
                        } catch (_: Exception) {}
                    }
                }
                cls = cls.superclass
            }

            android.util.Log.w("MainActivity", "getExoPlayer: no ExoPlayer found in ${playerObj.javaClass.name}")
            null
        } catch (e: Exception) {
            android.util.Log.e("MainActivity", "Failed to retrieve ExoPlayer: ${e.message}", e)
            null
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

