import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/uten_tokens.dart';
import '../../core/ui/capsule_nav_metrics.dart';

/// 右下角悬浮操作组。
///
/// 组内业务动作（按钮/胶囊）高度统一为 [controlHeight]；宽度也统一——首帧按
/// 各自自然宽度测量，取最宽者后所有孩子等宽（2026-10-02 用户口径「按钮应该
/// 一样大小」）。宽度只增不减：计数类文案（批量退回(N)）变化时不来回抖动。
class UtenFloatingActionGroup extends StatefulWidget {
  const UtenFloatingActionGroup({
    super.key,
    required this.children,
    this.maxWidth = 1080,
  });

  final List<Widget> children;
  final double maxWidth;

  /// 悬浮组内控件的统一高度。
  ///
  /// 取值 = [UtenButtonSize.large] 的最小高度：组里的业务动作一律用 large，
  /// 而「已选 N 项」胶囊默认按表格工具条的 48 走——两者并排时矮 4px，用户一眼
  /// 就看出来了（2026-09-11 反馈）。这里对每个孩子统一下 minHeight，谁也不用
  /// 记得在调用点传高度；用 min 而非 tight，超大字号下按钮文案换行仍能长高。
  static const double controlHeight = 52;

  /// 正文末尾的可滚动留白，可把末行完整滚到悬浮操作组上方。
  /// 包含两行按钮、底部安全区及额外阅读空间；详情和编辑页共用。
  static const double scrollClearance = 200;

  @override
  State<UtenFloatingActionGroup> createState() =>
      _UtenFloatingActionGroupState();
}

class _UtenFloatingActionGroupState extends State<UtenFloatingActionGroup> {
  double? _equalWidth;
  final List<GlobalKey> _measureKeys = [];

  @override
  void didUpdateWidget(UtenFloatingActionGroup oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 换按钮组（孩子 key 集变化，如认领失败态换按钮）→ 作废旧宽度重测，
    // 避免后来更宽的按钮被旧宽度卡小溢出。isLoading 等态不换 key，不受影响。
    if (!_listEquals(
      [for (final child in oldWidget.children) child.key],
      [for (final child in widget.children) child.key],
    )) {
      _equalWidth = null;
    }
  }

  static bool _listEquals(List<Key?> a, List<Key?> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.children.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final viewportWidth = MediaQuery.sizeOf(context).width;
    final availableWidth = (viewportWidth - UtenSpacing.s32)
        .clamp(0.0, widget.maxWidth)
        .toDouble();

    // 自然宽度测量（仅在无等宽值时挂测量键并帧末取最宽）。
    while (_measureKeys.length < widget.children.length) {
      _measureKeys.add(GlobalKey());
    }
    while (_measureKeys.length > widget.children.length) {
      _measureKeys.removeLast();
    }
    if (_equalWidth == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _measureWidest());
    }

    // compact 悬浮胶囊避让：本组常挂在 Scaffold FAB 位或表格 Stage 的贴底
    // Positioned 上，靠自带底 padding 抬到胶囊上方（弹窗/抽屉里查不到 scope
    // 取 0，位置不变）。滚动末尾让位由各页滚动件另行查询，不在组内重复加。
    final capsuleOcclusion = UtenCapsuleNavScope.occlusionOf(context);

    return Padding(
      padding: EdgeInsets.only(bottom: capsuleOcclusion),
      child: Material(
        type: MaterialType.transparency,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: availableWidth),
          // LayoutBuilder 取宿主给本组的真实约束（FAB 位有边距，算术推的
          // availableWidth 会偏宽 1~2px，等宽硬套会溢出）。
          child: LayoutBuilder(
            builder: (context, groupConstraints) => Wrap(
              alignment: WrapAlignment.end,
              runAlignment: WrapAlignment.end,
              spacing: UtenSpacing.s8,
              runSpacing: UtenSpacing.s8,
              children: [
                for (var i = 0; i < widget.children.length; i++)
                  DecoratedBox(
                    key: _equalWidth == null ? _measureKeys[i] : null,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      boxShadow: UtenElevation.mid(
                        isDark: theme.brightness == Brightness.dark,
                      ),
                    ),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        minHeight: UtenFloatingActionGroup.controlHeight,
                      ),
                      // 等宽用 minWidth：每个孩子至少最宽者的宽度（皆 ≥ 最大值
                      // ⇒ 彼此相等），且永不会比自身内容窄——不存在溢出路径，
                      // 窄屏/大字号下由 Wrap 自然换行。
                      child: _equalWidth == null
                          ? widget.children[i]
                          : ConstrainedBox(
                              constraints: BoxConstraints(
                                minWidth: _equalWidth!,
                              ),
                              child: widget.children[i],
                            ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _measureWidest() {
    if (!mounted) return;
    var widest = 0.0;
    for (final key in _measureKeys) {
      final box = key.currentContext?.findRenderObject();
      if (box is RenderBox && box.hasSize) {
        widest = math.max(widest, box.size.width);
      }
    }
    // 只增不减：计数文案变化时宽度稳定，避免按钮来回抖动；超宽钳到可用宽度。
    if (widest > 0 && (_equalWidth ?? 0) < widest) {
      setState(() => _equalWidth = widest);
    } else if (widest > 0 && _equalWidth != null && _equalWidth! > widest) {
      // 孩子整体变窄（如撤掉了长文案动作）：允许收敛，但同帧只降一次。
      setState(() => _equalWidth = widest);
    }
  }
}
