import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../model/channel.dart';
import '../provider/epg_provider.dart';
import '../provider/favorites_provider.dart';
import '../provider/recent_provider.dart';
import '../widgets/channel_icon.dart';
import '../widgets/mini_guide.dart';
import '../widgets/timeline_guide.dart';
import 'home.dart' show isSelectKey;

enum ControlSection { playPause, recall, quality }

/// Full-screen live player.
/// ◀ (Left) opens Mini-Guide, OK toggles DTH Timeline Guide,
/// ▲/▼ zaps channels, Back closes overlays or returns to Home.
class Player extends StatefulWidget {
  final List<Channel> channels;
  final int index;
  final List<Channel> allChannels;
  final String initialCategory;

  const Player({
    super.key,
    required this.channels,
    required this.index,
    this.allChannels = const [],
    this.initialCategory = 'All',
  });

  @override
  State<Player> createState() => _PlayerState();
}

class _PlayerState extends State<Player> {
  static const _startTimeout = Duration(seconds: 12);

  late List<Channel> activeChannels;
  late List<Channel> allChannels;
  late int index = widget.index;
  int streamIdx = 0;
  VideoPlayerController? controller;
  bool failed = false;
  bool showInfo = true;
  bool showGuide = false;
  bool showTimelineGuide = false;
  bool showControls = false;
  ControlSection _controlSection = ControlSection.playPause;

  String selectedQuality = 'Auto';
  int focusedQualityIdx = 0;
  String? qualityNotice;
  Timer? _noticeTimer, controlsTimer, infoTimer, startTimer, zapTimer, guideTimer, timelineGuideTimer;
  final List<DateTime> _bufferEvents = [];

  int _generation = 0;
  final focus = FocusNode();
  DateTime _lastGuideClose = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastTimelineGuideClose = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastControlsClose = DateTime.fromMillisecondsSinceEpoch(0);

  Channel get channel => activeChannels[index];

  List<String> get availableQualities {
    final resSet = <String>{};
    for (final r in channel.streamResolutions) {
      if (r.isNotEmpty) resSet.add(r);
    }
    if (resSet.isEmpty && channel.resolution.isNotEmpty) {
      resSet.add(channel.resolution);
    }
    return ['Auto', ...resSet];
  }

