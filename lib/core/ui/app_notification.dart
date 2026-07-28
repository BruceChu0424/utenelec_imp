// 全局顶部通知服务：替代 ScaffoldMessenger.SnackBar，把反馈从底部挪到顶部。
// - 不依赖具体页面 ScaffoldMessenger，跨页面 / 路由切换时仍能稳定显示。
// - 同 message 600ms 内合并去重，避免"先 success 再 fail"的叠加抖动。
// - 队列上限 3 条（FIFO 出队），防止堆积。
// - API 错误自动带 fieldErrors，高密度提示。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../network/api_error.dart';
import '../network/api_exception.dart';

/// 通知类型。
enum AppNotificationKind { success, error, warning, info }

/// 通知值对象。
class AppNotification {
  AppNotification({
    required this.id,
    required this.kind,
    required this.message,
    this.title,
    this.durationMs = 3200,
    this.fieldErrors,
    this.icon,
    this.onTap,
  });

  final String id;
  final AppNotificationKind kind;
  final String? title;
  final String message;
  final int durationMs;
  final List<ApiFieldError>? fieldErrors;

  /// 自定义左侧图标（微信式消息弹条场景，如发送人头像/业务图标）；
  /// null 时回退到 kind 对应的语义图标。
  final IconData? icon;

  /// 点击弹条后的动作（如跳转到对应详情页）；null 时点击仅关闭。
  final VoidCallback? onTap;
}

/// 通知服务：Notifier 持有内存队列；所有页面通过 `context.appSuccess/Error/...` 调用。
class AppNotificationService extends Notifier<List<AppNotification>> {
  static const int _maxQueue = 3;
  static const int _dedupeMs = 600;
  static const int _seqMod = 0xFFFFFF;

  int _seq = 0;

  @override
  List<AppNotification> build() => const <AppNotification>[];

  String _newId() {
    final ts = DateTime.now().millisecondsSinceEpoch;
    _seq = (_seq + 1) % _seqMod;
    return '$ts-$_seq';
  }

  /// 距 id 时间戳的毫秒数，用于去重窗口判定。
  int _tsOf(String id) {
    final first = id.split('-').first;
    return int.tryParse(first) ?? 0;
  }

  void _show(AppNotification n) {
    final now = DateTime.now().millisecondsSinceEpoch;
    // 同 message + 同 kind 在 600ms 内合并去重，避免重复触发时的叠加。
    final hasRecent = state.any((x) =>
        x.kind == n.kind &&
        x.message == n.message &&
        now - _tsOf(x.id) < _dedupeMs);
    if (hasRecent) return;

    final fresh = AppNotification(
      id: _newId(),
      kind: n.kind,
      title: n.title,
      message: n.message,
      durationMs: n.durationMs,
      fieldErrors: n.fieldErrors,
      icon: n.icon,
      onTap: n.onTap,
    );
    final next = <AppNotification>[...state, fresh];
    while (next.length > _maxQueue) {
      next.removeAt(0);
    }
    state = next;
  }

  void dismiss(String id) {
    final next = state.where((n) => n.id != id).toList(growable: false);
    if (next.length != state.length) state = next;
  }

  void clear() {
    if (state.isNotEmpty) state = const <AppNotification>[];
  }

  void showSuccess(
    String message, {
    String? title,
    Duration? duration,
  }) =>
      _show(AppNotification(
        id: '',
        kind: AppNotificationKind.success,
        title: title,
        message: message,
        durationMs: duration?.inMilliseconds ?? 3200,
      ));

  void showError(
    String message, {
    String? title,
    Duration? duration,
    List<ApiFieldError>? fieldErrors,
  }) =>
      _show(AppNotification(
        id: '',
        kind: AppNotificationKind.error,
        title: title,
        message: message,
        durationMs: duration?.inMilliseconds ?? 5000,
        fieldErrors: fieldErrors,
      ));

  void showWarning(
    String message, {
    String? title,
    Duration? duration,
  }) =>
      _show(AppNotification(
        id: '',
        kind: AppNotificationKind.warning,
        title: title,
        message: message,
        durationMs: duration?.inMilliseconds ?? 3200,
      ));

  void showInfo(
    String message, {
    String? title,
    Duration? duration,
  }) =>
      _show(AppNotification(
        id: '',
        kind: AppNotificationKind.info,
        title: title,
        message: message,
        durationMs: duration?.inMilliseconds ?? 3200,
      ));

  /// 通用入口（统一门面 UtenNotify.banner 走这里）。
  ///
  /// 支持自定义 [icon] 与点击动作 [onTap]，用于「微信式消息弹条」场景：
  /// 顶部滑入一条新消息，点击跳转详情，不阻塞当前操作。
  void showMessage(
    String message, {
    String? title,
    AppNotificationKind kind = AppNotificationKind.info,
    Duration? duration,
    IconData? icon,
    VoidCallback? onTap,
  }) =>
      _show(AppNotification(
        id: '',
        kind: kind,
        title: title,
        message: message,
        durationMs: duration?.inMilliseconds ?? 3200,
        icon: icon,
        onTap: onTap,
      ));
}

