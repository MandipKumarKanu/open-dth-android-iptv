import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';

import '../model/channel.dart';
import '../provider/channels_provider.dart';
import '../provider/epg_provider.dart';
import '../provider/favorites_provider.dart';
import '../provider/recent_provider.dart';
import '../provider/stream_memory_provider.dart';
import '../provider/player_settings_provider.dart';
import '../widgets/channel_icon.dart';
import '../widgets/tv_search_dialog.dart';
import 'player.dart';

const bg = Color(0xFF0B0B0F);
const sidebarBg = Color(0xFF131318);
const dim = Color(0xFF8E8E98);

const _icons = <String, IconData>{
  'Home': Icons.home_rounded,
  'All': Icons.apps_rounded,
  'Favorites': Icons.star_rounded,
  'Recent': Icons.history_rounded,
  'News': Icons.newspaper_rounded,
  'Entertainment': Icons.theater_comedy_rounded,
  'Movies': Icons.movie_rounded,
  'Music': Icons.music_note_rounded,
  'Sports': Icons.sports_cricket_rounded,
  'Kids': Icons.child_care_rounded,
  'Infotainment': Icons.explore_rounded,
  'Business': Icons.trending_up_rounded,
  'Devotional': Icons.temple_hindu_rounded,
  'Lifestyle': Icons.local_florist_rounded,
  'General': Icons.tv_rounded,
  'Animation': Icons.animation_rounded,
  'Education': Icons.school_rounded,
  'Religious': Icons.temple_hindu_rounded,
  'Legislative': Icons.gavel_rounded,
  'Culture': Icons.palette_rounded,
  'Other': Icons.more_horiz_rounded,
};

const indianLanguages = [
  'All',
  'Hindi',
  'English',
  'Telugu',
  'Tamil',
  'Bangla',
  'Punjabi',
  'Marathi',
  'Gujarati',
  'Bhojpuri',
  'Kannada',
  'Malayalam',
];

bool channelMatchesLanguage(Channel c, String lang) {
  if (lang == 'All') return true;
  final n = c.name.toLowerCase();
  final id = c.tvgId.toLowerCase();
  final l = lang.toLowerCase();

  if (l == 'hindi') {
    return n.contains('hindi') ||
        n.contains('aaj tak') ||
        n.contains('zee news') ||
        n.contains('india tv') ||
        n.contains('ndtv india') ||
        n.contains('news18 india') ||
        n.contains('abp news') ||
        n.contains('&tv') ||
        n.contains('colors rishtey') ||
        n.contains('star bharat') ||
        n.contains('star plus') ||
        n.contains('zee tv') ||
        n.contains('sony pal') ||
        n.contains('dangal') ||
        n.contains('shemaroo') ||
        n.contains('b4u') ||
        n.contains('manoranjan') ||
        n.contains('samay');
  }
  if (l == 'english') {
    return n.contains('english') ||
        n.contains('cnn') ||
        n.contains('bbc') ||
        n.contains('republic tv') ||
        n.contains('times now') ||
        n.contains('india today') ||
        n.contains('wion') ||
        n.contains('ndtv 24x7') ||
        n.contains('al jazeera');
  }
  if (l == 'bangla') {
    return n.contains('bangla') || n.contains('bengali') || n.contains('kolkata') || id.contains('bangla');
  }
  return n.contains(l) || id.contains(l);
}

bool isSelectKey(LogicalKeyboardKey k) =>
    k == LogicalKeyboardKey.select ||
    k == LogicalKeyboardKey.enter ||
    k == LogicalKeyboardKey.numpadEnter ||
    k == LogicalKeyboardKey.gameButtonA;

class Home extends StatefulWidget {
  const Home({super.key});

  @override
  State<Home> createState() => _HomeState();
}

/// Category sidebar on the left, channel grid on the right. D-pad movement is handled
/// explicitly (not by Flutter's geometric focus search) so it is predictable.
class _HomeState extends State<Home> {
  int get cols {
    final width = MediaQuery.sizeOf(context).width;
    if (width < 600) return 2;
    if (width < 900) return 3;
    if (width < 1100) return 4;
    return 6;
  }

  final provider = ChannelsProvider();

  List<String> categories = [];
  Map<String, List<Channel>> byCategory = {};
  int selected = 0;
  bool loading = true;
  String? error;

  String selectedLanguage = 'All';
  final FocusNode _searchNode = FocusNode();
  final FocusNode _headerLanguageNode = FocusNode();
  final ScrollController _sidebarController = ScrollController();
  final List<FocusNode> sideNodes = [];
  /// one node per tile, keyed "category/index"; kept until the screen closes
  final Map<String, FocusNode> tileNodes = {};
  double rowExtent = 100;

  /// Each category keeps its own grid (built once, then kept alive offstage), scroll position and
  /// last focused tile, so returning to a category costs nothing.
  final Map<String, ScrollController> _controllers = {};
  final Map<String, int> _lastTile = {};
  final Map<String, Widget> _grids = {};
  final List<String> _mounted = [];
  Size? _gridSizes;

  /// Categories not visited yet are pre-built one at a time while the remote is idle.
  Timer? _prebuildTimer;
  DateTime _lastInput = DateTime.fromMillisecondsSinceEpoch(0);

  String get _cat => categories[selected];
  ScrollController get grid => _controllers.putIfAbsent(_cat, () => ScrollController());
  int get lastTile => _lastTile[_cat] ?? 0;
  set lastTile(int v) => _lastTile[_cat] = v;

  /// Moving through the sidebar only moves the highlight; the grid switches once you pause.
  Timer? _switchTimer;
  static const _switchDelay = Duration(milliseconds: 200);

  final Map<String, List<Channel>> _renderedCategoryLists = {};
  final Map<String, List<Channel>> _renderedHomeRecents = {};
  final Map<String, List<Channel>> _renderedHomeFavs = {};
  final Set<String> _dirtyCategories = {};
  bool _hasFavChangesWhileInCat = false;
  bool _autoPlayTriggered = false;

  void _invalidateAllGrids() {
    _renderedCategoryLists.clear();
    _renderedHomeRecents.clear();
    _renderedHomeFavs.clear();
    _dirtyCategories.clear();
    _grids.clear();
    _hasFavChangesWhileInCat = false;
  }

