// 表格完整读取的顶部加载进度通知（2026-11-09）。
//
// 与普通顶部通知（app_notification.dart）同一视觉语言：顶部悬浮、居中、
// 圆角卡片 + elevation 4 投影 + 红色圆形关闭按钮（UtenCloseButton）。差异是
// 整张卡片背景就是进度条——已加载区从最左向右铺满全高，文字/图标/关闭按钮
// 恒浮在进度背景之上。
//
// 进度数据不在这里产生：`loadCompletePagedResult` 对发布渐进批次的完整读取
// （进入页面/刷新的主表读取）经 `CompleteReadProgressReporter` 上报已验证
// 累计行数与服务端总量；本控制器只做展示决策：
// - 延迟 [_showDelay] 才出现：快进快出的小读取（单批字典表、缓存命中）不闪卡；
// - 百分比 = 已验证累计行数 ÷ 服务端 total，总量未知时显示「正在加载数据…」
//   + 扫动光带，绝不编造百分比，也不允许定时器自行累加；
// - 加载中封顶 99%，只有完整结果成功返回才显示 100% 与完成态；
// - 红色关闭按钮只隐藏本轮提示，后台读取继续；本轮后续批次/完成不再唤出；
//   新的独立读取任务按正常规则重新显示；
// - 失败/退休/取消：卡片立即退场（错误提示沿用页面既有 appError 链路），
//   不显示完成态。
//
// 展示策略为「同轮最新主读取」：同一时刻只展示最近开始且仍在进行的一张卡，
// 旧任务迟到返回不更新新任务百分比（任务 id 隔离）。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../components/buttons/uten_close_button.dart';
import '../../shared/paging/complete_read_progress.dart';
import '../theme/uten_colors.dart';
import '../theme/uten_tokens.dart';

/// 卡片出现前的消抖：只吞掉「秒失败/缓存命中」这类零批次读取的闪现，
/// 真实分批读取一开始（150ms 内）卡片即入场。2026-11-09 用户口径：
/// 「不应该一开始就出现吗」——从原 600ms 防闪档改为立即出现档。
const Duration tableLoadNoticeShowDelay = Duration(milliseconds: 150);

/// 完成态停留时长：铺满 100% + 对勾后停一拍再向上收起。
const Duration tableLoadNoticeDoneHold = Duration(milliseconds: 1400);

/// 进度文字的目标卡宽（Constraint 上限）：2026-11-09 用户口径「字体尽量大」，
/// 卡片随之加宽给大字留呼吸位。
const double _kNoticeMaxCardWidth = 420;

/// 按实际卡宽分档的缩放：整卡（文字/图标/关闭钮命中带）同一比例缩，
/// 小屏适当变小、永不换行溢出。2026-11-09 用户口径「小屏幕的时候会适当变小」。
double _noticeScale(double cardWidth) {
  if (cardWidth >= 340) return 1;
  if (cardWidth >= 280) return 0.92;
  return 0.84;
}

/// 一张进度卡片当前要展示的内容。
class TableLoadProgressView {
  const TableLoadProgressView({
    required this.taskId,
    required this.done,
    required this.loaded,
    this.total,
  });

  final int taskId;
  final bool done;
  final int loaded;

  /// 服务端总量；null = 尚无可靠总量（不定进度）。
  final int? total;

  /// 0~1 的真实进度；null = 不定进度（未知总量）。done 时恒为 1。
  double? get fraction {
    if (done) return 1;
    final total = this.total;
    if (total == null || total <= 0) return null;
    return (loaded / total).clamp(0.0, 1.0);
  }
}

/// 进度通知展示控制器：把 [CompleteReadProgressReporter] 的事件流收敛成
/// 「当前展示哪张卡」的单一事实。
class TableLoadProgressNoticeController extends ChangeNotifier {
  TableLoadProgressNoticeController();

  /// app.dart 宿主挂载的默认实例。
  static final TableLoadProgressNoticeController instance =
      TableLoadProgressNoticeController();

