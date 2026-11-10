import 'dart:async';
import 'dart:math' as math;

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/l10n/gen/app_localizations.dart';
import '../../core/theme/uten_anim.dart';
import '../../core/theme/uten_tokens.dart';
import '../buttons/uten_button.dart';
import 'uten_dialog.dart';
import 'uten_motion.dart';

/// 进度详情里的文件大小(B / KB / MB / GB, 一位小数); 全项目进度文案共用。
String formatUtenBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB'];
  var value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(1)} ${units[unit]}';
}

/// 一次汇报的不可变进度状态。
///
/// [fraction] 为 null 表示「总量未知」的不确定进度(扫动条, 不显示百分比);
/// 有值时弹窗显示大号百分比数字。[done]/[total] 保留原始计数供详情行展示。
@immutable
class UtenProgressState {
  const UtenProgressState({
    required this.status,
    this.detail,
    this.fraction,
    this.done,
    this.total,
  });

  /// 当前阶段的一句话(如「正在生成文件」「正在下载」)。
  final String status;

  /// 详情行(如「3,200 / 35,763 行」「12.4 MB / 38.1 MB」), 空则不显示。
  final String? detail;

  /// 0..1 的完成比例; null 表示不确定进度。
  final double? fraction;

  /// 计数型进度的原始值(与 fraction 同时维护, 详情行用)。
  final int? done;
  final int? total;
}

/// 运行中的工作向进度弹窗汇报进度的会话。
///
/// 调用方在 [showUtenProgress.action] 里拿到它, 随时调用 [stage] / [percent] /
/// [count] / [detail]; 弹窗负责渲染。用户点「取消」后 [isCancelled] 立即为
/// true、[whenCancelled] 完成——调用方应把 CancelToken 挂到网络请求上让传输
/// 真正停下, 而不是只关弹窗。
class UtenProgressSession {
  UtenProgressSession._(UtenProgressState initial)
    : _state = ValueNotifier(initial);

  final ValueNotifier<UtenProgressState> _state;
  final Completer<void> _cancelled = Completer<void>();
  bool _userCancelled = false;

  /// 弹窗与内嵌视图监听状态变化的入口。
  ValueListenable<UtenProgressState> get states => _state;

  /// 当前状态快照。
  UtenProgressState get state => _state.value;

  /// 用户是否已经取消。
  bool get isCancelled => _userCancelled;

  /// 用户取消时完成的 Future; 挂网络 CancelToken 用 `await` 或 `then` 皆可。
  Future<void> get whenCancelled => _cancelled.future;

  /// 汇报一个总量未知的阶段: 扫动条 + 阶段文案, 不显示百分比。
  void stage(String status, {String? detail}) {
    _state.value = UtenProgressState(status: status, detail: detail);
  }

  /// 汇报 0..1 的完成比例(越界自动收敛), 显示百分比。
  void percent(double value, {String? status, String? detail}) {
    _state.value = UtenProgressState(
      status: status ?? _state.value.status,
      detail: detail ?? _state.value.detail,
      fraction: value.clamp(0.0, 1.0).toDouble(),
    );
  }

  /// 汇报计数型进度(done/total), 显示百分比与「done / total」详情。
  void count(int done, int total, {String? status, String? detail}) {
    if (total <= 0) {
      stage(status ?? _state.value.status, detail: detail);
      return;
    }
    final safeDone = done.clamp(0, total).toInt();
    _state.value = UtenProgressState(
      status: status ?? _state.value.status,
      detail: detail ?? '$safeDone / $total',
      fraction: safeDone / total,
      done: safeDone,
      total: total,
    );
  }

  /// 只更新详情行, 保留其余状态。
  void detail(String? detail) {
    final current = _state.value;
    _state.value = UtenProgressState(
      status: current.status,
      detail: detail,
      fraction: current.fraction,
      done: current.done,
      total: current.total,
    );
  }

  /// 汇报字节传输(可直接接 Dio 的 onReceiveProgress)。总量未知([total] ≤ 0,
  /// 服务端没给 Content-Length)时保持扫动条, 只在详情行显示已收大小。
  void bytes(int received, int total, {required String status}) {
    if (total > 0) {
      percent(
        received / total,
        status: status,
        detail: '${formatUtenBytes(received)} / ${formatUtenBytes(total)}',
      );
    } else {
      stage(status, detail: formatUtenBytes(received));
    }
  }

  /// Dio onReceiveProgress 回调的现成适配: 第一字节到达前保持当前阶段
  /// (服务端还在生成文件), 之后切到 [status] 汇报下载百分比。
  void Function(int received, int total) receiving(String status) =>
      (received, total) => bytes(received, total, status: status);

