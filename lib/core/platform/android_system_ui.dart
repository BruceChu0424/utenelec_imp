import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// One full-view Android system-bar owner, outside routed SafeAreas.
/// Insets and focus remain with the existing pages. Native API-level themes
/// own the transparent/legacy navigation color; Flutter owns live icon contrast.
class UtenAndroidSystemUi extends StatefulWidget {
  const UtenAndroidSystemUi({super.key, required this.child});

  final Widget child;

  @override
  State<UtenAndroidSystemUi> createState() => _UtenAndroidSystemUiState();
}

class _UtenAndroidSystemUiState extends State<UtenAndroidSystemUi>
    with WidgetsBindingObserver {
  late final bool _android =
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  Timer? _keyboardRestore;
  bool _keyboardVisible = false;

  @override
  void initState() {
    super.initState();
    if (!_android) return;
    WidgetsBinding.instance.addObserver(this);
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_android) _keyboardVisible = View.of(context).viewInsets.bottom > 0;
  }

  @override
  void didChangeMetrics() {
    final visible = View.of(context).viewInsets.bottom > 0;
    if (visible) _keyboardRestore?.cancel();
    if (_keyboardVisible && !visible) {
      _keyboardRestore?.cancel();
      // Android forbids changing system UI for one second after IME closes.
      // Restore the existing visible edge-to-edge mode after that documented
      // platform interval; never hide navigation or change page metrics.
      _keyboardRestore = Timer(const Duration(seconds: 1), _restore);
    }
    _keyboardVisible = visible;
  }

  void _restore() {
    if (mounted) unawaited(SystemChrome.restoreSystemUIOverlays());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _restore();
  }

  @override
  void dispose() {
    _keyboardRestore?.cancel();
    if (_android) WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_android) return widget.child;
    final theme = Theme.of(context);
    final icons = theme.brightness == Brightness.dark
        ? Brightness.light
        : Brightness.dark;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: icons,
        systemNavigationBarIconBrightness: icons,
        systemNavigationBarDividerColor: Colors.transparent,
        systemNavigationBarContrastEnforced: false,
        systemStatusBarContrastEnforced: false,
      ),
      child: ColoredBox(
        color: theme.scaffoldBackgroundColor,
        child: widget.child,
      ),
    );
  }
}