  TableLoadProgressView? _current;
  final Map<int, TableLoadProgressView> _active = {};
  final Set<int> _dismissed = {};
  Timer? _showTimer;
  int? _showTaskId;
  Timer? _doneExitTimer;
  bool _holding = false;
  int _hosts = 0;

  /// 当前应展示的卡片；null = 无卡（宿主随即让卡片退场）。
  TableLoadProgressView? get current => _current;

  /// 宿主挂载时登记。按宿主计数共用一份上报监听：app.dart 外壳的
  /// PlatformTablesHost 以登录身份为 key，登录、刷新后恢复会话、切换模拟
  /// 身份都会整棵重建宿主，而 Flutter 先 initState 新宿主、帧末才 dispose
  /// 旧宿主——布尔开关会让旧宿主的 [detach] 断开新宿主刚接上的监听，此后
  /// 读取链见 `hasListeners == false` 不再上报，卡片永不出现。
  void attach() {
    _hosts += 1;
    if (_hosts == 1) CompleteReadProgressReporter.addListener(_onEvent);
  }

  /// 宿主卸载时注销；最后一个宿主离开才断开上报并清空展示状态。
  void detach() {
    if (_hosts == 0) return;
    _hosts -= 1;
    if (_hosts == 0) _unhook();
  }

  void _unhook() {
    CompleteReadProgressReporter.removeListener(_onEvent);
    _showTimer?.cancel();
    _showTimer = null;
    _showTaskId = null;
    _doneExitTimer?.cancel();
    _doneExitTimer = null;
    _active.clear();
    _dismissed.clear();
    _holding = false;
    _current = null;
  }

  @override
  void dispose() {
    if (_hosts > 0) {
      _hosts = 0;
      _unhook();
    }
    super.dispose();
  }

  void _onEvent(CompleteReadProgressEvent event) {
    switch (event.phase) {
      case CompleteReadProgressPhase.started:
        _active[event.taskId] = TableLoadProgressView(
          taskId: event.taskId,
          done: false,
          loaded: 0,
          total: event.total,
        );
        if (_current?.taskId != event.taskId) _scheduleShow(event.taskId);
      case CompleteReadProgressPhase.batch:
        if (!_active.containsKey(event.taskId)) return;
        _active[event.taskId] = TableLoadProgressView(
          taskId: event.taskId,
          done: false,
          loaded: event.loaded,
          total: event.total,
        );
        if (_current?.taskId == event.taskId) {
          _current = _active[event.taskId];
          notifyListeners();
        }
      case CompleteReadProgressPhase.succeeded:
        _active.remove(event.taskId);
        _dismissed.remove(event.taskId);
        _cancelShowTimer(taskId: event.taskId);
        if (_current?.taskId == event.taskId) {
          _current = TableLoadProgressView(
            taskId: event.taskId,
            done: true,
            loaded: event.total ?? event.loaded,
            total: event.total,
          );
          _scheduleDoneExit();
          notifyListeners();
        }
      case CompleteReadProgressPhase.failed:
        _active.remove(event.taskId);
        _dismissed.remove(event.taskId);
        _cancelShowTimer(taskId: event.taskId);
        if (_current?.taskId == event.taskId) {
          // 失败/取消/退休：直接退场，错误提示由页面既有链路负责。
          _cancelDoneExit();
          _current = null;
          notifyListeners();
        }
    }
  }

  /// 延迟弹卡：同一时刻只排最新的候选任务；任务提前结束则不再出现。
  void _scheduleShow(int taskId) {
    _showTimer?.cancel();
    _showTaskId = taskId;
    _showTimer = Timer(tableLoadNoticeShowDelay, () {
      _showTimer = null;
      if (_showTaskId != taskId) return;
      _showTaskId = null;
      if (!_active.containsKey(taskId) || _dismissed.contains(taskId)) return;
      _cancelDoneExit();
      _current = _active[taskId];
      notifyListeners();
    });
  }