/// 全局 Provider。
final appNotificationProvider =
    NotifierProvider<AppNotificationService, List<AppNotification>>(
  AppNotificationService.new,
);

/// BuildContext 便捷调用扩展。
extension AppNotificationContextX on BuildContext {
  AppNotificationService get _notifier =>
      ProviderScope.containerOf(this, listen: false)
          .read(appNotificationProvider.notifier);

  /// 显示顶部成功通知。
  void appSuccess(String message, {String? title}) =>
      _notifier.showSuccess(message, title: title);

  /// 显示顶部错误通知。
  void appError(String message,
          {String? title, List<ApiFieldError>? fieldErrors}) =>
      _notifier.showError(message,
          title: title, fieldErrors: fieldErrors);

  /// 显示顶部警告通知。
  void appWarning(String message, {String? title}) =>
      _notifier.showWarning(message, title: title);

  /// 显示顶部信息通知。
  void appInfo(String message, {String? title}) =>
      _notifier.showInfo(message, title: title);

  /// 从 ApiException 自动提取 message + fieldErrors 显示为错误通知。
  void appApiError(Object error, {String? fallback = '操作失败，请稍后重试'}) {
    if (error is ApiException) {
      _notifier.showError(
        error.message.isNotEmpty ? error.message : (fallback ?? ''),
        fieldErrors: error.fieldErrors,
      );
    } else {
      _notifier.showError(fallback ?? '操作失败，请稍后重试');
    }
  }
}

/// 通知宿主：放在 MaterialApp.builder 内最上层（Stack 顶层）。
/// 监听全局 provider，把队列表渲染成顶部 banner 列表。
class AppNotificationHost extends ConsumerWidget {
  const AppNotificationHost({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(appNotificationProvider);
    if (list.isEmpty) return const SizedBox.shrink();
    final media = MediaQuery.of(context);
    return IgnorePointer(
      ignoring: false,
      child: Padding(
        padding: EdgeInsets.only(
          top: media.padding.top + 8,
          left: 16,
          right: 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final n in list) _AppNotificationBanner(key: ValueKey(n.id), notification: n),
          ],
        ),
      ),
    );
  }
}

/// 单条 banner：滑入 + 自动倒计时退出。
class _AppNotificationBanner extends ConsumerStatefulWidget {
  const _AppNotificationBanner({super.key, required this.notification});

  final AppNotification notification;

  @override
  ConsumerState<_AppNotificationBanner> createState() =>
      _AppNotificationBannerState();
}

class _AppNotificationBannerState
    extends ConsumerState<_AppNotificationBanner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    Future.delayed(Duration(milliseconds: widget.notification.durationMs),
        () {
      if (!mounted) return;
      ref
          .read(appNotificationProvider.notifier)
          .dismiss(widget.notification.id);
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _dismiss() async {
    await _ctrl.reverse();
    if (!mounted) return;
    ref
        .read(appNotificationProvider.notifier)
        .dismiss(widget.notification.id);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final n = widget.notification;
    final scheme = theme.colorScheme;
    final (bg, fg, icon) = switch (n.kind) {
      AppNotificationKind.success => (
          scheme.primary,
          scheme.onPrimary,
          Icons.check_circle_outline_rounded,
        ),
      AppNotificationKind.error => (
          scheme.error,
          scheme.onError,
          Icons.error_outline_rounded,
        ),
      AppNotificationKind.warning => (
          scheme.tertiary,
          scheme.onTertiary,
          Icons.warning_amber_rounded,
        ),
      AppNotificationKind.info => (
          scheme.surfaceContainerHighest,
          scheme.onSurface,
          Icons.info_outline_rounded,
        ),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: FadeTransition(
        opacity: _ctrl,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, -0.2),
            end: Offset.zero,
          ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic)),
          child: Dismissible(
            key: ValueKey('dismiss-${n.id}'),
            onDismissed: (_) {
              ref
                  .read(appNotificationProvider.notifier)
                  .dismiss(n.id);
            },
            child: Material(
              color: bg,
              elevation: 6,
              shadowColor: fg.withValues(alpha: 0.25),
              borderRadius: BorderRadius.circular(12),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                // 带跳转动作的弹条：点击先执行动作再关闭（微信式点消息进详情）
                onTap: n.onTap == null
                    ? _dismiss
                    : () {
                        n.onTap!();
                        _dismiss();
                      },
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(n.icon ?? icon, color: fg, size: 22),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (n.title != null && n.title!.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 2),
                                child: Text(
                                  n.title!,
                                  style: theme.textTheme.titleSmall?.copyWith(
                                    color: fg,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            Text(
                              n.message,
                              style: theme.textTheme.bodyMedium
                                  ?.copyWith(color: fg),
                            ),
                            if (n.fieldErrors != null &&
                                n.fieldErrors!.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text(
                                  '涉及字段：${n.fieldErrors!.map((f) => f.field).where((s) => s.isNotEmpty).join(', ')}',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: fg.withValues(alpha: 0.85),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: Icon(Icons.close_rounded, color: fg, size: 18),
                        onPressed: _dismiss,
                        tooltip: '',
                        visualDensity: VisualDensity.compact,
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
