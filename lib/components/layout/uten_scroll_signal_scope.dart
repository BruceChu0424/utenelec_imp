import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'uten_scrollbar_rail_delegate.dart';

/// A stable entry to an existing wheel gate. It routes the original signal,
/// never synthesizes another PointerEvent and never rescales its delta.
class UtenScrollSignalController {
  UtenScrollSignalController(this._handler, {this.resolveRailDelegate});

  ValueChanged<PointerSignalEvent>? _handler;
  UtenScrollSignalController? _parent;
  UtenScrollbarRailDelegate? Function(ScrollController source)?
  resolveRailDelegate;
  final _seen = Expando<bool>('uten-scroll-signal-event');

  UtenScrollbarRailDelegate? railDelegateFor(ScrollController source) =>
      _parent?.railDelegateFor(source) ?? resolveRailDelegate?.call(source);

  /// Linked gates can be nested. A host may suppress an ancestor viewport's
  /// secondary rail only when both sources really belong to this same chain.
  bool sharesLinkedChain(UtenScrollSignalController? other) {
    if (other == null) return false;
    final chain = Set<UtenScrollSignalController>.identity();
    for (
      UtenScrollSignalController? cursor = this;
      cursor != null && chain.add(cursor);
      cursor = cursor._parent
    ) {}
    final visited = Set<UtenScrollSignalController>.identity();
    for (
      UtenScrollSignalController? cursor = other;
      cursor != null && visited.add(cursor);
      cursor = cursor._parent
    ) {
      if (chain.contains(cursor)) return true;
    }
    return false;
  }

  void dispatch(PointerSignalEvent event) {
    if (_handler == null) return;
    // Child/parent listeners may receive transformed views of one event. Use
    // the original object's identity only for deduplication; the handler still
    // receives the current, already-normalized signal.
    final identity = event.original ?? event;
    if (_seen[identity] == true) return;
    _seen[identity] = true;
    // Existing overlay gates run before nested gates, matching their original
    // hit-test precedence. PointerSignalResolver keeps the first claim.
    _parent?.dispatch(event);
    _handler?.call(event);
  }

  void dispose() {
    _handler = null;
    _parent = null;
    resolveRailDelegate = null;
  }
}

/// Lets an external page rail use the exact gate that normally receives wheel
/// signals from this viewport's hit-test path. Each gate owns one controller.
class UtenScrollSignalScope extends StatelessWidget {
  const UtenScrollSignalScope({
    super.key,
    required this.controller,
    required this.child,
  });

  final UtenScrollSignalController controller;
  final Widget child;

  static UtenScrollSignalController? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_UtenScrollSignalScope>()
      ?.controller;

  @override
  Widget build(BuildContext context) {
    final parent = maybeOf(context);
    assert(
      !identical(parent, controller),
      'A wheel gate controller cannot own nested scopes.',
    );
    controller._parent = identical(parent, controller) ? null : parent;
    return _UtenScrollSignalScope(controller: controller, child: child);
  }
}

class _UtenScrollSignalScope extends InheritedWidget {
  const _UtenScrollSignalScope({
    required this.controller,
    required super.child,
  });
  final UtenScrollSignalController controller;

  @override
  bool updateShouldNotify(_UtenScrollSignalScope oldWidget) =>
      !identical(controller, oldWidget.controller);
}