  void _cancelShowTimer({int? taskId}) {
    if (taskId != null && _showTaskId != taskId) return;
    _showTimer?.cancel();
    _showTimer = null;
    _showTaskId = null;
  }

  void _scheduleDoneExit() {
    _doneExitTimer?.cancel();
    if (_holding) return;
    _doneExitTimer = Timer(tableLoadNoticeDoneHold, () {
      _doneExitTimer = null;
      _current = null;
      notifyListeners();
    });
  }

  void _cancelDoneExit() {
    _doneExitTimer?.cancel();
    _doneExitTimer = null;
  }

  /// 红色关闭按钮：只隐藏本轮提示，读取继续；同轮后续事件不再唤出卡片。
  void dismissCurrent() {
    final taskId = _current?.taskId;
    if (taskId == null) return;
    _dismissed.add(taskId);
    _cancelShowTimer();
    _cancelDoneExit();
    _current = null;
    notifyListeners();
  }

  /// 鼠标悬停时暂停完成态收起（读得完再走）；移出后重新计时。
  void setHold(bool holding) {
    if (_holding == holding) return;
    _holding = holding;
    if (holding) {
      _cancelDoneExit();
    } else if (_current?.done == true) {
      _scheduleDoneExit();
    }
  }
}

/// 顶部加载进度通知宿主：挂在 MaterialApp.builder 的顶部 Stack 里（普通
/// 通知叠放层的下方，同列堆叠互不遮挡）。
class TableLoadProgressNoticeHost extends StatefulWidget {
  const TableLoadProgressNoticeHost({super.key, this.controller});

  /// 测试注入独立控制器；生产用全局 [TableLoadProgressNoticeController.instance]。
  final TableLoadProgressNoticeController? controller;

  @override
  State<TableLoadProgressNoticeHost> createState() =>
      _TableLoadProgressNoticeHostState();
}

class _TableLoadProgressNoticeHostState
    extends State<TableLoadProgressNoticeHost> {
  late final TableLoadProgressNoticeController controller =
      widget.controller ?? TableLoadProgressNoticeController.instance;
  bool _cardMounted = false;

  @override
  void initState() {
    super.initState();
    controller.addListener(_onChanged);
    controller.attach();
    _cardMounted = controller.current != null;
  }

  @override
  void dispose() {
    controller.removeListener(_onChanged);
    controller.detach();
    super.dispose();
  }

  void _onChanged() {
    if (!mounted) return;
    if (controller.current != null) _cardMounted = true;
    setState(() {});
  }

  /// 卡片退场动画播完后由卡片回调；此时卸载，避免残留空壳。
  void _onCardExited() {
    if (!mounted) return;
    if (controller.current == null) setState(() => _cardMounted = false);
  }

  @override
  Widget build(BuildContext context) {
    if (!_cardMounted && controller.current == null) {
      return const SizedBox.shrink();
    }
    // view 传 null 表示正在退场：卡片保留最后内容播放收起动画。
    return TableLoadProgressCard(
      controller: controller,
      view: controller.current,
      onExited: _onCardExited,
    );
  }
}

/// 整卡背景即进度条的加载通知卡片。
///
/// - 入场：顶部轻微下滑 + 淡入（220ms，与普通通知一致）；
/// - 进度：填充宽度从当前显示值平滑推进到新目标，连续批次不重排动画；
/// - 完成：铺满 100%、细环换对勾、停留 [tableLoadNoticeDoneHold] 后上滑淡出；
/// - 减少动态效果（MediaQuery.disableAnimations）：入场/退场直接切换、
///   进度瞬移、扫动光带停驻、细环不旋转。
class TableLoadProgressCard extends StatefulWidget {
  const TableLoadProgressCard({
    super.key,
    required this.controller,
    required this.view,
    required this.onExited,
  });

  final TableLoadProgressNoticeController controller;

  /// 当前任务内容；null 表示退场（保留最后内容播放收起动画）。
  final TableLoadProgressView? view;
  final VoidCallback onExited;

