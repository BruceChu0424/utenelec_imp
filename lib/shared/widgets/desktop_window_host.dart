import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform/desktop_window.dart';
import '../../core/theme/uten_colors.dart';

/// Keep native controls outside display zoom and keep the routed subtree in
/// the same slot while changing modes, preserving focus and form controllers.
class DesktopWindowHost extends ConsumerStatefulWidget {
  static const controlsHeight = 36.0;

  const DesktopWindowHost({
    super.key,
    required this.mode,
    required this.child,
    this.overlayControls = false,
  });

  final DesktopWindowMode mode;
  final Widget child;

  /// Full-bleed login art handles its own safe scroll viewport. Other pages,
  /// including forced password changes, reserve a native-sized control strip.
  final bool overlayControls;

  @override
  ConsumerState<DesktopWindowHost> createState() => _DesktopWindowHostState();
}

class _DesktopWindowHostState extends ConsumerState<DesktopWindowHost> {
  late DesktopWindowController _controller;

  @override
  void initState() {
    super.initState();
    _controller = ref.read(desktopWindowControllerProvider);
    unawaited(_controller.setMode(widget.mode));
  }

  @override
  void didUpdateWidget(DesktopWindowHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.mode != widget.mode) {
      unawaited(_controller.setMode(widget.mode));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_controller.enabled) return widget.child;
    final login = widget.mode == DesktopWindowMode.login;
    return ColoredBox(
      color: Theme.of(context).scaffoldBackgroundColor,
      // MaterialApp.builder places this host above the route Navigator. Its
      // native control tooltips therefore need their own window-sized overlay.
      child: Overlay.wrap(
        child: Stack(
          children: [
            Positioned.fill(
              top: login && !widget.overlayControls
                  ? DesktopWindowHost.controlsHeight
                  : 0,
              child: widget.child,
            ),
            if (login)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: DesktopWindowHost.controlsHeight,
                child: _LoginWindowControls(controller: _controller),
              ),
          ],
        ),
      ),
    );
  }
}

class _LoginWindowControls extends StatelessWidget {
  const _LoginWindowControls({required this.controller});

  final DesktopWindowController controller;

  @override
  Widget build(BuildContext context) {
    final isMac = defaultTargetPlatform == TargetPlatform.macOS;
    final language = Localizations.localeOf(context).languageCode;
    final minimizeLabel = switch (language) {
      'zh' => '最小化',
      'ko' => '최소화',
      _ => 'Minimize',
    };
    final close = _WindowButton(
      key: const Key('desktop-window-close'),
      tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
      icon: Icons.close_rounded,
      backgroundColor: UtenColors.error,
      onPressed: controller.close,
    );
    final minimize = _WindowButton(
      key: const Key('desktop-window-minimize'),
      tooltip: minimizeLabel,
      icon: Icons.remove_rounded,
      backgroundColor: UtenColors.warning,
      onPressed: controller.minimize,
    );
    final dragArea = Expanded(
      child: Listener(
        key: const Key('desktop-window-drag'),
        behavior: HitTestBehavior.opaque,
        onPointerDown: (event) {
          if (event.buttons == kPrimaryButton) {
            unawaited(controller.beginDrag());
          }
        },
        child: const SizedBox.expand(),
      ),
    );
    return Material(
      color: Colors.transparent,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          textDirection: TextDirection.ltr,
          children: isMac
              ? [close, minimize, dragArea]
              : [dragArea, minimize, close],
        ),
      ),
    );
  }
}

class _WindowButton extends StatelessWidget {
  const _WindowButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.backgroundColor,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final Color backgroundColor;
  final Future<void> Function() onPressed;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 30,
    height: 36,
    child: IconButton(
      tooltip: tooltip,
      // Keep separate hit areas with an 8dp visual gap between the circles.
      icon: Container(
        width: 22,
        height: 22,
        decoration: BoxDecoration(
          color: backgroundColor,
          shape: BoxShape.circle,
        ),
        child: Icon(icon, size: 14, color: Colors.white),
      ),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.expand(),
      style: IconButton.styleFrom(
        shape: const CircleBorder(),
        foregroundColor: Colors.white,
        overlayColor: Theme.of(
          context,
        ).colorScheme.onSurface.withValues(alpha: 0.12),
      ),
      onPressed: () => unawaited(onPressed()),
    ),
  );
}