  void _cancel() {
    if (_userCancelled) return;
    _userCancelled = true;
    _cancelled.complete();
  }
}

/// 通用进度弹窗(组件文档: docs/02-组件库/通用进度弹窗.md)。
///
/// 「取消」的语义。
enum UtenProgressCancel {
  /// 读取 / 下载类: 立即关闭弹窗、返回 null, 调用方把 CancelToken 挂到请求上让
  /// 传输停下; 取消后 action 的任何结果或异常都被吞掉。
  immediate,

  /// 写入类批量(批量删除 / 下单 / 审批…): 不中断进行中的那一项(中断写请求会让
  /// 结果变成「未知提交」), 弹窗改为「正在停止」并禁用按钮, action 看到
  /// `isCancelled` 后不再开始下一项; action 结束后照常返回真实结果(含已完成的
  /// 部分), 调用方据此刷新与汇报, 不重放、不当作全部失败。
  afterCurrent,
}

/// 全项目导出、下载、批量下单/审批等长等待的统一外观: 大号百分比 + 圆角进度条
/// + 已用时间 + 「取消」。总量未知时显示扫动条, 绝不伪造百分比。样式只在本
/// 文件([UtenProgressBar] / [_figure] / 布局)里维护, 以后整体换风格只改这里。
///
/// 返回值: 成功返回 action 的结果; [UtenProgressCancel.immediate] 模式下用户取消
/// 返回 null(取消后 action 的任何后续结果或异常都被吞掉, 调用方不必再弹提示);
/// [UtenProgressCancel.afterCurrent] 模式下取消后仍返回 action 的真实结果。
/// 失败时关闭弹窗并把异常原样抛给调用方。
///
/// 挂在根导航上, 不要与 UtenBusyOverlay 同时显示(遮罩会盖住它); 确实需要在
/// 遮罩之上时先用 `UtenBusyOverlay.yieldWhile` 让位。
///
/// 不提供副标题: 界面规范不写独立成行的说明句, 阶段与计数走 [initialStatus] /
/// [initialDetail] 和会话汇报。
///
/// [isCurrent] / [invalidation] 与 `runUtenBlockingTask` 同口径: 身份、账号或
/// 服务器切换使 [invalidation] 发出通知且 [isCurrent] 为 false 时, 弹窗按取消
/// 收尾(会话 whenCancelled 完成, 网络请求随之停下)。
///
/// [onRouteOpened] 在弹窗路由推入后回调(重建时回调最新路由)。用 `route.isCurrent`
/// 之类「页面在顶才有效」响应守卫的调用方, 用它登记弹窗路由——自己推起的进度
/// 弹窗压顶不算「其他页面」, 但别的页面推到弹窗之上时路由不再是 current, 守卫
/// 照常生效(同 account 工作台 `_batchDialogs` 口径)。
Future<T?> showUtenProgress<T>(
  BuildContext context, {
  required String title,
  IconData? icon,
  String? initialStatus,
  String? initialDetail,
  bool cancellable = true,
  UtenProgressCancel cancelMode = UtenProgressCancel.immediate,
  bool showElapsed = true,
  Duration slowHintAfter = const Duration(seconds: 30),
  bool Function()? isCurrent,
  Listenable? invalidation,
  void Function(ModalRoute<dynamic> route)? onRouteOpened,
  required Future<T> Function(UtenProgressSession progress) action,
}) {
  final session = UtenProgressSession._(
    UtenProgressState(status: initialStatus ?? title, detail: initialDetail),
  );
  // action 在调用方的 Zone 里执行: `AuthenticatedRequestScope.run` /
  // `BusinessPrecisionTransport` 都靠 Zone.current 传递, 弹窗的 post-frame
  // 启动不能把它们丢掉, 否则网络段会脱离身份栅栏。
  final callerZone = Zone.current;
  return showDialog<_Outcome<T>>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) {
      final route = ModalRoute.of(dialogContext);
      if (route != null) onRouteOpened?.call(route);
      return _UtenProgressDialog<T>(
        title: title,
        icon: icon,
        cancellable: cancellable,
        cancelMode: cancelMode,
        showElapsed: showElapsed,
        slowHintAfter: slowHintAfter,
        isCurrent: isCurrent,
        invalidation: invalidation,
        session: session,
        callerZone: callerZone,
        action: action,
      );
    },
  ).then<T?>((outcome) {
    if (outcome == null) return null;
    if (outcome.error != null) {
      Error.throwWithStackTrace(
        outcome.error!,
        outcome.stackTrace ?? StackTrace.current,
      );
    }
    return outcome.value;
  });
}