  @override
  State<TableLoadProgressCard> createState() => _TableLoadProgressCardState();
}

class _TableLoadProgressCardState extends State<TableLoadProgressCard>
    with TickerProviderStateMixin {
  static const Duration _enterDuration = Duration(milliseconds: 220);
  static const Duration _fillDuration = Duration(milliseconds: 450);
  static const Duration _sweepDuration = Duration(milliseconds: 1500);

  late final AnimationController _entry;
  late final AnimationController _fill;
  late final AnimationController _sweep;
  Tween<double> _fillTween = Tween(begin: 0, end: 0);
  TableLoadProgressView? _lastView;
  bool _exiting = false;
  bool _exited = false;
  bool _motionInitialized = false;

  bool get _reduceMotion =>
      MediaQuery.maybeOf(context)?.disableAnimations ?? false;

  @override
  void initState() {
    super.initState();
    _entry = AnimationController(vsync: this, duration: _enterDuration);
    _fill = AnimationController(vsync: this, duration: _fillDuration);
    _sweep = AnimationController(vsync: this, duration: _sweepDuration);
    _lastView = widget.view;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_motionInitialized) return;
    _motionInitialized = true;
    _applyView(initial: true);
    if (_reduceMotion) {
      _entry.value = 1;
    } else {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_exiting) _entry.forward();
      });
    }
  }

  @override
  void didUpdateWidget(TableLoadProgressCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.view != null) {
      _lastView = widget.view;
      // 正在退场时新任务接管同一张卡：取消退场，卡片回到可见。
      if (_exiting && !_exited) {
        _exiting = false;
        if (_reduceMotion) {
          _entry.value = 1;
        } else {
          _entry.forward();
        }
      }
      _applyView();
    } else if (!_exiting) {
      _exit();
    }
  }

  @override
  void dispose() {
    _entry.dispose();
    _fill.dispose();
    _sweep.dispose();
    super.dispose();
  }

  /// 与文字一致的填充目标：加载中按显示口径取整并封顶 99%，完成铺满。
  double _displayedFraction(TableLoadProgressView view) {
    final fraction = view.fraction;
    if (fraction == null) return 0;
    if (view.done) return 1;
    return ((fraction * 100).floor().clamp(0, 99)) / 100;
  }

  void _applyView({bool initial = false}) {
    final view = _lastView;
    if (view == null) return;
    if (view.fraction == null) {
      if (_reduceMotion) {
        // 减少动态效果：光带停驻在固定位置，保持「仍在加载」的可视语义。
        _sweep
          ..stop()
          ..value = 0.22;
      } else if (!_sweep.isAnimating) {
        _sweep.repeat();
      }
    } else {
      _sweep
        ..stop()
        ..value = 0;
    }
    _retargetFill(_displayedFraction(view), instant: initial || _reduceMotion);
  }

  /// 从当前显示值向新目标推进；前一次过渡未完成时从中途续走，不排队不回弹。
  void _retargetFill(double target, {bool instant = false}) {
    final from = _fillTween.transform(_fill.value);
    if (!instant && (from - target).abs() < 0.0001 && !_fill.isAnimating) {
      _fillTween = Tween(begin: target, end: target);
      _fill.value = 1;
      return;
    }
    _fillTween = Tween(begin: from, end: target);
    if (instant || _reduceMotion) {
      _fill.value = 1;
    } else {
      _fill.forward(from: 0);
    }
  }

  Future<void> _exit() async {
    if (_exiting || _exited) return;
    _exiting = true;
    _sweep
      ..stop()
      ..value = 0;
    if (_reduceMotion) {
      _finishExit();
      return;
    }
    await _entry.reverse();
    if (mounted) _finishExit();
  }

  void _finishExit() {
    if (_exited) return;
    _exited = true;
    widget.onExited();
  }

  @override
  Widget build(BuildContext context) {
    final view = _lastView;
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final track = isDark
        ? UtenColors.loadNoticeTrackDark
        : UtenColors.loadNoticeTrack;
    final border = isDark
        ? UtenColors.loadNoticeBorderDark
        : UtenColors.loadNoticeBorder;
    final hasOverlay = Overlay.maybeOf(context) != null;
    final indeterminate = view != null && !view.done && view.fraction == null;
    final curvedEntry = CurvedAnimation(
      parent: _entry,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: FadeTransition(
        opacity: _entry,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, -0.25),
            end: Offset.zero,
          ).animate(curvedEntry),
          child: MouseRegion(
            onEnter: (_) => widget.controller.setHold(true),
            onExit: (_) => widget.controller.setHold(false),
            child: Semantics(
              container: true,
              label: _semanticLabel(view),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: _kNoticeMaxCardWidth),
              child: Material(
                color: track,
                elevation: 4,
                shadowColor: theme.colorScheme.shadow.withValues(alpha: 0.18),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(UtenRadius.card),
                  side: BorderSide(color: border),
                ),
                clipBehavior: Clip.antiAlias,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final scale = _noticeScale(constraints.maxWidth);
                    return Stack(
                      children: [
                        Positioned.fill(
                          child: AnimatedBuilder(
                            animation: _fill,
                            builder: (context, _) {
                              final value = _fillTween
                                  .transform(_fill.value)
                                  .clamp(0.0, 1.0);
                              if (value <= 0) return const SizedBox.shrink();
                              return FractionallySizedBox(
                                key: const ValueKey('load-notice-fill'),
                                alignment: Alignment.centerLeft,
                                widthFactor: value,
                                child: const _LoadNoticeFill(),
                              );
                            },
                          ),
                        ),
                        if (indeterminate)
                          AnimatedBuilder(
                            animation: _sweep,
                            builder: (context, _) {
                              final band = constraints.maxWidth * 0.42;
                              return Positioned(
                                left:
                                    -band +
                                    _sweep.value *
                                        (constraints.maxWidth + band),
                                top: 0,
                                bottom: 0,
                                width: band,
                                child: const _LoadNoticeSweepBand(
                                  key: ValueKey('load-notice-sweep'),
                                ),
                              );
                            },
                          ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 11, 10, 11),
                          // 定高内容行：图标 + 关闭按钮撑起卡片高度。文字用
                          // Positioned.fill + Center 悬在整个内容层上：
                          // 相对整卡真居中（图标列与关闭钮宽度不对称也不偏），
                          // 且 Text 按自身宽度收紧命中盒，不挡右侧关闭按钮。
                          child: Stack(
                            children: [
                              Row(
                                children: [
                                  _StatusIcon(view: view, scale: scale),
                                  const SizedBox(width: 14),
                                  const Expanded(child: SizedBox.shrink()),
                                  const SizedBox(width: 8),
                                  UtenCloseButton(
                                    onPressed: widget.controller.dismissCurrent,
                                    tooltip: '关闭加载提示',
                                    showTooltip: hasOverlay,
                                    // 命中带随卡宽同档缩放（48 → 44/40）；
                                    // 触控设备仍由内部规则保底 48。
                                    desktopHitExtent: (48 * scale).roundToDouble(),
                                  ),
                                ],
                              ),
                              Positioned.fill(
                                child: Center(
                                  child: _ProgressText(view: view, scale: scale),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
            ),
          ),
        ),
      ),
    );
  }

  String _semanticLabel(TableLoadProgressView? view) {
    if (view == null) return '加载提示';
    if (view.done) return '数据加载完成';
    final fraction = view.fraction;
    if (fraction == null) return '正在加载数据';
    return '正在加载数据，${(fraction * 100).floor().clamp(0, 99)}%';
  }
}

/// 已加载区：浅薄荷青绿轻微渐变，左起铺满全高，裁切在卡片圆角内。
class _LoadNoticeFill extends StatelessWidget {
  const _LoadNoticeFill();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: isDark
              ? const [
                  UtenColors.loadNoticeFillStartDark,
                  UtenColors.loadNoticeFillEndDark,
                ]
              : const [
                  UtenColors.loadNoticeFillStart,
                  UtenColors.loadNoticeFillEnd,
                ],
        ),
      ),
      child: const SizedBox.expand(),
    );
  }
}

