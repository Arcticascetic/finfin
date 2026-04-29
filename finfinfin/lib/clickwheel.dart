import 'package:flutter/material.dart';

class ClickwheelInputScreen extends StatefulWidget {
  const ClickwheelInputScreen({super.key, required this.title});
  final String title;

  @override
  State<ClickwheelInputScreen> createState() => _ClickwheelInputScreenState();
}

class _ClickwheelInputScreenState extends State<ClickwheelInputScreen> {
  int _currentDigit = 0;
  final List<int> _inputDigits = [0, 0, 0]; // start from 100s digit by default
  int _currentIndex =
      0; // 0 => 100s, 1 => 10s, 2 => 1s, then additional lower digits if appended
  double _currentValue = 0.0;
  // Flash flags for a subtle animation when a digit changes
  List<bool> _flashFlags = [];

  @override
  void initState() {
    super.initState();
    if (_currentIndex < _inputDigits.length) {
      _currentDigit = _inputDigits[_currentIndex];
    }
  }

  /// Increments the current digit, wrapping around 0-9.
  /// Also updates the visual state and resets the confirmation timer.
  void _incrementDigit() {
    setState(() {
      _currentDigit = (_currentDigit + 1) % 10;
      if (_currentIndex < _inputDigits.length) {
        _inputDigits[_currentIndex] = _currentDigit;
        _ensureFlashFlagsLength();
        _triggerFlash(_currentIndex);
      }
      _updateCurrentValue();
    });
  }

  /// Decrements the current digit, wrapping around 0-9.
  /// Also updates the visual state and resets the confirmation timer.
  void _decrementDigit() {
    setState(() {
      _currentDigit = (_currentDigit - 1 + 10) % 10;
      if (_currentIndex < _inputDigits.length) {
        _inputDigits[_currentIndex] = _currentDigit;
        _ensureFlashFlagsLength();
        _triggerFlash(_currentIndex);
      }
      _updateCurrentValue();
    });
  }


  /// Removes the last digit or resets the current one if it's the only one.
  /// Handles navigation back to the previous digit if applicable.
  void _removeLastDigit() {
    setState(() {
      if (_inputDigits.isNotEmpty) {
        if (_inputDigits.length > 3) {
          _inputDigits.removeLast();
          if (_currentIndex >= _inputDigits.length) {
            _currentIndex = _inputDigits.length - 1;
          }
          _currentDigit = _inputDigits[_currentIndex];
          _ensureFlashFlagsLength();
          _triggerFlash(_currentIndex);
        } else {
          _inputDigits[_currentIndex] = 0;
          _currentDigit = 0;
          _ensureFlashFlagsLength();
          _triggerFlash(_currentIndex);
        }
        _updateCurrentValue();
      } else {
        _currentDigit = 0;
      }
    });
  }

  /// Ensures the flash flags list matches the length of the input digits.
  void _ensureFlashFlagsLength() {
    while (_flashFlags.length < _inputDigits.length) {
      _flashFlags.add(false);
    }
    if (_flashFlags.length > _inputDigits.length) {
      _flashFlags = _flashFlags.sublist(0, _inputDigits.length);
    }
  }

  /// Triggers a brief flash animation for the digit at [idx].
  void _triggerFlash(int idx) {
    _ensureFlashFlagsLength();
    if (idx < 0 || idx >= _flashFlags.length) return;
    setState(() {
      _flashFlags[idx] = true;
    });
    Future.delayed(const Duration(milliseconds: 220), () {
      if (!mounted) return;
      setState(() {
        _flashFlags[idx] = false;
      });
    });
  }

