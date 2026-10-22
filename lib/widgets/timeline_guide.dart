import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../model/channel.dart';
import '../model/program.dart';
import '../provider/epg_provider.dart';
import '../screens/home.dart' show isSelectKey;
import 'channel_icon.dart';
import 'tv_program_details_dialog.dart';

/// Full-featured DTH Electronic Program Guide (EPG) Timeline Overlay
/// matching classic Indian DTH Set-Top-Box guides (Tata Play / Airtel Digital TV).
class TimelineGuide extends StatefulWidget {
  final List<Channel> allChannels;
  final Channel currentChannel;
  final String initialCategory;
  final ValueChanged<Channel> onTune;
  final VoidCallback onClose;
  final VoidCallback onUserActivity;

  const TimelineGuide({
    super.key,
    required this.allChannels,
    required this.currentChannel,
    required this.onTune,
    required this.onClose,
    required this.onUserActivity,
    this.initialCategory = 'All',
  });

  @override
  State<TimelineGuide> createState() => _TimelineGuideState();
}

class _TimelineGuideState extends State<TimelineGuide> {
  final FocusNode _focusNode = FocusNode();
  final ScrollController _channelScrollController = ScrollController();

  late List<String> _categories;
  late int _selectedCategoryIdx;
  late List<Channel> _activeCategoryChannels;
  late int _focusedChannelIdx;
  int _focusedProgIdx = -1;
  late DateTime _baseTime;
  Timer? _clockTimer;

  static const double _channelColWidth = 240.0;
  static const double _rowHeight = 44.0;
  double _slotWidth = 180.0; // 30 minutes per slot; width fitted to the screen in build()
  static const int _totalSlots = 8; // 4 hours window (8 x 30m)

