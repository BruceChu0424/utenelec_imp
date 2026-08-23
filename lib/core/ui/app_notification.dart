// 全局顶部通知服务：替代 ScaffoldMessenger.SnackBar，把反馈从底部挪到顶部。
// - 不依赖具体页面 ScaffoldMessenger，跨页面 / 路由切换时仍能稳定显示。
// - 同 message 600ms 内合并去重，避免"先 success 再 fail"的叠加抖动。
// - 任意时刻只显示 1 条；其余保留在 FIFO 队列中，前一条关闭后再逐条显示。
// - API 错误自动带 fieldErrors，高密度提示。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../network/api_error.dart';
import '../network/api_exception.dart';
import '../theme/uten_colors.dart';
import 'uten_top_banner_card.dart';

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
    this.onDismissed,
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

  /// 该条已实际显示并由自动/点击/关闭按钮/滑动完成关闭后的回调。
  ///
  /// 队列尚未轮到、宿主销毁或服务调用 [AppNotificationService.clear] 时不触发。
  final VoidCallback? onDismissed;
}

/// 通知服务：Notifier 持有内存队列；所有页面通过 `context.appSuccess/Error/...` 调用。
class AppNotificationService extends Notifier<List<AppNotification>> {
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

  /// 适老化默认停留时长：基础档（info/success/warning 3.2s、error 5s）+ 文案长度与
  /// 字段错误加成，确保操作人员读得完再消失。调用方显式传 [Duration] 时不走本函数。
  static int _readMs(
    AppNotificationKind kind,
    String message, {
    bool hasFieldErrors = false,
  }) {
    var ms = switch (kind) {
      AppNotificationKind.error => 5000,
      _ => 3200,
    };
    final len = message.length;
    if (len > 24) ms += ((len - 24) ~/ 12) * 600; // 每多约 12 字 +0.6s
    if (hasFieldErrors) ms += 1500; // 字段错误列表需要更多阅读时间
    return ms;
  }

  void _show(AppNotification n, {bool force = false}) {
    // force=true 时跳过 600ms 去重，用于必须让用户看到的关键提示
    // （如"请先审核"、"仓库未加载"等点击反馈，避免被前一条同文案吞掉）。
    if (!force) {
      final now = DateTime.now().millisecondsSinceEpoch;
      // 同 message + 同 kind 在 600ms 内合并去重，避免重复触发时的叠加。
      final hasRecent = state.any(
        (x) =>
            x.kind == n.kind &&
            x.message == n.message &&
            now - _tsOf(x.id) < _dedupeMs,
      );
      if (hasRecent) return;
    }

    final fresh = AppNotification(
      id: _newId(),
      kind: n.kind,
      title: n.title,
      message: n.message,
      durationMs: n.durationMs,
      fieldErrors: n.fieldErrors,
      icon: n.icon,
      onTap: n.onTap,
      onDismissed: n.onDismissed,
    );
    // state 同时承担「当前可见 + 等待显示」队列。宿主只渲染队首；
    // 队首自动/主动关闭后，下一项才会挂载并开始自己的停留计时。
    // 不能在这里 FIFO 丢弃：业务通知批量到达时，每一条都必须最终可见。
    state = <AppNotification>[...state, fresh];
  }

  /// 移除指定通知；返回是否确实从队列中移除。
  ///
  /// banner 用返回值区分「用户实际关闭」与「clear/外部移除后的迟到动画」，
  /// 从而保证 onDismissed 只触发一次且 clear 永不触发。
  bool dismiss(String id) {
    final next = state.where((n) => n.id != id).toList(growable: false);
    if (next.length == state.length) return false;
    state = next;
    return true;
  }

  void clear() {
    if (state.isNotEmpty) state = const <AppNotification>[];
  }

  void showSuccess(
    String message, {
    String? title,
    Duration? duration,
    bool force = false,
  }) => _show(
    AppNotification(
      id: '',
      kind: AppNotificationKind.success,
      title: title,
      message: message,
      durationMs:
          duration?.inMilliseconds ??
          _readMs(AppNotificationKind.success, message),
    ),
    force: force,
  );

  void showError(
    String message, {
    String? title,
    Duration? duration,
    List<ApiFieldError>? fieldErrors,
    bool force = false,
  }) => _show(
    AppNotification(
      id: '',
      kind: AppNotificationKind.error,
      title: title,
      message: message,
      durationMs:
          duration?.inMilliseconds ??
          _readMs(
            AppNotificationKind.error,
            message,
            hasFieldErrors: fieldErrors != null,
          ),
      fieldErrors: fieldErrors,
    ),
    force: force,
  );

  void showWarning(
    String message, {
    String? title,
    Duration? duration,
    bool force = false,
  }) => _show(
    AppNotification(
      id: '',
      kind: AppNotificationKind.warning,
      title: title,
      message: message,
      durationMs:
          duration?.inMilliseconds ??
          _readMs(AppNotificationKind.warning, message),
    ),
    force: force,
  );

