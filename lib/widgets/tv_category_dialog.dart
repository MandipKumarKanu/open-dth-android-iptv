import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../screens/home.dart' show isSelectKey;

/// TV-friendly Category & Genre selection modal dialog navigable with circular D-pad.
class TvCategoryPickerDialog extends StatefulWidget {
  final List<String> categories;
  final Map<String, int> categoryCounts;
  final String selectedCategory;
  final ValueChanged<String> onCategorySelected;

  const TvCategoryPickerDialog({
    super.key,
    required this.categories,
    required this.categoryCounts,
    required this.selectedCategory,
    required this.onCategorySelected,
  });

  static Future<void> show({
    required BuildContext context,
    required List<String> categories,
    required Map<String, int> categoryCounts,
    required String selectedCategory,
    required ValueChanged<String> onCategorySelected,
  }) {
    return showDialog(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.78),
      builder: (_) => TvCategoryPickerDialog(
        categories: categories,
        categoryCounts: categoryCounts,
        selectedCategory: selectedCategory,
        onCategorySelected: (cat) {
          Navigator.of(context).pop();
          onCategorySelected(cat);
        },
      ),
    );
  }

  @override
  State<TvCategoryPickerDialog> createState() => _TvCategoryPickerDialogState();
}

class _TvCategoryPickerDialogState extends State<TvCategoryPickerDialog> {
  late int _focusedIndex;
  final FocusNode _focusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();

  static const double _itemHeight = 54.0;

  @override
  void initState() {
    super.initState();
    final curIdx = widget.categories.indexOf(widget.selectedCategory);
    _focusedIndex = curIdx >= 0 ? curIdx : 0;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _focusNode.requestFocus();
        _scrollToFocused(animate: false);
      }
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToFocused({bool animate = true}) {
    if (!_scrollController.hasClients) return;
    final targetOffset = (_focusedIndex * _itemHeight) - 100.0;
    final clamped = targetOffset.clamp(0.0, _scrollController.position.maxScrollExtent);
    if (animate) {
      _scrollController.animateTo(
        clamped,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
      );
    } else {
      _scrollController.jumpTo(clamped);
    }
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
      if (_focusedIndex < widget.categories.length - 1) {
        setState(() => _focusedIndex++);
        _scrollToFocused();
      }
      return KeyEventResult.handled;
    }

    if (k == LogicalKeyboardKey.pageUp || k == LogicalKeyboardKey.channelUp) {
      if (_focusedIndex > 0) {
        setState(() => _focusedIndex = (_focusedIndex - 5).clamp(0, widget.categories.length - 1));
        _scrollToFocused();
      }
      return KeyEventResult.handled;
    }

    if (k == LogicalKeyboardKey.pageDown || k == LogicalKeyboardKey.channelDown) {
      if (_focusedIndex < widget.categories.length - 1) {
        setState(() => _focusedIndex = (_focusedIndex + 5).clamp(0, widget.categories.length - 1));
        _scrollToFocused();
      }
      return KeyEventResult.handled;
    }