  List<Channel> _getCategoryChannels(String cat) {
    if (_renderedCategoryLists.containsKey(cat)) {
      return _renderedCategoryLists[cat]!;
    }
    final raw = byCategory[cat] ?? const <Channel>[];
    final filtered = selectedLanguage == 'All'
        ? raw
        : raw.where((c) => channelMatchesLanguage(c, selectedLanguage)).toList();

    if (cat == 'Favorites' || cat == 'Recent') {
      _renderedHomeRecents[cat] = const [];
      _renderedHomeFavs[cat] = const [];
      _renderedCategoryLists[cat] = filtered;
      return filtered;
    }

    // 1. Category-specific recents (up to 2 rows = cols * 2 = 12 channels)
    final allRecent = byCategory['Recent'] ?? const <Channel>[];
    final recRaw = (cat == 'Home' || cat == 'All')
        ? allRecent
        : allRecent.where((c) => c.category == cat).toList();
    final recFiltered = selectedLanguage == 'All'
        ? recRaw
        : recRaw.where((c) => channelMatchesLanguage(c, selectedLanguage)).toList();
    final recents = recFiltered.take(cols * 2).toList();
    _renderedHomeRecents[cat] = recents;

    // 2. Category-specific favorites
    final allFav = byCategory['Favorites'] ?? const <Channel>[];
    final favRaw = (cat == 'Home' || cat == 'All')
        ? allFav
        : allFav.where((c) => c.category == cat).toList();
    final favFiltered = selectedLanguage == 'All'
        ? favRaw
        : favRaw.where((c) => channelMatchesLanguage(c, selectedLanguage)).toList();
    final favs = favFiltered.toList();
    _renderedHomeFavs[cat] = favs;

    // 3. All channels for this category
    final fullList = <Channel>[
      ...recents,
      ...favs,
      ...filtered,
    ];
    _renderedCategoryLists[cat] = fullList;
    return fullList;
  }

  List<Channel> get current {
    if (categories.isEmpty) return const [];
    return _getCategoryChannels(categories[selected]);
  }

  Timer? _okTimer;
  bool _okTriggered = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchNode.dispose();
    _headerLanguageNode.dispose();
    _sidebarController.dispose();
    for (final n in sideNodes) {
      n.dispose();
    }
    for (final n in tileNodes.values) {
      n.dispose();
    }
    for (final c in _controllers.values) {
      c.dispose();
    }
    _switchTimer?.cancel();
    _prebuildTimer?.cancel();
    _okTimer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    // 0) load saved favorites, recents, and EPG data
    await FavoritesProvider.instance.load();
    await RecentProvider.instance.load();
    await StreamMemoryProvider.instance.load();
    await PlayerSettingsProvider.instance.load();
    await EpgProvider.instance.loadCached();
    EpgProvider.instance.refresh();

