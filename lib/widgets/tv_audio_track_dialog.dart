import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../screens/home.dart' show isSelectKey;
import '../services/audio_track_service.dart';

/// Full TV-remote (Circular D-pad) navigable Audio Track Selection Modal.
class TvAudioTrackDialog extends StatefulWidget {
  final List<AudioTrack> tracks;
  final AudioTrack? selectedTrack;
  final ValueChanged<AudioTrack> onTrackSelected;

  const TvAudioTrackDialog({
    super.key,
    required this.tracks,
    required this.selectedTrack,
    required this.onTrackSelected,
  });

  @override
  State<TvAudioTrackDialog> createState() => _TvAudioTrackDialogState();
}

class _TvAudioTrackDialogState extends State<TvAudioTrackDialog> {
  late int _focusedIndex;
  final FocusNode _focusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    // Default focus to currently playing track, or 0
    final curIdx = widget.tracks.indexWhere(
      (t) =>
          widget.selectedTrack != null &&
          t.groupIndex == widget.selectedTrack!.groupIndex &&
          t.trackIndex == widget.selectedTrack!.trackIndex,
    );
    _focusedIndex = curIdx >= 0 ? curIdx : 0;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToFocused() {
    if (!_scrollController.hasClients) return;
    const itemHeight = 64.0;
    final targetOffset = (_focusedIndex * itemHeight) - 80;
    _scrollController.animateTo(
      targetOffset.clamp(0.0, _scrollController.position.maxScrollExtent),
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
    );
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final k = event.logicalKey;

    if (k == LogicalKeyboardKey.arrowUp) {
      if (_focusedIndex > 0) {
        setState(() => _focusedIndex--);
        _scrollToFocused();
      }
      return KeyEventResult.handled;
    }

    if (k == LogicalKeyboardKey.arrowDown) {
      if (_focusedIndex < widget.tracks.length - 1) {
        setState(() => _focusedIndex++);
        _scrollToFocused();
      }
      return KeyEventResult.handled;
    }

    if (isSelectKey(k)) {
      if (_focusedIndex >= 0 && _focusedIndex < widget.tracks.length) {
        widget.onTrackSelected(widget.tracks[_focusedIndex]);
      }
      return KeyEventResult.handled;
    }

    if (k == LogicalKeyboardKey.escape ||
        k == LogicalKeyboardKey.goBack ||
        k == LogicalKeyboardKey.browserBack) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: Center(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
            child: Container(
              width: 440,
              constraints: const BoxConstraints(maxHeight: 460),
              decoration: BoxDecoration(
                color: const Color(0xFF14171E).withValues(alpha: 0.92),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.white.withValues(alpha: 0.12), width: 1.5),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.8),
                    blurRadius: 36,
                    spreadRadius: 8,
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Dialog Header
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.amber.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: Colors.amber.withValues(alpha: 0.3)),
                          ),
                          child: const Icon(Icons.audiotrack, color: Colors.amber, size: 20),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Audio Track / Language',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 0.3,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '${widget.tracks.length} audio feeds available',
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.55),
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, color: Colors.white54, size: 20),
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                      ],
                    ),
                  ),

                  const Divider(color: Colors.white12, height: 1),

                  // Tracks List
                  Flexible(
                    child: ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      shrinkWrap: true,
                      itemCount: widget.tracks.length,
                      itemBuilder: (context, i) {
                        final track = widget.tracks[i];
                        final isFocused = i == _focusedIndex;
                        final isSelected = widget.selectedTrack != null &&
                            track.groupIndex == widget.selectedTrack!.groupIndex &&
                            track.trackIndex == widget.selectedTrack!.trackIndex;

                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: GestureDetector(
                            onTap: () => widget.onTrackSelected(track),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 140),
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                              decoration: BoxDecoration(
                                color: isFocused
                                    ? Colors.amber.withValues(alpha: 0.2)
                                    : (isSelected
                                        ? Colors.white.withValues(alpha: 0.08)
                                        : Colors.white.withValues(alpha: 0.03)),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: isFocused
                                      ? Colors.amber
                                      : (isSelected
                                          ? Colors.amber.withValues(alpha: 0.4)
                                          : Colors.white.withValues(alpha: 0.06)),
                                  width: isFocused ? 2 : 1,
                                ),
                                boxShadow: isFocused
                                    ? [
                                        BoxShadow(
                                          color: Colors.amber.withValues(alpha: 0.3),
                                          blurRadius: 12,
                                          spreadRadius: 1,
                                        ),
                                      ]
                                    : null,
                              ),
                              child: Row(
                                children: [
                                  // Selected Radio / Check indicator
                                  Container(
                                    width: 22,
                                    height: 22,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: isSelected
                                            ? Colors.amber
                                            : Colors.white.withValues(alpha: 0.3),
                                        width: 2,
                                      ),
                                      color: isSelected
                                          ? Colors.amber.withValues(alpha: 0.2)
                                          : Colors.transparent,
                                    ),
                                    child: isSelected
                                        ? const Center(
                                            child: Icon(Icons.check, size: 14, color: Colors.amber),
                                          )
                                        : null,
                                  ),
                                  const SizedBox(width: 14),

                                  // Track Info
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          track.displayName,
                                          style: TextStyle(
                                            color: isFocused ? Colors.amber : Colors.white,
                                            fontSize: 15,
                                            fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                                          ),
                                        ),
                                        if (track.language.isNotEmpty || track.channelCount > 0)
                                          Padding(
                                            padding: const EdgeInsets.only(top: 2),
                                            child: Text(
                                              [
                                                if (track.language.isNotEmpty)
                                                  track.language.toUpperCase(),
                                                if (track.channelCount > 0)
                                                  track.channelCount == 6
                                                      ? '5.1 Surround'
                                                      : (track.channelCount == 2 ? 'Stereo' : 'Mono'),
                                                if (track.sampleRate > 0)
                                                  '${(track.sampleRate / 1000).toStringAsFixed(1)} kHz',
                                              ].join(' · '),
                                              style: TextStyle(
                                                color: Colors.white.withValues(alpha: 0.45),
                                                fontSize: 11,
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),

                                  // Active Tag
                                  if (isSelected)
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                      decoration: BoxDecoration(
                                        color: Colors.amber.withValues(alpha: 0.2),
                                        borderRadius: BorderRadius.circular(6),
                                        border: Border.all(color: Colors.amber.withValues(alpha: 0.4)),
                                      ),
                                      child: const Text(
                                        'ACTIVE',
                                        style: TextStyle(
                                          color: Colors.amber,
                                          fontSize: 10,
                                          fontWeight: FontWeight.bold,
                                          letterSpacing: 0.5,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),

                  // Footer with TV Remote navigation hints
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.4),
                      borderRadius: const BorderRadius.vertical(bottom: Radius.circular(20)),
                      border: const Border(top: BorderSide(color: Colors.white10)),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _buildKeyHint('▲ / ▼', 'Select Track'),
                        const SizedBox(width: 16),
                        _buildKeyHint('OK', 'Switch Audio'),
                        const SizedBox(width: 16),
                        _buildKeyHint('Back', 'Close'),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildKeyHint(String key, String action) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: Colors.white24, width: 0.8),
          ),
          child: Text(
            key,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 10,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        const SizedBox(width: 5),
        Text(
          action,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.5),
            fontSize: 11,
          ),
        ),
      ],
    );
  }
}
