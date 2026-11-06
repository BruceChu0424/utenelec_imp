// UtenBusyOverlay - 「点了按钮在跑长任务」的全屏居中加载遮罩（全站统一口径）。
//
// 2026-09-12 用户口径（修订）：
//  - **蒙版必须全屏**：此前随宿主 Stack 挂载，宽屏左导航旁的内容区 Stack 只盖
//    住半屏、卡片也只在半屏居中。现在组件自己把画面送进 root Overlay——挂载
//    位置随便（body Stack、AbsorbPointer 内都可以），蒙版永远铺满整屏、卡片
//    永远居中**屏幕**正中。
//  - **蒙版颜色贴近页面背景**：不再是半透明黑灰（用户「很难看」），改为页面
//    背景色向中灰轻掺后的近色蒙版（浅色=米白偏灰、深色=深灰微亮），底下内容
//    隐约可见。
//  - 只跟随**网络调用本身**：结果弹层展示期间必须已经撤下，否则弹层背后还在
//    转圈，且 widget test 的 pumpAndSettle 永远 settle 不了。
import 'package:flutter/material.dart';

import '../../core/theme/uten_tokens.dart';
import '../buttons/uten_button.dart';
import 'uten_overlay_lifecycle.dart';

class UtenBusyOverlay extends StatefulWidget {
  const UtenBusyOverlay({
    super.key,
    required this.title,
    this.description,
    this.semanticsKey,
    this.showDoNotLeaveHint = true,
    this.onCancel,
    this.cancelLabel = '取消',
  }) : _runOwner = null,
       _runContext = null;

  const UtenBusyOverlay._run({
    required this.title,
    required Object owner,
    required BuildContext ownerContext,
  }) : _runOwner = owner,
       _runContext = ownerContext,
       description = null,
       semanticsKey = null,
       showDoNotLeaveHint = false,
       onCancel = null,
       cancelLabel = '取消';

  final Object? _runOwner;
  final BuildContext? _runContext;

  /// 进度卡片的语义 key（宿主测试锁定用，如物料分析的
  /// material-analysis-plan-submission-progress）。
  final Key? semanticsKey;

  /// 一句话标题，如「正在下达采购任务」。
  final String title;

  /// 补充说明（可空）：讲清“在做什么、别做什么”。
  final String? description;

  /// Optional waiting guidance. Hiding the copy keeps the same blocking mask,
  /// task lifetime and accessibility progress announcement.
  final bool showDoNotLeaveHint;
  final VoidCallback? onCancel;
  final String cancelLabel;

  /// Read/compute preparation shared by menu, header and dialog actions.
  /// End it before asking for input or showing the result dialog.
  static Future<T> run<T>(
    BuildContext context, {
    required String title,
    required Future<T> Function() action,
  }) async {
    // Register before insertion: action may yield to an interactive dialog in
    // this same event turn, before the overlay's State has ever mounted.
    final owner = Object();
    _active.add(owner);
    final entry = OverlayEntry(
      builder: (_) => UtenBusyOverlay._run(
        title: title,
        owner: owner,
        ownerContext: context,
      ),
    );
    var inserted = false;
    try {
      Overlay.of(context, rootOverlay: true).insert(entry);
      inserted = true;
      return await action();
    } finally {
      if (inserted) entry.remove();
      entry.dispose();
      _retire(owner);
    }
  }

  /// 活跃「让位」作用域计数，仅暂停进入作用域前已经存在的忙碌遮罩。
  static final ValueNotifier<int> _yielding = ValueNotifier<int>(0);
  static final _active = <Object>{};
  static final _yieldOwners = <Set<Object>>{};

  static void _retire(Object owner) {
    _active.remove(owner);
    for (final owners in _yieldOwners) {
      owners.remove(owner);
    }
  }

