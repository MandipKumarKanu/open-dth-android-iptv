import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../model/channel.dart';
import '../model/program.dart';
import '../provider/reminder_provider.dart';
import '../screens/home.dart' show isSelectKey;
import 'channel_icon.dart';

/// TV-optimized modal dialog displaying full program synopsis, episode, genre,
/// duration, cast highlights, and D-pad navigable actions (Tune Channel / Add Reminder).
class TvProgramDetailsDialog extends StatefulWidget {
  final Channel channel;
  final Program? program;
  final int? channelNumber;
  final VoidCallback onTuneChannel;

  const TvProgramDetailsDialog({
    super.key,
    required this.channel,
    required this.program,
    required this.onTuneChannel,
    this.channelNumber,
  });

  static Future<void> show({
    required BuildContext context,
    required Channel channel,
    required Program? program,
    required VoidCallback onTuneChannel,
    int? channelNumber,
  }) {
    return showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.85),
      builder: (_) => TvProgramDetailsDialog(
        channel: channel,
        program: program,
        channelNumber: channelNumber,
        onTuneChannel: onTuneChannel,
      ),
    );
  }

  @override
  State<TvProgramDetailsDialog> createState() => _TvProgramDetailsDialogState();
}

class _TvProgramDetailsDialogState extends State<TvProgramDetailsDialog> {
  final FocusNode _focusNode = FocusNode();
  final ScrollController _synopsisScrollController = ScrollController();

  int _focusedButtonIdx = 0; // 0 = Tune/Watch, 1 = Reminder, 2 = Close
  bool _isReminderSet = false;
  String? _statusMessage;

  @override
  void initState() {
    super.initState();
    _checkReminderStatus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _synopsisScrollController.dispose();
    super.dispose();
  }

  void _checkReminderStatus() {
    final p = widget.program;
    if (p != null) {
      _isReminderSet = ReminderProvider.instance.isReminderSet(widget.channel.idKey, p);
    }
  }

