import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Service that invokes the native Android TV Google Speech / Assistant recognition dialog.
class VoiceSearchService {
  static const _channel = MethodChannel('com.nk.live_tv/speech');

  /// Launches the native Android TV voice recognition overlay.
  /// Returns the recognized spoken text or null if cancelled / unavailable.
  static Future<String?> startListening({String prompt = 'Speak channel name (e.g. Aaj Tak, Star Sports)...'}) async {
    try {
      final text = await _channel.invokeMethod<String>('startSpeechRecognition', {'prompt': prompt});
      if (text != null && text.trim().isNotEmpty) {
        return text.trim();
      }
    } catch (e) {
      debugPrint('VoiceSearchService error: $e');
    }
    return null;
  }
}