    // 1) cached list -> instant start
    final cached = await provider.loadCached();
    if (cached != null && mounted) {
      _setChannels(cached);
      _maybeAutoPlayRecent(cached);
    }
    // 2) fresh list in the background
    try {
      final fresh = await provider.refresh();
      if (mounted) {
        _setChannels(fresh);
        if (!_autoPlayTriggered) {
          _maybeAutoPlayRecent(fresh);
        }
      }
    } catch (e) {
      if (mounted && categories.isEmpty) {
        setState(() {
          loading = false;
          error = 'Could not load channels. Check the internet connection.';
        });
      }
    }
  }

  void _maybeAutoPlayRecent(List<Channel> channels) {
    if (_autoPlayTriggered || !mounted) return;
    final recents = RecentProvider.instance.filterRecent(channels);
    if (recents.isEmpty) return;
    _autoPlayTriggered = true;

    final targetChannel = recents.first;
    final all = byCategory['All'] ?? byCategory['Home'] ?? channels;
    final idx = all.indexWhere((c) => c.idKey == targetChannel.idKey);
    if (idx < 0) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _playDirect(all, idx);
    });
  }

  void _setChannels(List<Channel> channels) {
    final map = <String, List<Channel>>{
      'Home': channels,
      'All': channels,
    };
    final favs = channels.where((c) => FavoritesProvider.instance.isFavorite(c)).toList();
    map['Favorites'] = favs;
    final recents = RecentProvider.instance.filterRecent(channels);
    map['Recent'] = recents;
    for (final c in channels) {
      (map[c.category] ??= []).add(c);
    }
    final remainingCats = map.keys
        .where((k) =>
            k != 'Home' &&
            k != 'Favorites' &&
            k != 'Recent' &&
            !categoryOrder.contains(k) &&
            (map[k]?.isNotEmpty ?? false))
        .toList()
      ..sort();
    final cats = [
      'Home',
      'Favorites',
      ...categoryOrder.where((c) => c != 'Favorites' && c != 'Recent' && (map[c]?.isNotEmpty ?? false)),
      ...remainingCats,
    ];
    final first = categories.isEmpty;
    final keep = first ? 'Home' : (categories[selected] == 'All' ? 'Home' : categories[selected]);
    setState(() {
      byCategory = map;
      categories = cats;
      selected = cats.contains(keep) ? cats.indexOf(keep) : 0;
      loading = false;
      error = null;
      while (sideNodes.length < cats.length) {
        sideNodes.add(FocusNode());
      }
      // new data: rebuild grids lazily again
      _invalidateAllGrids();
      _mounted
        ..clear()
        ..add(cats[selected]);
    });
    _prebuildTimer?.cancel();
    _prebuildTimer = Timer.periodic(const Duration(milliseconds: 400), (_) => _prebuildNext());
    if (first) {
      WidgetsBinding.instance.addPostFrameCallback((_) => sideNodes[selected].requestFocus());
    }
  }

  Future<void> _toggleFav(int i) async {
    final list = current;
    if (i < 0 || i >= list.length) return;
    final channel = list[i];
    await FavoritesProvider.instance.toggle(channel);
    if (!mounted) return;

    final all = byCategory['All'] ?? byCategory['Home'] ?? [];
    byCategory['Favorites'] = all.where((c) => FavoritesProvider.instance.isFavorite(c)).toList();
    byCategory['Recent'] = RecentProvider.instance.filterRecent(all);

    _hasFavChangesWhileInCat = true;
    _dirtyCategories.addAll(categories.where((c) => c != _cat));

    // Keep grid and current list stable; only update sidebar count via setState
    setState(() {});
  }

  void _openSearchDialog({bool autoStartVoice = false}) {
    showDialog(
      context: context,
      builder: (_) => TvSearchDialog(
        allChannels: byCategory['All'] ?? byCategory['Home'] ?? [],
        autoStartVoice: autoStartVoice,
        onChannelSelect: (ch) {
          final all = byCategory['All'] ?? byCategory['Home'] ?? [];
          final idx = all.indexWhere((c) => c.idKey == ch.idKey);
          _playDirect(all, idx >= 0 ? idx : 0);
        },
      ),
    );
  }

  // ---------------------------------------------------------------- navigation

  FocusNode _tileNode(int i) => tileNodes.putIfAbsent('${categories[selected]}/$selectedLanguage/$i', () => FocusNode());

  void _selectCategory(int i) {
    if (i == selected) return;
    lastTile = 0;
    final oldCat = _cat;
    if (_hasFavChangesWhileInCat) {
      _dirtyCategories.add(oldCat);
      _renderedCategoryLists.remove(oldCat);
      _renderedHomeFavs.remove(oldCat);
      _renderedHomeRecents.remove(oldCat);
      _grids.remove(oldCat);
      _hasFavChangesWhileInCat = false;
    }

    setState(() {
      selected = i;
      final newCat = categories[selected];
      if (_dirtyCategories.contains(newCat)) {
        _dirtyCategories.remove(newCat);
        _renderedCategoryLists.remove(newCat);
        _renderedHomeFavs.remove(newCat);
        _renderedHomeRecents.remove(newCat);
        _grids.remove(newCat);
      }
      if (!_mounted.contains(newCat)) _mounted.add(newCat);
    });
  }

  /// Builds one not-yet-visited category offstage, only when no key was pressed recently.
  void _prebuildNext() {
    if (!mounted || categories.isEmpty) return;
    if (DateTime.now().difference(_lastInput) < const Duration(milliseconds: 900)) return;
    final next = categories.where((c) => !_mounted.contains(c)).firstOrNull;
    if (next == null) {
      _prebuildTimer?.cancel();
      return;
    }
    setState(() => _mounted.add(next));
  }

  bool _isVoiceKey(LogicalKeyboardKey k) =>
      k.keyId == 0x002000000e7 || // KEYCODE_VOICE_ASSIST
      k.keyId == 0x00200000054 || // KEYCODE_SEARCH
      k.keyId == 0x002000000db || // KEYCODE_ASSIST
      k == LogicalKeyboardKey.f5;

  KeyEventResult _searchKey(KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (_isVoiceKey(k)) {
      _openSearchDialog(autoStartVoice: true);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowDown) {
      if (sideNodes.isNotEmpty) sideNodes[0].requestFocus();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowRight || isSelectKey(k)) {
      _openSearchDialog();
      return KeyEventResult.handled;
    }
    return KeyEventResult.handled;
  }

  KeyEventResult _sideKey(int i, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    _lastInput = DateTime.now();
    final k = e.logicalKey;
    if (_isVoiceKey(k)) {
      _openSearchDialog(autoStartVoice: true);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowUp) {
      if (i > 0) {
        sideNodes[i - 1].requestFocus();
      } else {
        _searchNode.requestFocus();
        if (_sidebarController.hasClients) {
          _sidebarController.animateTo(
            0,
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeInOut,
          );
        }
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowDown) {
      if (i < categories.length - 1) sideNodes[i + 1].requestFocus();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowRight || isSelectKey(k)) {
      if (i != selected) {
        _switchTimer?.cancel();
        _selectCategory(i);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (current.isNotEmpty) _focusTile(lastTile.clamp(0, current.length - 1));
        });
      } else if (current.isNotEmpty) {
        _focusTile(lastTile.clamp(0, current.length - 1));
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowLeft) return KeyEventResult.handled;
    return KeyEventResult.ignored;
  }

  KeyEventResult _tileKey(int i, KeyEvent e) {
    _lastInput = DateTime.now();
    final k = e.logicalKey;

    // Handle Select long-press for Favorites toggle, tap for Play
    if (isSelectKey(k)) {
      if (e is KeyDownEvent) {
        if (_okTimer == null && !_okTriggered) {
          _okTriggered = false;
          _okTimer = Timer(const Duration(milliseconds: 380), () {
            _okTriggered = true;
            _toggleFav(i);
          });
        }
        return KeyEventResult.handled;
      } else if (e is KeyRepeatEvent) {
        if (!_okTriggered) {
          _okTimer?.cancel();
          _okTimer = null;
          _okTriggered = true;
          _toggleFav(i);
        }
        return KeyEventResult.handled;
      } else if (e is KeyUpEvent) {
        final wasTriggered = _okTriggered;
        _okTimer?.cancel();
        _okTimer = null;
        _okTriggered = false;
        if (!wasTriggered) {
          _play(i);
        }
        return KeyEventResult.handled;
      }
      return KeyEventResult.handled;
    }

    // Voice Search on remote Google Assistant / Mic button
    if (_isVoiceKey(k)) {
      _openSearchDialog(autoStartVoice: true);
      return KeyEventResult.handled;
    }

    // Toggle Favorite instantly on remote MENU / PLAY_PAUSE / F1 / F3 keys
    if (k == LogicalKeyboardKey.contextMenu ||
        k == LogicalKeyboardKey.mediaPlayPause ||
        k == LogicalKeyboardKey.f1 ||
        k == LogicalKeyboardKey.f3) {
      if (e is KeyDownEvent) {
        _toggleFav(i);
      }
      return KeyEventResult.handled;
    }

    if (e is KeyUpEvent) return KeyEventResult.ignored;
    _okTimer?.cancel();
    _okTimer = null;
    _okTriggered = false;

    final n = current.length;
    int? target;
    final recCount = _renderedHomeRecents[_cat]?.length ?? 0;
    final favCount = _renderedHomeFavs[_cat]?.length ?? 0;
    final R = recCount;
    final F = favCount;
    final hasSections = (R > 0 || F > 0);

    if (k == LogicalKeyboardKey.arrowLeft) {
      if (hasSections) {
        final col = (i < R)
            ? (i % cols)
            : (i < R + F)
                ? ((i - R) % cols)
                : ((i - R - F) % cols);
        if (col == 0) {
          sideNodes[selected].requestFocus();
          return KeyEventResult.handled;
        }
        target = i - 1;
      } else {
        if (i % cols == 0) {
          sideNodes[selected].requestFocus();
          return KeyEventResult.handled;
        }
        target = i - 1;
      }
    } else if (k == LogicalKeyboardKey.arrowRight) {
      if (hasSections) {
        if (i < R) {
          if (i % cols < cols - 1 && i + 1 < R) target = i + 1;
        } else if (i < R + F) {
          final local = i - R;
          if (local % cols < cols - 1 && local + 1 < F) target = i + 1;
        } else {
          final local = i - R - F;
          final allLen = n - R - F;
          if (local % cols < cols - 1 && local + 1 < allLen) target = i + 1;
        }
      } else {
        if (i % cols < cols - 1 && i + 1 < n) target = i + 1;
      }
    } else if (k == LogicalKeyboardKey.arrowUp) {
      if (hasSections) {
        if (i < R) {
          if (i >= cols) {
            target = i - cols;
          } else {
            _headerLanguageNode.requestFocus();
            return KeyEventResult.handled;
          }
        } else if (i < R + F) {
          final local = i - R;
          if (local >= cols) {
            target = i - cols;
          } else if (R > 0) {
            final lastRecRow = (R - 1) ~/ cols;
            final lastRecRowStart = lastRecRow * cols;
            final colInRec = (local % cols).clamp(0, R - 1 - lastRecRowStart);
            target = lastRecRowStart + colInRec;
          } else {
            _headerLanguageNode.requestFocus();
            return KeyEventResult.handled;
          }
        } else {
          final local = i - R - F;
          if (local >= cols) {
            target = i - cols;
          } else if (F > 0) {
            final lastFavRow = (F - 1) ~/ cols;
            final lastFavRowStart = R + (lastFavRow * cols);
            final colInFav = (local % cols).clamp(0, F - 1 - (lastFavRow * cols));
            target = lastFavRowStart + colInFav;
          } else if (R > 0) {
            final lastRecRow = (R - 1) ~/ cols;
            final lastRecRowStart = lastRecRow * cols;
            final colInRec = (local % cols).clamp(0, R - 1 - lastRecRowStart);
            target = lastRecRowStart + colInRec;
          } else {
            _headerLanguageNode.requestFocus();
            return KeyEventResult.handled;
          }
        }
      } else {
        if (i >= cols) {
          target = i - cols;
        } else {
          _headerLanguageNode.requestFocus();
          return KeyEventResult.handled;
        }
      }
    } else if (k == LogicalKeyboardKey.arrowDown) {
      if (hasSections) {
        if (i < R) {
          if (i + cols < R) {
            target = i + cols;
          } else {
            final col = i % cols;
            if (F > 0) {
              target = R + col.clamp(0, F - 1);
            } else {
              final allLen = n - R;
              if (allLen > 0) {
                target = R + col.clamp(0, allLen - 1);
              }
            }
          }
        } else if (i < R + F) {
          final local = i - R;
          if (local + cols < F) {
            target = i + cols;
          } else {
            final col = local % cols;
            final allLen = n - R - F;
            if (allLen > 0) {
              target = R + F + col.clamp(0, allLen - 1);
            }
          }
        } else {
          final local = i - R - F;
          final allLen = n - R - F;
          if (local + cols < allLen) {
            target = i + cols;
          } else if (local ~/ cols < (allLen - 1) ~/ cols) {
            target = n - 1;
          }
        }
      } else {
        if (i + cols < n) {
          target = i + cols;
        } else if (i ~/ cols < (n - 1) ~/ cols) {
          target = n - 1;
        }
      }
    } else if (k == LogicalKeyboardKey.goBack || k == LogicalKeyboardKey.escape) {
      // Back from the grid returns to the sidebar; Back on the sidebar exits
      sideNodes[selected].requestFocus();
      return KeyEventResult.handled;
    } else {
      return KeyEventResult.ignored;
    }
    if (target != null) _focusTile(target);
    return KeyEventResult.handled;
  }

  /// Scroll so the row is visible, then focus the tile (tiles are built lazily).
  void _focusTile(int i) {
    lastTile = i;
    if (grid.hasClients) {
      final pos = grid.position;
      double top;
      final recCount = _renderedHomeRecents[_cat]?.length ?? 0;
      final favCount = _renderedHomeFavs[_cat]?.length ?? 0;
      final R = recCount;
      final F = favCount;

      if (R > 0 || F > 0) {
        // Measured against the sliver headers in the grid builder: each
        // header is a 20 px icon/text row plus padding (Recent 6/10, Fav top
        // 18 with recents above else 6, All 18/10 when a section precedes it).
        const headerRecHeight = 36.0; // 6 + 20 + 10
        final headerFavHeight = (R > 0 ? 18.0 : 6.0) + 30.0;
        const headerAllHeight = 48.0; // 18 + 20 + 10
        final recRows = (R + cols - 1) ~/ cols;
        final favRows = (F + cols - 1) ~/ cols;

        if (i < R) {
          top = headerRecHeight + (i ~/ cols) * rowExtent;
        } else if (i < R + F) {
          final local = i - R;
          top = (R > 0 ? headerRecHeight + (recRows * rowExtent) : 0) +
                headerFavHeight +
                ((local ~/ cols) * rowExtent);
        } else {
          final local = i - R - F;
          top = (R > 0 ? headerRecHeight + (recRows * rowExtent) : 0) +
                (F > 0 ? headerFavHeight + (favRows * rowExtent) : 0) +
                headerAllHeight +
                ((local ~/ cols) * rowExtent);
        }
      } else if (_cat == 'Home') {
        // Empty Home: tip banner (10 + 18 + 12) + All header (10 + 20 + 10)
        top = 80.0 + (i ~/ cols) * rowExtent;
      } else if (_cat != 'Favorites' && _cat != 'Recent') {
        // Category without recents/favs has "$cat (All)" header (18 + 20 + 10)
        const headerAllHeight = 48.0;
        top = headerAllHeight + (i ~/ cols) * rowExtent;
      } else {
        top = (i ~/ cols) * rowExtent;
      }

      const margin = 20.0;
      double? to;
      if (top - margin < pos.pixels) {
        to = top - margin;
      } else if (top + rowExtent + margin > pos.pixels + pos.viewportDimension) {
        to = top + rowExtent + margin - pos.viewportDimension;
      }
      if (to != null) {
        grid.animateTo(to.clamp(0.0, pos.maxScrollExtent),
            duration: const Duration(milliseconds: 140), curve: Curves.easeOut);
      }
    }
    final node = _tileNode(i);
    if (node.context != null) {
      node.requestFocus();
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => node.requestFocus());
    }
  }

  Future<void> _play(int i) async {
    final list = current;
    if (list.isEmpty || i >= list.length) return;
    final result = await Navigator.of(context).push<int>(PageRouteBuilder(
      pageBuilder: (_, __, ___) => Player(
        channels: list,
        index: i,
        allChannels: byCategory['All'] ?? byCategory['Home'] ?? list,
        initialCategory: categories[selected],
      ),
      transitionDuration: const Duration(milliseconds: 150),
      reverseTransitionDuration: const Duration(milliseconds: 120),
      transitionsBuilder: (_, a, __, child) => FadeTransition(opacity: a, child: child),
    ));
    // land on the channel that was playing last & refresh favorites & recents
    if (mounted && list.isNotEmpty) {
      final all = byCategory['All'] ?? byCategory['Home'] ?? [];
      byCategory['Favorites'] = all.where((c) => FavoritesProvider.instance.isFavorite(c)).toList();
      byCategory['Recent'] = RecentProvider.instance.filterRecent(all);
      _invalidateAllGrids();
      setState(() {});
      if (current.isNotEmpty) {
        final lastIdx = result ?? i;
        Channel? lastPlayed;
        if (lastIdx >= 0 && lastIdx < list.length) {
          lastPlayed = list[lastIdx];
        } else if (RecentProvider.instance.ids.isNotEmpty) {
          final firstKey = RecentProvider.instance.ids.first;
          lastPlayed = all.where((c) => c.idKey == firstKey).firstOrNull ?? current.first;
        }
        int targetIdx = -1;
        if (lastPlayed != null) {
          targetIdx = current.indexWhere((c) => c.idKey == lastPlayed!.idKey);
        }
        _focusTile((targetIdx >= 0 ? targetIdx : lastIdx).clamp(0, current.length - 1));
      }
    }
  }

  Future<void> _playDirect(List<Channel> list, int i) async {
    final result = await Navigator.of(context).push<int>(PageRouteBuilder(
      pageBuilder: (_, __, ___) => Player(
        channels: list,
        index: i,
        allChannels: byCategory['All'] ?? list,
        initialCategory: 'All',
      ),
      transitionDuration: const Duration(milliseconds: 150),
      reverseTransitionDuration: const Duration(milliseconds: 120),
      transitionsBuilder: (_, a, __, child) => FadeTransition(opacity: a, child: child),
    ));
    if (mounted) {
      final all = byCategory['All'] ?? [];
      byCategory['Favorites'] = all.where((c) => FavoritesProvider.instance.isFavorite(c)).toList();
      byCategory['Recent'] = RecentProvider.instance.filterRecent(all);
      _invalidateAllGrids();
      setState(() {});
      if (current.isNotEmpty) {
        final lastIdx = result ?? i;
        Channel? lastPlayed;
        if (lastIdx >= 0 && lastIdx < list.length) {
          lastPlayed = list[lastIdx];
        } else if (RecentProvider.instance.ids.isNotEmpty) {
          final firstKey = RecentProvider.instance.ids.first;
          lastPlayed = all.where((c) => c.idKey == firstKey).firstOrNull ?? current.first;
        }
        int targetIdx = -1;
        if (lastPlayed != null) {
          targetIdx = current.indexWhere((c) => c.idKey == lastPlayed!.idKey);
        }
        _focusTile((targetIdx >= 0 ? targetIdx : lastIdx).clamp(0, current.length - 1));
      }
    }
  }

  // ---------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final isMobile = size.width < 720 || size.shortestSide < 600;
    return Scaffold(
      backgroundColor: bg,
      body: SafeArea(
        child: isMobile
            ? Column(
                children: [
                  _mobileTopBar(),
                  _mobileCategoryBar(),
                  Expanded(child: _content(mobile: true)),
                ],
              )
            : Row(
                children: [
                  _sidebar(),
                  Expanded(child: _content()),
                ],
              ),
      ),
    );
  }

  Widget _mobileTopBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 12, 6),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              color: const Color(0xFFE53935),
              borderRadius: BorderRadius.circular(9),
            ),
            child: const Icon(Icons.live_tv_rounded, size: 20, color: Colors.white),
          ),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'Open DTH',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800),
            ),
          ),
          IconButton(
            tooltip: 'Search channels',
            onPressed: _openSearchDialog,
            style: IconButton.styleFrom(
              backgroundColor: const Color(0xFF1E293B),
              foregroundColor: const Color(0xFF38BDF8),
              minimumSize: const Size(46, 46),
            ),
            icon: const Icon(Icons.search_rounded),
          ),
        ],
      ),
    );
  }

  Widget _mobileCategoryBar() {
    if (categories.isEmpty) return const SizedBox(height: 8);
    return SizedBox(
      height: 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 3),
        itemCount: categories.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final isSelected = i == selected;
          final label = categories[i];
          return Semantics(
            button: true,
            selected: isSelected,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                _switchTimer?.cancel();
                _selectCategory(i);
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 140),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                decoration: BoxDecoration(
                  color: isSelected ? Colors.white : const Color(0xFF1B1B24),
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(
                    color: isSelected ? Colors.white : const Color(0x28FFFFFF),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _icons[label] ?? Icons.tv_rounded,
                      size: 16,
                      color: isSelected ? Colors.black : const Color(0xFFB4B4BE),
                    ),
                    const SizedBox(width: 7),
                    Text(
                      label,
                      style: TextStyle(
                        color: isSelected ? Colors.black : Colors.white,
                        fontSize: 13,
                        fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                      ),
                    ),
                    if (label == 'Favorites' && (byCategory[label]?.isNotEmpty ?? false)) ...[
                      const SizedBox(width: 5),
                      Text(
                        '${byCategory[label]!.length}',
                        style: TextStyle(
                          color: isSelected ? Colors.black54 : dim,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _sidebar() {
    return Container(
      width: 210,
      color: sidebarBg,
      padding: const EdgeInsets.fromLTRB(14, 26, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 8, bottom: 16),
            child: Row(children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(color: const Color(0xFFE53935), borderRadius: BorderRadius.circular(8)),
                child: const Icon(Icons.live_tv_rounded, size: 16, color: Colors.white),
              ),
              const SizedBox(width: 10),
              const Text('Live TV', style: TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.w700)),
            ]),
          ),
          _SearchSidebarTile(
            node: _searchNode,
            onTap: _openSearchDialog,
            onKey: _searchKey,
          ),
          const SizedBox(height: 10),
          Expanded(
            child: SingleChildScrollView(
              controller: _sidebarController,
              padding: const EdgeInsets.only(bottom: 24),
              child: Column(
                children: [
                  for (int i = 0; i < categories.length; i++)
                    _SideItem(
                      node: sideNodes[i],
                      icon: _icons[categories[i]] ?? Icons.tv_rounded,
                      label: categories[i],
                      count: byCategory[categories[i]]?.length ?? 0,
                      selected: i == selected,
                      onFocus: () {
                        _switchTimer?.cancel();
                        _switchTimer = Timer(_switchDelay, () {
                          if (mounted) _selectCategory(i);
                        });
                      },
                      onKey: (e) => _sideKey(i, e),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _content({bool mobile = false}) {
    if (loading && categories.isEmpty) {
      return const Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white)),
          SizedBox(height: 14),
          Text('Loading channels…', style: TextStyle(color: dim, fontSize: 14)),
        ]),
      );
    }
    if (error != null && categories.isEmpty) {
      return Center(child: Text(error!, style: const TextStyle(color: dim, fontSize: 15)));
    }
    final list = current;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Category title, count, resolution tag & language dropdown button
        Padding(
          padding: EdgeInsets.fromLTRB(mobile ? 16 : 28, mobile ? 10 : 22, mobile ? 16 : 28, mobile ? 8 : 12),
          child: mobile
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            categories[selected],
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white, fontSize: 21, fontWeight: FontWeight.w800),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text('${list.length} channels', style: const TextStyle(color: dim, fontSize: 12)),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                          decoration: BoxDecoration(
                            border: Border.all(color: dim.withValues(alpha: 0.45)),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Text('FHD · HD', style: TextStyle(color: dim, fontSize: 10, fontWeight: FontWeight.w600)),
                        ),
                        const Spacer(),
                        _buildLanguageDropdownButton(),
                      ],
                    ),
                  ],
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Text(categories[selected],
                        style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w700)),
                    const SizedBox(width: 12),
                    Text('${list.length} channels', style: const TextStyle(color: dim, fontSize: 13)),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                          border: Border.all(color: dim.withValues(alpha: 0.5)),
                          borderRadius: BorderRadius.circular(4)),
                      child: const Text('FHD · HD',
                          style: TextStyle(color: dim, fontSize: 10, fontWeight: FontWeight.w600)),
                    ),
                    const Spacer(),
                    _buildLanguageDropdownButton(),
                  ],
                ),
        ),

        Expanded(
          child: LayoutBuilder(builder: (context, box) {
            if (_gridSizes != box.biggest) {
              _gridSizes = box.biggest;
              _invalidateAllGrids();
            }
            return IndexedStack(
              index: _mounted.indexOf(_cat),
              children: [
                // same widget instance each time -> Flutter skips rebuilding hidden grids
                for (final c in _mounted) _grids.putIfAbsent(c, () => _grid(c, box.maxWidth)),
              ],
            );
          }),
        ),
      ],
    );
  }

  Widget _buildLanguageDropdownButton() {
    return Focus(
      focusNode: _headerLanguageNode,
      onKeyEvent: (_, e) {
        if (e is KeyUpEvent) return KeyEventResult.ignored;
        final k = e.logicalKey;
        if (k == LogicalKeyboardKey.arrowDown) {
          if (current.isNotEmpty) {
            _focusTile(0);
          }
          return KeyEventResult.handled;
        }
        if (k == LogicalKeyboardKey.arrowLeft) {
          sideNodes[selected].requestFocus();
          return KeyEventResult.handled;
        }
        if (isSelectKey(k)) {
          _openLanguageDialog();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: ListenableBuilder(
        listenable: _headerLanguageNode,
        builder: (context, _) {
          final hasFocus = _headerLanguageNode.hasFocus;
          return GestureDetector(
            onTap: _openLanguageDialog,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: BoxDecoration(
                color: hasFocus ? Colors.white : const Color(0xFF1E293B),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: hasFocus ? Colors.white : const Color(0xFF38BDF8).withValues(alpha: 0.4),
                  width: hasFocus ? 2 : 1,
                ),
                boxShadow: hasFocus
                    ? [BoxShadow(color: Colors.white.withValues(alpha: 0.5), blurRadius: 10)]
                    : null,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.translate_rounded,
                    size: 15,
                    color: hasFocus ? Colors.black : const Color(0xFF38BDF8),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    selectedLanguage == 'All' ? 'All Languages' : selectedLanguage,
                    style: TextStyle(
                      color: hasFocus ? Colors.black : Colors.white,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Icon(
                    Icons.arrow_drop_down_rounded,
                    size: 20,
                    color: hasFocus ? Colors.black : const Color(0xFF94A3B8),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _openLanguageDialog() {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black87,
      builder: (ctx) => _LanguageSelectionDialog(
        currentLanguage: selectedLanguage,
        languages: indianLanguages,
        onSelect: (lang) {
          setState(() {
            selectedLanguage = lang;
            _invalidateAllGrids();
          });
          _headerLanguageNode.requestFocus();
        },
      ),
    );
  }

  Widget _grid(String cat, double width) {
    const pad = 20.0;
    final cellW = (width - pad * 2) / cols;
    final cardW = cellW - 14;
    final cardH = cardW * 0.58;
    rowExtent = cardH + 40;
    final list = _getCategoryChannels(cat);

    if (cat != 'Favorites' && cat != 'Recent') {
      final recents = _renderedHomeRecents[cat] ?? const <Channel>[];
      final favs = _renderedHomeFavs[cat] ?? const <Channel>[];
      final raw = byCategory[cat] ?? const <Channel>[];
      final allList = selectedLanguage == 'All'
          ? raw
          : raw.where((c) => channelMatchesLanguage(c, selectedLanguage)).toList();
      final controller = _controllers.putIfAbsent(cat, () => ScrollController());

      final R = recents.length;
      final F = favs.length;
      final A = allList.length;

      if (A == 0 && R == 0 && F == 0) {
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.tv_off_rounded, size: 48, color: Colors.white24),
              const SizedBox(height: 12),
              Text('No channels found for $selectedLanguage in $cat',
                  style: const TextStyle(color: dim, fontSize: 14)),
            ],
          ),
        );
      }

      final slivers = <Widget>[];

      // 1. Tip banner if no recents and no favs on Home
      if (cat == 'Home' && R == 0 && F == 0) {
        slivers.add(
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(pad, 10, pad, 12),
              child: Row(
                children: [
                  Icon(Icons.history_rounded, color: Color(0xFF38BDF8), size: 18),
                  SizedBox(width: 8),
                  Text('Tip: Channels you watch will appear here in Recent for quick access',
                      style: TextStyle(color: Color(0xCCFFFFFF), fontSize: 13, fontWeight: FontWeight.w500)),
                ],
              ),
            ),
          ),
        );
      }

      // 2. Recent Channels Section (up to 2 rows = max 12 channels)
      if (R > 0) {
        slivers.add(
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(pad, 6, pad, 10),
              child: Row(
                children: [
                  const Icon(Icons.history_rounded, color: Color(0xFF38BDF8), size: 20),
                  const SizedBox(width: 8),
                  Text(cat == 'Home' ? 'Recently Watched' : '$cat Recently Watched',
                      style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0x2238BDF8),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: const Color(0x4438BDF8), width: 1),
                    ),
                    child: Text('$R',
                        style: const TextStyle(color: Color(0xFF38BDF8), fontSize: 11, fontWeight: FontWeight.w700)),
                  ),
                ],
              ),
            ),
          ),
        );
        slivers.add(
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: pad),
            sliver: SliverGrid(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: cols,
                mainAxisExtent: rowExtent,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, i) => _Tile(
                  key: ValueKey('$cat/$selectedLanguage/rec_$i'),
                  channel: recents[i],
                  node: tileNodes.putIfAbsent('$cat/$selectedLanguage/$i', () => FocusNode()),
                  cardW: cardW,
                  cardH: cardH,
                  onTap: () => _play(i),
                  onLongPress: () => _toggleFav(i),
                  onKey: (e) => _tileKey(i, e),
                ),
                childCount: R,
              ),
            ),
          ),
        );
      }

      // 3. Favorites Section (if any)
      if (F > 0) {
        slivers.add(
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(pad, R > 0 ? 18 : 6, pad, 10),
              child: Row(
                children: [
                  const Icon(Icons.star_rounded, color: Color(0xFFFFD700), size: 20),
                  const SizedBox(width: 8),
                  Text(cat == 'Home' ? 'Favorites' : '$cat Favorites',
                      style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0x22FFD700),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: const Color(0x44FFD700), width: 1),
                    ),
                    child: Text('$F',
                        style: const TextStyle(color: Color(0xFFFFD700), fontSize: 11, fontWeight: FontWeight.w700)),
                  ),
                ],
              ),
            ),
          ),
        );
        slivers.add(
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: pad),
            sliver: SliverGrid(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: cols,
                mainAxisExtent: rowExtent,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, f) {
                  final globalIdx = R + f;
                  return _Tile(
                    key: ValueKey('$cat/$selectedLanguage/fav_$f'),
                    channel: favs[f],
                    node: tileNodes.putIfAbsent('$cat/$selectedLanguage/$globalIdx', () => FocusNode()),
                    cardW: cardW,
                    cardH: cardH,
                    onTap: () => _play(globalIdx),
                    onLongPress: () => _toggleFav(globalIdx),
                    onKey: (e) => _tileKey(globalIdx, e),
                  );
                },
                childCount: F,
              ),
            ),
          ),
        );
      }

      // 4. All Channels Section
      if (A > 0) {
        slivers.add(
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(pad, (R > 0 || F > 0) ? 18 : 10, pad, 10),
              child: Row(
                children: [
                  Icon(_icons[cat] ?? Icons.tv_rounded, color: const Color(0xFF818CF8), size: 20),
                  const SizedBox(width: 8),
                  Text(cat == 'Home' ? 'All Channels' : '$cat (All)',
                      style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0x22818CF8),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: const Color(0x44818CF8), width: 1),
                    ),
                    child: Text('$A',
                        style: const TextStyle(color: Color(0xFF818CF8), fontSize: 11, fontWeight: FontWeight.w700)),
                  ),
                ],
              ),
            ),
          ),
        );
        slivers.add(
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(pad, 0, pad, 30),
            sliver: SliverGrid(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: cols,
                mainAxisExtent: rowExtent,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, j) {
                  final globalIdx = R + F + j;
                  return _Tile(
                    key: ValueKey('$cat/$selectedLanguage/all_$j'),
                    channel: allList[j],
                    node: tileNodes.putIfAbsent('$cat/$selectedLanguage/$globalIdx', () => FocusNode()),
                    cardW: cardW,
                    cardH: cardH,
                    onTap: () => _play(globalIdx),
                    onLongPress: () => _toggleFav(globalIdx),
                    onKey: (e) => _tileKey(globalIdx, e),
                  );
                },
                childCount: A,
              ),
            ),
          ),
        );
      }

      return CustomScrollView(
        key: ValueKey('grid/$cat/$selectedLanguage/$R/$F'),
        controller: controller,
        scrollCacheExtent: ScrollCacheExtent.pixels(rowExtent),
        slivers: slivers,
      );
    }

    if (cat == 'Favorites' && list.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: const Color(0x18FFD700),
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0x40FFD700), width: 1.5),
              ),
              child: const Icon(Icons.star_rounded, size: 52, color: Color(0xFFFFD700)),
            ),
            const SizedBox(height: 18),
            const Text('No Favorite Channels Yet',
                style: TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            const Text('Hold OK or press Menu on any channel to pin it here',
                style: TextStyle(color: dim, fontSize: 13.5)),
          ],
        ),
      );
    }

    if (cat == 'Recent' && list.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: const Color(0x1838BDF8),
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0x4038BDF8), width: 1.5),
              ),
              child: const Icon(Icons.history_rounded, size: 52, color: Color(0xFF38BDF8)),
            ),
            const SizedBox(height: 18),
            const Text('No Recently Watched Channels',
                style: TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            const Text('Channels you play will automatically appear here',
                style: TextStyle(color: dim, fontSize: 13.5)),
          ],
        ),
      );
    }

    if (list.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.tv_off_rounded, size: 48, color: Colors.white24),
            const SizedBox(height: 12),
            Text('No channels found for $selectedLanguage in $cat',
                style: const TextStyle(color: dim, fontSize: 14)),
          ],
        ),
      );
    }

    return GridView.builder(
      key: ValueKey('grid/$cat/$selectedLanguage'),
      controller: _controllers.putIfAbsent(cat, () => ScrollController()),
      scrollCacheExtent: ScrollCacheExtent.pixels(rowExtent),
      addAutomaticKeepAlives: false,
      // one layer for the whole grid instead of one per tile: cheaper to composite on a Mali-450
      addRepaintBoundaries: false,
      padding: const EdgeInsets.fromLTRB(pad, 14, pad, 30),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: cols,
        mainAxisExtent: rowExtent,
      ),
      itemCount: list.length,
      itemBuilder: (context, i) => _Tile(
        key: ValueKey('$cat/$selectedLanguage/$i'),
        channel: list[i],
        node: tileNodes.putIfAbsent('$cat/$selectedLanguage/$i', () => FocusNode()),
        cardW: cardW,
        cardH: cardH,
        onTap: () => _play(i),
        onLongPress: () => _toggleFav(i),
        onKey: (e) => _tileKey(i, e),
      ),
    );
  }
}