  void showInfo(
    String message, {
    String? title,
    Duration? duration,
    bool force = false,
  }) => _show(
    AppNotification(
      id: '',
      kind: AppNotificationKind.info,
      title: title,
      message: message,
      durationMs:
          duration?.inMilliseconds ??
          _readMs(AppNotificationKind.info, message),
    ),
    force: force,
  );

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
    VoidCallback? onDismissed,
    bool force = false,
  }) => _show(
    AppNotification(
      id: '',
      kind: kind,
      title: title,
      message: message,
      durationMs: duration?.inMilliseconds ?? _readMs(kind, message),
      icon: icon,
      onTap: onTap,
      onDismissed: onDismissed,
    ),
    force: force,
  );
}

/// 全局 Provider。
final appNotificationProvider =
    NotifierProvider<AppNotificationService, List<AppNotification>>(
      AppNotificationService.new,
    );

/// BuildContext 便捷调用扩展。
extension AppNotificationContextX on BuildContext {
  AppNotificationService get _notifier => ProviderScope.containerOf(
    this,
    listen: false,
  ).read(appNotificationProvider.notifier);

  /// 显示顶部成功通知。
  void appSuccess(String message, {String? title, bool force = false}) =>
      _notifier.showSuccess(message, title: title, force: force);

  /// 显示顶部错误通知。
  void appError(
    String message, {
    String? title,
    List<ApiFieldError>? fieldErrors,
    bool force = false,
  }) => _notifier.showError(
    message,
    title: title,
    fieldErrors: fieldErrors,
    force: force,
  );

  /// 显示顶部警告通知。
  void appWarning(String message, {String? title, bool force = false}) =>
      _notifier.showWarning(message, title: title, force: force);

  /// 显示顶部信息通知。
  void appInfo(String message, {String? title, bool force = false}) =>
      _notifier.showInfo(message, title: title, force: force);

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
  const AppNotificationHost({super.key, this.useSafeArea = true});

  final bool useSafeArea;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(appNotificationProvider);
    if (list.isEmpty) return const SizedBox.shrink();
    // SafeArea 置于宿主层：状态栏留白整列只算一次（避免每条都加）。Column 用默认
    // crossAxisAlignment.center 居中各条卡片——卡片本身收缩到内容宽度（≤720），
    // 故卡片两侧空白在命中测试里不命中任何手势层，点击直接穿透到下方页面。
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _AppNotificationBanner(
          key: ValueKey(list.first.id),
          notification: list.first,
        ),
      ],
    );
    const insets = EdgeInsets.fromLTRB(12, 6, 12, 0);
    return useSafeArea
        ? SafeArea(bottom: false, minimum: insets, child: content)
        : Padding(padding: insets, child: content);
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

