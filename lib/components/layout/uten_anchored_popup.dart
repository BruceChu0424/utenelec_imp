import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/uten_tokens.dart';
import '../../core/ui/capsule_nav_metrics.dart';
import '../feedback/uten_overlay_lifecycle.dart';
import '../inputs/uten_dropdown_scroll_scope.dart';

class UtenPopupController {
  _UtenAnchoredPopupState? _owner;
  bool get isOpen => _owner?._open ?? false;
  void open() => _owner?._change(true);
  void close() => _owner?._change(false);
  void toggle() => isOpen ? close() : open();
}

/// Project-owned anchored dropdown surface, shared by compact actions/search.
/// It follows its anchor, flips above near the bottom and stays inside the
/// visible keyboard/safe-area bounds. It uses no native menu/dropdown widget.
class UtenAnchoredPopup extends StatefulWidget {
  const UtenAnchoredPopup({
    super.key,
    required this.controller,
    required this.child,
    required this.popupBuilder,
    this.onChanged,
    this.width = 280,
    this.maxHeight = 420,
  });
  final UtenPopupController controller;
  final Widget child;
  final WidgetBuilder popupBuilder;
  final ValueChanged<bool>? onChanged;
  final double width;
  final double maxHeight;
  @override
  State<UtenAnchoredPopup> createState() => _UtenAnchoredPopupState();
}

class _UtenAnchoredPopupState extends State<UtenAnchoredPopup> {
  final _portal = OverlayPortalController();
  late final _lifecycle = UtenOverlayLifecycle(
    onUnavailable: () => _change(false),
  );
  bool _open = false;
  bool _active = true;

  @override
  void initState() {
    super.initState();
    widget.controller._owner = this;
  }

  void _change(bool value) {
    if (!mounted || _open == value) return;
    _open = value;
    if (!_active) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_open) {
          _portal.hide();
          if (_active) {
            setState(() {});
            widget.onChanged?.call(false);
          }
        }
      });
      return;
    }
    if (value) {
      _portal.show();
      _lifecycle.attach(context);
    } else {
      _portal.hide();
    }
    if (_active) {
      setState(() {});
      widget.onChanged?.call(value);
    }
  }

  @override
  void deactivate() {
    _active = false;
    _lifecycle.detach();
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    _active = true;
  }

  @override
  void dispose() {
    widget.controller._owner = null;
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  // A closed portal has no content to retain. Leaving its deferred render
  // child attached breaks GlobalKey moves performed by table LayoutBuilders
  // during fullscreen/responsive handoff after the popup has been used.
  Widget build(BuildContext context) => !_open
      ? widget.child
      : OverlayPortal.overlayChildLayoutBuilder(
          controller: _portal,
          overlayChildBuilder: (context, info) {
            final media = MediaQuery.of(context);
            final anchor = MatrixUtils.transformRect(
              info.childPaintTransform,
              Offset.zero & info.childSize,
            );
            final bounds = Rect.fromLTRB(
              12 + media.padding.left,
              12 + media.padding.top,
              info.overlaySize.width - 12 - media.padding.right,
              info.overlaySize.height -
                  12 -
                  math.max(
                    media.viewInsets.bottom,
                    math.max(
                      media.padding.bottom,
                      UtenCapsuleNavScope.occlusionOf(context),
                    ),
                  ),
            );
            return Stack(
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: widget.controller.close,
                    child: const ColoredBox(color: Colors.transparent),
                  ),
                ),
                CustomSingleChildLayout(
                  delegate: _PopupLayout(
                    anchor,
                    bounds,
                    widget.width,
                    widget.maxHeight,
                  ),
                  child: FocusScope(
                    autofocus: true,
                    child: Focus(
                      onKeyEvent: (_, event) {
                        if (event is KeyDownEvent &&
                            event.logicalKey == LogicalKeyboardKey.escape) {
                          widget.controller.close();
                          return KeyEventResult.handled;
                        }
                        return KeyEventResult.ignored;
                      },
                      child: Material(
                        key: const ValueKey('uten-anchored-popup'),
                        color: Theme.of(context).colorScheme.surface,
                        elevation: 8,
                        shape: RoundedRectangleBorder(
                          borderRadius: UtenRadius.controlAll,
                          side: BorderSide(
                            color: Theme.of(context).colorScheme.outlineVariant,
                          ),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: UtenDropdownScrollScope(
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: widget.popupBuilder(context),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
          child: widget.child,
        );
}

class _PopupLayout extends SingleChildLayoutDelegate {
  _PopupLayout(this.anchor, this.bounds, this.width, this.maxHeight);
  final Rect anchor;
  final Rect bounds;
  final double width;
  final double maxHeight;
  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final available = math.max(
      bounds.bottom - anchor.bottom - 6,
      anchor.top - bounds.top - 6,
    );
    final w = math.min(width, math.max(0.0, bounds.width));
    return BoxConstraints(
      minWidth: w,
      maxWidth: w,
      maxHeight: math.min(maxHeight, math.max(0.0, available)),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final down = anchor.bottom + 6;
    final top = down + childSize.height <= bounds.bottom
        ? down
        : anchor.top - 6 - childSize.height;
    return Offset(
      (anchor.right - childSize.width).clamp(
        bounds.left,
        math.max(bounds.left, bounds.right - childSize.width),
      ),
      top.clamp(
        bounds.top,
        math.max(bounds.top, bounds.bottom - childSize.height),
      ),
    );
  }

  @override
  bool shouldRelayout(_PopupLayout oldDelegate) =>
      anchor != oldDelegate.anchor ||
      bounds != oldDelegate.bounds ||
      width != oldDelegate.width ||
      maxHeight != oldDelegate.maxHeight;
}
