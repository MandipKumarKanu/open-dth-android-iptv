import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../model/channel.dart';

/// Remembers the last confirmed working stream URL for each channel.
/// When a channel has multiple streams (e.g. 1080p, 720p, backups) and the
/// primary stream fails or is dead, the player falls back to a working backup.
/// This provider persists that working stream so future playbacks start
/// directly with the working backup without waiting or trying dead links.
class StreamMemoryProvider extends ChangeNotifier {
  static final StreamMemoryProvider instance = StreamMemoryProvider._();
  StreamMemoryProvider._();

  static const _fileName = 'stream_memory.json';
  final Map<String, String> _workingUrls = {};
  bool _loaded = false;

  Map<String, String> get workingUrls => Map.unmodifiable(_workingUrls);

  Future<void> load() async {
    if (_loaded) return;
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}/$_fileName');
      if (await file.exists()) {
        final content = await file.readAsString();
        final map = jsonDecode(content) as Map<String, dynamic>;
        map.forEach((k, v) {
          if (v is String && v.isNotEmpty) {
            _workingUrls[k] = v;
          }
        });
      }
    } catch (_) {}
    _loaded = true;
    notifyListeners();
  }

  /// Returns the preferred stream index for a channel.
  /// If a working stream URL is remembered for this channel, returns its index
  /// in [channel.streamUrls]. Otherwise returns 0 (the primary stream).
  int getPreferredStreamIndex(Channel channel) {
    if (channel.streamUrls.isEmpty) return 0;
    final rememberedUrl = _workingUrls[channel.idKey];
    if (rememberedUrl != null && rememberedUrl.isNotEmpty) {
      final idx = channel.streamUrls.indexOf(rememberedUrl);
      if (idx >= 0) return idx;
    }
    return 0;
  }

  /// Saves the confirmed working stream URL for a channel.
  Future<void> rememberWorkingStream(Channel channel, String workingUrl) async {
    if (workingUrl.isEmpty) return;
    if (_workingUrls[channel.idKey] == workingUrl) return; // already remembered
    _workingUrls[channel.idKey] = workingUrl;
    notifyListeners();
    await _save();
  }

  /// Called when a stream fails. If the failed stream was our remembered one,
  /// remove it so the player can probe and save the next working backup.
  Future<void> reportStreamFailure(Channel channel, String failedUrl) async {
    if (_workingUrls[channel.idKey] == failedUrl) {
      _workingUrls.remove(channel.idKey);
      notifyListeners();
      await _save();
    }
  }

  Future<void> _save() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}/$_fileName');
      await file.writeAsString(jsonEncode(_workingUrls));
    } catch (_) {}
  }
}
