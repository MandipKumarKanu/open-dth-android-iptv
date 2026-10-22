import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../model/channel.dart';
import '../provider/epg_provider.dart';
import '../provider/favorites_provider.dart';
import '../provider/player_settings_provider.dart';
import '../provider/recent_provider.dart';
import '../provider/reminder_provider.dart';
import '../provider/stream_memory_provider.dart';
import '../services/audio_track_service.dart';
import '../widgets/channel_icon.dart';
import '../widgets/mini_guide.dart';
import '../widgets/timeline_guide.dart';
import '../widgets/tv_audio_track_dialog.dart';
import '../widgets/tv_search_dialog.dart';
import 'home.dart' show isSelectKey;

enum ControlSection { playPause, recall, quality, screenFit, audioTrack, epgGuide }

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
  static const _startTimeout = Duration(seconds: 5);

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
  List<AudioTrack> _audioTracks = [];
  AudioTrack? _selectedAudioTrack;
  Timer? _noticeTimer, controlsTimer, infoTimer, startTimer, zapTimer, guideTimer, timelineGuideTimer, _bufferingStepDownTimer;
  final List<DateTime> _bufferEvents = [];

  int _generation = 0;
  final focus = FocusNode();
  DateTime _lastGuideClose = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastTimelineGuideClose = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastControlsClose = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastInfoClose = DateTime.fromMillisecondsSinceEpoch(0);

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

  int _streamRetryCount = 0;
  static const int _maxStreamRetries = 3;
  Timer? _retryTimer;
  Timer? _autoRecoveryTimer;
  bool _isReconnecting = false;
  int _recoveryAttempts = 0;

  @override
  void initState() {
    super.initState();
    activeChannels = List.from(widget.channels);
    allChannels = widget.allChannels.isNotEmpty ? widget.allChannels : widget.channels;
    streamIdx = StreamMemoryProvider.instance.getPreferredStreamIndex(channel);
    PlayerSettingsProvider.instance.load().then((_) {
      if (mounted) setState(() {});
    });
    ReminderProvider.instance.load();
    ReminderProvider.instance.onReminderDue = _showReminderAlert;
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
    _reminderAlertTimer?.cancel();
    _retryTimer?.cancel();
    _autoRecoveryTimer?.cancel();
    _bufferingStepDownTimer?.cancel();
    if (ReminderProvider.instance.onReminderDue == _showReminderAlert) {
      ReminderProvider.instance.onReminderDue = null;
    }
    controller?.dispose();
    focus.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  Future<void> _open({bool persistWorkingStream = true}) async {
    final gen = ++_generation;
    final old = controller;
    controller = null;
    failed = false;
    showInfo = true;
    _audioTracks = [];
    _selectedAudioTrack = null;
    infoTimer?.cancel();
    setState(() {});
    old?.dispose();

    if (streamIdx >= channel.streamUrls.length) streamIdx = 0;
    final c = VideoPlayerController.networkUrl(
      Uri.parse(channel.streamUrls[streamIdx]),
      httpHeaders: const {
        'User-Agent':
            'Mozilla/5.0 (Linux; Android 10; TV) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        'Accept': '*/*',
        'Connection': 'keep-alive',
      },
    );
    controller = c;
    startTimer?.cancel();
    startTimer = Timer(_startTimeout, () {
      if (gen == _generation && !c.value.isInitialized) {
        _handleStreamError(gen);
      }
    });
    c.addListener(() {
      if (gen != _generation) return;
      if (c.value.hasError) {
        _handleStreamError(gen);
      } else if (c.value.isBuffering) {
        _onBufferEvent();
      }
    });
    try {
      await c.initialize();
      if (gen != _generation) return;
      startTimer?.cancel();
      await c.play();
      _streamRetryCount = 0;
      _stopAutoRecoveryTimer();
      if (_isReconnecting) {
        setState(() => _isReconnecting = false);
        _showQualityNotice('Connection restored · Stream resumed');
      }
      RecentProvider.instance.add(channel);
      final currentUrl = channel.streamUrls[streamIdx];
      if (persistWorkingStream) {
        StreamMemoryProvider.instance.rememberWorkingStream(channel, currentUrl);
      }

      // Apply saved preferred audio language if set
      final prefLang = PlayerSettingsProvider.instance.preferredAudioLanguage;
      if (prefLang.isNotEmpty) {
        AudioTrackService.setPreferredAudioLanguage(
          language: prefLang,
        );
      }
      _refreshAudioTracks(c, gen);

      // Establish ~18-second live buffer window behind live edge so ExoPlayer holds
      // multiple media chunks in memory, preventing buffering on transient network jitter.
      Future.delayed(const Duration(milliseconds: 1400), () {
        if (mounted && gen == _generation && controller == c) {
          AudioTrackService.enableLiveBufferWindow(offsetMs: 18000);
        }
      });

      if (mounted) {
        if (streamIdx > 0 && !_isReconnecting) {
          final res = streamIdx < channel.streamResolutions.length ? channel.streamResolutions[streamIdx] : 'Backup';
          _showQualityNotice('Connected to backup stream ($res) · Saved as default');
        }
        setState(_flashInfo);
      }
    } catch (_) {
      if (gen == _generation) _handleStreamError(gen);
    }
  }

  Future<void> _refreshAudioTracks(VideoPlayerController c, int gen, [int retryCount = 0]) async {
    try {
      final tracks = await AudioTrackService.getAudioTracks();
      if (gen != _generation) return;
      if (tracks.isNotEmpty) {
        final active = tracks.where((t) => t.isSelected).firstOrNull ?? tracks.first;
        if (mounted) {
          setState(() {
            _audioTracks = tracks;
            _selectedAudioTrack = active;
          });
        }
      } else if (retryCount < 4) {
        // HLS manifests may take a split-second to parse on ExoPlayer
        Future.delayed(const Duration(milliseconds: 600), () {
          if (mounted && gen == _generation && controller == c) {
            _refreshAudioTracks(c, gen, retryCount + 1);
          }
        });
      } else {
        if (mounted && gen == _generation) {
          setState(() {
            _audioTracks = [];
            _selectedAudioTrack = null;
          });
        }
      }
    } catch (_) {}
  }

  Future<void> _selectAudioTrack(AudioTrack track) async {
    final c = controller;
    if (c == null) return;
    final success = await AudioTrackService.selectAudioTrack(
      groupIndex: track.groupIndex,
      trackIndex: track.trackIndex,
    );
    if (success) {
      if (track.language.isNotEmpty) {
        await PlayerSettingsProvider.instance.setPreferredAudioLanguage(track.language);
      }
      _showQualityNotice('Audio: ${track.displayName} · Saved as preferred');
      await _refreshAudioTracks(c, _generation);
    } else {
      _showQualityNotice('Failed to switch audio track');
    }
  }

  void _openAudioTrackDialog() {
    if (_audioTracks.isEmpty) return;
    showDialog(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.65),
      builder: (ctx) => TvAudioTrackDialog(
        tracks: _audioTracks,
        selectedTrack: _selectedAudioTrack,
        onTrackSelected: (track) async {
          Navigator.of(ctx).pop();
          await _selectAudioTrack(track);
        },
      ),
    ).then((_) {
      if (mounted) {
        focus.requestFocus();
      }
    });
  }



  Channel? get _previousChannel {
    final prevKey = RecentProvider.instance.getPreviousKey(channel.idKey);
    if (prevKey == null) return null;
    for (final c in allChannels) {
      if (c.idKey == prevKey) return c;
    }
    for (final c in activeChannels) {
      if (c.idKey == prevKey) return c;
    }
    return null;
  }

  void _onBufferEvent() {
    if (selectedQuality != 'Auto' || _isReconnecting) return;
    final now = DateTime.now();
    _bufferEvents.add(now);
    _bufferEvents.removeWhere((t) => now.difference(t).inSeconds > 15);

    // If stream stays buffering for > 3.5s continuously, step down to backup stream
    _bufferingStepDownTimer?.cancel();
    _bufferingStepDownTimer = Timer(const Duration(milliseconds: 3500), () {
      if (mounted && controller?.value.isBuffering == true) {
        _stepDownToBackupStream();
      }
    });

    // If buffering occurs 2 times within 15 seconds, step down to backup stream
    if (_bufferEvents.length >= 2) {
      _stepDownToBackupStream();
    }
  }

  void _stepDownToBackupStream() {
    _bufferingStepDownTimer?.cancel();
    _bufferEvents.clear();
    if (streamIdx + 1 < channel.streamUrls.length) {
      streamIdx++;
      final newRes = streamIdx < channel.streamResolutions.length
          ? channel.streamResolutions[streamIdx]
          : 'backup stream';
      _showQualityNotice('Network slow · Auto-switched to $newRes');
      _open(persistWorkingStream: false);
    }
  }

  ProgramReminder? _activeReminderAlert;
  Timer? _reminderAlertTimer;

  void _showReminderAlert(ProgramReminder r) {
    if (!mounted) return;
    _reminderAlertTimer?.cancel();
    setState(() => _activeReminderAlert = r);
    _reminderAlertTimer = Timer(const Duration(seconds: 14), () {
      if (mounted) setState(() => _activeReminderAlert = null);
    });
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
    _streamRetryCount = 0;
    _retryTimer?.cancel();
    _stopAutoRecoveryTimer();
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
      StreamMemoryProvider.instance.rememberWorkingStream(channel, channel.streamUrls[streamIdx]);
      _showQualityNotice('Quality locked to $q');
      _open();
    }
    setState(() {});
  }

  void _toggleScreenFit() async {
    final next = await PlayerSettingsProvider.instance.cycleScreenFit();
    _showQualityNotice('Screen Fit: ${next.label} (${next.description})');
    if (mounted) setState(() {});
  }

  /// Transient network error handler: performs silent exponential retries on the current stream
  /// before giving up or falling back to a backup stream.
  void _handleStreamError(int gen) {
    if (gen != _generation || !mounted) return;
    if (_retryTimer?.isActive == true) return;
    startTimer?.cancel();

    if (_streamRetryCount < _maxStreamRetries) {
      _streamRetryCount++;
      setState(() => _isReconnecting = true);
      final delayMs = _streamRetryCount * 700; // 700ms, 1400ms, 2100ms
      _showQualityNotice('Signal drop detected · Auto-reconnecting ($_streamRetryCount/$_maxStreamRetries)...');
      _retryTimer = Timer(Duration(milliseconds: delayMs), () {
        if (mounted && gen == _generation) {
          _open(persistWorkingStream: false);
        }
      });
    } else {
      // 3 retries on this stream failed -> fall back to next backup stream or auto-recovery
      _nextStream(gen);
    }
  }

  /// Automatically polls in the background when a channel fails (e.g. Wi-Fi dropped for 10+ seconds).
  /// As soon as network connectivity is restored on the TV, playback auto-resumes seamlessly.
  void _startAutoRecoveryTimer() {
    _autoRecoveryTimer?.cancel();
    _recoveryAttempts = 0;
    _autoRecoveryTimer = Timer.periodic(const Duration(seconds: 4), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (!failed) {
        timer.cancel();
        return;
      }
      _recoveryAttempts++;
      if (_recoveryAttempts > 30) {
        timer.cancel();
        if (mounted) setState(() {});
        return;
      }
      if (mounted) setState(() {});
      final prefIdx = StreamMemoryProvider.instance.getPreferredStreamIndex(channel);
      streamIdx = prefIdx < channel.streamUrls.length ? prefIdx : 0;
      _streamRetryCount = 0;
      _open(persistWorkingStream: false);
    });
  }

  void _stopAutoRecoveryTimer() {
    _autoRecoveryTimer?.cancel();
    _autoRecoveryTimer = null;
    _recoveryAttempts = 0;
  }

  /// Current stream failed: report failure and try the channel's next backup.
  void _nextStream(int gen) {
    if (gen != _generation || !mounted) return;
    _retryTimer?.cancel();
    _streamRetryCount = 0;

    final failedUrl = (streamIdx < channel.streamUrls.length) ? channel.streamUrls[streamIdx] : '';
    if (failedUrl.isNotEmpty) {
      StreamMemoryProvider.instance.reportStreamFailure(channel, failedUrl);
    }

    if (streamIdx + 1 < channel.streamUrls.length) {
      streamIdx++;
      final nextRes = streamIdx < channel.streamResolutions.length
          ? channel.streamResolutions[streamIdx]
          : 'backup ${streamIdx + 1}';
      _showQualityNotice('Stream $streamIdx unavailable · Trying backup $nextRes...');
      _open();
    } else {
      startTimer?.cancel();
      setState(() {
        failed = true;
        showInfo = true;
        _isReconnecting = false;
      });
      infoTimer?.cancel();
      _startAutoRecoveryTimer();
    }
  }

  void _zap(int delta) {
    _retryTimer?.cancel();
    _stopAutoRecoveryTimer();
    _streamRetryCount = 0;
    _isReconnecting = false;
    final n = activeChannels.length;
    setState(() {
      index = (index + delta) % n;
      if (index < 0) index += n;
      streamIdx = StreamMemoryProvider.instance.getPreferredStreamIndex(activeChannels[index]);
      selectedQuality = 'Auto';
      showInfo = true;
      showControls = false;
      showTimelineGuide = false;
    });
    infoTimer?.cancel();
    controlsTimer?.cancel();
    timelineGuideTimer?.cancel();
    zapTimer?.cancel();
    // Cancel any pending start-timeout from the previous channel: during the
    // 350 ms debounce window _generation hasn't changed yet, so it would fire
    // against the already-updated channel index.
    startTimer?.cancel();
    zapTimer = Timer(const Duration(milliseconds: 350), _open);
  }

  void _flashInfo() {
    showInfo = true;
    infoTimer?.cancel();
    infoTimer = Timer(const Duration(seconds: 5), () {
      if (mounted && !failed) setState(() => showInfo = false);
    });
  }

  void _closeInfo() {
    _lastInfoClose = DateTime.now();
    infoTimer?.cancel();
    if (mounted) {
      setState(() => showInfo = false);
    }
  }

  bool _isBackKey(LogicalKeyboardKey k) =>
      k == LogicalKeyboardKey.escape ||
      k == LogicalKeyboardKey.goBack ||
      k == LogicalKeyboardKey.browserBack;

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

  void _closeTimelineGuide({bool flashInfo = false}) {
    _lastTimelineGuideClose = DateTime.now();
    timelineGuideTimer?.cancel();
    if (mounted) {
      setState(() => showTimelineGuide = false);
      focus.requestFocus();
      if (flashInfo) _flashInfo();
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

  void _openVoiceSearch() {
    if (showTimelineGuide) _closeTimelineGuide();
    if (showGuide) _closeGuide();
    setState(() => showControls = false);
    showDialog(
      context: context,
      builder: (_) => TvSearchDialog(
        allChannels: allChannels,
        autoStartVoice: true,
        onChannelSelect: (ch) {
          _tuneToChannel(ch);
        },
      ),
    );
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

  void _closeGuide({bool flashInfo = false}) {
    _lastGuideClose = DateTime.now();
    guideTimer?.cancel();
    if (mounted) {
      setState(() => showGuide = false);
      focus.requestFocus();
      if (flashInfo) _flashInfo();
    }
  }


  void _resetGuideTimer() {
    guideTimer?.cancel();
    guideTimer = Timer(const Duration(seconds: 14), () {
      if (mounted && showGuide) _closeGuide();
    });
  }

  void _tuneToChannel(Channel newChannel) {
    _retryTimer?.cancel();
    _stopAutoRecoveryTimer();
    _streamRetryCount = 0;
    _isReconnecting = false;
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
      streamIdx = StreamMemoryProvider.instance.getPreferredStreamIndex(newChannel);
      selectedQuality = 'Auto';
      showControls = false;
    });
    if (showTimelineGuide) _closeTimelineGuide();
    if (showGuide) _closeGuide();
    _open();
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    final k = e.logicalKey;
    if (e is KeyUpEvent) {
      if (_isBackKey(k)) {
        if (DateTime.now().difference(_lastInfoClose) < const Duration(milliseconds: 450) ||
            DateTime.now().difference(_lastControlsClose) < const Duration(milliseconds: 450) ||
            DateTime.now().difference(_lastGuideClose) < const Duration(milliseconds: 450) ||
            DateTime.now().difference(_lastTimelineGuideClose) < const Duration(milliseconds: 450)) {
          return KeyEventResult.handled;
        }
      }
      return KeyEventResult.ignored;
    }

    // Active reminder alert interception (OK to tune, Back to dismiss)
    if (_activeReminderAlert != null) {
      if (isSelectKey(k)) {
        final alert = _activeReminderAlert!;
        _reminderAlertTimer?.cancel();
        setState(() => _activeReminderAlert = null);
        try {
          final target = allChannels.firstWhere(
            (c) => c.idKey == alert.channelKey,
            orElse: () => activeChannels.firstWhere(
              (c) => c.name.toLowerCase() == alert.channelName.toLowerCase(),
              orElse: () => channel,
            ),
          );
          _tuneToChannel(target);
        } catch (_) {}
        return KeyEventResult.handled;
      }
      if (_isBackKey(k)) {
        _reminderAlertTimer?.cancel();
        setState(() => _activeReminderAlert = null);
        return KeyEventResult.handled;
      }
    }

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
        } else if (_controlSection == ControlSection.audioTrack) {
          setState(() => _controlSection = ControlSection.screenFit);
        } else if (_controlSection == ControlSection.screenFit) {
          setState(() => _controlSection = ControlSection.epgGuide);
        } else if (_controlSection == ControlSection.epgGuide) {
          setState(() => _controlSection = ControlSection.playPause);
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
        } else if (_controlSection == ControlSection.playPause) {
          setState(() => _controlSection = ControlSection.epgGuide);
        } else if (_controlSection == ControlSection.epgGuide) {
          setState(() => _controlSection = ControlSection.screenFit);
        } else if (_controlSection == ControlSection.screenFit && _audioTracks.isNotEmpty) {
          setState(() => _controlSection = ControlSection.audioTrack);
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
        } else if (_controlSection == ControlSection.epgGuide) {
          _openTimelineGuide();
        } else if (_controlSection == ControlSection.screenFit) {
          _toggleScreenFit();
        } else if (_controlSection == ControlSection.audioTrack) {
          _openAudioTrackDialog();
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
    } else if (k == LogicalKeyboardKey.digit0 || k == LogicalKeyboardKey.f2) {
      _toggleScreenFit();
      return KeyEventResult.handled;
    } else if (k.keyId == 0x002000000e7 || // KEYCODE_VOICE_ASSIST
        k.keyId == 0x00200000054 || // KEYCODE_SEARCH
        k.keyId == 0x002000000db || // KEYCODE_ASSIST
        k == LogicalKeyboardKey.f5) {
      _openVoiceSearch();
      return KeyEventResult.handled;
    } else if (k == LogicalKeyboardKey.mediaPlayPause) {
      FavoritesProvider.instance.toggle(channel).then((_) {
        if (mounted) setState(_flashInfo);
      });
      return KeyEventResult.handled;
    } else if (k == LogicalKeyboardKey.arrowLeft) {
      // Left key exclusively opens the channel guide
      _openGuide();
      return KeyEventResult.handled;
    } else if (_isBackKey(k)) {
      if (DateTime.now().difference(_lastInfoClose) < const Duration(milliseconds: 450) ||
          DateTime.now().difference(_lastControlsClose) < const Duration(milliseconds: 450) ||
          DateTime.now().difference(_lastGuideClose) < const Duration(milliseconds: 450) ||
          DateTime.now().difference(_lastTimelineGuideClose) < const Duration(milliseconds: 450)) {
        return KeyEventResult.handled;
      }
      if (showTimelineGuide) {
        _closeTimelineGuide();
        return KeyEventResult.handled;
      }
      if (showControls) {
        _lastControlsClose = DateTime.now();
        setState(() => showControls = false);
        return KeyEventResult.handled;
      }
      if (showGuide) {
        _closeGuide();
        return KeyEventResult.handled;
      }
      if (showInfo && !failed) {
        _closeInfo();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    } else if (isSelectKey(k)) {
      if (failed) {
        _stopAutoRecoveryTimer();
        streamIdx = 0;
        _streamRetryCount = 0;
        _showQualityNotice('Retrying connection...');
        _open();
        return KeyEventResult.handled;
      }
      if (DateTime.now().difference(_lastGuideClose) < const Duration(milliseconds: 350) ||
          DateTime.now().difference(_lastTimelineGuideClose) < const Duration(milliseconds: 350) ||
          DateTime.now().difference(_lastControlsClose) < const Duration(milliseconds: 350) ||
          DateTime.now().difference(_lastInfoClose) < const Duration(milliseconds: 350)) {
        return KeyEventResult.handled;
      }
      _openControls();
      return KeyEventResult.handled;
    } else if (k == LogicalKeyboardKey.arrowRight) {
      if (!showInfo) {
        setState(_flashInfo);
      } else {
        _openTimelineGuide();
      }
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
        if (_activeReminderAlert != null) {
          _reminderAlertTimer?.cancel();
          setState(() => _activeReminderAlert = null);
          return;
        }
        if (showTimelineGuide) {
          _closeTimelineGuide();
          return;
        }
        if (showControls) {
          _lastControlsClose = DateTime.now();
          setState(() => showControls = false);
          return;
        }
        if (DateTime.now().difference(_lastControlsClose) < const Duration(milliseconds: 450)) {
          return;
        }
        if (showGuide) {
          _closeGuide();
          return;
        }
        if (DateTime.now().difference(_lastGuideClose) < const Duration(milliseconds: 450) ||
            DateTime.now().difference(_lastTimelineGuideClose) < const Duration(milliseconds: 450)) {
          return;
        }
        // If bottom Info Bar is visible, dismiss it first! Do NOT exit the channel!
        if (showInfo && !failed) {
          _closeInfo();
          return;
        }
        if (DateTime.now().difference(_lastInfoClose) < const Duration(milliseconds: 450)) {
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
                Positioned.fill(
                  child: FittedBox(
                    fit: PlayerSettingsProvider.instance.screenFit.boxFit,
                    child: SizedBox(
                      width: c.value.size.width > 0 ? c.value.size.width : 16,
                      height: c.value.size.height > 0 ? c.value.size.height : 9,
                      child: VideoPlayer(c),
                    ),
                  ),
                ),
              if (!failed)
                ValueListenableBuilder<VideoPlayerValue>(
                  valueListenable: c ?? ValueNotifier(const VideoPlayerValue.uninitialized()),
                  builder: (_, v, __) {
                    final isBufferingOrInit = !v.isInitialized || v.isBuffering;
                    if (isBufferingOrInit || _isReconnecting) {
                      return Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.72),
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.5),
                                blurRadius: 16,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.5,
                                  color: _isReconnecting ? const Color(0xFF64B5F6) : Colors.white70,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Text(
                                _isReconnecting
                                    ? 'Reconnecting stream ($_streamRetryCount/$_maxStreamRetries)...'
                                    : 'Buffering stream...',
                                style: TextStyle(
                                  color: _isReconnecting ? const Color(0xFF90CAF9) : Colors.white.withValues(alpha: 0.9),
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: 0.2,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }
                    return const SizedBox.shrink();
                  },
                ),
              if (failed && !showControls)
                Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.82),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.6),
                          blurRadius: 24,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.signal_wifi_bad_rounded, color: Color(0xFFEF5350), size: 44),
                      const SizedBox(height: 12),
                      const Text(
                        'This channel isn’t available right now',
                        style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 8),
                      if (_autoRecoveryTimer?.isActive == true && _recoveryAttempts <= 30) ...[
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF64B5F6)),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'Auto-reconnecting in background (Attempt $_recoveryAttempts)...',
                              style: const TextStyle(color: Color(0xFF90CAF9), fontSize: 13, fontWeight: FontWeight.w500),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                      ],
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('OK: Retry Now  ·  ',
                              style: TextStyle(color: Colors.white.withValues(alpha: 0.85), fontSize: 13, fontWeight: FontWeight.w600)),
                          Text('Menu: Controls  ·  ',
                              style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 13)),
                          Icon(Icons.unfold_more_rounded, size: 14, color: Colors.white.withValues(alpha: 0.6)),
                          const SizedBox(width: 2),
                          Text('Zap  ·  ', style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 13)),
                          Icon(Icons.arrow_back_rounded, size: 13, color: Colors.white.withValues(alpha: 0.6)),
                          const SizedBox(width: 2),
                          Text('Channels', style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 13)),
                        ],
                      ),
                    ]),
                  ),
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
                  height: 380,
                  child: TimelineGuide(
                    allChannels: allChannels,
                    currentChannel: channel,
                    initialCategory: widget.initialCategory,
                    onTune: _tuneToChannel,
                    onClose: _closeTimelineGuide,
                    onUserActivity: _resetTimelineGuideTimer,
                  ),
                ),

              // Reminder Alert Banner (when a scheduled program reminder is due)
              if (_activeReminderAlert != null)
                Positioned(
                  top: 24,
                  right: 28,
                  child: _buildReminderToast(_activeReminderAlert!),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildReminderToast(ProgramReminder r) {
    return Container(
      width: 360,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xF00F172A),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFF59E0B), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFF59E0B).withValues(alpha: 0.35),
            blurRadius: 18,
            spreadRadius: 1,
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.8),
            blurRadius: 12,
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: const BoxDecoration(
              color: Color(0x33F59E0B),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.notifications_active_rounded, color: Color(0xFFFBBF24), size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    const Text(
                      'PROGRAM REMINDER',
                      style: TextStyle(
                        color: Color(0xFFFBBF24),
                        fontSize: 9.5,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.8,
                      ),
                    ),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(
                        color: const Color(0x22FFFFFF),
                        borderRadius: BorderRadius.circular(3),
                      ),
                      child: const Text(
                        'OK: Tune',
                        style: TextStyle(color: Colors.white, fontSize: 9.5, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  r.programTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700),
                ),
                Text(
                  'Starting now on ${r.channelName}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 11),
                ),
              ],
            ),
          ),
        ],
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

            // Center Controls: Recall Button (if available) + Play / Pause Hero Button + Screen Fit + Audio Track
            Builder(
              builder: (context) {
                final prev = _previousChannel;
                return Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (prev != null) ...[
                      _buildRecallButton(prev),
                      const SizedBox(width: 32),
                    ],
                    _buildPlayPauseButton(isPlaying, c),
                    const SizedBox(width: 32),
                    _buildTimelineGuideButton(),
                    const SizedBox(width: 32),
                    _buildScreenFitButton(),
                    if (_audioTracks.isNotEmpty) ...[
                      const SizedBox(width: 32),
                      _buildAudioTrackButton(),
                    ],
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
                        ? 'OK: Select  ·  Left/Right: Switch  ·  Up: Quality  ·  Back: Close'
                        : 'OK: ${isPlaying ? 'Pause' : 'Play'}  ·  Up: Quality  ·  Left: Guide  ·  Back: Close',
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

  Widget _buildTimelineGuideButton() {
    final isFocused = _controlSection == ControlSection.epgGuide;
    return GestureDetector(
      onTap: () {
        _openTimelineGuide();
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
              color: isFocused ? const Color(0xFF6366F1) : const Color(0x33FFFFFF),
              boxShadow: isFocused
                  ? [
                      BoxShadow(
                        color: const Color(0xFF6366F1).withValues(alpha: 0.8),
                        blurRadius: 20,
                        spreadRadius: 2,
                      ),
                    ]
                  : [],
              border: Border.all(
                color: isFocused ? Colors.white : const Color(0x66FFFFFF),
                width: 2,
              ),
            ),
            child: const Icon(
              Icons.view_timeline_rounded,
              size: 38,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 10),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 140),
            child: Text(
              'TV GUIDE',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: isFocused ? Colors.white : Colors.white70,
                fontSize: 12,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.2,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildScreenFitButton() {
    final isFocused = _controlSection == ControlSection.screenFit;
    final mode = PlayerSettingsProvider.instance.screenFit;
    return GestureDetector(
      onTap: () {
        _toggleScreenFit();
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
              color: isFocused ? const Color(0xFF38BDF8) : const Color(0x33FFFFFF),
              boxShadow: isFocused
                  ? [
                      BoxShadow(
                        color: const Color(0xFF38BDF8).withValues(alpha: 0.8),
                        blurRadius: 20,
                        spreadRadius: 2,
                      ),
                    ]
                  : [],
              border: Border.all(
                color: isFocused ? Colors.white : const Color(0x66FFFFFF),
                width: 2,
              ),
            ),
            child: Icon(
              Icons.aspect_ratio_rounded,
              size: 38,
              color: isFocused ? Colors.black : Colors.white,
            ),
          ),
          const SizedBox(height: 10),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 140),
            child: Text(
              'FIT: ${mode.label.toUpperCase()}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: isFocused ? const Color(0xFF38BDF8) : Colors.white70,
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

  Widget _buildAudioTrackButton() {
    final isFocused = _controlSection == ControlSection.audioTrack;
    final currentTrack = _selectedAudioTrack;
    final label = currentTrack != null ? currentTrack.displayName : 'Audio';

    return GestureDetector(
      onTap: () {
        _openAudioTrackDialog();
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
              color: isFocused ? const Color(0xFFF59E0B) : const Color(0x33FFFFFF),
              boxShadow: isFocused
                  ? [
                      BoxShadow(
                        color: const Color(0xFFF59E0B).withValues(alpha: 0.8),
                        blurRadius: 20,
                        spreadRadius: 2,
                      ),
                    ]
                  : [],
              border: Border.all(
                color: isFocused ? Colors.white : const Color(0x66FFFFFF),
                width: 2,
              ),
            ),
            child: Icon(
              Icons.audiotrack_rounded,
              size: 38,
              color: isFocused ? Colors.black : Colors.white,
            ),
          ),
          const SizedBox(height: 10),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 140),
            child: Text(
              'AUDIO: ${label.toUpperCase()}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: isFocused ? const Color(0xFFF59E0B) : Colors.white70,
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
                    if (_audioTracks.isNotEmpty) ...[
                      const SizedBox(width: 6),
                      // Multi-Audio Pill
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0x18F59E0B),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: const Color(0x55F59E0B), width: 0.8),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.volume_up_rounded, size: 10, color: Color(0xFFF59E0B)),
                            const SizedBox(width: 3),
                            Text(
                              (_selectedAudioTrack?.displayName ?? 'AUDIO').toUpperCase(),
                              style: const TextStyle(
                                color: Color(0xFFF59E0B),
                                fontSize: 10.5,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            if (_audioTracks.length > 1) ...[
                              const SizedBox(width: 3),
                              Text(
                                '(${_audioTracks.length})',
                                style: const TextStyle(
                                  color: Color(0xFFF59E0B),
                                  fontSize: 9.5,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
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
                      _buildInfoBarRemoteHints(),
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
                      _buildInfoBarRemoteHints(),
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

  Widget _buildInfoBarRemoteHints() {
    const hintStyle = TextStyle(
      color: Color(0xFF64748B),
      fontSize: 11,
      fontWeight: FontWeight.w500,
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_audioTracks.length > 1) ...[
          const Icon(Icons.audiotrack_rounded, size: 12, color: Color(0xFFF59E0B)),
          const SizedBox(width: 2),
          const Text('Multi-Audio', style: TextStyle(color: Color(0xFFF59E0B), fontSize: 11, fontWeight: FontWeight.w600)),
          const SizedBox(width: 8),
        ],
        const Text('OK: Guide', style: hintStyle),
        const SizedBox(width: 8),
        const Text('Back: Hide', style: hintStyle),
        const SizedBox(width: 8),
        const Icon(Icons.arrow_back_rounded, size: 12, color: Color(0xFF64748B)),
        const SizedBox(width: 2),
        const Text('Channels', style: hintStyle),
        const SizedBox(width: 8),
        const Icon(Icons.unfold_more_rounded, size: 13, color: Color(0xFF64748B)),
        const SizedBox(width: 2),
        const Text('Zap', style: hintStyle),
        const SizedBox(width: 8),
        const Text('Menu: ', style: hintStyle),
        const Icon(Icons.star_rounded, size: 13, color: Color(0xFFFFD700)),
        const SizedBox(width: 2),
        const Text('Fav', style: hintStyle),
      ],
    );
  }
}