  /// Updates the double value based on the current list of digits.
  /// Assumes the input represents a value in cents/hundreths.
  void _updateCurrentValue() {
    final numStr = _inputDigits.map((e) => e.toString()).join();
    _currentValue = (int.tryParse(numStr) ?? 0) / 100.0;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              'Input Amount:',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 10),
            Text(
              _currentValue.toStringAsFixed(2),
              style: Theme.of(context).textTheme.displaySmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            const SizedBox(height: 40),
            Container(
              width: 200,
              height: 200,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withAlpha((0.2 * 255).round()),
                    blurRadius: 10,
                    offset: const Offset(0, 5),
                  ),
                ],
              ),
              child: GestureDetector(
                onHorizontalDragEnd: (details) {
                  final vx = details.velocity.pixelsPerSecond.dx;
                  setState(() {
                    if (vx < -100) {
                      // Swipe Left -> Next Digit
                      if (_currentIndex < _inputDigits.length) {
                        _inputDigits[_currentIndex] = _currentDigit;
                        _ensureFlashFlagsLength();
                        _triggerFlash(_currentIndex);
                      } else {
                        _inputDigits.add(_currentDigit);
                        _ensureFlashFlagsLength();
                        _triggerFlash(_inputDigits.length - 1);
                      }
                      _currentIndex = _currentIndex + 1;
                      if (_currentIndex >= _inputDigits.length) {
                        _inputDigits.add(0);
                      }
                      _currentDigit = _inputDigits[_currentIndex];
                    } else if (vx > 100) {
                      // Swipe Right -> Previous Digit
                      if (_currentIndex > 0) {
                        // Save current before leaving?
                        if (_currentIndex < _inputDigits.length) {
                          _inputDigits[_currentIndex] = _currentDigit;
                        }
                        _currentIndex = _currentIndex - 1;
                        _currentDigit = _inputDigits[_currentIndex];
                        _ensureFlashFlagsLength();
                        _triggerFlash(_currentIndex);
                      }
                    }
                    _updateCurrentValue();
                  });
                },
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Positioned(
                      top: 10,
                      child: IconButton(
                        icon: const Icon(Icons.keyboard_arrow_up, size: 50),
                        onPressed: _incrementDigit,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: _inputDigits.asMap().entries.map((entry) {
                            final idx = entry.key;
                            final val = entry.value;
                            final selected = idx == _currentIndex;
                            // Animate digit changes with a subtle scale+opacity flash.
                            final isFlashing =
                                idx < _flashFlags.length && _flashFlags[idx];
                            final baseScale = selected ? 1.05 : 1.0;
                            final flashScale = isFlashing ? 1.18 : baseScale;
                            return AnimatedScale(
                              duration: const Duration(milliseconds: 220),
                              curve: Curves.easeOut,
                              scale: flashScale,
                              child: AnimatedOpacity(
                                duration: const Duration(milliseconds: 220),
                                opacity: isFlashing
                                    ? 1.0
                                    : (selected ? 1.0 : 0.88),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6.0,
                                  ),
                                  child: Text(
                                    val.toString(),
                                    style: Theme.of(context)
                                        .textTheme
                                        .displaySmall
                                        ?.copyWith(
                                          fontWeight: selected
                                              ? FontWeight.bold
                                              : FontWeight.normal,
                                          color: selected
                                              ? Theme.of(
                                                  context,
                                                ).colorScheme.primary
                                              : Theme.of(
                                                  context,
                                                ).colorScheme.onSurfaceVariant,
                                          fontSize: selected ? 42 : 24,
                                        ),
                                  ),
                                ),
                              ),
                            );
                          }).toList(),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          _currentIndex == 0
                              ? '100s'
                              : (_currentIndex == 1
                                    ? '10s'
                                    : (_currentIndex == 2 ? '1s' : 'lower')),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                    Positioned(
                      bottom: 10,
                      child: IconButton(
                        icon: const Icon(Icons.keyboard_arrow_down, size: 50),
                        onPressed: _decrementDigit,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 40),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ElevatedButton.icon(
                  onPressed: _inputDigits.isNotEmpty ? _removeLastDigit : null,
                  icon: const Icon(Icons.backspace),
                  label: const Text('Back'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 15,
                    ),
                  ),
                ),
                const SizedBox(width: 20),
                ElevatedButton.icon(
                  onPressed: () => Navigator.of(context).pop(_currentValue),
                  icon: const Icon(Icons.done),
                  label: const Text('Done'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 15,
                    ),
                    backgroundColor: Theme.of(context).colorScheme.primary,
                    foregroundColor: Theme.of(context).colorScheme.onPrimary,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}