  Future<void> _toggleReminder() async {
    final p = widget.program;
    if (p == null) return;

    final added = await ReminderProvider.instance.toggleReminder(
      channel: widget.channel,
      program: p,
    );

    if (!mounted) return;
    setState(() {
      _isReminderSet = added;
      _statusMessage = added
          ? 'Reminder set! We will notify you before the show starts.'
          : 'Reminder removed.';
    });
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;

    if (k == LogicalKeyboardKey.arrowLeft) {
      if (_focusedButtonIdx > 0) {
        setState(() => _focusedButtonIdx--);
      }
      return KeyEventResult.handled;
    }

    if (k == LogicalKeyboardKey.arrowRight) {
      if (_focusedButtonIdx < 2) {
        setState(() => _focusedButtonIdx++);
      }
      return KeyEventResult.handled;
    }

    if (k == LogicalKeyboardKey.arrowUp) {
      if (_synopsisScrollController.hasClients) {
        _synopsisScrollController.animateTo(
          max(0.0, _synopsisScrollController.offset - 60),
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
        );
      }
      return KeyEventResult.handled;
    }

    if (k == LogicalKeyboardKey.arrowDown) {
      if (_synopsisScrollController.hasClients) {
        _synopsisScrollController.animateTo(
          _synopsisScrollController.offset + 60,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
        );
      }
      return KeyEventResult.handled;
    }

    if (isSelectKey(k)) {
      _triggerFocusedButton();
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

  void _triggerFocusedButton() {
    switch (_focusedButtonIdx) {
      case 0:
        Navigator.of(context).pop();
        widget.onTuneChannel();
        break;
      case 1:
        if (widget.program != null) {
          _toggleReminder();
        }
        break;
      case 2:
        Navigator.of(context).pop();
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.program;
    final ch = widget.channel;
    final isLive = p?.isLive ?? true;

    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Center(
        child: Material(
          color: Colors.transparent,
          child: Container(
            width: 680,
            constraints: const BoxConstraints(maxHeight: 520),
            margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0xFF0F172A),
                  Color(0xFF090E17),
                  Color(0xFF030712),
                ],
              ),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: const Color(0x6638BDF8),
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.cyanAccent.withValues(alpha: 0.18),
                  blurRadius: 36,
                  spreadRadius: 2,
                ),
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.9),
                  blurRadius: 28,
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 1. Channel Header Bar
                _buildChannelHeader(ch, p, isLive),

                // 2. Program Title & Badges
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 20, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        p?.title ?? 'Live Broadcast on ${ch.name}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.2,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 10),
                      _buildMetadataChips(ch, p),
                    ],
                  ),
                ),

                // 3. Live Progress Bar (if live)
                if (p != null && isLive)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(
                            value: p.progress,
                            minHeight: 4,
                            backgroundColor: const Color(0x3338BDF8),
                            valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF38BDF8)),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              '${(p.progress * 100).toInt()}% Elapsed',
                              style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 11, fontWeight: FontWeight.w600),
                            ),
                            Text(
                              p.remainingText,
                              style: const TextStyle(color: Color(0xFF38BDF8), fontSize: 11, fontWeight: FontWeight.w700),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),

                // 4. Synopsis / Story Summary (Scrollable)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 10),
                    child: Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0x28000000),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0x18FFFFFF), width: 1),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.description_outlined, size: 14, color: Color(0xFF38BDF8)),
                              const SizedBox(width: 6),
                              const Text(
                                'SYNOPSIS & DETAILS',
                                style: TextStyle(
                                  color: Color(0xFF94A3B8),
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 1.1,
                                ),
                              ),
                              const Spacer(),
                              if (p?.castHighlight != null)
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: const Color(0x2506B6D4),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: const Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.person_rounded, size: 11, color: Color(0xFF22D3EE)),
                                      SizedBox(width: 4),
                                      Text(
                                        'Featured Cast',
                                        style: TextStyle(color: Color(0xFF22D3EE), fontSize: 9.5, fontWeight: FontWeight.w700),
                                      ),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Expanded(
                            child: SingleChildScrollView(
                              controller: _synopsisScrollController,
                              child: Text(
                                p?.synopsis ?? 'Live broadcast. Tune into ${ch.name} to watch current program.',
                                style: const TextStyle(
                                  color: Color(0xFFE2E8F0),
                                  fontSize: 13.5,
                                  height: 1.45,
                                  fontWeight: FontWeight.w400,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

                // 5. Status Toast Banner (e.g. reminder added)
                if (_statusMessage != null)
                  Container(
                    margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(0x3310B981),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: const Color(0x6610B981), width: 1),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.check_circle_rounded, color: Color(0xFF34D399), size: 14),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _statusMessage!,
                            style: const TextStyle(color: Color(0xFFECFDF5), fontSize: 11.5, fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                    ),
                  ),

                // 6. Action Buttons Bar
                _buildActionButtons(isLive),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildChannelHeader(Channel ch, Program? p, bool isLive) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: const BoxDecoration(
        color: Color(0x401E293B),
        borderRadius: BorderRadius.vertical(top: Radius.circular(15)),
        border: Border(bottom: BorderSide(color: Color(0x22FFFFFF), width: 1)),
      ),
      child: Row(
        children: [
          ChannelIcon(
            channel: ch,
            width: 44,
            height: 28,
          ),
          const SizedBox(width: 12),
          if (widget.channelNumber != null) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0x330284C7),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                '#${widget.channelNumber}',
                style: const TextStyle(color: Color(0xFF38BDF8), fontSize: 11, fontWeight: FontWeight.w800),
              ),
            ),
            const SizedBox(width: 8),
          ],
          Text(
            ch.name,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14.5,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 8),
          if (ch.resolution.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B),
                borderRadius: BorderRadius.circular(3),
                border: Border.all(color: const Color(0x44FFFFFF), width: 1),
              ),
              child: Text(
                ch.resolution,
                style: const TextStyle(color: Colors.white70, fontSize: 10, fontWeight: FontWeight.w700),
              ),
            ),
          const Spacer(),
          // Live or Upcoming Badge
          if (p != null)
            _buildStatusBadge(p, isLive)
          else
            _buildStaticLiveBadge(),
        ],
      ),
    );
  }

  Widget _buildStatusBadge(Program p, bool isLive) {
    if (isLive) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: const Color(0x28EF4444),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFEF4444), width: 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: const BoxDecoration(
                color: Color(0xFFEF4444),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 6),
            const Text(
              'LIVE NOW',
              style: TextStyle(
                color: Color(0xFFEF4444),
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.8,
              ),
            ),
          ],
        ),
      );
    } else {
      final isUpcoming = DateTime.now().isBefore(p.start);
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: isUpcoming ? const Color(0x280284C7) : const Color(0x2264748B),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isUpcoming ? const Color(0xFF38BDF8) : const Color(0xFF64748B),
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isUpcoming ? Icons.alarm_rounded : Icons.history_rounded,
              color: isUpcoming ? const Color(0xFF38BDF8) : const Color(0xFF94A3B8),
              size: 13,
            ),
            const SizedBox(width: 5),
            Text(
              isUpcoming ? p.remainingText : 'ENDED',
              style: TextStyle(
                color: isUpcoming ? const Color(0xFF38BDF8) : const Color(0xFF94A3B8),
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      );
    }
  }

  Widget _buildStaticLiveBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0x2810B981),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF10B981), width: 1),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.live_tv_rounded, color: Color(0xFF10B981), size: 13),
          SizedBox(width: 5),
          Text(
            'ON AIR',
            style: TextStyle(color: Color(0xFF10B981), fontSize: 11, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }

  Widget _buildMetadataChips(Channel ch, Program? p) {
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: [
        // Time Chip
        if (p != null)
          _ChipItem(
            icon: Icons.schedule_rounded,
            label: p.timeRangeText,
            color: const Color(0xFFFFD700),
          ),

        // Duration Chip
        if (p != null)
          _ChipItem(
            icon: Icons.timelapse_rounded,
            label: p.durationText,
            color: const Color(0xFF38BDF8),
          ),

        // Episode Info (if detected)
        if (p?.episodeInfo != null)
          _ChipItem(
            icon: Icons.video_collection_rounded,
            label: p!.episodeInfo!,
            color: const Color(0xFFA78BFA),
          ),

        // Category / Genre Chip
        if (ch.category.isNotEmpty)
          _ChipItem(
            icon: Icons.category_rounded,
            label: ch.category,
            color: const Color(0xFF2DD4BF),
          ),
      ],
    );
  }

  Widget _buildActionButtons(bool isLive) {
    final p = widget.program;
    final isUpcoming = p != null && DateTime.now().isBefore(p.start);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: const BoxDecoration(
        color: Color(0x400A0E17),
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(15)),
        border: Border(top: BorderSide(color: Color(0x18FFFFFF), width: 1)),
      ),
      child: Row(
        children: [
          // 1. Tune Channel Button
          Expanded(
            flex: 4,
            child: _TvActionButton(
              icon: Icons.play_arrow_rounded,
              label: isLive ? 'Watch Channel' : 'Tune Channel',
              isFocused: _focusedButtonIdx == 0,
              primaryColor: const Color(0xFF0284C7),
              onTap: () {
                setState(() => _focusedButtonIdx = 0);
                _triggerFocusedButton();
              },
            ),
          ),
          const SizedBox(width: 12),

          // 2. Add / Remove Reminder Button
          Expanded(
            flex: 4,
            child: _TvActionButton(
              icon: _isReminderSet ? Icons.notifications_active_rounded : Icons.notification_add_rounded,
              label: _isReminderSet ? 'Reminder Set' : 'Add to Reminder',
              isFocused: _focusedButtonIdx == 1,
              primaryColor: _isReminderSet ? const Color(0xFF059669) : const Color(0xFFD97706),
              enabled: isUpcoming,
              subtitle: !isUpcoming && isLive ? 'Live Now' : null,
              onTap: () {
                setState(() => _focusedButtonIdx = 1);
                _triggerFocusedButton();
              },
            ),
          ),
          const SizedBox(width: 12),

          // 3. Close Button
          Expanded(
            flex: 3,
            child: _TvActionButton(
              icon: Icons.close_rounded,
              label: 'Close',
              isFocused: _focusedButtonIdx == 2,
              primaryColor: const Color(0xFF475569),
              onTap: () {
                setState(() => _focusedButtonIdx = 2);
                _triggerFocusedButton();
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _ChipItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;

  const _ChipItem({
    required this.icon,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.35), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.95),
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _TvActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isFocused;
  final Color primaryColor;
  final VoidCallback onTap;
  final bool enabled;
  final String? subtitle;

  const _TvActionButton({
    required this.icon,
    required this.label,
    required this.isFocused,
    required this.primaryColor,
    required this.onTap,
    this.enabled = true,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveColor = enabled ? primaryColor : const Color(0xFF334155);

    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(8),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: isFocused ? effectiveColor : effectiveColor.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isFocused ? Colors.white : effectiveColor.withValues(alpha: 0.5),
            width: isFocused ? 2 : 1,
          ),
          boxShadow: isFocused
              ? [
                  BoxShadow(
                    color: effectiveColor.withValues(alpha: 0.55),
                    blurRadius: 12,
                    spreadRadius: 1,
                  ),
                ]
              : null,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 16,
              color: isFocused ? Colors.white : (enabled ? Colors.white : Colors.white38),
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isFocused ? Colors.white : (enabled ? Colors.white : Colors.white38),
                      fontSize: 12,
                      fontWeight: isFocused ? FontWeight.w800 : FontWeight.w600,
                    ),
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle!,
                      style: const TextStyle(color: Colors.white38, fontSize: 9),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
