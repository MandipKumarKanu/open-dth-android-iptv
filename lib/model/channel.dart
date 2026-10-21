class Channel {
  final String name;
  final String logoUrl;
  final String category;
  final String tvgId;
  final String resolution;

  /// First URL is the main stream; the rest are backups tried when it fails.
  final List<String> streamUrls;

  /// Resolution labels matching each stream in [streamUrls] (e.g. ['1080p', '720p']).
  final List<String> streamResolutions;

  Channel({
    required this.name,
    required this.logoUrl,
    required this.category,
    required this.streamUrls,
    this.streamResolutions = const [],
    this.tvgId = '',
    this.resolution = 'HD',
  });

  bool get hasLogo => logoUrl.startsWith('http');

  String get idKey => tvgId.isNotEmpty ? tvgId.toLowerCase() : '$category|${name.toLowerCase()}';

  Map<String, dynamic> toJson() => {
        'n': name,
        'l': logoUrl,
        'c': category,
        'i': tvgId,
        's': streamUrls,
        'sr': streamResolutions,
        'r': resolution,
      };

  factory Channel.fromJson(Map<String, dynamic> j) {
    final urls = (j['s'] as List).cast<String>();
    final res = j['r'] as String? ?? 'HD';
    final sResolutions = (j['sr'] as List?)?.cast<String>() ?? List.filled(urls.length, res);
    return Channel(
      name: j['n'] as String,
      logoUrl: j['l'] as String,
      category: j['c'] as String,
      tvgId: j['i'] as String? ?? '',
      streamUrls: urls,
      streamResolutions: sResolutions,
      resolution: res,
    );
  }
}
