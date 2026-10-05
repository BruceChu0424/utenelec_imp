import 'package:flutter/material.dart';

import '../../shared/ai/page_context/ai_page_context.dart';

/// Table guidance lives in the header. Row-specific messages remain available
/// on the cell itself, without a second disclosure icon or an extra tab stop.
///
/// [aiCell] (ADR-150) lets the owning table read this cell's yellow review /
/// error / required-empty state when the AI assistant captures the page. It is
/// a registration only; nothing is computed until a capture asks for it.
class UtenTableCellHints extends StatefulWidget {
  const UtenTableCellHints({super.key, required this.child, this.aiCell});

  final Widget child;
  final AiCellIdentity? aiCell;

  static bool contains(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_TableCellHintScope>() != null;

  static UtenTableCellHintRegistration? registrationOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_TableCellHintScope>()?.state;

  @override
  State<UtenTableCellHints> createState() => _UtenTableCellHintsState();
}

abstract interface class UtenTableCellHintRegistration {
  /// [error]/[autofill] carry the same text split by kind, for page capture.
  void setMessage(
    Object owner,
    String? message, {
    required bool liveRegion,
    String? error,
    String? autofill,
  });
  void removeMessage(Object owner);

  /// A required cell's emptiness probe (RequiredCellFrame), read on capture.
  void setRequiredProbe(Object owner, bool Function()? isEmpty);
}

class _UtenTableCellHintsState extends State<UtenTableCellHints>
    implements UtenTableCellHintRegistration {
  final _messages = <Object, ({String text, bool liveRegion})>{};
  final _kinds = <Object, ({String? error, String? autofill})>{};
  final _requiredProbes = <Object, bool Function()>{};
  AiCellIdentity? _aiCell;

  @override
  void initState() {
    super.initState();
    _bindAiCell();
  }

  @override
  void didUpdateWidget(covariant UtenTableCellHints oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.aiCell != widget.aiCell) _bindAiCell();
  }

  @override
  void dispose() {
    _aiCell?.registry.remove(this);
    super.dispose();
  }

  void _bindAiCell() {
    _aiCell?.registry.remove(this);
    _aiCell = widget.aiCell;
    final cell = _aiCell;
    if (cell != null) cell.registry.add(this, cell, _aiFacts);
  }

  List<AiCellFact> _aiFacts() => [
    if (_requiredProbes.values.any((isEmpty) => isEmpty()))
      const AiCellFact(AiCellState.requiredEmpty),
    for (final kind in _kinds.values)
      if (kind.error?.isNotEmpty ?? false)
        AiCellFact(AiCellState.error, kind.error)
      else if (kind.autofill?.isNotEmpty ?? false)
        AiCellFact(AiCellState.review, kind.autofill),
  ];

  @override
  void setRequiredProbe(Object owner, bool Function()? isEmpty) {
    if (isEmpty == null) {
      _requiredProbes.remove(owner);
    } else {
      _requiredProbes[owner] = isEmpty;
    }
  }

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
  void setMessage(
    Object owner,
    String? message, {
    required bool liveRegion,
    String? error,
    String? autofill,
  }) {
    if (error == null && autofill == null) {
      _kinds.remove(owner);
    } else {
      _kinds[owner] = (error: error, autofill: autofill);
    }
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
    _kinds.remove(owner);
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
