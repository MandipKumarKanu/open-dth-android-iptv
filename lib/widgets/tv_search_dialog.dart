import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../model/channel.dart';
import '../screens/home.dart' show isSelectKey;
import '../services/voice_search_service.dart';
import 'channel_icon.dart';

class TvSearchDialog extends StatefulWidget {
  final List<Channel> allChannels;
  final ValueChanged<Channel> onChannelSelect;
  final bool autoStartVoice;

  const TvSearchDialog({
    super.key,
    required this.allChannels,
    required this.onChannelSelect,
    this.autoStartVoice = false,
  });

  @override
  State<TvSearchDialog> createState() => _TvSearchDialogState();
}

class _TvSearchDialogState extends State<TvSearchDialog> {
  String _query = '';
  final FocusNode _keyboardFocus = FocusNode();
  final FocusNode _gridFocus = FocusNode();
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _mobileSearchController = TextEditingController();

  int _kbRow = 0;
  int _kbCol = 0;
  int _focusedResultIdx = 0;
  bool _inResults = false;
  bool _isListening = false;
  String? _voiceHeardText;

  static const List<List<String>> _keys = [
    ['A', 'B', 'C', 'D', 'E', 'F'],
    ['G', 'H', 'I', 'J', 'K', 'L'],
    ['M', 'N', 'O', 'P', 'Q', 'R'],
    ['S', 'T', 'U', 'V', 'W', 'X'],
    ['Y', 'Z', '0', '1', '2', '3'],
    ['4', '5', '6', '7', '8', '9'],
    ['MIC', 'SPACE', 'DEL', 'CLEAR', 'CLOSE'],
  ];

