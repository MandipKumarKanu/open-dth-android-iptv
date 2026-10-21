import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../model/channel.dart';

class FavoritesProvider extends ChangeNotifier {
  static final FavoritesProvider instance = FavoritesProvider._();
  FavoritesProvider._();

  static const _fileName = 'favorites.json';
  final Set<String> _favorites = {};
  bool _loaded = false;

  Set<String> get ids => Set.unmodifiable(_favorites);

  Future<void> load() async {
    if (_loaded) return;
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}/$_fileName');
      if (await file.exists()) {
        final content = await file.readAsString();
        final list = jsonDecode(content) as List;
        _favorites.addAll(list.cast<String>());
      }
    } catch (_) {}
    _loaded = true;
    notifyListeners();
  }

  bool isFavorite(Channel channel) => _favorites.contains(channel.idKey);

  Future<bool> toggle(Channel channel) async {
    final key = channel.idKey;
    final added = _favorites.add(key);
    if (!added) {
      _favorites.remove(key);
    }
    notifyListeners();
    await _save();
    return added;
  }

  Future<void> _save() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}/$_fileName');
      await file.writeAsString(jsonEncode(_favorites.toList()));
    } catch (_) {}
  }
}