class _Outcome<T> {
  const _Outcome.value(this.value) : error = null, stackTrace = null;
  const _Outcome.failure(Object this.error, this.stackTrace) : value = null;

  final T? value;
  final Object? error;
  final StackTrace? stackTrace;
}

class _UtenProgressDialog<T> extends StatefulWidget {
  const _UtenProgressDialog({
    required this.title,
    required this.icon,
    required this.cancellable,
    required this.cancelMode,
    required this.showElapsed,
    required this.slowHintAfter,
    required this.isCurrent,
    required this.invalidation,
    required this.session,
    required this.callerZone,
    required this.action,
  });

  final String title;
  final IconData? icon;
  final bool cancellable;
  final UtenProgressCancel cancelMode;
  final bool showElapsed;
  final Duration slowHintAfter;
  final bool Function()? isCurrent;
  final Listenable? invalidation;
  final UtenProgressSession session;
  final Zone callerZone;
  final Future<T> Function(UtenProgressSession progress) action;

  @override
  State<_UtenProgressDialog<T>> createState() => _UtenProgressDialogState<T>();
}

class _UtenProgressDialogState<T> extends State<_UtenProgressDialog<T>> {
  late final DateTime _startedAt;
  Timer? _ticker;
  Duration _elapsed = Duration.zero;
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    _startedAt = clock.now();
    if (widget.showElapsed) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted || _closed) return;
        setState(() => _elapsed = clock.now().difference(_startedAt));
      });
    }
    widget.invalidation?.addListener(_retireIfStale);
    // 帧后再启动: action 可能同步汇报进度, 构建期不能 setState。
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    widget.invalidation?.removeListener(_retireIfStale);
    // 弹窗被外力移除(如整页重建)时也通知工作停下。
    if (!_closed) widget.session._cancel();
    super.dispose();
  }

  /// 身份/账号/服务器切换: 按取消收尾。通知可能在构建期发出, 推迟到微任务。
  void _retireIfStale() {
    scheduleMicrotask(() {
      final isCurrent = widget.isCurrent;
      if (!mounted || _closed || (isCurrent != null && isCurrent())) return;
      _cancel();
    });
  }

  void _start() {
    if (!mounted || _closed) return;
    if (widget.isCurrent != null && !widget.isCurrent!()) {
      _cancel();
      return;
    }
    final Future<T> future;
    try {
      // 回到调用方的 Zone 启动: 见 showUtenProgress 里的 callerZone 注释。
      future = widget.callerZone.run(() => widget.action(widget.session));
    } catch (error, stackTrace) {
      _close(_Outcome<T>.failure(error, stackTrace));
      return;
    }
    future.then(
      (value) {
        if (!mounted || _closed) return;
        // 立即取消模式: 用户已取消则结果不再呈现; 「完成当前项」模式照常交回真实结果。
        _close(
          widget.session.isCancelled && !_drains
              ? null
              : _Outcome<T>.value(value),
        );
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!mounted || _closed) return;
        // 取消引发的异常(如 Dio cancel)不再打扰用户; 写入类的真实失败照常抛出。
        if (widget.session.isCancelled && !_drains) {
          _close(null);
          return;
        }
        _close(_Outcome<T>.failure(error, stackTrace));
      },
    );
  }

  bool get _drains => widget.cancelMode == UtenProgressCancel.afterCurrent;

  void _cancel() {
    if (_closed) return;
    if (_drains) {
      // 写入类: 不中断进行中的那一项, 停在当前项完成后; 弹窗保留到 action 结束。
      if (widget.session.isCancelled) return;
      widget.session._cancel();
      if (mounted) setState(() {});
      return;
    }
    widget.session._cancel();
    _close(null);
  }

  /// 只关掉本弹窗自己: 结束时上面可能正压着别的弹窗(如重新登录框), 直接 pop
  /// 会关错。本弹窗不在最上层时按路由精确移除, 结果照样交给调用方。
  void _close(_Outcome<T>? outcome) {
    if (_closed) return;
    _closed = true;
    _ticker?.cancel();
    final navigator = Navigator.of(context);
    final route = ModalRoute.of(context);
    if (route == null || route.isCurrent) {
      navigator.pop(outcome);
    } else if (route.isActive) {
      navigator.removeRoute(route, outcome);
    }
  }

  @override
  Widget build(BuildContext context) {
    // 基础组件不强依赖本地化代理(独立窗口/测试宿主可能没有), 缺省回落中文。
    final l10n =
        Localizations.of<AppLocalizations>(context, AppLocalizations) ??
        lookupAppLocalizations(const Locale('zh'));
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && widget.cancellable) _cancel();
      },
      child: UtenDialogFrame(
        insetPadding: const EdgeInsets.all(UtenSpacing.s24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                UtenDialogHeader(
                  title: Text(widget.title),
                  icon: widget.icon,
                  showCloseButton: widget.cancellable,
                  onClose: _cancel,
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 4, 24, 20),
                  child: ValueListenableBuilder<UtenProgressState>(
                    valueListenable: widget.session.states,
                    builder: (context, state, _) => Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _figure(context, state),
                        const SizedBox(height: UtenSpacing.s8),
                        UtenProgressBar(value: state.fraction),
                        if (state.detail != null &&
                            state.detail!.isNotEmpty) ...[
                          const SizedBox(height: UtenSpacing.s8),
                          Text(
                            state.detail!,
                            key: const ValueKey('uten-progress-detail'),
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                  fontFeatures: const [
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                          ),
                        ],
                        if (widget.showElapsed) ...[
                          const SizedBox(height: UtenSpacing.s12),
                          Row(
                            children: [
                              Icon(
                                Icons.schedule_rounded,
                                size: 16,
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                              const SizedBox(width: UtenSpacing.s6),
                              Expanded(
                                child: Text(
                                  l10n.progressElapsed(
                                    _formatElapsed(_elapsed),
                                  ),
                                  key: const ValueKey('uten-progress-elapsed'),
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.onSurfaceVariant,
                                        fontFeatures: const [
                                          FontFeature.tabularFigures(),
                                        ],
                                      ),
                                ),
                              ),
                            ],
                          ),
                        ],
                        if (_elapsed >= widget.slowHintAfter &&
                            !widget.session.isCancelled) ...[
                          const SizedBox(height: UtenSpacing.s12),
                          _HintLine(text: l10n.progressSlowHint),
                        ],
                        if (_drains && widget.session.isCancelled) ...[
                          const SizedBox(height: UtenSpacing.s12),
                          _HintLine(
                            key: const ValueKey('uten-progress-stopping'),
                            text: l10n.progressStopping,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                if (widget.cancellable)
                  UtenDialogActions(
                    children: [
                      UtenButton(
                        key: const ValueKey('uten-progress-cancel'),
                        type: UtenButtonType.ghost,
                        // 适老化触控基线 48。
                        height: 48,
                        icon: Icons.close_rounded,
                        // 「完成当前项」模式: 点过一次后等待当前项结束, 不可重复点。
                        onPressed: _drains && widget.session.isCancelled
                            ? null
                            : _cancel,
                        child: Text(
                          _drains && widget.session.isCancelled
                              ? l10n.progressStoppingButton
                              : l10n.progressCancel,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 大号百分比(确定进度)或阶段标题(不确定进度)。
  ///
  /// 总量未知时绝不显示假数字——用标题顶住版面, 靠扫动条与已用时间表达「在动」。
  Widget _figure(BuildContext context, UtenProgressState state) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fraction = state.fraction;
    final heading = Semantics(
      liveRegion: true,
      label: fraction == null
          ? state.status
          : '${state.status} ${(fraction * 100).round()}%',
      child: ExcludeSemantics(
        child: fraction == null
            ? Text(
                state.status,
                key: const ValueKey('uten-progress-status'),
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface,
                ),
              )
            : Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  _AnimatedPercent(value: fraction),
                  const SizedBox(width: UtenSpacing.s4),
                  Text(
                    '%',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: UtenSpacing.s12),
                  Expanded(
                    child: Text(
                      state.status,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
    return heading;
  }

  static String _formatElapsed(Duration elapsed) {
    final minutes = elapsed.inMinutes;
    final seconds = elapsed.inSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}

/// 大号百分比数字; 允许动画时随进度平滑跳动(等宽数字, 不抖宽)。
class _AnimatedPercent extends StatelessWidget {
  const _AnimatedPercent({required this.value});

  final double value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget figure(int percent) => Text(
      '$percent',
      key: const ValueKey('uten-progress-percent'),
      style: theme.textTheme.headlineMedium?.copyWith(
        fontWeight: FontWeight.w700,
        color: theme.colorScheme.primary,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
    if (utenMotionDurationOf(context, UtenAnim.fast) == Duration.zero) {
      return figure((value.clamp(0.0, 1.0) * 100).round());
    }
    return TweenAnimationBuilder<double>(
      tween: Tween(end: value.clamp(0.0, 1.0).toDouble()),
      duration: UtenAnim.slow,
      curve: UtenAnim.standard,
      builder: (_, v, _) => figure((v * 100).round()),
    );
  }
}

/// 全项目唯一的进度条样式: 细长圆角, 有值时填充, 无值([value] 为 null)时缓慢
/// 扫动。省电档或系统「减少动画」时扫动退化为静止短条, 靠数字/时间表达活性。
///
/// 弹窗与内嵌(下载页等)共用; 以后换进度条外观只改这里。
class UtenProgressBar extends StatelessWidget {
  const UtenProgressBar({super.key, this.value, this.height = 6});

  /// 0..1; null 表示不确定进度。
  final double? value;
  final double height;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final track = scheme.primaryContainer.withValues(alpha: 0.5);
    if (value != null) {
      final clamped = value!.clamp(0.0, 1.0).toDouble();
      Widget bar(double v) => ClipRRect(
        borderRadius: UtenRadius.pillAll,
        child: LinearProgressIndicator(
          value: v,
          minHeight: height,
          color: scheme.primary,
          backgroundColor: track,
        ),
      );
      if (utenMotionDurationOf(context, UtenAnim.fast) == Duration.zero) {
        return bar(clamped);
      }
      return TweenAnimationBuilder<double>(
        tween: Tween(end: clamped),
        duration: UtenAnim.slow,
        curve: UtenAnim.standard,
        builder: (_, v, _) => bar(v),
      );
    }
    return _SweepBar(height: height, color: scheme.primary, track: track);
  }
}

/// 全项目唯一的圆环进度样式: 细描边圆环按 [progress](0..1) 画弧, 圆头收笔。
/// 静态呈现(旋转等外层动效由调用方自己的动画语义决定); 以后换圆环外观只改这里。
class UtenProgressRing extends StatelessWidget {
  const UtenProgressRing({
    super.key,
    required this.progress,
    required this.accent,
    required this.track,
    this.strokeWidth = 2.5,
  });

  /// 0..1, 越界自动收敛。
  final double progress;
  final Color accent;
  final Color track;
  final double strokeWidth;

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _UtenRingPainter(
      accent: accent,
      track: track,
      progress: progress,
      strokeWidth: strokeWidth,
    ),
  );
}

class _UtenRingPainter extends CustomPainter {
  const _UtenRingPainter({
    required this.accent,
    required this.track,
    required this.progress,
    required this.strokeWidth,
  });

  final Color accent, track;
  final double progress;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(2);
    final pen = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
    canvas.drawOval(rect, pen..color = track);
    canvas.drawArc(
      rect,
      -math.pi / 2,
      2 * math.pi * progress.clamp(0.0, 1.0),
      false,
      pen..color = accent,
    );
  }

  @override
  bool shouldRepaint(covariant _UtenRingPainter oldDelegate) =>
      accent != oldDelegate.accent ||
      track != oldDelegate.track ||
      progress != oldDelegate.progress ||
      strokeWidth != oldDelegate.strokeWidth;
}

/// 不确定进度的扫动短条; 系统要求减少动画/省电档时静止。
class _SweepBar extends StatefulWidget {
  const _SweepBar({
    required this.height,
    required this.color,
    required this.track,
  });

  final double height;
  final Color color;
  final Color track;

  @override
  State<_SweepBar> createState() => _SweepBarState();
}

class _SweepBarState extends State<_SweepBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  void _sync() {
    final allowed =
        utenMotionDurationOf(context, const Duration(milliseconds: 1)) !=
        Duration.zero;
    if (allowed) {
      if (!_controller.isAnimating) _controller.repeat();
    } else if (_controller.isAnimating) {
      _controller.stop(canceled: false);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const band = 0.28;
    return ClipRRect(
      borderRadius: UtenRadius.pillAll,
      child: SizedBox(
        height: widget.height,
        child: Stack(
          children: [
            Positioned.fill(child: ColoredBox(color: widget.track)),
            Positioned.fill(
              child: AnimatedBuilder(
                animation: _controller,
                builder: (context, _) {
                  final t = Curves.easeInOutCubic.transform(_controller.value);
                  return Align(
                    alignment: Alignment(-1.0 + 2.0 * t, 0.0),
                    child: FractionallySizedBox(
                      widthFactor: band,
                      heightFactor: 1,
                      child: ColoredBox(color: widget.color),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HintLine extends StatelessWidget {
  const _HintLine({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s12,
        vertical: UtenSpacing.s8,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.35),
        borderRadius: UtenRadius.controlAll,
      ),
      child: Row(
        children: [
          Icon(
            Icons.hourglass_top_rounded,
            size: 16,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
