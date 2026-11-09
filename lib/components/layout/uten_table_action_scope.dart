import 'package:flutter/widgets.dart';

/// Table toolbar buttons share one visual size. The scope wraps actions only,
/// leaving table cells, document forms and transient dialogs independent.
class UtenTableActionScope extends InheritedWidget {
  const UtenTableActionScope({super.key, required super.child});

  static bool contains(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<UtenTableActionScope>() !=
      null;

  @override
  bool updateShouldNotify(UtenTableActionScope oldWidget) => false;
}

/// Holds one host batch action of a table while the selection it acts on is
/// not ready: a save in flight (`UtenEditableGrid.selectionEnabled` false) or
/// rows that are still a growing prefix of a complete read
/// (`MasterDataTableView`). The action keeps its place, label and own enabled
/// state, so the layout does not jump; pointer, keyboard focus and semantic
/// actions are held and it dims until the table is ready again.
///
/// The gate stays in the tree in both states: toggling it never remounts the
/// action (an in-flight action keeps its own busy state). `UtenActionOverflow`
/// treats the gate as the action it wraps, so compact menus keep the action.
class UtenTableActionGate extends StatelessWidget {
  const UtenTableActionGate({
    super.key,
    required this.enabled,
    required this.child,
  });

  final bool enabled;
  final Widget child;

  @override
  Widget build(BuildContext context) => ExcludeFocus(
    excluding: !enabled,
    child: IgnorePointer(
      ignoring: !enabled,
      child: AnimatedOpacity(
        opacity: enabled ? 1 : 0.45,
        duration: MediaQuery.maybeDisableAnimationsOf(context) == true
            ? Duration.zero
            : const Duration(milliseconds: 150),
        child: child,
      ),
    ),
  );
}
