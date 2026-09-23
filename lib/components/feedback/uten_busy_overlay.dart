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

class UtenBusyOverlay extends StatefulWidget {
  const UtenBusyOverlay({
    super.key,
    required this.title,
    this.description,
    this.semanticsKey,
  });

  /// 进度卡片的语义 key（宿主测试锁定用，如物料分析的
  /// material-analysis-plan-submission-progress）。
  final Key? semanticsKey;

  /// 一句话标题，如「正在下达采购任务」。
  final String title;

  /// 补充说明（可空）：讲清“在做什么、别做什么”。
  final String? description;

  /// 全局「让位」计数：大于 0 时所有忙碌遮罩暂不绘制、不挡点击。
  static final ValueNotifier<int> _yielding = ValueNotifier<int>(0);

  /// 在 [body] 运行期间让所有忙碌遮罩让位，结束(含异常)后恢复。
  ///
  /// 给必须压在遮罩之上、等用户操作的全局弹窗用(如敏感操作的再认证密码框)：遮罩是
  /// root Overlay 里的裸 OverlayEntry，Navigator 每推一个路由都会把裸 entry 重新抬到最顶层，
  /// 盖住后弹出的对话框——请求在等密码、遮罩在等请求，整页卡死。让位期间对话框自带的
  /// 模态屏障照样挡住底下页面。
  static Future<T> yieldWhile<T>(Future<T> Function() body) async {
    _yielding.value++;
    try {
      return await body();
    } finally {
      _yielding.value--;
    }
  }

  @override
  State<UtenBusyOverlay> createState() => _UtenBusyOverlayState();
}

class _UtenBusyOverlayState extends State<UtenBusyOverlay> {
  OverlayEntry? _entry;

  @override
  void initState() {
    super.initState();
    // 下一帧推入 root Overlay：initState 期 Overlay.of 拿不到宿主层级稳定引用，
    // 且 build 里同步插 Overlay 会“构建期改树”。
    WidgetsBinding.instance.addPostFrameCallback((_) => _ensureEntry());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // TickerMode 变化（宿主被压栈→回前台）时帧后再评估挂载——构建期不能插
    // OverlayEntry（会 markNeedsBuild during build 崩溃）。
    if (_entry == null && TickerMode.valuesOf(context).enabled) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _ensureEntry());
    }
  }

  void _ensureEntry() {
    if (!mounted || _entry != null || !TickerMode.valuesOf(context).enabled) {
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
  void dispose() {
    _entry?.remove();
    _entry = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();

  Widget _buildOverlay(BuildContext ctx) {
    return ValueListenableBuilder<int>(
      valueListenable: UtenBusyOverlay._yielding,
      builder: (context, yielding, _) =>
          yielding > 0 ? const SizedBox.shrink() : _buildMask(context),
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
  });

  final Key? semanticsKey;
  final String title;
  final String? description;

  /// 是否附带「请勿重复点击或关闭页面」那句尾巴。跑批遮罩恒为真；单独拿卡片
  /// 画**首屏加载**时要关掉——那种场景没有可重复点的按钮，返回按钮也是故意
  /// 留着能点的，再劝人别关页面就是自相矛盾(领料汇总页首屏，2026-09-21)。
  final bool showDoNotLeaveHint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(UtenSpacing.s24),
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
          child: ExcludeSemantics(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Material(
                color: theme.colorScheme.surface,
                elevation: 12,
                borderRadius: UtenRadius.lgAll,
                child: Padding(
                  padding: const EdgeInsets.all(UtenSpacing.s24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(
                            width: 32,
                            height: 32,
                            child: CircularProgressIndicator(strokeWidth: 3),
                          ),
                          const SizedBox(width: UtenSpacing.s16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
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
                            ),
                          ),
                        ],
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
