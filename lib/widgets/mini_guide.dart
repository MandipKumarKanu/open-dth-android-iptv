import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../model/channel.dart';
import '../provider/channels_provider.dart' show categoryOrder;
import '../provider/favorites_provider.dart';
import '../widgets/channel_icon.dart';
import '../screens/home.dart' show isSelectKey;

class MiniGuide extends StatefulWidget {
  final List<Channel> allChannels;
  final Channel currentChannel;
  final String initialCategory;
  final ValueChanged<Channel> onTune;
  final VoidCallback onClose;
  final VoidCallback onUserActivity;

  const MiniGuide({
    super.key,
    required this.allChannels,
    required this.currentChannel,
    required this.initialCategory,
    required this.onTune,
    required this.onClose,
    required this.onUserActivity,
  });

  @override
  State<MiniGuide> createState() => _MiniGuideState();
}

class _MiniGuideState extends State<MiniGuide> {
  static const double _itemExtent = 62.0;

  late List<String> _tabs;
  late int _selectedTab = 0;
  late ScrollController _scrollController;
  late ScrollController _tabScrollController;
  final FocusNode _focusNode = FocusNode();
  int _focusedIndex = 0;

  List<Channel> _getChannelsForTab(String tab) {
    if (tab == 'Favorites') {
      return widget.allChannels.where((c) => FavoritesProvider.instance.isFavorite(c)).toList();
    }
    if (tab == 'All') {
      return widget.allChannels;
    }
    return widget.allChannels.where((c) => c.category == tab).toList();
  }

  List<Channel> get _currentList => _getChannelsForTab(_tabs[_selectedTab]);

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    _tabScrollController = ScrollController();

    // Collect all available categories present in the channel catalog
    final catsWithChannels = <String>{};
    for (final c in widget.allChannels) {
      if (c.category.isNotEmpty) catsWithChannels.add(c.category);
    }

    final knownOrdered = categoryOrder.where((c) => c != 'Favorites' && catsWithChannels.contains(c)).toList();
    final remaining = catsWithChannels.where((c) => !categoryOrder.contains(c)).toList()..sort();

    _tabs = [
      'Favorites',
      'All',
      ...knownOrdered,
      ...remaining,
    ];

    // Default to Favorites if initial category was Favorites, or current channel's category
    if (widget.initialCategory == 'Favorites' && _tabs.contains('Favorites')) {
      _selectedTab = _tabs.indexOf('Favorites');
    } else if (_tabs.contains(widget.currentChannel.category)) {
      _selectedTab = _tabs.indexOf(widget.currentChannel.category);
    } else if (_tabs.contains(widget.initialCategory)) {
      _selectedTab = _tabs.indexOf(widget.initialCategory);
    } else {
      _selectedTab = _tabs.indexOf('All');
    }