  @override
  void initState() {
    super.initState();
    _initTime();
    _initCategories();

    _clockTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _focusNode.requestFocus();
        _scrollToFocusedChannel();
      }
    });
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    _channelScrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _initTime() {
    final now = DateTime.now();
    // Floor to nearest half-hour
    final minute = now.minute >= 30 ? 30 : 0;
    _baseTime = DateTime(now.year, now.month, now.day, now.hour, minute);
  }

  void _initCategories() {
    final set = <String>{};
    for (final c in widget.allChannels) {
      if (c.category.isNotEmpty) set.add(c.category);
    }
    _categories = ['All', ...set];

    final catToFind = widget.currentChannel.category.isNotEmpty
        ? widget.currentChannel.category
        : widget.initialCategory;
    _selectedCategoryIdx = _categories.contains(catToFind) ? _categories.indexOf(catToFind) : 0;
    _updateChannelsForCategory();

    final curIdx = _activeCategoryChannels.indexWhere((c) => c.idKey == widget.currentChannel.idKey);
    _focusedChannelIdx = curIdx >= 0 ? curIdx : 0;
    _syncFocusedProgramForChannel();
  }

  void _updateChannelsForCategory() {
    final cat = _categories[_selectedCategoryIdx];
    if (cat == 'All') {
      _activeCategoryChannels = List.from(widget.allChannels);
    } else {
      _activeCategoryChannels = widget.allChannels.where((c) => c.category == cat).toList();
    }
    if (_focusedChannelIdx >= _activeCategoryChannels.length) {
      _focusedChannelIdx = max(0, _activeCategoryChannels.length - 1);
    }
    _syncFocusedProgramForChannel();
  }

  void _syncFocusedProgramForChannel() {
    if (_activeCategoryChannels.isEmpty || _focusedChannelIdx >= _activeCategoryChannels.length) {
      _focusedProgIdx = -1;
      return;
    }
    final ch = _activeCategoryChannels[_focusedChannelIdx];
    final windowStart = _baseTime;
    final windowEnd = _baseTime.add(const Duration(minutes: _totalSlots * 30));
    final progs = EpgProvider.instance.getSchedule(ch, from: windowStart, to: windowEnd);
    if (progs.isEmpty) {
      _focusedProgIdx = -1;
      return;
    }
    final liveIdx = progs.indexWhere((p) => p.isLive);
    _focusedProgIdx = liveIdx >= 0 ? liveIdx : 0;
  }

  void _cycleCategory() {
    setState(() {
      _selectedCategoryIdx = (_selectedCategoryIdx + 1) % _categories.length;
      _updateChannelsForCategory();
      _focusedChannelIdx = 0;
      _syncFocusedProgramForChannel();
    });
    _scrollToFocusedChannel();
  }

  void _scrollToFocusedChannel() {
    if (!_channelScrollController.hasClients) return;
    final targetY = max(0.0, (_focusedChannelIdx - 1) * _rowHeight);
    _channelScrollController.animateTo(
      targetY.clamp(0.0, _channelScrollController.position.maxScrollExtent),
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOut,
    );
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    widget.onUserActivity();
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;

    final ch = (_activeCategoryChannels.isNotEmpty && _focusedChannelIdx < _activeCategoryChannels.length)
        ? _activeCategoryChannels[_focusedChannelIdx]
        : null;
    final windowStart = _baseTime;
    final windowEnd = _baseTime.add(const Duration(minutes: _totalSlots * 30));
    final progs = ch != null
        ? EpgProvider.instance.getSchedule(ch, from: windowStart, to: windowEnd)
        : <Program>[];

    if (k == LogicalKeyboardKey.arrowUp) {
      if (_focusedChannelIdx > 0) {
        setState(() {
          _focusedChannelIdx--;
          _syncFocusedProgramForChannel();
        });
        _scrollToFocusedChannel();
      }
      return KeyEventResult.handled;
    }

    if (k == LogicalKeyboardKey.arrowDown) {
      if (_focusedChannelIdx < _activeCategoryChannels.length - 1) {
        setState(() {
          _focusedChannelIdx++;
          _syncFocusedProgramForChannel();
        });
        _scrollToFocusedChannel();
      }
      return KeyEventResult.handled;
    }

    if (k == LogicalKeyboardKey.arrowRight) {
      // Next programme in the visible window; at the end, page the window forward
      if (progs.isNotEmpty && _focusedProgIdx < progs.length - 1) {
        setState(() => _focusedProgIdx++);
      } else {
        _pageTimeline(1);
      }
      return KeyEventResult.handled;
    }

    if (k == LogicalKeyboardKey.arrowLeft) {
      // Previous programme in the visible window; at the start, page the window back
      if (progs.isNotEmpty && _focusedProgIdx > 0) {
        setState(() => _focusedProgIdx--);
      } else {
        _pageTimeline(-1);
      }
      return KeyEventResult.handled;
    }

    if (isSelectKey(k) || _isInfoKey(k)) {
      if (ch != null) {
        final prog = (progs.isNotEmpty && _focusedProgIdx >= 0 && _focusedProgIdx < progs.length)
            ? progs[_focusedProgIdx]
            : (EpgProvider.instance.getNow(ch) ?? (progs.isNotEmpty ? progs.first : null));

        _openProgramDetails(ch, prog, _focusedChannelIdx + 1);
      }
      return KeyEventResult.handled;
    }

    if (k == LogicalKeyboardKey.escape ||
        k == LogicalKeyboardKey.goBack ||
        k == LogicalKeyboardKey.browserBack) {
      widget.onClose();
      return KeyEventResult.handled;
    }

    // Green button or F2 or Key C cycles Category/Genre
    if (k == LogicalKeyboardKey.f2 ||
        k == LogicalKeyboardKey.contextMenu ||
        k == LogicalKeyboardKey.keyC) {
      _cycleCategory();
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  bool _isInfoKey(LogicalKeyboardKey k) =>
      k == LogicalKeyboardKey.info ||
      k == LogicalKeyboardKey.f1 ||
      k == LogicalKeyboardKey.f3 ||
      k == LogicalKeyboardKey.keyI;

  /// Moves the visible 4-hour window forward (direction 1) or back (-1) and
  /// re-syncs the focused programme. The window always fits the screen width,
  /// so no horizontal scrolling (and no header/row desync) can occur.
  void _pageTimeline(int direction) {
    setState(() {
      _baseTime = _baseTime.add(Duration(minutes: direction * _totalSlots * 30));
      final now = DateTime.now();
      final floored = DateTime(now.year, now.month, now.day, now.hour, now.minute >= 30 ? 30 : 0);
      final minBase = floored.subtract(const Duration(hours: 4));
      final maxBase = floored.add(const Duration(hours: 24));
      if (_baseTime.isBefore(minBase)) _baseTime = minBase;
      if (_baseTime.isAfter(maxBase)) _baseTime = maxBase;
      _syncFocusedProgramForChannel();
    });
  }

  void _openProgramDetails(Channel ch, Program? prog, [int? channelNum]) {
    TvProgramDetailsDialog.show(
      context: context,
      channel: ch,
      program: prog,
      channelNumber: channelNum ?? (_focusedChannelIdx + 1),
      onTuneChannel: () {
        widget.onClose();
        widget.onTune(ch);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // Fit the 4-hour window to the screen so the time ruler and the program
    // rows always share the same width — free horizontal scrolling can't keep
    // lazily-built rows in sync, so Left/Right page the window instead.
    _slotWidth = (MediaQuery.sizeOf(context).width - _channelColWidth) / _totalSlots;
    final now = DateTime.now();
    final activeCat = _categories[_selectedCategoryIdx];
    final focusedChannel = _activeCategoryChannels.isNotEmpty && _focusedChannelIdx < _activeCategoryChannels.length
        ? _activeCategoryChannels[_focusedChannelIdx]
        : null;

    final windowStart = _baseTime;
    final windowEnd = _baseTime.add(const Duration(minutes: _totalSlots * 30));
    final focusedProgs = focusedChannel != null
        ? EpgProvider.instance.getSchedule(focusedChannel, from: windowStart, to: windowEnd)
        : <Program>[];

    final currentProgram = focusedChannel != null ? EpgProvider.instance.getNow(focusedChannel) : null;
    final displayedProgram = (focusedProgs.isNotEmpty &&
            _focusedProgIdx >= 0 &&
            _focusedProgIdx < focusedProgs.length)
        ? focusedProgs[_focusedProgIdx]
        : currentProgram;

    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Container(
          height: 380,
          width: double.infinity,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color(0xF00A0E17),
                Color(0xFA05080E),
                Color(0xFF000000),
              ],
            ),
            border: Border(
              top: BorderSide(color: Colors.cyan.withValues(alpha: 0.5), width: 1.5),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.8),
                blurRadius: 20,
                spreadRadius: 4,
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 1. Top Header Bar (Genre Pill, Date, Clock)
              _buildHeaderBar(activeCat, now),

              // 2. Focused Program Summary (Shows show title & description)
              if (focusedChannel != null) _buildProgramSummary(focusedChannel, displayedProgram),

              // 3. Timeline Header (Time Slots: 12:00 am, 12:30 am, 01:00 am...)
              _buildTimelineHeader(),

              // 4. Channel Rows + Timeline Blocks
              Expanded(
                child: _buildGridBody(),
              ),

              // 5. Bottom Remote Help / Action Bar
              _buildBottomBar(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeaderBar(String activeCat, DateTime now) {
    final dateStr = 'Today ${_formatDayMonth(now)}';
    final clockStr = _formatFullClock(now);

    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: const BoxDecoration(
        color: Color(0x331E293B),
        border: Border(bottom: BorderSide(color: Color(0x22FFFFFF), width: 1)),
      ),
      child: Row(
        children: [
          // Guide Title Tag
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            decoration: BoxDecoration(
              color: const Color(0xFF1E293B),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: const Color(0x4438BDF8), width: 1),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.tv_rounded, color: Color(0xFF38BDF8), size: 14),
                SizedBox(width: 6),
                Text(
                  'Guide',
                  style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),

          // Genre / Category Pill
          GestureDetector(
            onTap: _cycleCategory,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
              decoration: BoxDecoration(
                color: const Color(0xFF0F766E),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFF2DD4BF), width: 1),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    activeCat,
                    style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(width: 6),
                  const Icon(Icons.arrow_drop_down_rounded, color: Colors.white, size: 16),
                ],
              ),
            ),
          ),
          const SizedBox(width: 14),

          // Date Text
          Text(
            dateStr,
            style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12, fontWeight: FontWeight.w600),
          ),

          const Spacer(),

          // Live Clock top right
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.access_time_filled_rounded, color: Color(0xFF38BDF8), size: 13),
              const SizedBox(width: 6),
              Text(
                clockStr,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildProgramSummary(Channel channel, Program? program) {
    return GestureDetector(
      onTap: () => _openProgramDetails(channel, program, _focusedChannelIdx + 1),
      child: Container(
        height: 46,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        color: const Color(0x18000000),
        child: Row(
          children: [
            ChannelIcon(
              key: ValueKey(channel.logoUrl + channel.name),
              channel: channel,
              width: 44,
              height: 28,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          program != null ? program.title : 'Live Broadcast on ${channel.name}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Color(0xFFFFD700),
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      if (program != null) ...[
                        const SizedBox(width: 8),
                        Text(
                          '(${program.timeRangeText})',
                          style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 11, fontWeight: FontWeight.w500),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                          decoration: BoxDecoration(
                            color: const Color(0x3338BDF8),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            program.remainingText,
                            style: const TextStyle(color: Color(0xFF38BDF8), fontSize: 10, fontWeight: FontWeight.w700),
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (program != null && program.desc.isNotEmpty)
                    Text(
                      program.desc,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 11),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0x2038BDF8),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: const Color(0x4438BDF8), width: 1),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.info_outline_rounded, size: 12, color: Color(0xFF38BDF8)),
                  SizedBox(width: 4),
                  Text(
                    'Synopsis (OK)',
                    style: TextStyle(color: Color(0xFF38BDF8), fontSize: 10.5, fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTimelineHeader() {
    return Container(
      height: 26,
      decoration: const BoxDecoration(
        color: Color(0xFF0F172A),
        border: Border(
          top: BorderSide(color: Color(0x18FFFFFF), width: 1),
          bottom: BorderSide(color: Color(0x33FFFFFF), width: 1),
        ),
      ),
      child: Row(
        children: [
          // Left Corner: Channels Header
          Container(
            width: _channelColWidth,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            alignment: Alignment.centerLeft,
            child: const Text(
              'CHANNELS',
              style: TextStyle(
                color: Color(0xFF64748B),
                fontSize: 10,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.2,
              ),
            ),
          ),

          // Right Timeline Header (fits the screen exactly; never scrolls)
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const NeverScrollableScrollPhysics(),
              child: Row(
                children: List.generate(_totalSlots, (idx) {
                  final slotTime = _baseTime.add(Duration(minutes: idx * 30));
                  return Container(
                    width: _slotWidth,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    alignment: Alignment.centerLeft,
                    decoration: const BoxDecoration(
                      border: Border(
                        right: BorderSide(color: Color(0x22FFFFFF), width: 1),
                      ),
                    ),
                    child: Text(
                      _formatSlotTime(slotTime),
                      style: const TextStyle(
                        color: Color(0xFF94A3B8),
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  );
                }),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGridBody() {
    if (_activeCategoryChannels.isEmpty) {
      return const Center(
        child: Text(
          'No channels in this category',
          style: TextStyle(color: Color(0xFF64748B), fontSize: 14),
        ),
      );
    }

    final windowStart = _baseTime;
    final windowEnd = _baseTime.add(const Duration(minutes: _totalSlots * 30));
    const windowMinutes = _totalSlots * 30;

    return ListView.builder(
      controller: _channelScrollController,
      itemCount: _activeCategoryChannels.length,
      itemExtent: _rowHeight,
      itemBuilder: (context, rowIdx) {
        final ch = _activeCategoryChannels[rowIdx];
        final isFocused = rowIdx == _focusedChannelIdx;

        // Fetch programs for this channel within timeline window
        final progs = EpgProvider.instance.getSchedule(ch, from: windowStart, to: windowEnd);

        return Container(
          height: _rowHeight,
          decoration: BoxDecoration(
            color: isFocused ? const Color(0x250284C7) : Colors.transparent,
            border: Border(
              bottom: BorderSide(
                color: isFocused ? const Color(0x550284C7) : const Color(0x10FFFFFF),
                width: 1,
              ),
            ),
          ),
          child: Row(
            children: [
              // 1. Channel Number & Name (Left Column)
              InkWell(
                onTap: () {
                  setState(() => _focusedChannelIdx = rowIdx);
                  _openProgramDetails(ch, EpgProvider.instance.getNow(ch), rowIdx + 1);
                },
                child: Container(
                  width: _channelColWidth,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    color: isFocused ? const Color(0xFF0284C7) : const Color(0x150F172A),
                    border: isFocused
                        ? const Border(right: BorderSide(color: Colors.white, width: 2))
                        : const Border(right: BorderSide(color: Color(0x22FFFFFF), width: 1)),
                  ),
                  child: Row(
                    children: [
                      Text(
                        '${rowIdx + 1}',
                        style: TextStyle(
                          color: isFocused ? Colors.white : const Color(0xFF64748B),
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          ch.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: isFocused ? Colors.white : const Color(0xFFE2E8F0),
                            fontSize: 12.5,
                            fontWeight: isFocused ? FontWeight.w700 : FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // 2. Timeline Programs (Right Row)
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  physics: const NeverScrollableScrollPhysics(),
                  child: SizedBox(
                    width: _slotWidth * _totalSlots,
                    child: progs.isEmpty
                        ? _buildEmptyProgramBlock(ch, rowIdx, isFocused)
                        : _buildProgramBlocks(progs, windowStart, windowMinutes, isFocused, ch, rowIdx),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildEmptyProgramBlock(Channel ch, int rowIdx, bool isRowFocused) {
    return InkWell(
      onTap: () {
        setState(() => _focusedChannelIdx = rowIdx);
        _openProgramDetails(ch, null, rowIdx + 1);
      },
      child: Container(
        width: _slotWidth * _totalSlots,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(
          color: isRowFocused ? const Color(0x180284C7) : Colors.transparent,
        ),
        child: Text(
          'Live Broadcast · ${ch.name}',
          style: TextStyle(
            color: isRowFocused ? Colors.white70 : const Color(0xFF475569),
            fontSize: 11.5,
            fontStyle: FontStyle.italic,
          ),
        ),
      ),
    );
  }

  Widget _buildProgramBlocks(
    List<Program> progs,
    DateTime windowStart,
    int windowMinutes,
    bool isRowFocused,
    Channel ch,
    int rowIdx,
  ) {
    final totalWidth = _slotWidth * _totalSlots;
    final blocks = <Widget>[];

    for (var i = 0; i < progs.length; i++) {
      final p = progs[i];
      final startOffset = max(0, p.start.difference(windowStart).inMinutes);
      final endOffset = min(windowMinutes, p.stop.difference(windowStart).inMinutes);
      if (endOffset <= startOffset) continue;

      final duration = endOffset - startOffset;
      final blockWidth = (duration / windowMinutes) * totalWidth;
      final isNowPlaying = p.isLive;
      final isProgFocused = isRowFocused && _focusedProgIdx == i;

      blocks.add(
        InkWell(
          onTap: () {
            setState(() {
              _focusedChannelIdx = rowIdx;
              _focusedProgIdx = i;
            });
            _openProgramDetails(ch, p, rowIdx + 1);
          },
          child: Container(
            width: blockWidth,
            height: _rowHeight - 4,
            margin: const EdgeInsets.symmetric(vertical: 2),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: isProgFocused
                  ? (isNowPlaying ? const Color(0xFF0284C7) : const Color(0xFF1E3A8A))
                  : (isNowPlaying
                      ? (isRowFocused ? const Color(0xFF0369A1) : const Color(0x350284C7))
                      : (isRowFocused ? const Color(0x22FFFFFF) : const Color(0x0CFFFFFF))),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(
                color: isProgFocused
                    ? Colors.white
                    : (isNowPlaying
                        ? (isRowFocused ? Colors.cyanAccent : const Color(0x660284C7))
                        : const Color(0x18FFFFFF)),
                width: isProgFocused ? 2 : 1,
              ),
              boxShadow: isProgFocused
                  ? [
                      BoxShadow(
                        color: (isNowPlaying ? Colors.cyanAccent : Colors.lightBlueAccent).withValues(alpha: 0.5),
                        blurRadius: 10,
                        spreadRadius: 1,
                      ),
                    ]
                  : null,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  children: [
                    if (isNowPlaying) ...[
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: isProgFocused ? Colors.white : Colors.cyanAccent,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 4),
                    ],
                    Expanded(
                      child: Text(
                        p.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: isProgFocused
                              ? Colors.white
                              : (isNowPlaying ? Colors.white : const Color(0xFFCBD5E1)),
                          fontSize: 11.5,
                          fontWeight: (isProgFocused || isNowPlaying) ? FontWeight.w800 : FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
                Text(
                  p.timeRangeText,
                  maxLines: 1,
                  overflow: TextOverflow.clip,
                  style: TextStyle(
                    color: isProgFocused
                        ? Colors.white.withValues(alpha: 0.9)
                        : (isNowPlaying ? Colors.cyanAccent.withValues(alpha: 0.8) : const Color(0xFF64748B)),
                    fontSize: 9.5,
                    fontWeight: isProgFocused ? FontWeight.w700 : FontWeight.normal,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Row(children: blocks);
  }

  Widget _buildBottomBar() {
    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      color: const Color(0xFF05080E),
      child: const Row(
        children: [
          _KeyHint(icon: Icons.unfold_more_rounded, text: 'Ch Up/Down'),
          SizedBox(width: 14),
          _KeyHint(icon: Icons.swap_horiz_rounded, text: 'Shows Left/Right'),
          SizedBox(width: 14),
          _KeyHint(icon: Icons.info_outline_rounded, text: 'OK / Info: Details & Tune'),
          SizedBox(width: 14),
          _ColorHint(color: Color(0xFF10B981), text: 'Other Genres (C)'),
          Spacer(),
          _KeyHint(icon: Icons.keyboard_return_rounded, text: 'Back: Close'),
        ],
      ),
    );
  }

  static String _formatDayMonth(DateTime dt) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${dt.day} ${months[dt.month - 1]}';
  }

  static String _formatFullClock(DateTime dt) {
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final day = days[dt.weekday - 1];
    final hour = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final min = dt.minute.toString().padLeft(2, '0');
    final ampm = dt.hour >= 12 ? 'pm' : 'am';
    return '$day ${dt.day} ${_formatDayMonth(dt)} $hour:$min $ampm';
  }

  static String _formatSlotTime(DateTime dt) {
    final hour = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final min = dt.minute.toString().padLeft(2, '0');
    final ampm = dt.hour >= 12 ? 'pm' : 'am';
    return '$hour:$min $ampm';
  }
}

class _KeyHint extends StatelessWidget {
  final IconData icon;
  final String text;

  const _KeyHint({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: const Color(0xFF94A3B8)),
        const SizedBox(width: 4),
        Text(text, style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 11, fontWeight: FontWeight.w600)),
      ],
    );
  }
}

class _ColorHint extends StatelessWidget {
  final Color color;
  final String text;

  const _ColorHint({required this.color, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Text(text, style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 11, fontWeight: FontWeight.w600)),
      ],
    );
  }
}
