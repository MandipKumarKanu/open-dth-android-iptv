import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

class AudioTrack {
  final int groupIndex;
  final int trackIndex;
  final String id;
  final String label;
  final String language;
  final int bitrate;
  final int channelCount;
  final int sampleRate;
  final bool isSelected;
  final bool isSupported;

  const AudioTrack({
    required this.groupIndex,
    required this.trackIndex,
    this.id = '',
    this.label = '',
    this.language = '',
    this.bitrate = 0,
    this.channelCount = 0,
    this.sampleRate = 0,
    this.isSelected = false,
    this.isSupported = true,
  });

  factory AudioTrack.fromMap(Map<dynamic, dynamic> map) {
    return AudioTrack(
      groupIndex: map['groupIndex'] as int? ?? 0,
      trackIndex: map['trackIndex'] as int? ?? 0,
      id: map['id']?.toString() ?? '',
      label: map['label']?.toString() ?? '',
      language: map['language']?.toString() ?? '',
      bitrate: map['bitrate'] as int? ?? 0,
      channelCount: map['channelCount'] as int? ?? 0,
      sampleRate: map['sampleRate'] as int? ?? 0,
      isSelected: map['isSelected'] as bool? ?? false,
      isSupported: map['isSupported'] as bool? ?? true,
    );
  }

  /// Friendly display label for TV UI.
  String get displayName {
    if (label.trim().isNotEmpty && !RegExp(r'^\d+$').hasMatch(label.trim())) {
      return _capitalize(label.trim());
    }

    final lang = language.trim().toLowerCase();
    switch (lang) {
      case 'hi':
      case 'hin':
        return 'Hindi';
      case 'en':
      case 'eng':
        return 'English';
      case 'bn':
      case 'ben':
        return 'Bengali';
      case 'ta':
      case 'tam':
        return 'Tamil';
      case 'te':
      case 'tel':
        return 'Telugu';
      case 'kn':
      case 'kan':
        return 'Kannada';
      case 'ml':
      case 'mal':
        return 'Malayalam';
      case 'mr':
      case 'mar':
        return 'Marathi';
      case 'pa':
      case 'pan':
        return 'Punjabi';
      case 'gu':
      case 'guj':
        return 'Gujarati';
      case 'or':
      case 'ori':
        return 'Odia';
      case 'ur':
      case 'urd':
        return 'Urdu';
      case 'as':
      case 'asm':
        return 'Assamese';
      case 'bho':
        return 'Bhojpuri';
      case 'und':
      case '':
        return 'Track ${trackIndex + 1}';
      default:
        return lang.length <= 3 ? lang.toUpperCase() : _capitalize(lang);
    }
  }

  String _capitalize(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1).toLowerCase();

  @override
  String toString() =>
      'AudioTrack(g:$groupIndex, t:$trackIndex, name:$displayName, lang:$language, selected:$isSelected)';
}

/// Service to query and switch multi-audio streams via native ExoPlayer bridge.
class AudioTrackService {
  static const MethodChannel _channel = MethodChannel('com.nk.live_tv/audio_tracks');

  /// Fetches audio tracks from the active video player.
  static Future<List<AudioTrack>> getAudioTracks({int? playerId}) async {
    try {
      final res = await _channel.invokeMethod('getAudioTracks', {
        if (playerId != null) 'playerId': playerId,
      });
      if (res is List) {
        return res
            .whereType<Map>()
            .map((e) => AudioTrack.fromMap(e))
            .where((t) => t.isSupported)
            .toList();
      }
    } catch (_) {}
    return [];
  }

  /// Selects a specific audio track by group & track index.
  static Future<bool> selectAudioTrack({
    int? playerId,
    required int groupIndex,
    required int trackIndex,
  }) async {
    try {
      final res = await _channel.invokeMethod('selectAudioTrack', {
        if (playerId != null) 'playerId': playerId,
        'groupIndex': groupIndex,
        'trackIndex': trackIndex,
      });
      return res == true;
    } catch (_) {
      return false;
    }
  }

  /// Sets user's preferred audio language (e.g. 'hin', 'eng').
  static Future<bool> setPreferredAudioLanguage({
    int? playerId,
    required String language,
  }) async {
    try {
      final res = await _channel.invokeMethod('setPreferredAudioLanguage', {
        if (playerId != null) 'playerId': playerId,
        'language': language,
      });
      return res == true;
    } catch (_) {
      return false;
    }
  }

  /// Resets audio track to default selection.
  static Future<bool> resetAudioTrack({int? playerId}) async {
    try {
      final res = await _channel.invokeMethod('resetAudioTrack', {
        if (playerId != null) 'playerId': playerId,
      });
      return res == true;
    } catch (_) {
      return false;
    }
  }

  /// Quick probe for HLS master manifest (#EXT-X-MEDIA:TYPE=AUDIO)
  static Future<List<Map<String, String>>> probeHlsAudioManifest(String url) async {
    try {
      final uri = Uri.parse(url);
      final resp = await http.get(uri).timeout(const Duration(seconds: 4));
      if (resp.statusCode != 200) return [];

      final lines = const LineSplitter().convert(resp.body);
      final audioTracks = <Map<String, String>>[];

      for (final line in lines) {
        if (line.startsWith('#EXT-X-MEDIA:') && line.contains('TYPE=AUDIO')) {
          final nameMatch = RegExp(r'NAME="([^"]+)"').firstMatch(line);
          final langMatch = RegExp(r'LANGUAGE="([^"]+)"').firstMatch(line);
          final defaultMatch = RegExp(r'DEFAULT=(YES|NO)').firstMatch(line);
          final uriMatch = RegExp(r'URI="([^"]+)"').firstMatch(line);

          final name = nameMatch?.group(1) ?? '';
          final lang = langMatch?.group(1) ?? '';
          final isDefault = (defaultMatch?.group(1) ?? 'NO') == 'YES';
          final subUri = uriMatch?.group(1) ?? '';

          audioTracks.add({
            'name': name,
            'language': lang,
            'isDefault': isDefault ? 'true' : 'false',
            'uri': subUri.isNotEmpty ? uri.resolve(subUri).toString() : '',
          });
        }
      }
      return audioTracks;
    } catch (_) {
      return [];
    }
  }
}