/// 不定进度时的柔和扫动光带（细窄高光渐隐，非发光装饰）。
class _LoadNoticeSweepBand extends StatelessWidget {
  const _LoadNoticeSweepBand({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final base = isDark
        ? UtenColors.loadNoticeFillStartDark
        : UtenColors.loadNoticeFillStart;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            base.withValues(alpha: 0),
            base.withValues(alpha: 0.85),
            base.withValues(alpha: 0),
          ],
        ),
      ),
    );
  }
}

/// 左侧状态图标：加载中为细线旋转环，完成后平滑切换对勾。随卡宽同档缩放。
class _StatusIcon extends StatelessWidget {
  const _StatusIcon({required this.view, required this.scale});

  final TableLoadProgressView? view;
  final double scale;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final color = isDark
        ? UtenColors.loadNoticeAccentDark
        : UtenColors.loadNoticeAccent;
    final done = view?.done ?? false;
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final size = 26 * scale;
    return SizedBox(
      width: size,
      height: size,
      child: AnimatedSwitcher(
        duration: reduceMotion
            ? Duration.zero
            : const Duration(milliseconds: 200),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: ScaleTransition(
            scale: Tween(begin: 0.8, end: 1.0).animate(animation),
            child: child,
          ),
        ),
        child: done
            ? Icon(
                Icons.check_rounded,
                key: const ValueKey('load-notice-done'),
                size: size,
                color: color,
              )
            : SizedBox(
                key: const ValueKey('load-notice-loading'),
                width: size,
                height: size,
                child: CircularProgressIndicator(
                  // 减少动态效果：固定弧段不旋转，仍表达「进行中」。
                  value: reduceMotion ? 0.72 : null,
                  strokeWidth: 2.5 * scale,
                  strokeCap: StrokeCap.round,
                  color: color,
                ),
              ),
      ),
    );
  }
}

