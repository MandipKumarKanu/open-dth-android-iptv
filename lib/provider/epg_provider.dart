import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../model/channel.dart';
import '../model/program.dart';

/// Provides Electronic Program Guide (EPG) schedules for live Indian channels.
/// Downloads compressed XMLTV feed, parses programs in a background isolate,
/// and provides fast O(1) now/next program lookups for player OSD and Timeline Guide.
class EpgProvider extends ChangeNotifier {
  static final EpgProvider instance = EpgProvider._();
  EpgProvider._();

  static const epgUrl = 'https://mitthu786.github.io/tvepg/tataplay/epg.xml.gz';
  static const _cacheFileName = 'epg_today_v1.json';

  Map<String, List<Program>> _programsByKey = {};
  bool _isLoading = false;
  DateTime? _lastLoaded;

  bool get isLoading => _isLoading;
  bool get hasData => _programsByKey.isNotEmpty;
  DateTime? get lastLoaded => _lastLoaded;

  static String nameKey(String name) => name
      .toLowerCase()
      .replaceAll(RegExp(r'\(.*?\)|\[.*?\]'), '')
      .replaceAll(RegExp(r'\bhd\b'), '')
      .replaceAll(RegExp(r'[^a-z0-9]'), '');

  String getChannelKey(Channel channel) {
    final keyFromName = nameKey(channel.name);
    if (_programsByKey.containsKey(keyFromName)) return keyFromName;

    if (channel.tvgId.isNotEmpty) {
      final keyFromId = nameKey(channel.tvgId.split('@').first);
      if (_programsByKey.containsKey(keyFromId)) return keyFromId;
    }
    return keyFromName;
  }

  Program? getNow(Channel channel) {
    final key = getChannelKey(channel);
    final list = _programsByKey[key];
    if (list == null || list.isEmpty) return null;
    final now = DateTime.now();
    for (final p in list) {
      if (now.isAfter(p.start) && now.isBefore(p.stop)) {
        return p;
      }
    }
    return null;
  }

  Program? getNext(Channel channel) {
    final key = getChannelKey(channel);
    final list = _programsByKey[key];
    if (list == null || list.isEmpty) return null;
    final now = DateTime.now();
    Program? nextCandidate;
    for (final p in list) {
      if (p.start.isAfter(now) || p.start.isAtSameMomentAs(now)) {
        if (nextCandidate == null || p.start.isBefore(nextCandidate.start)) {
          nextCandidate = p;
        }
      }
    }
    return nextCandidate;
  }

  List<Program> getSchedule(Channel channel, {DateTime? from, DateTime? to}) {
    final key = getChannelKey(channel);
    final list = _programsByKey[key];
    if (list == null || list.isEmpty) return const [];
    if (from == null && to == null) return list;
    return list.where((p) {
      if (to != null && p.start.isAfter(to)) return false;
      if (from != null && p.stop.isBefore(from)) return false;
      return true;
    }).toList();
  }

