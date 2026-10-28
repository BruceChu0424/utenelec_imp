import 'package:flutter/material.dart';

/// One listener for the application, including kept-alive shell pages. A help
/// overlay belongs to the page that opened it, even when that page stays mounted.
class UtenTooltipNavigationHost extends StatefulWidget {
  const UtenTooltipNavigationHost({
    super.key,
    required this.navigation,
    required this.child,
  });

  final Listenable navigation;
  final Widget child;

  @override
  State<UtenTooltipNavigationHost> createState() =>
      _UtenTooltipNavigationHostState();
}

class _UtenTooltipNavigationHostState extends State<UtenTooltipNavigationHost> {
  bool _pending = false;

  @override
  void initState() {
    super.initState();
    widget.navigation.addListener(_onNavigation);
  }

  void _onNavigation() {
    if (_pending) return;
    _pending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pending = false;
      if (mounted) Tooltip.dismissAllToolTips();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void didUpdateWidget(UtenTooltipNavigationHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.navigation != widget.navigation) {
      oldWidget.navigation.removeListener(_onNavigation);
      widget.navigation.addListener(_onNavigation);
    }
  }

  @override
  void dispose() {
    widget.navigation.removeListener(_onNavigation);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