/// 中间文字：说明句加粗 + 百分比（含百分号）更大更重，相对整卡居中，
/// 不随进度填充移动。字号随卡宽同档缩放（小屏适当变小，永不溢出）。
class _ProgressText extends StatelessWidget {
  const _ProgressText({this.view, required this.scale});

  final TableLoadProgressView? view;

  /// [_noticeScale] 的当前档位（1 / 0.92 / 0.84）。
  final double scale;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final text = isDark
        ? UtenColors.loadNoticeTextDark
        : UtenColors.loadNoticeText;
    final accent = isDark
        ? UtenColors.loadNoticeAccentDark
        : UtenColors.loadNoticeAccent;
    final label =
        theme.textTheme.bodyMedium?.copyWith(
          color: text,
          fontWeight: FontWeight.w700,
          fontSize: 17 * scale,
        ) ??
        TextStyle(color: text, fontWeight: FontWeight.w700);
    final percent = label.copyWith(
      fontWeight: FontWeight.w800,
      fontSize: 21 * scale,
      color: accent,
    );
    final v = view;
    if (v == null) return Text('正在加载数据…', style: label);
    if (v.done) {
      return Text.rich(
        TextSpan(
          children: [
            TextSpan(text: '数据加载完成：', style: label),
            TextSpan(text: '100%', style: percent),
          ],
        ),
      );
    }
    final fraction = v.fraction;
    if (fraction == null) {
      return Text('正在加载数据…', style: label);
    }
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: '正在加载数据：', style: label),
          TextSpan(
            // 加载中封顶 99%：100% 只属于真正完成的完整结果。
            text: '${(fraction * 100).floor().clamp(0, 99)}%',
            style: percent,
          ),
        ],
      ),
    );
  }
}