    if (isSelectKey(k)) {
      if (_focusedIndex >= 0 && _focusedIndex < widget.categories.length) {
        widget.onCategorySelected(widget.categories[_focusedIndex]);
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

  IconData _getCategoryIcon(String cat) {
    final lower = cat.toLowerCase();
    if (lower == 'all') return Icons.tv_rounded;
    if (lower.contains('news')) return Icons.newspaper_rounded;
    if (lower.contains('movie') || lower.contains('cinema')) return Icons.movie_filter_rounded;
    if (lower.contains('sport')) return Icons.sports_soccer_rounded;
    if (lower.contains('music')) return Icons.music_note_rounded;
    if (lower.contains('kid') || lower.contains('cartoon') || lower.contains('anime')) {
      return Icons.child_care_rounded;
    }
    if (lower.contains('knowledge') || lower.contains('doc') || lower.contains('info') || lower.contains('science')) {
      return Icons.travel_explore_rounded;
    }
    if (lower.contains('entertain') || lower.contains('general') || lower.contains('comedy')) {
      return Icons.theater_comedy_rounded;
    }
    if (lower.contains('lifestyle') || lower.contains('fashion') || lower.contains('food')) {
      return Icons.style_rounded;
    }
    if (lower.contains('devotion') || lower.contains('spirit') || lower.contains('relig')) {
      return Icons.self_improvement_rounded;
    }
    return Icons.grid_view_rounded;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: Center(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
            child: Container(
              width: 460,
              constraints: const BoxConstraints(maxHeight: 520),
              decoration: BoxDecoration(
                color: const Color(0xF20B132B),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: const Color(0xFF38BDF8).withValues(alpha: 0.35),
                  width: 1.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.85),
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
                    padding: const EdgeInsets.fromLTRB(22, 18, 22, 14),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(9),
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              colors: [Color(0xFF0F766E), Color(0xFF0284C7)],
                            ),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: const Color(0xFF38BDF8).withValues(alpha: 0.4)),
                          ),
                          child: const Icon(Icons.category_rounded, color: Colors.white, size: 20),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Select Category',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 0.3,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '${widget.categories.length} categories available',
                                style: const TextStyle(
                                  color: Color(0xFF94A3B8),
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

                  const Divider(color: Color(0x22FFFFFF), height: 1),

                  // Categories List
                  Flexible(
                    child: ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      shrinkWrap: true,
                      itemCount: widget.categories.length,
                      itemBuilder: (context, i) {
                        final cat = widget.categories[i];
                        final isFocused = i == _focusedIndex;
                        final isSelected = cat == widget.selectedCategory;
                        final count = widget.categoryCounts[cat] ?? 0;

                        return Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: GestureDetector(
                            onTap: () => widget.onCategorySelected(cat),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 140),
                              height: _itemHeight,
                              padding: const EdgeInsets.symmetric(horizontal: 14),
                              decoration: BoxDecoration(
                                color: isFocused
                                    ? const Color(0xFF0284C7)
                                    : (isSelected
                                        ? const Color(0x330F766E)
                                        : Colors.white.withValues(alpha: 0.03)),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: isFocused
                                      ? const Color(0xFF38BDF8)
                                      : (isSelected
                                          ? const Color(0xFF2DD4BF)
                                          : Colors.white.withValues(alpha: 0.07)),
                                  width: isFocused ? 2 : 1,
                                ),
                                boxShadow: isFocused
                                    ? [
                                        BoxShadow(
                                          color: const Color(0xFF38BDF8).withValues(alpha: 0.45),
                                          blurRadius: 10,
                                          spreadRadius: 1,
                                        ),
                                      ]
                                    : null,
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    _getCategoryIcon(cat),
                                    size: 19,
                                    color: isFocused
                                        ? Colors.white
                                        : (isSelected ? const Color(0xFF2DD4BF) : const Color(0xFF94A3B8)),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      cat,
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 14,
                                        fontWeight: isFocused || isSelected ? FontWeight.w700 : FontWeight.w500,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  if (count > 0)
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: isFocused
                                            ? Colors.black.withValues(alpha: 0.25)
                                            : Colors.white.withValues(alpha: 0.07),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Text(
                                        '$count',
                                        style: TextStyle(
                                          color: isFocused ? Colors.white : const Color(0xFF94A3B8),
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                  const SizedBox(width: 8),
                                  if (isSelected)
                                    const Icon(
                                      Icons.check_circle_rounded,
                                      size: 18,
                                      color: Color(0xFF2DD4BF),
                                    )
                                  else if (isFocused)
                                    const Icon(
                                      Icons.arrow_forward_ios_rounded,
                                      size: 12,
                                      color: Colors.white70,
                                    ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),

                  const Divider(color: Color(0x22FFFFFF), height: 1),

                  // Bottom D-Pad Hints Bar
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                    color: Colors.black.withValues(alpha: 0.3),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.unfold_more_rounded, size: 14, color: Color(0xFF94A3B8)),
                            SizedBox(width: 4),
                            Text(
                              'Up/Down: Navigate',
                              style: TextStyle(color: Color(0xFF94A3B8), fontSize: 11, fontWeight: FontWeight.w600),
                            ),
                          ],
                        ),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.check_circle_outline_rounded, size: 14, color: Color(0xFF94A3B8)),
                            SizedBox(width: 4),
                            Text(
                              'OK: Select',
                              style: TextStyle(color: Color(0xFF94A3B8), fontSize: 11, fontWeight: FontWeight.w600),
                            ),
                          ],
                        ),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.keyboard_return_rounded, size: 14, color: Color(0xFF94A3B8)),
                            SizedBox(width: 4),
                            Text(
                              'Back: Cancel',
                              style: TextStyle(color: Color(0xFF94A3B8), fontSize: 11, fontWeight: FontWeight.w600),
                            ),
                          ],
                        ),
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
}