  /// 在 [body] 运行期间让既有忙碌遮罩让位，结束(含异常)后恢复。
  /// 弹窗内新开始的任务仍显示自身遮罩，避免验证等按钮只禁用而没有等待反馈。
  ///
  /// 给必须压在遮罩之上、等用户操作的全局弹窗用(如敏感操作的再认证密码框)：遮罩是
  /// root Overlay 里的裸 OverlayEntry，Navigator 每推一个路由都会把裸 entry 重新抬到最顶层，
  /// 盖住后弹出的对话框——请求在等密码、遮罩在等请求，整页卡死。让位期间对话框自带的
  /// 模态屏障照样挡住底下页面。
  static Future<T> yieldWhile<T>(Future<T> Function() body) async {
    // Embedded hosts requested by setState need this frame to register their
    // State owner. run() already registers a pending token before insertion.
    // Both kinds share one snapshot before the modal body starts; work created
    // by that body owns a new token and is never hidden by this yield scope.
    final binding = WidgetsBinding.instance;
    final frame = binding.endOfFrame;
    // post-frame callers still need the next frame explicitly scheduled.
    binding.ensureVisualUpdate();
    await frame;
    // Yield the operations which were already waiting. A newly started task
    // inside the modal (for example password verification) owns its own mask.
    final owners = Set<Object>.of(_active);
    _yieldOwners.add(owners);
    _yielding.value++;
    try {
      return await body();
    } finally {
      _yieldOwners.remove(owners);
      _yielding.value = _yieldOwners.length;
    }
  }

  /// 仅测试用：widget 测试卸树时弃掉的让位 Future 永不完成，全局计数永久
  /// 大于 0，后续用例的遮罩全部隐身。逐条用例复位。
  @visibleForTesting
  static void debugResetYield() {
    _yieldOwners.clear();
    _yielding.value = 0;
  }

  @override
  State<UtenBusyOverlay> createState() => _UtenBusyOverlayState();
}

class _UtenBusyOverlayState extends State<UtenBusyOverlay> {
  OverlayEntry? _entry;
  late final Object _owner = widget._runOwner ?? this;
  late final _lifecycle = UtenOverlayLifecycle(
    transient: false,
    onAvailable: _ensureEntry,
    onUnavailable: _removeEntry,
  );

  @override
  void initState() {
    super.initState();
    UtenBusyOverlay._active.add(_owner);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The carrier lives in the root Overlay. Ownership remains with the
    // original route/ticker/element; its lifetime must not become root-global.
    _lifecycle.attach(widget._runContext ?? context);
  }

  void _ensureEntry() {
    if (!mounted || _entry != null || !_lifecycle.isAvailable) {
      return;
    }
    _entry = OverlayEntry(builder: (ctx) => _buildOverlay(ctx));
    Overlay.of(context, rootOverlay: true).insert(_entry!);
  }