  @override
  void initState() {
    super.initState();
    if (widget.autoStartVoice) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _triggerVoiceSearch();
      });
    }
  }

  Future<void> _triggerVoiceSearch() async {
    if (_isListening) return;
    setState(() {
      _isListening = true;
      _voiceHeardText = null;
    });

    final text = await VoiceSearchService.startListening();
    if (!mounted) return;

    setState(() {
      _isListening = false;
      if (text != null && text.trim().isNotEmpty) {
        _query = text.trim().toUpperCase();
        _mobileSearchController.value = TextEditingValue(
          text: _query,
          selection: TextSelection.collapsed(offset: _query.length),
        );
        _voiceHeardText = text.trim();
        final results = _filteredChannels;
        if (results.isNotEmpty) {
          _inResults = true;
          _focusedResultIdx = 0;
          _gridFocus.requestFocus();
        } else {
          _inResults = false;
          _keyboardFocus.requestFocus();
        }
      }
    });
  }

  List<Channel> get _filteredChannels {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return const [];
    return widget.allChannels.where((c) {
      return c.name.toLowerCase().contains(q) ||
          c.category.toLowerCase().contains(q) ||
          c.tvgId.toLowerCase().contains(q);
    }).toList();
  }

  void _onKeyPress(String key) {
    if (key == 'MIC') {
      _triggerVoiceSearch();
    } else if (key == 'SPACE') {
      setState(() => _query += ' ');
    } else if (key == 'DEL') {
      if (_query.isNotEmpty) {
        setState(() => _query = _query.substring(0, _query.length - 1));
      }
    } else if (key == 'CLEAR') {
      setState(() {
        _query = '';
        _voiceHeardText = null;
      });
    } else if (key == 'CLOSE') {
      Navigator.of(context).pop();
    } else {
      setState(() => _query += key);
    }
  }

  KeyEventResult _handleKey(FocusNode _, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;

    // Voice Remote Mic Key / Assistant Key
    if (k.keyId == 0x002000000e7 || // KEYCODE_VOICE_ASSIST
        k.keyId == 0x00200000054 || // KEYCODE_SEARCH
        k.keyId == 0x002000000db || // KEYCODE_ASSIST
        k == LogicalKeyboardKey.f5) {
      _triggerVoiceSearch();
      return KeyEventResult.handled;
    }

    // Physical typing support (voice remotes, USB keyboards, ADB)
    final char = e.character;
    if (char != null && char.isNotEmpty && char.codeUnitAt(0) >= 32 && char.codeUnitAt(0) <= 126) {
      setState(() => _query += char.toUpperCase());
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.backspace) {
      if (_query.isNotEmpty) {
        setState(() => _query = _query.substring(0, _query.length - 1));
      }
      return KeyEventResult.handled;
    }

    // Back key
    if (k == LogicalKeyboardKey.escape || k == LogicalKeyboardKey.goBack) {
      if (_inResults) {
        setState(() => _inResults = false);
        _keyboardFocus.requestFocus();
        return KeyEventResult.handled;
      }
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }

    if (_inResults) {
      final results = _filteredChannels;
      if (results.isEmpty) {
        setState(() => _inResults = false);
        _keyboardFocus.requestFocus();
        return KeyEventResult.handled;
      }

      const cols = 3;
      if (k == LogicalKeyboardKey.arrowUp) {
        if (_focusedResultIdx >= cols) {
          setState(() => _focusedResultIdx -= cols);
          _scrollToFocused();
        }
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.arrowDown) {
        if (_focusedResultIdx + cols < results.length) {
          setState(() => _focusedResultIdx += cols);
          _scrollToFocused();
        }
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.arrowLeft) {
        if (_focusedResultIdx % cols > 0) {
          setState(() => _focusedResultIdx--);
        } else {
          setState(() => _inResults = false);
          _keyboardFocus.requestFocus();
        }
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.arrowRight) {
        if (_focusedResultIdx < results.length - 1 && (_focusedResultIdx % cols < cols - 1)) {
          setState(() => _focusedResultIdx++);
        }
        return KeyEventResult.handled;
      }
      if (isSelectKey(k)) {
        if (_focusedResultIdx < results.length) {
          final ch = results[_focusedResultIdx];
          Navigator.of(context).pop();
          widget.onChannelSelect(ch);
        }
        return KeyEventResult.handled;
      }
      return KeyEventResult.handled;
    }

    // Navigating inside the virtual keyboard
    final curRow = _keys[_kbRow];
    if (k == LogicalKeyboardKey.arrowUp) {
      if (_kbRow > 0) {
        setState(() {
          _kbRow--;
          _kbCol = _kbCol.clamp(0, _keys[_kbRow].length - 1);
        });
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowDown) {
      if (_kbRow < _keys.length - 1) {
        setState(() {
          _kbRow++;
          _kbCol = _kbCol.clamp(0, _keys[_kbRow].length - 1);
        });
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowLeft) {
      if (_kbCol > 0) {
        setState(() => _kbCol--);
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowRight) {
      if (_kbCol < curRow.length - 1) {
        setState(() => _kbCol++);
      } else if (_filteredChannels.isNotEmpty) {
        // Shift focus to the results grid
        setState(() {
          _inResults = true;
          _focusedResultIdx = 0;
        });
        _gridFocus.requestFocus();
      }
      return KeyEventResult.handled;
    }
    if (isSelectKey(k)) {
      _onKeyPress(curRow[_kbCol]);
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  void _scrollToFocused() {
    const rowHeight = 72.0;
    const cols = 3;
    final row = _focusedResultIdx ~/ cols;
    final target = (row * rowHeight) - 80;
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        target.clamp(0.0, _scrollController.position.maxScrollExtent),
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  void dispose() {
    _keyboardFocus.dispose();
    _gridFocus.dispose();
    _scrollController.dispose();
    _mobileSearchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final results = _filteredChannels;
    final isMobile = MediaQuery.sizeOf(context).shortestSide < 600;

    return Focus(
      focusNode: _inResults ? _gridFocus : _keyboardFocus,
      autofocus: true,
      onKeyEvent: isMobile ? null : _handleKey,
      child: Scaffold(
        backgroundColor: const Color(0xFA090D16),
        body: SafeArea(
          child: isMobile
              ? _buildMobileSearchLayout(results)
              : Padding(
            padding: const EdgeInsets.fromLTRB(28, 20, 28, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Top Search Bar Display
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: const Color(0xFF2563EB),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(Icons.search_rounded, size: 20, color: Colors.white),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1E293B),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: _inResults ? const Color(0x33FFFFFF) : const Color(0xFF38BDF8),
                            width: 1.5,
                          ),
                        ),
                        child: Row(
                          children: [
                            Text(
                              _query.isEmpty ? 'Type to search channels...' : _query,
                              style: TextStyle(
                                color: _query.isEmpty ? Colors.white38 : Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 1.2,
                              ),
                            ),
                            if (!_inResults) ...[
                              const SizedBox(width: 2),
                              Container(width: 2, height: 18, color: const Color(0xFF38BDF8)),
                            ],
                            const Spacer(),
                            if (_query.isNotEmpty)
                              Text(
                                '${results.length} found',
                                style: const TextStyle(color: Color(0xFF38BDF8), fontSize: 13, fontWeight: FontWeight.w600),
                              ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    // Voice Search / Mic Action Button
                    GestureDetector(
                      onTap: _triggerVoiceSearch,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 160),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color: _isListening ? const Color(0xFFE11D48) : const Color(0xFF0F766E),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: _isListening ? const Color(0xFFFB7185) : const Color(0xFF2DD4BF),
                            width: 1.5,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: (_isListening ? const Color(0xFFE11D48) : const Color(0xFF0F766E)).withValues(alpha: 0.45),
                              blurRadius: 10,
                            ),
                          ],
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(_isListening ? Icons.mic : Icons.mic_rounded, size: 20, color: Colors.white),
                            const SizedBox(width: 8),
                            Text(
                              _isListening ? 'Listening...' : 'Voice Search',
                              style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _inResults ? Icons.arrow_back_rounded : Icons.arrow_forward_rounded,
                          size: 13,
                          color: Colors.white54,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          _inResults ? 'Keyboard · OK: Play' : 'Results · Back: Exit',
                          style: const TextStyle(color: Colors.white54, fontSize: 12),
                        ),
                      ],
                    ),
                  ],
                ),
                if (_voiceHeardText != null) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Icon(Icons.mic_rounded, size: 14, color: Color(0xFF2DD4BF)),
                      const SizedBox(width: 6),
                      Text(
                        'Heard: "$_voiceHeardText"',
                        style: const TextStyle(color: Color(0xFF2DD4BF), fontSize: 12.5, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 18),

                // Main Area: Virtual Keyboard on Left, Results on Right
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Keyboard Container
                      Container(
                        width: 320,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFF131C2E),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0x1AFFFFFF)),
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            for (var r = 0; r < _keys.length; r++)
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  for (var c = 0; c < _keys[r].length; c++) ...[
                                    _buildKeyTile(_keys[r][c], r, c),
                                    if (c < _keys[r].length - 1) const SizedBox(width: 6),
                                  ],
                                ],
                              ),
                          ],
                        ),
                      ),

                      const SizedBox(width: 20),

                      // Results Grid Container
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xFF131C2E),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: _inResults ? const Color(0xFF38BDF8).withValues(alpha: 0.5) : const Color(0x1AFFFFFF),
                            ),
                          ),
                          child: _query.isEmpty
                              ? const Center(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.search_rounded, size: 48, color: Colors.white24),
                                      SizedBox(height: 12),
                                      Text(
                                        'Use remote arrows to type\nor use microphone / phone keyboard',
                                        textAlign: TextAlign.center,
                                        style: TextStyle(color: Colors.white38, fontSize: 14),
                                      ),
                                    ],
                                  ),
                                )
                              : results.isEmpty
                                  ? const Center(
                                      child: Text(
                                        'No matching channels found',
                                        style: TextStyle(color: Colors.white38, fontSize: 15),
                                      ),
                                    )
                                  : GridView.builder(
                                      controller: _scrollController,
                                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                                        crossAxisCount: 3,
                                        mainAxisExtent: 72,
                                        crossAxisSpacing: 10,
                                        mainAxisSpacing: 10,
                                      ),
                                      itemCount: results.length,
                                      itemBuilder: (context, i) {
                                        final ch = results[i];
                                        final isFocused = _inResults && i == _focusedResultIdx;
                                        return AnimatedContainer(
                                          duration: const Duration(milliseconds: 120),
                                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                          decoration: BoxDecoration(
                                            color: isFocused ? Colors.white : const Color(0xFF1E293B),
                                            borderRadius: BorderRadius.circular(8),
                                            border: Border.all(
                                              color: isFocused ? Colors.white : const Color(0x22FFFFFF),
                                              width: isFocused ? 2 : 1,
                                            ),
                                            boxShadow: isFocused
                                                ? [
                                                    BoxShadow(
                                                      color: Colors.white.withValues(alpha: 0.4),
                                                      blurRadius: 10,
                                                    ),
                                                  ]
                                                : null,
                                          ),
                                          child: Row(
                                            children: [
                                              ChannelIcon(
                                                key: ValueKey(ch.logoUrl + ch.name),
                                                channel: ch,
                                                width: 48,
                                                height: 32,
                                              ),
                                              const SizedBox(width: 8),
                                              Expanded(
                                                child: Column(
                                                  crossAxisAlignment: CrossAxisAlignment.start,
                                                  mainAxisAlignment: MainAxisAlignment.center,
                                                  children: [
                                                    Text(
                                                      ch.name,
                                                      maxLines: 1,
                                                      overflow: TextOverflow.ellipsis,
                                                      style: TextStyle(
                                                        color: isFocused ? Colors.black : Colors.white,
                                                        fontSize: 12,
                                                        fontWeight: FontWeight.w700,
                                                      ),
                                                    ),
                                                    const SizedBox(height: 2),
                                                    Text(
                                                      '${ch.category} · ${ch.resolution}',
                                                      style: TextStyle(
                                                        color: isFocused ? Colors.black54 : Colors.white54,
                                                        fontSize: 10,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ],
                                          ),
                                        );
                                      },
                                    ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMobileSearchLayout(List<Channel> results) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.search_rounded, color: Color(0xFF38BDF8), size: 24),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'Search channels',
                  style: TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.w800),
                ),
              ),
              IconButton(
                tooltip: 'Voice search',
                onPressed: _triggerVoiceSearch,
                icon: Icon(
                  Icons.mic_rounded,
                  color: _isListening ? const Color(0xFFFB7185) : const Color(0xFF2DD4BF),
                ),
              ),
              IconButton(
                tooltip: 'Close search',
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close_rounded, color: Colors.white70),
              ),
            ],
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _mobileSearchController,
            autofocus: true,
            textInputAction: TextInputAction.search,
            onChanged: (value) => setState(() => _query = value),
            style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500),
            decoration: InputDecoration(
              hintText: 'Name, category or channel ID',
              hintStyle: const TextStyle(color: Colors.white38, fontSize: 14),
              prefixIcon: const Icon(Icons.search_rounded, color: Color(0xFF38BDF8)),
              suffixIcon: _query.isNotEmpty
                  ? IconButton(
                      tooltip: 'Clear search',
                      onPressed: () {
                        _mobileSearchController.clear();
                        setState(() => _query = '');
                      },
                      icon: const Icon(Icons.close_rounded, color: Colors.white54),
                    )
                  : null,
              filled: true,
              fillColor: const Color(0xFF151D2B),
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: Color(0x2238BDF8)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: Color(0x2238BDF8)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: Color(0xFF38BDF8), width: 1.5),
              ),
            ),
          ),
          const SizedBox(height: 14),
          if (_voiceHeardText != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                'Voice search: “$_voiceHeardText”',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Color(0xFF2DD4BF), fontSize: 12),
              ),
            ),
          Expanded(
            child: _query.trim().isEmpty
                ? const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.live_tv_rounded, color: Colors.white24, size: 44),
                        SizedBox(height: 10),
                        Text(
                          'Search for your favourite channel',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white54, fontSize: 14),
                        ),
                      ],
                    ),
                  )
                : results.isEmpty
                    ? const Center(
                        child: Text(
                          'No matching channels found',
                          style: TextStyle(color: Colors.white54, fontSize: 14),
                        ),
                      )
                    : ListView.separated(
                        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                        itemCount: results.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (context, i) {
                          final ch = results[i];
                          return Material(
                            color: const Color(0xFF151D2B),
                            borderRadius: BorderRadius.circular(12),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(12),
                              onTap: () {
                                Navigator.of(context).pop();
                                widget.onChannelSelect(ch);
                              },
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                child: Row(
                                  children: [
                                    ChannelIcon(
                                      key: ValueKey(ch.logoUrl + ch.name),
                                      channel: ch,
                                      width: 58,
                                      height: 38,
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            ch.name,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 14,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                          const SizedBox(height: 3),
                                          Text(
                                            '${ch.category} · ${ch.resolution}',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(color: Colors.white54, fontSize: 11),
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    const Icon(Icons.play_circle_outline_rounded, color: Color(0xFF38BDF8)),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildKeyTile(String label, int r, int c) {
    final isFocused = !_inResults && _kbRow == r && _kbCol == c;
    final isAction = label.length > 1;
    final isMic = label == 'MIC';

    return Expanded(
      flex: isAction ? 2 : 1,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 100),
        height: 34,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: isFocused
              ? Colors.white
              : isMic
                  ? const Color(0xFF0F766E)
                  : isAction
                      ? const Color(0xFF1E293B)
                      : const Color(0x14FFFFFF),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: isFocused
                ? Colors.white
                : isMic
                    ? const Color(0xFF2DD4BF)
                    : const Color(0x1AFFFFFF),
            width: isFocused || isMic ? 1.5 : 1,
          ),
          boxShadow: isFocused
              ? [BoxShadow(color: Colors.white.withValues(alpha: 0.6), blurRadius: 8)]
              : isMic
                  ? [BoxShadow(color: const Color(0xFF0F766E).withValues(alpha: 0.4), blurRadius: 6)]
                  : null,
        ),
        child: isMic
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.mic_rounded, size: 14, color: isFocused ? Colors.black : const Color(0xFF2DD4BF)),
                  const SizedBox(width: 4),
                  Text(
                    'MIC',
                    style: TextStyle(
                      color: isFocused ? Colors.black : Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              )
            : Text(
                label,
                style: TextStyle(
                  color: isFocused
                      ? Colors.black
                      : isAction
                          ? const Color(0xFF38BDF8)
                          : Colors.white,
                  fontSize: isAction ? 11 : 13,
                  fontWeight: isFocused || isAction ? FontWeight.w800 : FontWeight.w600,
                ),
              ),
      ),
    );
  }
}