    _initPosition();
  }

  void _initPosition() {
    final list = _currentList;
    final idx = list.indexWhere((c) => c.idKey == widget.currentChannel.idKey);
    _focusedIndex = idx >= 0 ? idx : 0;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
      _scrollToSelectedTab(animate: false);
      if (_scrollController.hasClients && _focusedIndex > 2) {
        final targetOffset = (_focusedIndex - 2) * _itemExtent;
        _scrollController.jumpTo(targetOffset.clamp(0.0, _scrollController.position.maxScrollExtent));
      }
    });
  }

  void _scrollToSelectedTab({bool animate = true}) {
    if (!_tabScrollController.hasClients) return;
    final targetOffset = (_selectedTab * 80.0) - 100.0;
    final clamped = targetOffset.clamp(0.0, _tabScrollController.position.maxScrollExtent);
    if (animate) {
      _tabScrollController.animateTo(
        clamped,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    } else {
      _tabScrollController.jumpTo(clamped);
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _tabScrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _scrollToFocused() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    final itemTop = _focusedIndex * _itemExtent;
    final itemBottom = itemTop + _itemExtent;

    if (itemTop < pos.pixels) {
      _scrollController.animateTo(
        itemTop,
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOut,
      );
    } else if (itemBottom > pos.pixels + pos.viewportDimension) {
      _scrollController.animateTo(
        itemBottom - pos.viewportDimension,
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOut,
      );
    }
  }

  void _switchTab(int newTab) {
    setState(() {
      _selectedTab = newTab;
      final newList = _getChannelsForTab(_tabs[_selectedTab]);
      final playIdx = newList.indexWhere((c) => c.idKey == widget.currentChannel.idKey);
      _focusedIndex = playIdx >= 0 ? playIdx : 0;
    });
    _scrollToSelectedTab();
    if (_scrollController.hasClients) {
      if (_focusedIndex > 2) {
        final targetOffset = (_focusedIndex - 2) * _itemExtent;
        _scrollController.jumpTo(targetOffset.clamp(0.0, _scrollController.position.maxScrollExtent));
      } else {
        _scrollController.jumpTo(0);
      }
    }
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    widget.onUserActivity();
    if (e is KeyUpEvent) return KeyEventResult.ignored;

    final k = e.logicalKey;
    final list = _currentList;

    if (k == LogicalKeyboardKey.arrowUp) {
      if (_focusedIndex > 0) {
        setState(() => _focusedIndex--);
        _scrollToFocused();
      }
      return KeyEventResult.handled;
    }

    if (k == LogicalKeyboardKey.arrowDown) {
      if (_focusedIndex < list.length - 1) {
        setState(() => _focusedIndex++);
        _scrollToFocused();
      }
      return KeyEventResult.handled;
    }

    if (k == LogicalKeyboardKey.arrowLeft) {
      if (_selectedTab > 0) {
        _switchTab(_selectedTab - 1);
      }
      return KeyEventResult.handled;
    }

    if (k == LogicalKeyboardKey.arrowRight) {
      if (_selectedTab < _tabs.length - 1) {
        _switchTab(_selectedTab + 1);
      }
      return KeyEventResult.handled;
    }

    if (isSelectKey(k)) {
      if (list.isNotEmpty && _focusedIndex < list.length) {
        widget.onTune(list[_focusedIndex]);
      }
      return KeyEventResult.handled;
    }

    if (k == LogicalKeyboardKey.escape) {
      widget.onClose();
      return KeyEventResult.handled;
    }

    if (k == LogicalKeyboardKey.contextMenu ||
        k == LogicalKeyboardKey.mediaPlayPause ||
        k == LogicalKeyboardKey.f1 ||
        k == LogicalKeyboardKey.f3) {
      if (list.isNotEmpty && _focusedIndex < list.length) {
        FavoritesProvider.instance.toggle(list[_focusedIndex]).then((_) {
          if (mounted) setState(() {});
        });
      }
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final list = _currentList;

    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Container(
        width: 380,
        height: double.infinity,
        decoration: BoxDecoration(
          color: const Color(0xF2101018),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.8),
              blurRadius: 24,
              offset: const Offset(8, 0),
            ),
          ],
          border: const Border(
            right: BorderSide(color: Color(0x28FFFFFF), width: 1),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeader(),
            _buildTabs(),
            const Divider(color: Color(0x1FFFFFFF), height: 1),
            Expanded(
              child: list.isEmpty ? _buildEmptyState() : _buildChannelList(list),
            ),
            _buildFooter(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: const Color(0xFFE53935),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.live_tv_rounded, size: 16, color: Colors.white),
          ),
          const SizedBox(width: 10),
          const Text(
            'Channel Guide',
            style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700),
          ),
          const Spacer(),
          Text(
            '◀ ▶ Tabs',
            style: TextStyle(color: Colors.white.withValues(alpha: 0.45), fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildTabs() {
    return SizedBox(
      height: 42,
      child: SingleChildScrollView(
        controller: _tabScrollController,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            for (var i = 0; i < _tabs.length; i++) ...[
              GestureDetector(
                onTap: () {
                  _switchTab(i);
                  widget.onUserActivity();
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: _selectedTab == i ? Colors.white : const Color(0x14FFFFFF),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_tabs[i] == 'Favorites') ...[
                        Icon(
                          Icons.star_rounded,
                          size: 14,
                          color: _selectedTab == i ? Colors.amber.shade800 : const Color(0xFFFFD700),
                        ),
                        const SizedBox(width: 4),
                      ],
                      Text(
                        _tabs[i],
                        style: TextStyle(
                          color: _selectedTab == i ? Colors.black : Colors.white70,
                          fontSize: 12.5,
                          fontWeight: _selectedTab == i ? FontWeight.w700 : FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildChannelList(List<Channel> list) {
    return ListView.builder(
      controller: _scrollController,
      itemExtent: _itemExtent,
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      itemCount: list.length,
      itemBuilder: (context, i) {
        final c = list[i];
        final isFocused = i == _focusedIndex;
        final isPlaying = c.idKey == widget.currentChannel.idKey;
        final isFav = FavoritesProvider.instance.isFavorite(c);

        return GestureDetector(
          onTap: () {
            setState(() => _focusedIndex = i);
            widget.onTune(c);
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 100),
            margin: const EdgeInsets.only(bottom: 4),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: isFocused
                  ? Colors.white
                  : isPlaying
                      ? const Color(0x24FFFFFF)
                      : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
              border: isPlaying && !isFocused
                  ? Border.all(color: const Color(0x40FFFFFF), width: 1)
                  : null,
            ),
            child: Row(
              children: [
                ChannelIcon(channel: c, width: 44, height: 28),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        c.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: isFocused ? Colors.black : Colors.white,
                          fontSize: 14,
                          fontWeight: isFocused || isPlaying ? FontWeight.w700 : FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          if (isPlaying) ...[
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                              decoration: BoxDecoration(
                                color: isFocused ? Colors.black : const Color(0xFFE53935),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                'PLAYING',
                                style: TextStyle(
                                  color: isFocused ? Colors.white : Colors.white,
                                  fontSize: 8.5,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                          ],
                          Text(
                            c.category,
                            style: TextStyle(
                              color: isFocused
                                  ? Colors.black54
                                  : Colors.white.withValues(alpha: 0.5),
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                  decoration: BoxDecoration(
                    color: isFocused ? const Color(0x22000000) : const Color(0x22FFFFFF),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    c.resolution,
                    style: TextStyle(
                      color: isFocused ? Colors.black87 : Colors.white70,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (isFav) ...[
                  const SizedBox(width: 6),
                  Icon(
                    Icons.star_rounded,
                    size: 16,
                    color: isFocused ? Colors.amber.shade800 : const Color(0xFFFFD700),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.star_border_rounded, size: 40, color: Colors.white.withValues(alpha: 0.3)),
          const SizedBox(height: 12),
          Text(
            'No Channels in ${_tabs[_selectedTab]}',
            style: const TextStyle(color: Colors.white70, fontSize: 14, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Text(
            'Press Menu on any channel to favorite',
            style: TextStyle(color: Colors.white.withValues(alpha: 0.4), fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildFooter() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
      decoration: const BoxDecoration(
        color: Color(0xFF0C0C12),
        border: Border(top: BorderSide(color: Color(0x15FFFFFF), width: 1)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text('OK to Watch', style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 11.5)),
          Text('Menu: ⭐ Fav', style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 11.5)),
          Text('Back to Exit', style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 11.5)),
        ],
      ),
    );
  }
}
