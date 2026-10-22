import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

enum ScreenFitMode {
  fill('Full (16:9)', 'Fills 100% TV screen · Zero black borders', BoxFit.fill),
  contain('Original', 'Standard broadcast aspect ratio', BoxFit.contain),
  cover('Zoom', 'Crops top/bottom to fill screen', BoxFit.cover);

  final String label;
  final String description;
  final BoxFit boxFit;
  const ScreenFitMode(this.label, this.description, this.boxFit);
}

/// Stores and persists player settings such as screen aspect ratio / fit mode.
class PlayerSettingsProvider extends ChangeNotifier {
  static final PlayerSettingsProvider instance = PlayerSettingsProvider._();
  PlayerSettingsProvider._();

  static const _fileName = 'player_settings.json';
  ScreenFitMode _screenFit = ScreenFitMode.fill;
  String _preferredAudioLanguage = '';
  bool _loaded = false;

  ScreenFitMode get screenFit => _screenFit;
  String get preferredAudioLanguage => _preferredAudioLanguage;

  Future<void> load() async {
    if (_loaded) return;
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}/$_fileName');
      if (await file.exists()) {
        final content = await file.readAsString();
        final map = jsonDecode(content) as Map<String, dynamic>;
        final fitName = map['screenFit'] as String?;
        if (fitName != null) {
          _screenFit = ScreenFitMode.values.firstWhere(
            (e) => e.name == fitName,
            orElse: () => ScreenFitMode.fill,
          );
        }
        _preferredAudioLanguage = map['audioLang'] as String? ?? '';
      }
    } catch (_) {}
    _loaded = true;
    notifyListeners();
  }

  Future<void> setScreenFit(ScreenFitMode mode) async {
    if (_screenFit == mode) return;
    _screenFit = mode;
    notifyListeners();
    await _save();
  }

  Future<void> setPreferredAudioLanguage(String lang) async {
    if (_preferredAudioLanguage == lang) return;
    _preferredAudioLanguage = lang;
    notifyListeners();
    await _save();
  }

  Future<ScreenFitMode> cycleScreenFit() async {
    final nextIdx = (_screenFit.index + 1) % ScreenFitMode.values.length;
    final nextMode = ScreenFitMode.values[nextIdx];
    await setScreenFit(nextMode);
    return nextMode;
  }

  Future<void> _save() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}/$_fileName');
      await file.writeAsString(jsonEncode({
        'screenFit': _screenFit.name,
        'audioLang': _preferredAudioLanguage,
      }));
    } catch (_) {}
  }
}