  Future<void> loadCached() async {
    try {
      final dir = (await getApplicationSupportDirectory()).path;
      final f = File('$dir/$_cacheFileName');
      if (!await f.exists()) return;
      final modified = await f.lastModified();
      // Always load the cache, even if it's older than 16 h: offline users get
      // yesterday's guide instead of none at all. refresh() — called right after
      // loadCached by the app — replaces it with fresh data when online.
      final jsonStr = await f.readAsString();
      final map = await compute(_decodeCache, jsonStr);
      if (map.isNotEmpty) {
        _programsByKey = map;
        _lastLoaded = modified;
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> refresh() async {
    if (_isLoading) return;
    _isLoading = true;
    try {
      final resp = await http.get(Uri.parse(epgUrl)).timeout(const Duration(seconds: 30));
      if (resp.statusCode != 200 || resp.bodyBytes.isEmpty) {
        _isLoading = false;
        return;
      }

      final parsed = await compute(_parseEpgWorker, resp.bodyBytes);
      if (parsed.isNotEmpty) {
        _programsByKey = parsed;
        _lastLoaded = DateTime.now();
        notifyListeners();

        // Save cache to disk
        try {
          final dir = (await getApplicationSupportDirectory()).path;
          final f = File('$dir/$_cacheFileName');
          final jsonMap = <String, dynamic>{};
          for (final entry in parsed.entries) {
            jsonMap[entry.key] = entry.value.map((p) => p.toJson()).toList();
          }
          await f.writeAsString(jsonEncode(jsonMap));
        } catch (_) {}
      }
    } catch (_) {
    } finally {
      _isLoading = false;
    }
  }
}

// ---------------------------------------------------------------- Background Parsing Worker

Map<String, List<Program>> _decodeCache(String jsonStr) {
  final rawMap = jsonDecode(jsonStr) as Map<String, dynamic>;
  final result = <String, List<Program>>{};
  for (final e in rawMap.entries) {
    final list = (e.value as List).map((j) => Program.fromJson(j as Map<String, dynamic>)).toList();
    result[e.key] = list;
  }
  return result;
}

Map<String, List<Program>> _parseEpgWorker(List<int> gzipBytes) {
  final decompressed = gzip.decode(gzipBytes);
  final xml = utf8.decode(decompressed);

  // 1. Map channel ID to cleaned nameKey
  final chanIdToKey = <String, String>{};
  final chanNameRegex = RegExp(r'<channel id="([^"]+)">\s*<display-name>([^<]+)</display-name>');
  for (final m in chanNameRegex.allMatches(xml)) {
    final id = m.group(1)!;
    final name = _unescapeXml(m.group(2)!);
    chanIdToKey[id] = EpgProvider.nameKey(name);
  }

  // 2. Window: Keep programs from 4 hours ago to 28 hours ahead (today + tonight)
  final now = DateTime.now();
  final minTime = now.subtract(const Duration(hours: 4));
  final maxTime = now.add(const Duration(hours: 28));

  final progRegex = RegExp(
    r'<programme start="([^"]+)" stop="([^"]+)" channel="([^"]+)"[^>]*>\s*<title>([^<]+)</title>(?:\s*<desc>([^<]*)</desc>)?',
  );

  final out = <String, List<Program>>{};

  for (final m in progRegex.allMatches(xml)) {
    final startStr = m.group(1)!;
    final stopStr = m.group(2)!;
    final chId = m.group(3)!;
    final title = _unescapeXml(m.group(4)!.trim());
    final desc = _unescapeXml((m.group(5) ?? '').trim());

    final key = chanIdToKey[chId];
    if (key == null) continue;

    final start = _parseXmlTime(startStr);
    final stop = _parseXmlTime(stopStr);

    if (stop.isBefore(minTime) || start.isAfter(maxTime)) continue;

    final p = Program(
      title: title,
      desc: desc,
      start: start,
      stop: stop,
      channelKey: key,
    );

    (out[key] ??= []).add(p);
  }

  // Sort each channel's schedule chronologically
  for (final list in out.values) {
    list.sort((a, b) => a.start.compareTo(b.start));
  }

  return out;
}

/// Decodes the five predefined XML entities plus numeric character references
/// (&#NN; / &#xHH;) that appear in XMLTV titles, descriptions and display
/// names. `&amp;` is replaced last so `&amp;lt;` decodes correctly.
String _unescapeXml(String s) {
  if (!s.contains('&')) return s;
  var out = s
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'");
  out = out.replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'), (m) {
    final code = int.tryParse(m.group(1)!, radix: 16);
    return (code != null && code > 0 && code <= 0x10FFFF) ? String.fromCharCode(code) : m.group(0)!;
  });
  out = out.replaceAllMapped(RegExp(r'&#(\d+);'), (m) {
    final code = int.tryParse(m.group(1)!);
    return (code != null && code > 0 && code <= 0x10FFFF) ? String.fromCharCode(code) : m.group(0)!;
  });
  return out.replaceAll('&amp;', '&');
}

DateTime _parseXmlTime(String s) {
  final clean = s.split(' ').first.trim();
  final y = int.parse(clean.substring(0, 4));
  final m = int.parse(clean.substring(4, 6));
  final d = int.parse(clean.substring(6, 8));
  final h = int.parse(clean.substring(8, 10));
  final min = int.parse(clean.substring(10, 12));
  final sec = clean.length >= 14 ? int.parse(clean.substring(12, 14)) : 0;
  return DateTime.utc(y, m, d, h, min, sec).toLocal();
}
