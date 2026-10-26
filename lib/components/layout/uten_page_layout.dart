import 'package:flutter/material.dart';

import '../../core/responsive/display_zoom.dart';
import 'uten_scroll_gutter.dart';

/// Window-sized page chrome. Local viewport lanes retain their existing units.
abstract final class UtenPageChromeMetrics {
  static const double railWidthWindow = 14;
  static const double railRightWindow = 2;
  static const double contentGapWindow = 8;
  static const double endWindow =
      railWidthWindow + railRightWindow + contentGapWindow;

  static double canvas(BuildContext context, double windowPixels) =>
      windowPixels / UtenDisplayScale.fontZoomOf(context);
  static double endOf(BuildContext context) => canvas(context, endWindow);
}

enum UtenPageScrollRole { main, local }

class UtenPageScrollRoleScope extends InheritedWidget {
  const UtenPageScrollRoleScope({
    super.key,
    required this.role,
    required super.child,
  });

  const UtenPageScrollRoleScope.local({super.key, required super.child})
    : role = UtenPageScrollRole.local;

  final UtenPageScrollRole role;

  static bool isPageOf(BuildContext context) {
    if (context
                .dependOnInheritedWidgetOfExactType<UtenPageScrollRoleScope>()
                ?.role ==
            UtenPageScrollRole.local ||
        ModalRoute.of(context) is PopupRoute) {
      return false;
    }
    var local = false;
    context.visitAncestorElements((element) {
      if (element.widget is Dialog ||
          element.widget is Drawer ||
          element.widget is BottomSheet ||
          element.widget is EditableText) {
        local = true;
        return false;
      }
      return true;
    });
    return !local;
  }

  @override
  bool updateShouldNotify(UtenPageScrollRoleScope oldWidget) =>
      role != oldWidget.role;
}

/// A retained tab supplies its stable identity and active state. Background
/// domains retain their own geometry but cannot compete with the active page.
class UtenPageLayoutDomainScope extends InheritedWidget {
  const UtenPageLayoutDomainScope({
    super.key,
    required this.domain,
    required this.active,
    required super.child,
  });
  final Object domain;
  final bool active;

  static UtenPageLayoutDomainScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<UtenPageLayoutDomainScope>();

  @override
  bool updateShouldNotify(UtenPageLayoutDomainScope oldWidget) =>
      domain != oldWidget.domain || active != oldWidget.active;
}

/// Page horizontal ownership without LayoutBuilder, intrinsic or height changes.
/// Local panels preserve the supplied padding in its original canvas units.
class UtenPageEdgePadding extends StatelessWidget {
  const UtenPageEdgePadding({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
    this.preserveStart = false,
  }) : scrollBuilder = null;

  /// Keeps top/bottom inside the scroll content where they originally belonged.
  /// The returned scroll view's descendants inherit horizontal ownership.
  const UtenPageEdgePadding.scroll({
    super.key,
    required this.padding,
    this.preserveStart = false,
    required Widget Function(BuildContext context, EdgeInsets padding) builder,
  }) : scrollBuilder = builder,
       child = null;

  final Widget? child;
  final EdgeInsetsGeometry padding;
  final bool preserveStart;
  final Widget Function(BuildContext context, EdgeInsets padding)?
  scrollBuilder;

  static EdgeInsets resolve(
    BuildContext context,
    EdgeInsetsGeometry padding, {
    bool preserveStart = false,
  }) {
    final original = padding.resolve(Directionality.of(context));
    if (!UtenPageScrollRoleScope.isPageOf(context)) return original;
    final owned = UtenContentInsetsScope.isPresentOf(context);
    return EdgeInsets.fromLTRB(
      owned && !preserveStart ? 0 : original.left,
      original.top,
      owned ? 0 : UtenPageChromeMetrics.endOf(context),
      original.bottom,
    );
  }

  static EdgeInsets resolveScrollPadding(
    BuildContext context,
    EdgeInsetsGeometry padding, {
    bool preserveStart = false,
  }) => resolve(context, padding, preserveStart: preserveStart);

  @override
  Widget build(BuildContext context) {
    final resolved = resolve(context, padding, preserveStart: preserveStart);
    final page = UtenPageScrollRoleScope.isPageOf(context);
    final inherited = UtenContentInsetsScope.isPresentOf(context);
    final Widget content;
    if (scrollBuilder case final builder?) {
      content = Builder(builder: (inner) => builder(inner, resolved));
    } else {
      content = Padding(padding: resolved, child: child);
    }
    return UtenContentInsetsScope(
      ownsInsets: page || inherited,
      child: content,
    );
  }
}

/// A source's stable layout disposition, independent of local paint visibility.
class UtenPageScrollLaneScope extends InheritedWidget {
  const UtenPageScrollLaneScope({
    super.key,
    required this.pageOwned,
    required super.child,
  });
  final bool pageOwned;
  static bool pageOwnedOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<UtenPageScrollLaneScope>()
          ?.pageOwned ??
      false;
  @override
  bool updateShouldNotify(UtenPageScrollLaneScope oldWidget) =>
      pageOwned != oldWidget.pageOwned;
}
