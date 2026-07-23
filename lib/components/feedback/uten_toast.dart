// UtenToast - 轻提示
// 文档：docs/02-组件库/UtenToast.md（待写）

import 'package:flutter/material.dart';

import '../../core/theme/uten_colors.dart';

/// Uten 轻提示类型
enum UtenToastType { success, error, warning, info }

/// Uten 轻提示
class UtenToast {
  UtenToast._();

  static void show(
    BuildContext context,
    String message, {
    UtenToastType type = UtenToastType.info,
    Duration duration = const Duration(seconds: 2),
  }) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final (icon, color) = switch (type) {
      UtenToastType.success => (
          Icons.check_circle_rounded,
          UtenColors.success,
        ),
      UtenToastType.error => (
          Icons.cancel_rounded,
          UtenColors.error,
        ),
      UtenToastType.warning => (
          Icons.warning_rounded,
          UtenColors.warning,
        ),
      UtenToastType.info => (
          Icons.info_rounded,
          UtenColors.info,
        ),
    };

    final overlay = Overlay.of(context);
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) => _ToastView(
        message: message,
        icon: icon,
        color: color,
        isDark: isDark,
        onDismiss: () => entry.remove(),
      ),
    );

    overlay.insert(entry);
    Future.delayed(duration, () {
      if (entry.mounted) entry.remove();
    });
  }

  static void success(BuildContext context, String message) =>
      show(context, message, type: UtenToastType.success);

  static void error(BuildContext context, String message) =>
      show(context, message, type: UtenToastType.error);

  static void warning(BuildContext context, String message) =>
      show(context, message, type: UtenToastType.warning);

  static void info(BuildContext context, String message) =>
      show(context, message);
}

class _ToastView extends StatefulWidget {
  const _ToastView({
    required this.message,
    required this.icon,
    required this.color,
    required this.isDark,
    required this.onDismiss,
  });

  final String message;
  final IconData icon;
  final Color color;
  final bool isDark;
  final VoidCallback onDismiss;

  @override
  State<_ToastView> createState() => _ToastViewState();
}

class _ToastViewState extends State<_ToastView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: MediaQuery.of(context).padding.top + 16,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Center(
          child: FadeTransition(
            opacity: _controller,
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.95, end: 1).animate(_controller),
              child: Material(
                color: Colors.transparent,
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 380),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: widget.isDark
                        ? const Color(0xFF1A2D24)
                        : const Color(0xFF1E293B),
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.2),
                        blurRadius: 16,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(widget.icon, color: widget.color, size: 20),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          widget.message,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                          ),
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
}
