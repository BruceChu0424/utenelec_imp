import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform/desktop_window.dart';

/// Keep native controls outside display zoom and keep the routed subtree in
/// the same slot while changing modes, preserving focus and form controllers.
class DesktopWindowHost extends ConsumerStatefulWidget {
  const DesktopWindowHost({super.key, required this.mode, required this.child});

  final DesktopWindowMode mode;
  final Widget child;

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
    return Column(
      children: [
        SizedBox(
          height: login ? 36 : 0,
          child: login ? _LoginWindowControls(controller: _controller) : null,
        ),
        Expanded(child: widget.child),
      ],
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
      onPressed: controller.close,
    );
    final minimize = _WindowButton(
      key: const Key('desktop-window-minimize'),
      tooltip: minimizeLabel,
      icon: Icons.remove_rounded,
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
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Row(
        textDirection: TextDirection.ltr,
        children: isMac
            ? [close, minimize, dragArea]
            : [dragArea, minimize, close],
      ),
    );
  }
}

class _WindowButton extends StatelessWidget {
  const _WindowButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final Future<void> Function() onPressed;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 44,
    height: 36,
    child: IconButton(
      tooltip: tooltip,
      icon: Icon(icon, size: 18),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.expand(),
      style: IconButton.styleFrom(
        shape: const RoundedRectangleBorder(),
        foregroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      onPressed: () => unawaited(onPressed()),
    ),
  );
}