  @override
  void initState() {
    super.initState();
    activeChannels = List.from(widget.channels);
    allChannels = widget.allChannels.isNotEmpty ? widget.allChannels : widget.channels;
    WakelockPlus.enable();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) focus.requestFocus();
    });
    _open();
  }

  @override
  void dispose() {
    infoTimer?.cancel();
    startTimer?.cancel();
    zapTimer?.cancel();
    guideTimer?.cancel();
    timelineGuideTimer?.cancel();
    controlsTimer?.cancel();
    _noticeTimer?.cancel();
    controller?.dispose();
    focus.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  Future<void> _open() async {
    final gen = ++_generation;
    final old = controller;
    controller = null;
    failed = false;
    showInfo = true;
    infoTimer?.cancel();
    setState(() {});
    old?.dispose();

    if (streamIdx >= channel.streamUrls.length) streamIdx = 0;
    final c = VideoPlayerController.networkUrl(Uri.parse(channel.streamUrls[streamIdx]));
    controller = c;
    startTimer?.cancel();
    startTimer = Timer(_startTimeout, () {
      if (gen == _generation && !c.value.isInitialized) _nextStream(gen);
    });
    c.addListener(() {
      if (gen != _generation) return;
      if (c.value.hasError) {
        _nextStream(gen);
      } else if (c.value.isBuffering) {
        _onBufferEvent();
      }
    });
    try {
      await c.initialize();
      if (gen != _generation) return;
      startTimer?.cancel();
      await c.play();
      RecentProvider.instance.add(channel);
      if (mounted) setState(_flashInfo);
    } catch (_) {
      if (gen == _generation) _nextStream(gen);
    }
  }

  Channel? get _previousChannel {
    final prevKey = RecentProvider.instance.getPreviousKey(channel.idKey);
    if (prevKey == null) return null;
    try {
      return allChannels.firstWhere(
        (c) => c.idKey == prevKey,
        orElse: () => activeChannels.firstWhere((c) => c.idKey == prevKey),
      );
    } catch (_) {
      return null;
    }
  }

  void _onBufferEvent() {
    if (selectedQuality != 'Auto') return;
    final now = DateTime.now();
    _bufferEvents.add(now);
    _bufferEvents.removeWhere((t) => now.difference(t).inSeconds > 15);

    // If buffering persists (>= 2 events in 15 seconds), step down to backup stream
    if (_bufferEvents.length >= 2 && streamIdx + 1 < channel.streamUrls.length) {
      _bufferEvents.clear();
      streamIdx++;
      final newRes = streamIdx < channel.streamResolutions.length
          ? channel.streamResolutions[streamIdx]
          : 'lower stream';
      _showQualityNotice('Network slow · Auto-switched to $newRes');
      _open();
    }
  }

  void _showQualityNotice(String msg) {
    _noticeTimer?.cancel();
    setState(() => qualityNotice = msg);
    _noticeTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => qualityNotice = null);
    });
  }

  void _setQuality(String q) {
    selectedQuality = q;
    if (q == 'Auto') {
      streamIdx = 0;
      _showQualityNotice('Quality: Auto (Network Adaptive)');
      _open();
    } else {
      int target = -1;
      for (var i = 0; i < channel.streamResolutions.length; i++) {
        if (channel.streamResolutions[i].toLowerCase() == q.toLowerCase()) {
          target = i;
          break;
        }
      }
      streamIdx = target >= 0 ? target : 0;
      _showQualityNotice('Quality locked to $q');
      _open();
    }
    setState(() {});
  }

  /// Current stream failed: try the channel's next backup, else show the error.
  void _nextStream(int gen) {
    if (gen != _generation || !mounted) return;
    if (streamIdx + 1 < channel.streamUrls.length) {
      streamIdx++;
      _open();
    } else {
      startTimer?.cancel();
      setState(() {
        failed = true;
        showInfo = true;
      });
      infoTimer?.cancel();
    }
  }

  void _zap(int delta) {
    final n = activeChannels.length;
    setState(() {
      index = (index + delta) % n;
      if (index < 0) index += n;
      streamIdx = 0;
      selectedQuality = 'Auto';
      showInfo = true;
      showControls = false;
    });
    infoTimer?.cancel();
    controlsTimer?.cancel();
    zapTimer?.cancel();
    zapTimer = Timer(const Duration(milliseconds: 350), _open);
  }

  void _flashInfo() {
    showInfo = true;
    infoTimer?.cancel();
    infoTimer = Timer(const Duration(seconds: 5), () {
      if (mounted && !failed) setState(() => showInfo = false);
    });
  }

  void _openTimelineGuide() {
    setState(() {
      showTimelineGuide = true;
      showGuide = false;
      showControls = false;
      showInfo = false;
    });
    infoTimer?.cancel();
    controlsTimer?.cancel();
    guideTimer?.cancel();
    _resetTimelineGuideTimer();
  }

  void _closeTimelineGuide() {
    _lastTimelineGuideClose = DateTime.now();
    timelineGuideTimer?.cancel();
    if (mounted) {
      setState(() => showTimelineGuide = false);
      focus.requestFocus();
      _flashInfo();
    }
  }

  void _resetTimelineGuideTimer() {
    timelineGuideTimer?.cancel();
    timelineGuideTimer = Timer(const Duration(seconds: 30), () {
      if (mounted && showTimelineGuide) _closeTimelineGuide();
    });
  }

  void _openControls() {
    setState(() {
      showControls = true;
      showInfo = false;
      showGuide = false;
      showTimelineGuide = false;
      _controlSection = ControlSection.playPause;
      final qList = availableQualities;
      focusedQualityIdx = qList.contains(selectedQuality) ? qList.indexOf(selectedQuality) : 0;
    });
    infoTimer?.cancel();
    timelineGuideTimer?.cancel();
    _resetControlsTimer();
  }

  void _resetControlsTimer() {
    controlsTimer?.cancel();
    controlsTimer = Timer(const Duration(seconds: 8), () {
      if (mounted && showControls) {
        setState(() => showControls = false);
      }
    });
  }

  void _openGuide() {
    setState(() {
      showGuide = true;
      showInfo = false;
      showControls = false;
      showTimelineGuide = false;
    });
    infoTimer?.cancel();
    controlsTimer?.cancel();
    timelineGuideTimer?.cancel();
    _resetGuideTimer();
  }

  void _closeGuide() {
    _lastGuideClose = DateTime.now();
    guideTimer?.cancel();
    if (mounted) {
      setState(() => showGuide = false);
      focus.requestFocus();
      _flashInfo();
    }
  }

  void _resetGuideTimer() {
    guideTimer?.cancel();
    guideTimer = Timer(const Duration(seconds: 14), () {
      if (mounted && showGuide) _closeGuide();
    });
  }

  void _tuneToChannel(Channel newChannel) {
    if (newChannel.idKey == channel.idKey) {
      // Channel is already playing! Just close overlay without reloading
      if (showTimelineGuide) _closeTimelineGuide();
      if (showGuide) _closeGuide();
      return;
    }
    int n = activeChannels.indexWhere((c) => c.idKey == newChannel.idKey);
    if (n < 0) {
      activeChannels.add(newChannel);
      n = activeChannels.length - 1;
    }
    setState(() {
      index = n;
      streamIdx = 0;
      selectedQuality = 'Auto';
      showControls = false;
    });
    if (showTimelineGuide) _closeTimelineGuide();
    if (showGuide) _closeGuide();
    _open();
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;

    // 1. Controls Overlay is active
    if (showControls) {
      _resetControlsTimer();
      final c = controller;
      final qList = availableQualities;

      if (k == LogicalKeyboardKey.arrowUp) {
        setState(() => _controlSection = ControlSection.quality);
        return KeyEventResult.handled;
      }

      if (k == LogicalKeyboardKey.arrowDown) {
        if (_controlSection == ControlSection.quality) {
          setState(() => _controlSection = ControlSection.playPause);
        } else {
          setState(() => showControls = false);
        }
        return KeyEventResult.handled;
      }

      if (k == LogicalKeyboardKey.arrowLeft) {
        if (_controlSection == ControlSection.quality) {
          if (focusedQualityIdx > 0) {
            setState(() => focusedQualityIdx--);
          }
        } else if (_controlSection == ControlSection.playPause && _previousChannel != null) {
          setState(() => _controlSection = ControlSection.recall);
        } else {
          setState(() => showControls = false);
          _openGuide();
        }
        return KeyEventResult.handled;
      }

      if (k == LogicalKeyboardKey.arrowRight) {
        if (_controlSection == ControlSection.quality) {
          if (focusedQualityIdx < qList.length - 1) {
            setState(() => focusedQualityIdx++);
          }
        } else if (_controlSection == ControlSection.recall) {
          setState(() => _controlSection = ControlSection.playPause);
        }
        return KeyEventResult.handled;
      }

      if (isSelectKey(k)) {
        if (_controlSection == ControlSection.playPause) {
          if (c != null && c.value.isInitialized) {
            if (c.value.isPlaying) {
              c.pause();
            } else {
              c.play();
            }
            setState(() {});
          } else if (failed) {
            streamIdx = 0;
            _open();
          }
        } else if (_controlSection == ControlSection.recall) {
          final prev = _previousChannel;
          if (prev != null) {
            _tuneToChannel(prev);
          }
        } else if (_controlSection == ControlSection.quality) {
          if (focusedQualityIdx >= 0 && focusedQualityIdx < qList.length) {
            _setQuality(qList[focusedQualityIdx]);
          }
        }
        return KeyEventResult.handled;
      }

      if (k == LogicalKeyboardKey.channelUp) {
        _zap(-1);
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.channelDown) {
        _zap(1);
        return KeyEventResult.handled;
      }

      return KeyEventResult.handled;
    }

    // 2. Default Video Playback Controls
    if (k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.channelUp) {
      _zap(-1);
      return KeyEventResult.handled;
    } else if (k == LogicalKeyboardKey.arrowDown || k == LogicalKeyboardKey.channelDown) {
      _zap(1);
      return KeyEventResult.handled;
    } else if (k == LogicalKeyboardKey.contextMenu ||
        k == LogicalKeyboardKey.f1 ||
        k == LogicalKeyboardKey.f3) {
      _openControls();
      return KeyEventResult.handled;
    } else if (k == LogicalKeyboardKey.mediaPlayPause) {
      FavoritesProvider.instance.toggle(channel).then((_) {
        if (mounted) setState(_flashInfo);
      });
      return KeyEventResult.handled;
    } else if (k == LogicalKeyboardKey.arrowLeft) {
      // Left key exclusively opens the channel guide
      if (failed) {
        streamIdx = 0;
        _open();
      } else {
        _openGuide();
      }
      return KeyEventResult.handled;
    } else if (isSelectKey(k)) {
      if (DateTime.now().difference(_lastGuideClose) < const Duration(milliseconds: 350) ||
          DateTime.now().difference(_lastTimelineGuideClose) < const Duration(milliseconds: 350)) {
        return KeyEventResult.handled;
      }
      // OK key opens full DTH Timeline Guide!
      _openTimelineGuide();
      return KeyEventResult.handled;
    } else if (k == LogicalKeyboardKey.arrowRight) {
      setState(_flashInfo);
      return KeyEventResult.handled;
    } else {
      return KeyEventResult.ignored;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final ready = c != null && c.value.isInitialized;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (showTimelineGuide) {
          _closeTimelineGuide();
          return;
        }
        if (showControls) {
          _lastControlsClose = DateTime.now();
          setState(() => showControls = false);
          return;
        }
        if (DateTime.now().difference(_lastControlsClose) < const Duration(milliseconds: 350)) {
          return;
        }
        if (showGuide) {
          _closeGuide();
          return;
        }
        if (DateTime.now().difference(_lastGuideClose) < const Duration(milliseconds: 350) ||
            DateTime.now().difference(_lastTimelineGuideClose) < const Duration(milliseconds: 350)) {
          return;
        }
        Navigator.of(context).pop(index);
      },
      child: Focus(
        focusNode: focus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            fit: StackFit.expand,
            children: [
              if (ready)
                Center(
                  child: AspectRatio(
                    aspectRatio: c.value.aspectRatio > 0 ? c.value.aspectRatio : 16 / 9,
                    child: VideoPlayer(c),
                  ),
                ),
              if (!failed)
                ValueListenableBuilder<VideoPlayerValue>(
                  valueListenable: c ?? ValueNotifier(const VideoPlayerValue.uninitialized()),
                  builder: (_, v, __) => (!v.isInitialized || v.isBuffering)
                      ? const Center(
                          child: SizedBox(
                              width: 34,
                              height: 34,
                              child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white70)))
                      : const SizedBox.shrink(),
                ),
              if (failed && !showControls)
                Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.signal_wifi_bad_rounded, color: Colors.white54, size: 40),
                    const SizedBox(height: 12),
                    const Text('This channel isn’t available right now',
                        style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 6),
                    Text('OK: Timeline Guide · Menu: Controls · ▲ ▼: Another channel · ◀: Channels',
                        style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 13)),
                  ]),
                ),

              // Simple bottom info bar when controls and guide are hidden
              AnimatedOpacity(
                opacity: showInfo && !showGuide && !showControls && !showTimelineGuide ? 1 : 0,
                duration: const Duration(milliseconds: 250),
                child: Align(alignment: Alignment.bottomCenter, child: _infoBar()),
              ),

              // Full Controls Overlay (Play/Pause & Quality switcher)
              if (showControls && !showGuide && !showTimelineGuide)
                Positioned.fill(
                  child: _buildControlsOverlay(c),
                ),

              // Mini Guide Sidebar
              if (showGuide && !showTimelineGuide)
                Positioned(
                  top: 0,
                  bottom: 0,
                  left: 0,
                  child: MiniGuide(
                    allChannels: allChannels,
                    currentChannel: channel,
                    initialCategory: widget.initialCategory,
                    onTune: _tuneToChannel,
                    onClose: _closeGuide,
                    onUserActivity: _resetGuideTimer,
                  ),
                ),

              // Full DTH Timeline Guide Overlay (Airtel/Tata Play STB style from photo!)
              if (showTimelineGuide)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: TimelineGuide(
                    allChannels: allChannels,
                    currentChannel: channel,
                    initialCategory: widget.initialCategory,
                    onTune: _tuneToChannel,
                    onClose: _closeTimelineGuide,
                    onUserActivity: _resetTimelineGuideTimer,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildControlsOverlay(VideoPlayerController? c) {
    final qList = availableQualities;
    final isPlaying = c != null && c.value.isPlaying;

    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color(0xCC000000),
            Color(0x55000000),
            Color(0xE6000000),
          ],
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            // Top Bar: Live badge & Quality Selector
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 20, 28, 12),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE53935),
                      borderRadius: BorderRadius.circular(6),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFFE53935).withValues(alpha: 0.5),
                          blurRadius: 8,
                        ),
                      ],
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.circle, size: 7, color: Colors.white),
                        SizedBox(width: 6),
                        Text('LIVE',
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 1.2)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 14),
                  Text(channel.name,
                      style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
                  const Spacer(),
                  // Quality Selector Pills
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.tune_rounded, size: 16, color: Colors.white70),
                      const SizedBox(width: 6),
                      const Text('Quality: ',
                          style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w500)),
                      const SizedBox(width: 8),
                      for (var i = 0; i < qList.length; i++) ...[
                        _buildQualityPill(qList[i], i),
                        if (i < qList.length - 1) const SizedBox(width: 8),
                      ],
                    ],
                  ),
                ],
              ),
            ),

            // Quality notification toast (if active)
            if (qualityNotice != null) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E293B),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: const Color(0xFF38BDF8), width: 1),
                  boxShadow: [
                    BoxShadow(color: const Color(0xFF38BDF8).withValues(alpha: 0.25), blurRadius: 10),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.auto_awesome_rounded, size: 14, color: Color(0xFF38BDF8)),
                    const SizedBox(width: 8),
                    Text(qualityNotice!,
                        style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            ],

            const Spacer(),

            // Center Controls: Recall Button (if available) + Play / Pause Hero Button
            Builder(
              builder: (context) {
                final prev = _previousChannel;
                return Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (prev != null) ...[
                      _buildRecallButton(prev),
                      const SizedBox(width: 48),
                    ],
                    _buildPlayPauseButton(isPlaying, c),
                  ],
                );
              },
            ),

            const Spacer(),

            // Bottom bar: Channel info & remote hints
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 12, 28, 24),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  ChannelIcon(key: ValueKey(channel.logoUrl + channel.name), channel: channel, width: 84, height: 48),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(channel.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w700)),
                            ),
                            if (FavoritesProvider.instance.isFavorite(channel)) ...[
                              const SizedBox(width: 8),
                              const Icon(Icons.star_rounded, color: Color(0xFFFFD700), size: 20),
                            ],
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${channel.category}  ·  Quality: $selectedQuality (${channel.streamResolutions.length > streamIdx ? channel.streamResolutions[streamIdx] : channel.resolution})',
                          style: TextStyle(color: Colors.white.withValues(alpha: 0.65), fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                  Text(
                    _previousChannel != null
                        ? 'OK: Select  ·  ◀ / ▶: Switch Controls  ·  ▲: Quality  ·  Back: Close'
                        : 'OK: ${isPlaying ? 'Pause' : 'Play'}  ·  ▲: Quality  ·  ◀: Guide  ·  Back: Close',
                    style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRecallButton(Channel prev) {
    final isFocused = _controlSection == ControlSection.recall;
    return GestureDetector(
      onTap: () {
        _tuneToChannel(prev);
        _resetControlsTimer();
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            width: 76,
            height: 76,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isFocused ? Colors.white : const Color(0x33FFFFFF),
              boxShadow: isFocused
                  ? [
                      BoxShadow(color: Colors.white.withValues(alpha: 0.8), blurRadius: 20, spreadRadius: 2),
                    ]
                  : [],
              border: Border.all(
                color: isFocused ? Colors.white : const Color(0x66FFFFFF),
                width: 2,
              ),
            ),
            child: Icon(
              Icons.replay_rounded,
              size: 40,
              color: isFocused ? Colors.black : Colors.white,
            ),
          ),
          const SizedBox(height: 10),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 140),
            child: Text(
              'LAST: ${prev.name}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: isFocused ? Colors.white : Colors.white70,
                fontSize: 12,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.1,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlayPauseButton(bool isPlaying, VideoPlayerController? c) {
    final isFocused = _controlSection == ControlSection.playPause;
    return GestureDetector(
      onTap: () {
        if (c != null) {
          c.value.isPlaying ? c.pause() : c.play();
          setState(() {});
          _resetControlsTimer();
        }
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            width: 76,
            height: 76,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isFocused ? Colors.white : const Color(0x33FFFFFF),
              boxShadow: isFocused
                  ? [
                      BoxShadow(color: Colors.white.withValues(alpha: 0.8), blurRadius: 20, spreadRadius: 2),
                    ]
                  : [],
              border: Border.all(
                color: isFocused ? Colors.white : const Color(0x66FFFFFF),
                width: 2,
              ),
            ),
            child: Icon(
              isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
              size: 44,
              color: isFocused ? Colors.black : Colors.white,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            isPlaying ? 'PAUSE' : 'PLAY',
            style: TextStyle(
              color: isFocused ? Colors.white : Colors.white70,
              fontSize: 12,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQualityPill(String q, int i) {
    final isSelected = q == selectedQuality;
    final isFocused = _controlSection == ControlSection.quality && i == focusedQualityIdx;

    return GestureDetector(
      onTap: () {
        _setQuality(q);
        _resetControlsTimer();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isFocused
              ? Colors.white
              : isSelected
                  ? const Color(0xFF2563EB)
                  : const Color(0x22FFFFFF),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isFocused
                ? Colors.white
                : isSelected
                    ? const Color(0xFF60A5FA)
                    : const Color(0x25FFFFFF),
            width: isFocused || isSelected ? 1.5 : 1,
          ),
          boxShadow: isFocused
              ? [BoxShadow(color: Colors.white.withValues(alpha: 0.6), blurRadius: 10)]
              : isSelected
                  ? [BoxShadow(color: const Color(0xFF2563EB).withValues(alpha: 0.4), blurRadius: 8)]
                  : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (q == 'Auto') ...[
              Icon(
                Icons.auto_awesome_rounded,
                size: 13,
                color: isFocused
                    ? Colors.black
                    : isSelected
                        ? Colors.white
                        : Colors.white70,
              ),
              const SizedBox(width: 4),
            ],
            Text(
              q,
              style: TextStyle(
                color: isFocused
                    ? Colors.black
                    : isSelected
                        ? Colors.white
                        : Colors.white70,
                fontSize: 12,
                fontWeight: isFocused || isSelected ? FontWeight.w800 : FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _infoBar() {
    final nowProg = EpgProvider.instance.getNow(channel);
    final nextProg = EpgProvider.instance.getNext(channel);
    final now = DateTime.now();
    final hour = now.hour % 12 == 0 ? 12 : now.hour % 12;
    final minute = now.minute.toString().padLeft(2, '0');
    final ampm = now.hour >= 12 ? 'PM' : 'AM';
    final timeStr = '$hour:$minute $ampm';

    final resText = channel.streamResolutions.length > streamIdx
        ? channel.streamResolutions[streamIdx]
        : channel.resolution;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(28, 20, 28, 20),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color(0x00000000),
            Color(0xB3050B14),
            Color(0xF0050B14),
          ],
          stops: [0.0, 0.35, 1.0],
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // 1. Channel Logo & Number
          Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: const Color(0x33000000),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0x22FFFFFF), width: 1),
            ),
            child: ChannelIcon(
              key: ValueKey(channel.logoUrl + channel.name),
              channel: channel,
              width: 90,
              height: 52,
            ),
          ),
          const SizedBox(width: 18),

          // 2. Main EPG & Channel Details
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Top Row: Channel number + name + Badges + Clock
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0284C7),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '${index + 1}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        channel.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.2,
                        ),
                      ),
                    ),
                    if (FavoritesProvider.instance.isFavorite(channel)) ...[
                      const SizedBox(width: 6),
                      const Icon(Icons.star_rounded, color: Color(0xFFFFD700), size: 20),
                    ],
                    const SizedBox(width: 10),
                    // Category pill
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0x22FFFFFF),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        channel.category,
                        style: const TextStyle(
                          color: Color(0xFF94A3B8),
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    // Resolution / Quality pill
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0x1838BDF8),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: const Color(0x4438BDF8), width: 0.8),
                      ),
                      child: Text(
                        resText.toUpperCase(),
                        style: const TextStyle(
                          color: Color(0xFF38BDF8),
                          fontSize: 10.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    const Spacer(),
                    // Live Clock
                    Text(
                      timeStr,
                      style: const TextStyle(
                        color: Color(0xFFF1F5F9),
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),

                // Now Playing Program Row
                if (nowProg != null) ...[
                  Row(
                    children: [
                      const Text(
                        'NOW',
                        style: TextStyle(
                          color: Color(0xFF38BDF8),
                          fontSize: 11,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0.8,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          nowProg.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        nowProg.timeRangeText,
                        style: const TextStyle(
                          color: Color(0xFF94A3B8),
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                        decoration: BoxDecoration(
                          color: const Color(0x250284C7),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          nowProg.remainingText,
                          style: const TextStyle(
                            color: Color(0xFF38BDF8),
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  // Progress Bar
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: SizedBox(
                      height: 3,
                      child: LinearProgressIndicator(
                        value: nowProg.progress.clamp(0.0, 1.0),
                        backgroundColor: const Color(0x22FFFFFF),
                        valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF38BDF8)),
                      ),
                    ),
                  ),
                  const SizedBox(height: 5),
                  // Next Show Row + Remote Key Hints
                  Row(
                    children: [
                      if (nextProg != null) ...[
                        const Text(
                          'NEXT',
                          style: TextStyle(
                            color: Color(0xFF64748B),
                            fontSize: 10.5,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.6,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            '${nextProg.title} (${nextProg.timeRangeText})',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Color(0xFF94A3B8),
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ] else ...[
                        const Text(
                          'Live Streaming',
                          style: TextStyle(color: Color(0xFF64748B), fontSize: 12),
                        ),
                      ],
                      const Spacer(),
                      const Text(
                        'OK: Guide  ·  ◀: Channels  ·  ▲▼: Zap  ·  Menu: ⭐',
                        style: TextStyle(
                          color: Color(0xFF64748B),
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ] else ...[
                  // Fallback when no EPG data for this channel
                  Row(
                    children: [
                      const Text(
                        'Live Broadcast',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 14.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        'Channel ${index + 1} of ${activeChannels.length}  ·  $selectedQuality',
                        style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
                      ),
                      const Spacer(),
                      const Text(
                        'OK: Guide  ·  ◀: Channels  ·  ▲▼: Zap  ·  Menu: ⭐',
                        style: TextStyle(
                          color: Color(0xFF64748B),
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

