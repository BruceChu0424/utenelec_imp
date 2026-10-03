import 'package:flutter/material.dart';

/// Table guidance lives in the header. Row-specific messages remain available
/// on the cell itself, without a second disclosure icon or an extra tab stop.
class UtenTableCellHints extends StatefulWidget {
  const UtenTableCellHints({super.key, required this.child});

  final Widget child;

  static bool contains(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_TableCellHintScope>() != null;

  static UtenTableCellHintRegistration? registrationOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_TableCellHintScope>()?.state;

  @override
  State<UtenTableCellHints> createState() => _UtenTableCellHintsState();
}

abstract interface class UtenTableCellHintRegistration {
  void setMessage(Object owner, String? message, {required bool liveRegion});
  void removeMessage(Object owner);
}

class _UtenTableCellHintsState extends State<UtenTableCellHints>
    implements UtenTableCellHintRegistration {
  final _messages = <Object, ({String text, bool liveRegion})>{};
  final _tooltipKey = GlobalKey<TooltipState>();
  // Tooltip drops its overlay wrappers when the message becomes empty. Keep
  // the editor subtree alive across that reparenting, including its focus and
  // blur callbacks; hint registration must never recreate the input field.
  final _contentKey = GlobalKey();
  bool _queued = false;

  void _scheduleRefresh() {
    if (_queued || !mounted) return;
    _queued = true;
    // Registrations occur while descendants build or dispose. Rebuild only the
    // tooltip after that frame; never rebuild the field or replace its focus.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _queued = false;
      setState(() {});
    });
  }

  @override
  void setMessage(Object owner, String? message, {required bool liveRegion}) {
    if (message == null || message.isEmpty) {
      removeMessage(owner);
      return;
    }
    final value = (text: message, liveRegion: liveRegion);
    if (_messages[owner] == value) return;
    _messages[owner] = value;
    _scheduleRefresh();
  }

  @override
  void removeMessage(Object owner) {
    if (_messages.remove(owner) != null) _scheduleRefresh();
  }

  @override
  Widget build(BuildContext context) {
    final message = _messages.values
        .map((value) => value.text)
        .toSet()
        .join('\n\n');
    final liveRegion = _messages.values.any((value) => value.liveRegion);
    return _TableCellHintScope(
      state: this,
      child: Focus(
        canRequestFocus: false,
        onFocusChange: (focused) {
          if (focused && liveRegion) {
            _tooltipKey.currentState?.ensureTooltipVisible();
          } else if (!focused) {
            Tooltip.dismissAllToolTips();
          }
        },
        child: Tooltip(
          key: _tooltipKey,
          message: message,
          waitDuration: const Duration(milliseconds: 250),
          showDuration: const Duration(seconds: 10),
          constraints: const BoxConstraints(maxWidth: 480),
          excludeFromSemantics: true,
          child: Semantics(
            key: _contentKey,
            hint: message.isEmpty ? null : message,
            liveRegion: liveRegion,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

class _TableCellHintScope extends InheritedWidget {
  const _TableCellHintScope({required this.state, required super.child});

  final UtenTableCellHintRegistration state;

  @override
  bool updateShouldNotify(_TableCellHintScope oldWidget) =>
      state != oldWidget.state;
}
