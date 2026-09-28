import 'dart:async';
import 'dart:math' as math;

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../components/buttons/uten_button.dart';
import '../../core/l10n/gen/app_localizations.dart';
import '../../core/performance/performance_tier.dart';
import '../../core/theme/uten_anim.dart';
import '../../core/theme/uten_colors.dart';
import '../../core/theme/uten_tokens.dart';
import '../providers/performance_provider.dart';
import 'ai_job_models.dart';
import 'ai_job_runner.dart';

/// 进度弹窗里的一步。[serverStages] 是这一步覆盖的服务端阶段键(见 [AiJobSnapshot.stage])。
///
/// 覆盖客户端上传的那一步应把 [AiJobSnapshot.uploadingStage] 写进 [serverStages]
/// (或直接用它做 [key]); 上传完成(拿到作业 id)后弹窗会自动走到下一步。
class AiProgressStage {
  const AiProgressStage({
    required this.key,
    required this.label,
    this.serverStages = const [],
  });

  final String key;
  final String label;
  final List<String> serverStages;

  bool covers(String? stage) =>
      stage != null && (key == stage || serverStages.contains(stage));
}

/// 一次在弹窗里运行的作业: 弹窗把进度回调与取消令牌交给它。
typedef AiProgressTask =
    Future<AiJobSnapshot> Function(
      AiJobProgressCallback onProgress,
      AiJobCancelToken cancelToken,
    );

/// 公共 AI 进度弹窗(组件文档: docs/02-组件库/AI任务进度弹窗.md)。
///
/// 模态卡片, 显示分步进度、已用时间与「取消」。返回终态快照;
/// 用户取消返回 null; 作业失败时关闭弹窗并把 [AiJobFailure] 抛给调用方
/// (提交被拒等传输错误原样抛出 ApiException)。
///
/// 弹窗挂在根导航上, 不能与 UtenBusyOverlay 同时显示(遮罩会盖住它)。
Future<AiJobSnapshot?> showAiProgressDialog(
  BuildContext context, {
  required String title,
  String? subtitle,
  required List<AiProgressStage> stages,
  required AiProgressTask task,
}) async {
  final outcome = await showDialog<_AiProgressOutcome>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _AiProgressDialog(
      title: title,
      subtitle: subtitle,
      stages: stages,
      task: task,
    ),
  );
  if (outcome == null) return null;
  final error = outcome.error;
  if (error != null) {
    Error.throwWithStackTrace(error, outcome.stackTrace ?? StackTrace.current);
  }
  return outcome.snapshot;
}

/// 最常用的组合: 用 [runner] 提交 [request], 在进度弹窗里等到结果。
///
/// ```dart
/// final snapshot = await runAiJob(
///   context,
///   runner: ref.read(aiJobRunnerProvider),
///   request: AiJobRequest(kind: 'SALES_DOCUMENT_INTAKE', params: {...},
///       bytes: file.bytes!, fileName: file.name, contentType: mime),
///   title: '正在识别客户文件',
///   stages: const [
///     AiProgressStage(key: AiJobSnapshot.uploadingStage, label: '上传文件'),
///     AiProgressStage(key: 'READ', label: '读取表格', serverStages: ['READING']),
///   ],
/// );
/// if (snapshot == null) return; // 用户取消
/// ```
Future<AiJobSnapshot?> runAiJob(
  BuildContext context, {
  required AiJobRunner runner,
  required AiJobRequest request,
  required String title,
  String? subtitle,
  required List<AiProgressStage> stages,
}) => showAiProgressDialog(
  context,
  title: title,
  subtitle: subtitle,
  stages: stages,
  task: (onProgress, cancelToken) =>
      runner.run(request, onProgress: onProgress, cancelToken: cancelToken),
);

class _AiProgressOutcome {
  const _AiProgressOutcome.success(AiJobSnapshot this.snapshot)
    : error = null,
      stackTrace = null;

  const _AiProgressOutcome.failure(Object this.error, this.stackTrace)
    : snapshot = null;

  final AiJobSnapshot? snapshot;
  final Object? error;
  final StackTrace? stackTrace;
}

