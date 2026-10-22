class Program {
  final String title;
  final String desc;
  final DateTime start;
  final DateTime stop;
  final String channelKey;

  Program({
    required this.title,
    required this.desc,
    required this.start,
    required this.stop,
    required this.channelKey,
  });

  bool get isLive {
    final now = DateTime.now();
    return now.isAfter(start) && now.isBefore(stop);
  }

  double get progress {
    final now = DateTime.now();
    if (now.isBefore(start)) return 0.0;
    if (now.isAfter(stop)) return 1.0;
    final total = stop.difference(start).inSeconds;
    if (total <= 0) return 0.0;
    return (now.difference(start).inSeconds / total).clamp(0.0, 1.0);
  }

  String get timeRangeText {
    return '${_formatTime(start)} - ${_formatTime(stop)}';
  }

  String get remainingText {
    final now = DateTime.now();
    if (now.isBefore(start)) {
      final inMin = start.difference(now).inMinutes;
      return inMin > 60 ? 'Starts in ${inMin ~/ 60}h ${inMin % 60}m' : 'Starts in $inMin min';
    }
    final rem = stop.difference(now).inMinutes;
    return rem > 0 ? '$rem min left' : 'Ending soon';
  }

  static String _formatTime(DateTime dt) {
    final hour = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final min = dt.minute.toString().padLeft(2, '0');
    final ampm = dt.hour >= 12 ? 'PM' : 'AM';
    return '$hour:$min $ampm';
  }

  Map<String, dynamic> toJson() => {
        't': title,
        'd': desc,
        's': start.millisecondsSinceEpoch,
        'e': stop.millisecondsSinceEpoch,
        'k': channelKey,
      };

  factory Program.fromJson(Map<String, dynamic> j) {
    return Program(
      title: j['t'] as String? ?? '',
      desc: j['d'] as String? ?? '',
      start: DateTime.fromMillisecondsSinceEpoch(j['s'] as int),
      stop: DateTime.fromMillisecondsSinceEpoch(j['e'] as int),
      channelKey: j['k'] as String? ?? '',
    );
  }
}