  @override
  void didUpdateWidget(covariant UtenBusyOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    // title/description 变化时重建浮层（builder 经 State 读最新 widget）。
    // 必须帧后再标脏：didUpdateWidget 本身跑在宿主重建的 build 相位里，
    // 直接 markNeedsBuild 一个 root Overlay 的 entry 会触发「构建期改树」
    // 断言（级联页跑批期间标题逐段热更时踩到，2026-09-15）。
    if (_entry != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _entry != null) _entry!.markNeedsBuild();
      });
    }
  }

  @override
  void deactivate() {
    _lifecycle.detach();
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _lifecycle.attach(widget._runContext ?? context);
    });
  }

  void _removeEntry() {
    _entry?.remove();
    _entry = null;
  }

  @override
  void dispose() {
    UtenBusyOverlay._retire(_owner);
    _lifecycle.dispose();
    _removeEntry();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();

  Widget _buildOverlay(BuildContext ctx) {
    return ValueListenableBuilder<int>(
      valueListenable: UtenBusyOverlay._yielding,
      builder: (context, yielding, _) =>
          yielding > 0 &&
              UtenBusyOverlay._yieldOwners.any(
                (owners) => owners.contains(_owner),
              )
          ? const SizedBox.shrink()
          : _buildMask(context),
    );
  }

  Widget _buildMask(BuildContext ctx) {
    final theme = Theme.of(ctx);
    return Stack(
      children: [
        Positioned.fill(
          child: Material(
            type: MaterialType.transparency,
            child: ModalBarrier(
              dismissible: false,
              color: _barrierColor(theme),
            ),
          ),
        ),
        Center(
          child: UtenBusyOverlayCard(
            title: widget.title,
            description: widget.description,
            semanticsKey: widget.semanticsKey,
            showDoNotLeaveHint: widget.showDoNotLeaveHint,
            onCancel: widget.onCancel,
            cancelLabel: widget.cancelLabel,
          ),
        ),
      ],
    );
  }

  /// 蒙版色：页面背景向中灰轻掺（浅色掺 12%、深色掺 16%）——「和背景差不多的
  /// 颜色但偏灰点」；再整体 82% 不透明度，底下内容隐约可见不至于糊死。
  Color _barrierColor(ThemeData theme) {
    final light = theme.brightness == Brightness.light;
    final tint = light ? const Color(0xFF8A8A8A) : const Color(0xFF707070);
    return Color.alphaBlend(
      tint.withValues(alpha: light ? 0.12 : 0.16),
      theme.scaffoldBackgroundColor,
    ).withValues(alpha: 0.82);
  }
}

/// 卡片画面（与蒙版同浮层，屏幕正中）。拆成公开控件便于同类遮罩复用。
class UtenBusyOverlayCard extends StatelessWidget {
  const UtenBusyOverlayCard({
    super.key,
    required this.title,
    this.description,
    this.semanticsKey,
    this.showDoNotLeaveHint = true,
    this.onCancel,
    this.cancelLabel = '取消',
  });

  final Key? semanticsKey;
  final String title;
  final String? description;

  /// 是否附带通用等待说明。主档操作或首屏加载可只保留动作标题，
  /// 其余场景保持默认提示；这只控制文案，不改变阻止重复操作的蒙版。
  final bool showDoNotLeaveHint;
  final VoidCallback? onCancel;
  final String cancelLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final compact = MediaQuery.sizeOf(context).width < 600;
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        if (description?.isNotEmpty == true) ...[
          const SizedBox(height: UtenSpacing.s4),
          Text(
            description!,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.45,
            ),
          ),
        ],
        if (showDoNotLeaveHint) ...[
          const SizedBox(height: UtenSpacing.s4),
          Text(
            '请勿重复点击或关闭页面，完成后自动继续。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
    const progress = SizedBox(
      width: 32,
      height: 32,
      child: CircularProgressIndicator(strokeWidth: 3),
    );
    return Padding(
      padding: EdgeInsets.all(compact ? UtenSpacing.s12 : UtenSpacing.s24),
      child: SingleChildScrollView(
        child: Semantics(
          key: semanticsKey,
          container: true,
          liveRegion: true,
          label: [
            title,
            ?description,
            if (showDoNotLeaveHint) '请勿重复提交或关闭页面',
          ].map((line) => '$line。').join(),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Material(
              color: theme.colorScheme.surface,
              elevation: 12,
              borderRadius: UtenRadius.lgAll,
              child: Padding(
                padding: EdgeInsets.all(
                  compact ? UtenSpacing.s16 : UtenSpacing.s24,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ExcludeSemantics(
                      child: compact
                          ? Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                progress,
                                const SizedBox(height: UtenSpacing.s12),
                                text,
                              ],
                            )
                          : Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                progress,
                                const SizedBox(width: UtenSpacing.s16),
                                Expanded(child: text),
                              ],
                            ),
                    ),
                    if (onCancel != null) ...[
                      const SizedBox(height: UtenSpacing.s16),
                      UtenButton(
                        type: UtenButtonType.secondary,
                        onPressed: onCancel,
                        child: Text(cancelLabel),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