class _AppNotificationBannerState extends ConsumerState<_AppNotificationBanner>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _ctrl;
  Timer? _autoDismissTimer;
  bool _dismissing = false;
  bool _actionTriggered = false;
  bool _dismissCallbackTriggered = false;
  bool _animationStarted = false;
  // 鼠标悬停（桌面端）暂停自动消失，让用户读得完再走；触摸端无悬停事件，恒 false。
  bool _hovering = false;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    WidgetsBinding.instance.addObserver(this);
    _scheduleAutoDismiss();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_animationStarted) return;
    _animationStarted = true;
    if (MediaQuery.maybeOf(context)?.disableAnimations ?? false) {
      _ctrl.value = 1;
    } else {
      _ctrl.forward();
    }
  }

  @override
  void dispose() {
    _autoDismissTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _ctrl.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _scheduleAutoDismiss();
    } else {
      _autoDismissTimer?.cancel();
      _autoDismissTimer = null;
    }
  }

  /// 重排自动消失计时：悬停中或正在收起则暂停，否则按停留时长重新计时。
  void _scheduleAutoDismiss() {
    _autoDismissTimer?.cancel();
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (_hovering ||
        _dismissing ||
        (lifecycle != null && lifecycle != AppLifecycleState.resumed)) {
      return;
    }
    _autoDismissTimer = Timer(
      Duration(milliseconds: widget.notification.durationMs),
      _dismiss,
    );
  }

  void _setHovering(bool value) {
    if (_hovering == value) return;
    _hovering = value;
    _scheduleAutoDismiss();
  }

  Future<void> _dismiss() async {
    if (_dismissing) return;
    _dismissing = true;
    _autoDismissTimer?.cancel();
    if (MediaQuery.maybeOf(context)?.disableAnimations ?? false) {
      _ctrl.value = 0;
    } else {
      await _ctrl.reverse();
    }
    if (!mounted) return;
    _removeAndNotifyDismissed();
  }

  Future<bool> _confirmSwipeDismiss(DismissDirection _) async {
    if (_dismissing) return false;
    _dismissing = true;
    _autoDismissTimer?.cancel();
    return true;
  }

  void _handleSwipeDismissed(DismissDirection _) {
    if (!mounted) return;
    _removeAndNotifyDismissed();
  }

  void _removeAndNotifyDismissed() {
    final removed = ref
        .read(appNotificationProvider.notifier)
        .dismiss(widget.notification.id);
    if (!removed || _dismissCallbackTriggered) return;
    _dismissCallbackTriggered = true;
    widget.notification.onDismissed?.call();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final n = widget.notification;
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final hasOverlay = Overlay.maybeOf(context) != null;
    // 柔和容器色（与连接恢复横幅同语言）。注意：本主题 primary/secondary/
    // tertiaryContainer 同为 teal，success 与 warning 同底色，靠语义图标区分。
    // info 不再用中性灰 surfaceContainerHighest——灰底 + hover InkWell 罩会把整条
    // 刷成一片灰长条（用户误以为「灰色面板」）；改用浅蓝/深蓝容器色（见 UtenColors）。
    final (bg, fg, icon) = switch (n.kind) {
      AppNotificationKind.success => (
        scheme.primaryContainer,
        scheme.onPrimaryContainer,
        Icons.check_circle_outline_rounded,
      ),
      AppNotificationKind.error => (
        scheme.errorContainer,
        scheme.onErrorContainer,
        Icons.error_outline_rounded,
      ),
      AppNotificationKind.warning => (
        scheme.tertiaryContainer,
        scheme.onTertiaryContainer,
        Icons.warning_amber_rounded,
      ),
      AppNotificationKind.info => (
        isDark ? UtenColors.infoContainerDark : UtenColors.infoContainer,
        isDark ? UtenColors.onInfoContainerDark : UtenColors.onInfoContainer,
        Icons.info_outline_rounded,
      ),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: MouseRegion(
        // 鼠标移入暂停自动消失（读得完再走），移出重新计时。触摸端不触发。
        onEnter: (_) => _setHovering(true),
        onExit: (_) => _setHovering(false),
        child: FadeTransition(
          key: ValueKey('app-notification-fade-${n.id}'),
          opacity: _ctrl,
          child: SlideTransition(
            position:
                Tween<Offset>(
                  begin: const Offset(0, -0.2),
                  end: Offset.zero,
                ).animate(
                  CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic),
                ),
            child: Dismissible(
              key: ValueKey('dismiss-${n.id}'),
              confirmDismiss: _confirmSwipeDismiss,
              onDismissed: _handleSwipeDismissed,
              // 视觉外壳与连接横幅共用 UtenTopBannerCard（居中/maxWidth720/圆角14/
              // elevation4/柔和容器色）。语义默认 explicitChildNodes（省略
              // semanticLabel）让标题/正文被分别朗读。crossAxisAlignment 走默认
              // center，图标/关闭钮与正文上下居中（与连接横幅一致；IconButton
              // 至少 48dp 高，center 才不会让内容贴顶）。
              // 带跳转动作的弹条：点击先执行动作再关闭（微信式点消息进详情）
              child: UtenTopBannerCard(
                background: bg,
                foreground: fg,
                icon: n.icon ?? icon,
                onTap: n.onTap == null
                    ? _dismiss
                    : () {
                        if (_actionTriggered || _dismissing) return;
                        _actionTriggered = true;
                        try {
                          n.onTap!();
                        } finally {
                          _dismiss();
                        }
                      },
                content: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (n.title != null && n.title!.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: Text(
                          n.title!,
                          maxLines: n.onTap == null ? null : 2,
                          overflow: n.onTap == null
                              ? TextOverflow.clip
                              : TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: fg,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    Text(
                      n.message,
                      maxLines: n.onTap == null ? null : 3,
                      overflow: n.onTap == null
                          ? TextOverflow.clip
                          : TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(color: fg),
                    ),
                    if (n.fieldErrors != null && n.fieldErrors!.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          '涉及字段：${n.fieldErrors!.map((f) => f.field).where((s) => s.isNotEmpty).join(', ')}',
                          maxLines: n.onTap == null ? null : 2,
                          overflow: n.onTap == null
                              ? TextOverflow.clip
                              : TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: fg.withValues(alpha: 0.85),
                          ),
                        ),
                      ),
                  ],
                ),
                trailing: IconButton(
                  icon: Icon(
                    Icons.close_rounded,
                    color: fg,
                    size: 18,
                    semanticLabel: '关闭通知',
                  ),
                  onPressed: _dismiss,
                  tooltip: hasOverlay ? '关闭通知' : null,
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                ),
              ), // UtenTopBannerCard
            ), // Dismissible
          ), // SlideTransition
        ), // FadeTransition
      ), // MouseRegion（悬停暂停）
    ); // Padding
  }
}