/// 等多久开始安慰用户「文件大要一两分钟」。
const _slowHintAfter = Duration(seconds: 30);

class _AiProgressDialog extends StatefulWidget {
  const _AiProgressDialog({
    required this.title,
    required this.subtitle,
    required this.stages,
    required this.task,
  });

  final String title;
  final String? subtitle;
  final List<AiProgressStage> stages;
  final AiProgressTask task;

  @override
  State<_AiProgressDialog> createState() => _AiProgressDialogState();
}

class _AiProgressDialogState extends State<_AiProgressDialog> {
  final _cancelToken = AiJobCancelToken();
  late final DateTime _startedAt;
  Timer? _ticker;
  Duration _elapsed = Duration.zero;
  AiJobSnapshot? _snapshot;
  int _current = 0;
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    _startedAt = clock.now();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _closed) return;
      setState(() => _elapsed = clock.now().difference(_startedAt));
    });
    // 帧后再启动: 作业可能同步回调进度, 构建期不能 setState。
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    // 弹窗被外力移除(如整页重建)时也通知作业停下。
    if (!_closed) _cancelToken.cancel();
    super.dispose();
  }

  void _start() {
    if (!mounted || _closed) return;
    final Future<AiJobSnapshot> future;
    try {
      future = widget.task(_onProgress, _cancelToken);
    } catch (error, stackTrace) {
      _close(_AiProgressOutcome.failure(error, stackTrace));
      return;
    }
    future.then(
      (snapshot) {
        if (!mounted || _closed) return;
        _close(
          _cancelToken.isCancelled
              ? null
              : _AiProgressOutcome.success(snapshot),
        );
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!mounted || _closed) return;
        if (_cancelToken.isCancelled ||
            (error is AiJobFailure && error.isCancelled)) {
          _close(null);
          return;
        }
        _close(_AiProgressOutcome.failure(_localized(error), stackTrace));
      },
    );
  }

  /// 客户端自己判定的失败与兜底文案换成当前语言; 服务端给的原因原样保留。
  Object _localized(Object error) {
    if (error is! AiJobFailure) return error;
    final l10n = AppLocalizations.of(context);
    final message = switch (error.code) {
      AiJobFailure.codeClientTimeout => l10n.aiJobTimeout,
      AiJobFailure.codeJobGone => l10n.aiJobGone,
      _ when error.clientMessage => l10n.aiJobFailedGeneric,
      _ => null,
    };
    return message == null
        ? error
        : AiJobFailure(
            message: message,
            code: error.code,
            snapshot: error.snapshot,
            clientMessage: error.clientMessage,
          );
  }

  void _onProgress(AiJobSnapshot snapshot) {
    if (!mounted || _closed) return;
    setState(() {
      _snapshot = snapshot;
      _current = _nextStageIndex(snapshot);
    });
  }

  /// 阶段只进不退: 服务端未登记的阶段键保持当前一步。
  int _nextStageIndex(AiJobSnapshot snapshot) {
    final stages = widget.stages;
    if (stages.isEmpty) return 0;
    var next = _current;
    final matched = stages.indexWhere((stage) => stage.covers(snapshot.stage));
    if (matched > next) next = matched;
    if (snapshot.id.isNotEmpty) {
      // 拿到作业 id 就说明文件已传完。
      final upload = stages.indexWhere(
        (stage) => stage.covers(AiJobSnapshot.uploadingStage),
      );
      if (upload >= 0 && next <= upload) {
        next = math.min(upload + 1, stages.length - 1);
      }
    }
    return next;
  }

  void _cancel() {
    if (_closed) return;
    _cancelToken.cancel();
    _close(null);
  }

  /// 只关掉本弹窗自己: 作业结束时上面可能正压着别的弹窗(如会话过期后的重新登录框),
  /// 直接 pop 会关错。本弹窗不在最上层时按路由精确移除, 结果照样交给调用方。
  void _close(_AiProgressOutcome? outcome) {
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

  double _progressValue() {
    final stages = widget.stages;
    final serverProgress = (_snapshot?.progress ?? 0).clamp(0, 100) / 100;
    final stageProgress = stages.isEmpty ? 0.0 : _current / stages.length;
    // 至少露出一点进度, 让人一眼看出「在动」。
    return math.max(0.04, math.max(serverProgress, stageProgress));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final snapshot = _snapshot;
    final queued =
        snapshot != null &&
        snapshot.id.isNotEmpty &&
        snapshot.status == AiJobStatus.pending;
    final slow = _elapsed >= _slowHintAfter;
    final currentLabel = widget.stages.isEmpty
        ? widget.title
        : widget.stages[_current].label;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _cancel();
      },
      child: Dialog(
        insetPadding: const EdgeInsets.all(UtenSpacing.s24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(UtenSpacing.s24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const AiSparkleBadge(),
                    const SizedBox(width: UtenSpacing.s16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.title,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          if (widget.subtitle != null) ...[
                            const SizedBox(height: UtenSpacing.s4),
                            Text(
                              widget.subtitle!,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: UtenSpacing.s20),
                _AnimatedProgressBar(value: _progressValue()),
                const SizedBox(height: UtenSpacing.s16),
                Semantics(
                  liveRegion: true,
                  label: currentLabel,
                  child: ExcludeSemantics(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (var i = 0; i < widget.stages.length; i++)
                          _StageRow(
                            key: ValueKey('ai-progress-stage-$i'),
                            label: widget.stages[i].label,
                            state: i < _current
                                ? _StageState.done
                                : i == _current
                                ? _StageState.current
                                : _StageState.pending,
                            isLast: i == widget.stages.length - 1,
                          ),
                      ],
                    ),
                  ),
                ),
                if (queued || slow) ...[
                  const SizedBox(height: UtenSpacing.s12),
                  _HintLine(
                    text: queued ? l10n.aiJobQueued : l10n.aiJobSlowHint,
                  ),
                ],
                const SizedBox(height: UtenSpacing.s20),
                Row(
                  children: [
                    Icon(
                      Icons.schedule_rounded,
                      size: 16,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: UtenSpacing.s6),
                    Expanded(
                      child: Text(
                        l10n.aiJobElapsed(_formatElapsed(_elapsed)),
                        key: const ValueKey('ai-progress-elapsed'),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                    UtenButton(
                      key: const ValueKey('ai-progress-cancel'),
                      type: UtenButtonType.ghost,
                      // 适老化触控基线 48。
                      height: 48,
                      icon: Icons.close_rounded,
                      onPressed: _cancel,
                      child: Text(l10n.aiJobCancel),
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

  static String _formatElapsed(Duration elapsed) {
    final minutes = elapsed.inMinutes;
    final seconds = elapsed.inSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}

enum _StageState { done, current, pending }

/// 时间线式的一步: 左侧状态点(✓ / 转圈 / 空心圈) + 竖向连线, 右侧文字。
class _StageRow extends StatelessWidget {
  const _StageRow({
    super.key,
    required this.label,
    required this.state,
    required this.isLast,
  });

  final String label;
  final _StageState state;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final success = dark ? UtenColors.successOnDark : UtenColors.success;
    const dot = 24.0;
    final Widget indicator = switch (state) {
      _StageState.done => Container(
        width: dot,
        height: dot,
        decoration: BoxDecoration(color: success, shape: BoxShape.circle),
        child: Icon(Icons.check_rounded, size: 16, color: scheme.surface),
      ),
      _StageState.current => SizedBox(
        width: dot,
        height: dot,
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: CircularProgressIndicator(
            strokeWidth: 2.6,
            color: scheme.primary,
            // 底圈让「当前这一步」在转圈的任意瞬间都看得见。
            backgroundColor: scheme.primaryContainer,
          ),
        ),
      ),
      _StageState.pending => Container(
        width: dot,
        height: dot,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: scheme.outlineVariant, width: 2),
        ),
      ),
    };
    final textStyle = switch (state) {
      _StageState.done => theme.textTheme.bodyMedium?.copyWith(
        color: scheme.onSurfaceVariant,
      ),
      _StageState.current => theme.textTheme.bodyLarge?.copyWith(
        fontWeight: FontWeight.w600,
        color: scheme.onSurface,
      ),
      _StageState.pending => theme.textTheme.bodyMedium?.copyWith(
        color: scheme.outline,
      ),
    };
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: dot,
            child: Column(
              children: [
                indicator,
                if (!isLast)
                  Expanded(
                    child: Container(
                      width: 2,
                      margin: const EdgeInsets.symmetric(
                        vertical: UtenSpacing.s2,
                      ),
                      decoration: BoxDecoration(
                        color: state == _StageState.done
                            ? success.withValues(alpha: 0.5)
                            : scheme.outlineVariant,
                        borderRadius: UtenRadius.pillAll,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: UtenSpacing.s12),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(
                top: 2,
                bottom: isLast ? 0 : UtenSpacing.s16,
              ),
              child: Text(label, style: textStyle),
            ),
          ),
        ],
      ),
    );
  }
}

class _HintLine extends StatelessWidget {
  const _HintLine({required this.text});

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

/// 细长的圆角进度条; 允许动画时平滑前进, 省电档或系统「减少动画」时直接跳到位。
class _AnimatedProgressBar extends StatelessWidget {
  const _AnimatedProgressBar({required this.value});

  final double value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget bar(double v) => ClipRRect(
      borderRadius: UtenRadius.pillAll,
      child: LinearProgressIndicator(
        value: v,
        minHeight: 6,
        color: scheme.primary,
        backgroundColor: scheme.primaryContainer.withValues(alpha: 0.5),
      ),
    );
    if (!aiMotionAllowed(context)) return bar(value);
    return TweenAnimationBuilder<double>(
      tween: Tween(end: value),
      duration: UtenAnim.slow,
      curve: UtenAnim.standard,
      builder: (_, v, _) => bar(v),
    );
  }
}

/// 当前能否播放 AI 组件的装饰动画: 系统未要求减少动画、祖先 TickerMode 开启、且不在省电档。
///
/// 读不到性能档(测试或极早期启动时偏好尚未注入)按标准档处理。
bool aiMotionAllowed(BuildContext context) {
  if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) return false;
  if (!TickerMode.valuesOf(context).enabled) return false;
  return !_performanceTierOf(context).isLite;
}

PerformanceTier _performanceTierOf(BuildContext context) {
  try {
    return ProviderScope.containerOf(
      context,
      listen: false,
    ).read(performanceProvider);
  } catch (_) {
    return PerformanceTier.standard;
  }
}

/// AI 标识: 品牌青绿渐变圆 + 闪光图标, 允许动画时轻微「呼吸」。
///
/// 省电档、系统「减少动画」或页面不可见(TickerMode 关)时静止, 不跑循环动画。
class AiSparkleBadge extends ConsumerStatefulWidget {
  const AiSparkleBadge({super.key, this.size = 52, this.animate = true});

  final double size;

  /// 调用方可显式关掉呼吸动画(如静态卡片里的小徽标)。
  final bool animate;

  @override
  ConsumerState<AiSparkleBadge> createState() => _AiSparkleBadgeState();
}

class _AiSparkleBadgeState extends ConsumerState<AiSparkleBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(covariant AiSparkleBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    final allowed = widget.animate && aiMotionAllowed(context);
    if (allowed) {
      if (!_controller.isAnimating) _controller.repeat(reverse: true);
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
    // 用户在设置里切换性能档时立即响应; 偏好尚未注入时按标准档, 不报错。
    ref.listen<PerformanceTier>(
      performanceProvider,
      (_, _) => _sync(),
      onError: (_, _) {},
    );
    final scheme = Theme.of(context).colorScheme;
    final size = widget.size;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final t = Curves.easeInOut.transform(_controller.value);
        return Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [scheme.tertiary, scheme.primary],
            ),
            boxShadow: [
              BoxShadow(
                color: scheme.primary.withValues(alpha: 0.18 + 0.22 * t),
                blurRadius: size * (0.25 + 0.2 * t),
                spreadRadius: size * 0.04 * t,
              ),
            ],
          ),
          child: Transform.scale(scale: 0.94 + 0.1 * t, child: child),
        );
      },
      child: Icon(
        Icons.auto_awesome_rounded,
        size: size * 0.5,
        color: scheme.onPrimary,
      ),
    );
  }
}
