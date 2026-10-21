import 'dart:async';

import 'package:flutter/material.dart';

/// Keeps a header action busy for the lifetime of the Future it actually
/// returns. Synchronous navigation and dialog opening keep their normal flow.
/// The action's owner retains error handling, permissions and result feedback.
class UtenAppBarActionFeedback extends StatefulWidget {
  const UtenAppBarActionFeedback({
    super.key,
    required this.onPressed,
    this.onLongPress,
    this.isLoading = false,
    required this.builder,
  });

  final FutureOr<void> Function()? onPressed;
  final FutureOr<void> Function()? onLongPress;
  final bool isLoading;
  final Widget Function(
    BuildContext context,
    bool isLoading,
    VoidCallback? onPressed,
    VoidCallback? onLongPress,
  )
  builder;

  @override
  State<UtenAppBarActionFeedback> createState() =>
      _UtenAppBarActionFeedbackState();
}

class _UtenAppBarActionFeedbackState extends State<UtenAppBarActionFeedback> {
  bool _running = false;

  Future<void> _run(FutureOr<void> Function() action) async {
    if (_running || widget.isLoading) return;
    setState(() => _running = true);
    try {
      await Future<void>.sync(action);
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final busy = _running || widget.isLoading;
    final press = widget.onPressed;
    final longPress = widget.onLongPress;
    return widget.builder(
      context,
      busy,
      busy || press == null ? null : () => _run(press),
      busy || longPress == null ? null : () => _run(longPress),
    );
  }
}

/// Preserve natural width so progress cannot push a full header into its menu.
class UtenAppBarActionProgress extends StatelessWidget {
  const UtenAppBarActionProgress({
    super.key,
    required this.isLoading,
    required this.child,
  });

  final bool isLoading;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // A dialog/new route is already the visible response. Stop animating the
    // covered header while retaining its in-flight guard and original label.
    final showProgress = isLoading && (ModalRoute.isCurrentOf(context) ?? true);
    return Semantics(
      value: isLoading ? '处理中' : null,
      liveRegion: isLoading,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Opacity(
            opacity: showProgress ? 0 : 1,
            alwaysIncludeSemantics: true,
            child: child,
          ),
          if (showProgress)
            const Positioned.fill(
              child: Center(
                child: ExcludeSemantics(
                  child: SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
