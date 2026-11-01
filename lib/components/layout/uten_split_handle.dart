import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/uten_tokens.dart';

/// Shared splitter interaction. Hosts own constraints, ratio and persistence.
class UtenSplitHandle extends StatefulWidget {
  const UtenSplitHandle({
    super.key,
    required this.onDelta,
    required this.onReset,
    this.onTap,
    this.onDragEnd,
    this.width = 12,
    this.tooltip = '拖动调整宽度 · 双击复位',
  });

  final ValueChanged<double> onDelta;
  final VoidCallback onReset;
  final VoidCallback? onTap, onDragEnd;
  final double width;
  final String tooltip;

  @override
  State<UtenSplitHandle> createState() => _UtenSplitHandleState();
}

class _UtenSplitHandleState extends State<UtenSplitHandle> {
  final _focus = FocusNode();
  bool _hover = false, _drag = false;

  void _tap() {
    _focus.requestFocus();
    widget.onTap?.call();
  }

  void _nudge(double delta) {
    widget.onDelta(delta);
    widget.onDragEnd?.call();
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final active = _hover || _drag || _focus.hasFocus;
    return Semantics(
      label: widget.tooltip,
      button: widget.onTap != null,
      onIncrease: () => _nudge(16),
      onDecrease: () => _nudge(-16),
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeColumn,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: Tooltip(
          message: widget.tooltip,
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
                  _nudge(-16),
              const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
                  _nudge(16),
              const SingleActivator(LogicalKeyboardKey.home): widget.onReset,
              if (widget.onTap != null) ...{
                const SingleActivator(LogicalKeyboardKey.enter): _tap,
                const SingleActivator(LogicalKeyboardKey.space): _tap,
              },
            },
            child: Focus(
              focusNode: _focus,
              onFocusChange: (_) => setState(() {}),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _tap,
                onDoubleTap: widget.onReset,
                onHorizontalDragStart: (_) => setState(() => _drag = true),
                onHorizontalDragUpdate: (d) => widget.onDelta(d.delta.dx),
                onHorizontalDragEnd: (_) {
                  setState(() => _drag = false);
                  widget.onDragEnd?.call();
                },
                onHorizontalDragCancel: () => setState(() => _drag = false),
                // Long-press then drag also works on touch screens.
                onLongPressStart: (_) {
                  _longPressX = 0;
                  setState(() => _drag = true);
                },
                onLongPressMoveUpdate: (d) {
                  widget.onDelta(d.localOffsetFromOrigin.dx - _longPressX);
                  _longPressX = d.localOffsetFromOrigin.dx;
                },
                onLongPressEnd: (_) {
                  _longPressX = 0;
                  setState(() => _drag = false);
                  widget.onDragEnd?.call();
                },
                child: SizedBox(
                  width: widget.width,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Container(
                        width: active ? 2 : 1,
                        color: active ? colors.primary : colors.outlineVariant,
                      ),
                      Container(
                        width: widget.width,
                        height: 48,
                        decoration: BoxDecoration(
                          color: active
                              ? colors.primaryContainer
                              : colors.surfaceContainerHigh,
                          borderRadius: UtenRadius.controlAll,
                          border: Border.all(
                            color: active
                                ? colors.primary
                                : colors.outlineVariant,
                          ),
                        ),
                        child: Icon(
                          Icons.more_vert_rounded,
                          size: 20,
                          color: active
                              ? colors.primary
                              : colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  double _longPressX = 0;
}