class _SearchSidebarTile extends StatefulWidget {
  final FocusNode node;
  final VoidCallback onTap;
  final KeyEventResult Function(KeyEvent) onKey;

  const _SearchSidebarTile({
    required this.node,
    required this.onTap,
    required this.onKey,
  });

  @override
  State<_SearchSidebarTile> createState() => _SearchSidebarTileState();
}

class _SearchSidebarTileState extends State<_SearchSidebarTile> {
  bool focused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: widget.node,
      onFocusChange: (f) => setState(() => focused = f),
      onKeyEvent: (_, e) => widget.onKey(e),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          height: 38,
          margin: const EdgeInsets.only(bottom: 4),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: focused ? Colors.white : const Color(0x18FFFFFF),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: focused ? Colors.white : Colors.transparent,
              width: 1.5,
            ),
          ),
          child: Row(
            children: [
              Icon(
                Icons.search_rounded,
                size: 18,
                color: focused ? Colors.black : const Color(0xFF38BDF8),
              ),
              const SizedBox(width: 10),
              Text(
                'Search',
                style: TextStyle(
                  color: focused ? Colors.black : Colors.white,
                  fontSize: 14,
                  fontWeight: focused ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
              const Spacer(),
              Icon(
                Icons.mic_rounded,
                size: 16,
                color: focused ? Colors.black54 : const Color(0xFF2DD4BF),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SideItem extends StatefulWidget {
  final FocusNode node;
  final IconData icon;
  final String label;
  final int count;
  final bool selected;
  final VoidCallback onFocus;
  final KeyEventResult Function(KeyEvent) onKey;

  const _SideItem({
    required this.node,
    required this.icon,
    required this.label,
    required this.count,
    required this.selected,
    required this.onFocus,
    required this.onKey,
  });

  @override
  State<_SideItem> createState() => _SideItemState();
}

class _SideItemState extends State<_SideItem> {
  bool focused = false;

  @override
  Widget build(BuildContext context) {
    final isFav = widget.label == 'Favorites';
    final isRecent = widget.label == 'Recent';
    final fg = focused ? Colors.black : (widget.selected ? Colors.white : const Color(0xFFB4B4BE));
    final iconColor = focused
        ? Colors.black
        : (isFav
            ? const Color(0xFFFFD700)
            : isRecent
                ? const Color(0xFF38BDF8)
                : (widget.selected ? Colors.white : const Color(0xFFB4B4BE)));

    return Focus(
      focusNode: widget.node,
      onFocusChange: (f) {
        setState(() => focused = f);
        if (f) {
          Scrollable.ensureVisible(
            context,
            alignment: 0.35,
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeInOut,
          );
          widget.onFocus();
        }
      },
      onKeyEvent: (_, e) => widget.onKey(e),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        height: 38,
        margin: const EdgeInsets.only(bottom: 3),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: focused
              ? Colors.white
              : widget.selected
                  ? const Color(0x1FFFFFFF)
                  : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(children: [
          Icon(widget.icon, size: 18, color: iconColor),
          const SizedBox(width: 12),
          Expanded(
            child: Text(widget.label,
                style: TextStyle(
                    color: fg,
                    fontSize: 14,
                    fontWeight: focused || widget.selected ? FontWeight.w600 : FontWeight.w500)),
          ),
          Text('${widget.count}', style: TextStyle(color: focused ? Colors.black54 : dim, fontSize: 12)),
        ]),
      ),
    );
  }
}

class _Tile extends StatefulWidget {
  final Channel channel;
  final FocusNode node;
  final double cardW;
  final double cardH;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final KeyEventResult Function(KeyEvent) onKey;

  const _Tile({
    super.key,
    required this.channel,
    required this.node,
    required this.cardW,
    required this.cardH,
    required this.onTap,
    required this.onLongPress,
    required this.onKey,
  });

  @override
  State<_Tile> createState() => _TileState();
}

class _TileState extends State<_Tile> {
  bool focused = false;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: FavoritesProvider.instance,
      builder: (context, _) {
        final isFav = FavoritesProvider.instance.isFavorite(widget.channel);
        Widget card = Padding(
          padding: const EdgeInsets.all(4.5),
          child: Stack(
            children: [
              ChannelIcon(
                key: ValueKey(widget.channel.logoUrl + widget.channel.name),
                channel: widget.channel,
                width: widget.cardW - 9,
                height: widget.cardH - 9,
              ),
              if (isFav)
                Positioned(
                  top: 5,
                  right: 5,
                  child: Container(
                    padding: const EdgeInsets.all(2.5),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.8),
                      shape: BoxShape.circle,
                      border: Border.all(color: const Color(0xFFFFD700).withValues(alpha: 0.6), width: 1),
                    ),
                    child: const Icon(Icons.star_rounded, size: 12, color: Color(0xFFFFD700)),
                  ),
                ),
            ],
          ),
        );
        if (focused) {
          card = Transform.scale(
            scale: 1.1,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12.5),
                border: Border.all(color: Colors.white, width: 2),
                boxShadow: [
                  BoxShadow(color: Colors.white.withValues(alpha: 0.35), blurRadius: 14, spreadRadius: 1),
                ],
              ),
              child: card,
            ),
          );
        }
        return Focus(
          focusNode: widget.node,
          onFocusChange: (f) => setState(() => focused = f),
          onKeyEvent: (_, e) => widget.onKey(e),
          child: GestureDetector(
            onTap: widget.onTap,
            onLongPress: widget.onLongPress,
            child: Column(
              children: [
                card,
                const SizedBox(height: 7),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    widget.channel.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: focused ? _nameFocused : _name,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  static const _name = TextStyle(color: Color(0xFFA0A0AA), fontSize: 11.5, fontWeight: FontWeight.w500);
  static const _nameFocused = TextStyle(color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.w600);
}

class _LanguageSelectionDialog extends StatefulWidget {
  final String currentLanguage;
  final List<String> languages;
  final ValueChanged<String> onSelect;

  const _LanguageSelectionDialog({
    required this.currentLanguage,
    required this.languages,
    required this.onSelect,
  });

  @override
  State<_LanguageSelectionDialog> createState() => _LanguageSelectionDialogState();
}

class _LanguageSelectionDialogState extends State<_LanguageSelectionDialog> {
  late final List<FocusNode> _nodes =
      List.generate(widget.languages.length, (_) => FocusNode());

  @override
  void initState() {
    super.initState();
    final idx = widget.languages.indexOf(widget.currentLanguage);
    final focusIdx = idx >= 0 ? idx : 0;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _nodes.isNotEmpty) {
        _nodes[focusIdx].requestFocus();
      }
    });
  }

  @override
  void dispose() {
    for (final n in _nodes) {
      n.dispose();
    }
    super.dispose();
  }

  void _choose(String lang) {
    widget.onSelect(lang);
    Navigator.of(context).pop();
  }

  KeyEventResult _handleKey(int i, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    const cols = 3;
    final count = widget.languages.length;

    if (k == LogicalKeyboardKey.arrowLeft) {
      if (i % cols > 0) {
        _nodes[i - 1].requestFocus();
        return KeyEventResult.handled;
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowRight) {
      if (i % cols < cols - 1 && i + 1 < count) {
        _nodes[i + 1].requestFocus();
        return KeyEventResult.handled;
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowUp) {
      if (i - cols >= 0) {
        _nodes[i - cols].requestFocus();
        return KeyEventResult.handled;
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowDown) {
      if (i + cols < count) {
        _nodes[i + cols].requestFocus();
        return KeyEventResult.handled;
      }
      return KeyEventResult.handled;
    }
    if (isSelectKey(k)) {
      _choose(widget.languages[i]);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.escape || k == LogicalKeyboardKey.backspace) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
      child: Container(
        width: 620,
        decoration: BoxDecoration(
          color: const Color(0xFF13131A),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xFF2E2E42), width: 1.5),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.8),
              blurRadius: 30,
              spreadRadius: 4,
            ),
          ],
        ),
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0x2238BDF8),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.translate_rounded, color: Color(0xFF38BDF8), size: 20),
                ),
                const SizedBox(width: 12),
                const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Filter by Language',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'Select a language to filter channels',
                      style: TextStyle(color: dim, fontSize: 12),
                    ),
                  ],
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0x18FFFFFF),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.keyboard_backspace_rounded, size: 14, color: dim),
                      SizedBox(width: 4),
                      Text('Back', style: TextStyle(color: dim, fontSize: 11)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),

            // Languages Grid (3 columns)
            Flexible(
              child: GridView.builder(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  mainAxisExtent: 46,
                ),
                itemCount: widget.languages.length,
                itemBuilder: (context, i) {
                  final lang = widget.languages[i];
                  final isCurrent = lang == widget.currentLanguage;
                  final node = _nodes[i];

                  return Focus(
                    focusNode: node,
                    onKeyEvent: (_, e) => _handleKey(i, e),
                    child: ListenableBuilder(
                      listenable: node,
                      builder: (context, _) {
                        final hasFocus = node.hasFocus;
                        return GestureDetector(
                          onTap: () => _choose(lang),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 130),
                            padding: const EdgeInsets.symmetric(horizontal: 14),
                            decoration: BoxDecoration(
                              color: hasFocus
                                  ? Colors.white
                                  : (isCurrent ? const Color(0x2238BDF8) : const Color(0x14FFFFFF)),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: hasFocus
                                    ? Colors.white
                                    : (isCurrent ? const Color(0xFF38BDF8) : const Color(0x22FFFFFF)),
                                width: hasFocus ? 2 : (isCurrent ? 1.5 : 1),
                              ),
                              boxShadow: hasFocus
                                  ? [
                                      BoxShadow(
                                        color: Colors.white.withValues(alpha: 0.6),
                                        blurRadius: 10,
                                      )
                                    ]
                                  : null,
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    lang == 'All' ? 'All Languages' : lang,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: hasFocus
                                          ? Colors.black
                                          : (isCurrent ? const Color(0xFF38BDF8) : Colors.white),
                                      fontSize: 13,
                                      fontWeight: hasFocus || isCurrent
                                          ? FontWeight.w700
                                          : FontWeight.w500,
                                    ),
                                  ),
                                ),
                                if (isCurrent)
                                  Icon(
                                    Icons.check_circle_rounded,
                                    size: 16,
                                    color: hasFocus ? const Color(0xFF0284C7) : const Color(0xFF38BDF8),
                                  ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

