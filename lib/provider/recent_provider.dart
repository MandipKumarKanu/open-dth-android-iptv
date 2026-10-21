import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../model/channel.dart';

class RecentProvider extends ChangeNotifier {
  static final RecentProvider instance = RecentProvider._();
  RecentProvider._();

  static const _fileName = 'recent_channels.json';
  static const int maxRecent = 20;

  final List<String> _recent = [];
  bool _loaded = false;

  List<String> get ids => List.unmodifiable(_recent);

  Future<void> load() async {
    if (_loaded) return;
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}/$_fileName');
      if (await file.exists()) {
        final content = await file.readAsString();
        final list = jsonDecode(content) as List;
        _recent.clear();
        _recent.addAll(list.cast<String>());
      }
    } catch (_) {}
    _loaded = true;
    notifyListeners();
  }

  /// Adds a channel to the top of recent history.
  Future<void> add(Channel channel) async {
    final key = channel.idKey;
    _recent.remove(key);
    _recent.insert(0, key);
    if (_recent.length > maxRecent) {
      _recent.removeRange(maxRecent, _recent.length);
    }
    notifyListeners();
    await _save();
  }

  /// Returns previous channel key (for Recall ⟲ button).
  String? getPreviousKey(String currentKey) {
    for (final k in _recent) {
      if (k != currentKey) return k;
    }
    return null;
  }

  List<Channel> filterRecent(List<Channel> all) {
    final map = {for (final c in all) c.idKey: c};
    final out = <Channel>[];
    for (final k in _recent) {
      final ch = map[k];
      if (ch != null) out.add(ch);
    }
    return out;
  }

  Future<void> clear() async {
    _recent.clear();
    notifyListeners();
    await _save();
  }

  Future<void> _save() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}/$_fileName');
      await file.writeAsString(jsonEncode(_recent));
    } catch (_) {}
  }
}
