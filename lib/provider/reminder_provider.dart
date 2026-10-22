import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../model/channel.dart';
import '../model/program.dart';

class ProgramReminder {
  final String id;
  final String channelName;
  final String channelKey;
  final String channelLogoUrl;
  final String programTitle;
  final String programDesc;
  final DateTime startTime;
  final DateTime stopTime;
  bool isTriggered;

  ProgramReminder({
    required this.id,
    required this.channelName,
    required this.channelKey,
    required this.channelLogoUrl,
    required this.programTitle,
    required this.programDesc,
    required this.startTime,
    required this.stopTime,
    this.isTriggered = false,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'cn': channelName,
        'ck': channelKey,
        'cl': channelLogoUrl,
        'pt': programTitle,
        'pd': programDesc,
        'st': startTime.millisecondsSinceEpoch,
        'et': stopTime.millisecondsSinceEpoch,
        'tr': isTriggered,
      };

  factory ProgramReminder.fromJson(Map<String, dynamic> j) {
    return ProgramReminder(
      id: j['id'] as String,
      channelName: j['cn'] as String? ?? '',
      channelKey: j['ck'] as String? ?? '',
      channelLogoUrl: j['cl'] as String? ?? '',
      programTitle: j['pt'] as String? ?? '',
      programDesc: j['pd'] as String? ?? '',
      startTime: DateTime.fromMillisecondsSinceEpoch(j['st'] as int),
      stopTime: DateTime.fromMillisecondsSinceEpoch(j['et'] as int),
      isTriggered: j['tr'] as bool? ?? false,
    );
  }
}

class ReminderProvider extends ChangeNotifier {
  static final ReminderProvider instance = ReminderProvider._();
  ReminderProvider._() {
    _startTimer();
  }

  static const _fileName = 'program_reminders_v1.json';
  final List<ProgramReminder> _reminders = [];
  bool _loaded = false;
  Timer? _timer;

  void Function(ProgramReminder)? onReminderDue;

  List<ProgramReminder> get reminders => List.unmodifiable(_reminders);

  static String buildId(String channelKey, Program program) {
    return '${channelKey}_${program.title}_${program.start.millisecondsSinceEpoch}';
  }

  Future<void> load() async {
    if (_loaded) return;
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}/$_fileName');
      if (await file.exists()) {
        final content = await file.readAsString();
        final list = jsonDecode(content) as List;
        _reminders.clear();
        final now = DateTime.now();
        for (final item in list) {
          final r = ProgramReminder.fromJson(item as Map<String, dynamic>);
          // Prune reminders older than 12 hours
          if (now.difference(r.stopTime).inHours < 12) {
            _reminders.add(r);
          }
        }
      }
    } catch (_) {}
    _loaded = true;
    notifyListeners();
  }

  bool isReminderSet(String channelKey, Program program) {
    final id = buildId(channelKey, program);
    return _reminders.any((r) => r.id == id);
  }

  Future<bool> toggleReminder({
    required Channel channel,
    required Program program,
  }) async {
    await load();
    final channelKey = channel.idKey;
    final id = buildId(channelKey, program);
    final existingIdx = _reminders.indexWhere((r) => r.id == id);

    if (existingIdx >= 0) {
      _reminders.removeAt(existingIdx);
      notifyListeners();
      await _save();
      return false; // Removed
    } else {
      _reminders.add(
        ProgramReminder(
          id: id,
          channelName: channel.name,
          channelKey: channelKey,
          channelLogoUrl: channel.logoUrl,
          programTitle: program.title,
          programDesc: program.desc,
          startTime: program.start,
          stopTime: program.stop,
        ),
      );
      notifyListeners();
      await _save();
      return true; // Added
    }
  }

  Future<void> _save() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}/$_fileName');
      final list = _reminders.map((r) => r.toJson()).toList();
      await file.writeAsString(jsonEncode(list));
    } catch (_) {}
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _checkReminders());
  }

  void _checkReminders() {
    final now = DateTime.now();
    bool changed = false;

    for (final r in _reminders) {
      if (r.isTriggered) continue;
      // Trigger if program starts within the next 2 minutes or started less than 3 minutes ago
      final diffMin = r.startTime.difference(now).inMinutes;
      if (diffMin <= 2 && diffMin >= -3) {
        r.isTriggered = true;
        changed = true;
        onReminderDue?.call(r);
      }
    }

    if (changed) {
      _save();
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
