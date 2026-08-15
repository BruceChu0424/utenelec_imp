// UtenSplitView - 左右分栏 + 可拖动分割线（左面板 / 右详情）
// 文档：docs/02-组件库/UtenSplitView.md
//
// 解决什么：
// 货品资料 / 客户分类 / 供应商分类 / 模具分类 / 部门管理 / 我的部门 /
// 应收应付 / 权限管理等页面原本是同一套固定布局：
//   Row([ SizedBox(width: 300, 左树), 1px 分割线, Expanded(右详情) ])
// 左栏宽度写死 300，窗口大时浪费、树名长时不够看。本组件把这套布局下沉为
// 统一组件：分割线可左右拖动改两栏比例，各页面只传 leading/trailing 两块内容。
//
// 交互设计（对齐 master_data_table_view / uten_editable_grid 的列宽拖拽手感）：
// - 视觉线 1px（outlineVariant），命中区 12px 宽，悬停出 resizeColumn 光标；
// - 中央常驻握把（圆角小块 + 抓握纹）一眼可见可拖（触屏无 hover 也能看出）；
//   悬停/拖动时线加粗染 primary、握把染主色并轻微放大；
// - 拖动实时改左栏宽，clamp 在 [minLeadingWidth, maxLeadingWidth] 之间，
//   且永远给右栏留足 [minTrailingWidth]（窗口再小也不会把详情拖没）；
// - 双击分割线复位到 [initialLeadingWidth]；
// - 键盘：聚焦手柄后 ←/→ 每次 ±16px（无障碍 / 无鼠标场景）；
// - RTL：拖动方向与箭头方向自动翻转（Directionality 驱动）。
//
// 宽度记忆（可选）：传 [persistenceKey] 即把用户拖定的宽度存进本地
// shared_preferences（key 命名 `uten.splitView.<persistenceKey>`），下次进
// 页面自动恢复。不走服务端偏好（像素宽与设备屏幕相关，跨端同步无意义）。
// 建议各页面传稳定且唯一的 key，如 'basicData.goods'、'department.manage'。
//
// 用法：
//   UtenSplitView(
//     persistenceKey: 'basicData.goods',
//     leading: _buildTree(...),
//     trailing: selected == null ? 空态 : _DetailPane(...),
//   )
//
// 注意：compact 断点的抽屉回退仍由页面自己处理（本组件只管分栏分支）；
// 本组件依赖父容器给出有界宽度（页面 body 天然有界）。

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 左右分栏布局：左面板固定宽（可拖调），右面板占满剩余。
class UtenSplitView extends StatefulWidget {
  const UtenSplitView({
    super.key,
    required this.leading,
    required this.trailing,
    this.initialLeadingWidth = 300,
    this.minLeadingWidth = 220,
    this.maxLeadingWidth = 520,
    this.minTrailingWidth = 360,
    this.persistenceKey,
    this.onWidthChanged,
  });

  /// 左侧面板（通常是分类树 / 列表）。
  final Widget leading;

  /// 右侧面板（通常是详情区），占满剩余宽度。
  final Widget trailing;

  /// 初始（也是双击复位的）左栏宽，默认 300（对齐旧版固定宽）。
  final double initialLeadingWidth;

  /// 左栏可拖到的最小宽。
  final double minLeadingWidth;

  /// 左栏可拖到的最大宽（另受「右栏至少留 [minTrailingWidth]」约束）。
  final double maxLeadingWidth;

  /// 右栏保底宽度：分割线再向右拖也会给详情区留出这么多。
  final double minTrailingWidth;

  /// 本地宽度记忆 key（页面级唯一）。传 null 不记忆。
  final String? persistenceKey;

  /// 宽度变化回调（拖动结束 / 双击复位 / 键盘调整后触发）。
  final ValueChanged<double>? onWidthChanged;

  /// 分割线命中区总宽（视觉线居中，两侧各留 (hitWidth-1)/2 的可点区）。
  static const double gutterWidth = 12;

  static String _storeKey(String persistenceKey) =>
      'uten.splitView.$persistenceKey';

  @override
  State<UtenSplitView> createState() => _UtenSplitViewState();
}

class _UtenSplitViewState extends State<UtenSplitView> {
  late double _width = widget.initialLeadingWidth;
  bool _hovering = false;
  bool _dragging = false;
  final FocusNode _handleFocus = FocusNode();

  /// 最近一次布局的总宽（拖动 clamp 用）。build 时刷新。
  double _totalWidth = double.infinity;

  bool get _active => _hovering || _dragging;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  @override
  void didUpdateWidget(UtenSplitView old) {
    super.didUpdateWidget(old);
    if (old.persistenceKey != widget.persistenceKey) _restore();
  }

  /// 从本地缓存恢复上次拖定的宽度（越界值在 build clamp 时自然收敛）。
  Future<void> _restore() async {
    final key = widget.persistenceKey;
    if (key == null) return;
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getDouble(UtenSplitView._storeKey(key));
    if (saved != null && mounted && saved != _width) {
      setState(() => _width = saved);
    }
  }

  Future<void> _persist() async {
    final key = widget.persistenceKey;
    if (key == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(UtenSplitView._storeKey(key), _width);
  }

  double _clamp(double width) {
    final maxBySpace =
        _totalWidth - UtenSplitView.gutterWidth - widget.minTrailingWidth;
    final upper = math.min(widget.maxLeadingWidth, maxBySpace);
    // 极窄窗口：下限让位上限，保证 clamp 区间合法（宁可左栏略小也不拖没右栏）。
    final lower = math.min(widget.minLeadingWidth, upper);
    return width.clamp(lower, upper);
  }

  void _applyWidth(double next, {required bool persist}) {
    final clamped = _clamp(next);
    if (clamped == _width) return;
    setState(() => _width = clamped);
    widget.onWidthChanged?.call(clamped);
    if (persist) _persist();
  }

  /// 拖动/键盘方向：LTR 向右拖左栏变宽；RTL 左栏在右，方向取反。
  double get _dirSign =>
      Directionality.of(context) == TextDirection.rtl ? -1.0 : 1.0;

  void _onDragUpdate(DragUpdateDetails d) =>
      _applyWidth(_width + d.delta.dx * _dirSign, persist: false);

  void _nudge(double delta) =>
      _applyWidth(_width + delta * _dirSign, persist: true);

  void _reset() => _applyWidth(widget.initialLeadingWidth, persist: true);

  @override
  void dispose() {
    _handleFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _totalWidth = constraints.maxWidth;
        final width = _clamp(_width);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(width: width, child: widget.leading),
            _buildGutter(context),
            Expanded(child: widget.trailing),
          ],
        );
      },
    );
  }

  /// 握把上的抓握纹（2 列 × 3 行小圆点）——通用「可拖拽」标志，方向无关。
  Widget _gripDots(Color color) {
    Widget dot() => Container(
      width: 3,
      height: 3,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(1.5),
      ),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(
        3,
        (_) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 1.5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [dot(), const SizedBox(width: 2), dot()],
          ),
        ),
      ),
    );
  }

  /// 分割线与拖拽手柄：12px 命中区，1px 视觉线居中，常驻握把提示可拖（悬停/拖动高亮放大）。
  Widget _buildGutter(BuildContext context) {
    final theme = Theme.of(context);
    final active = _active;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // 点击手柄即取焦，保证 ←/→ 键盘微调可用。
        onTap: _handleFocus.requestFocus,
        onHorizontalDragStart: (_) => setState(() => _dragging = true),
        onHorizontalDragUpdate: _onDragUpdate,
        onHorizontalDragEnd: (_) {
          setState(() => _dragging = false);
          _persist(); // 拖动期间只改内存，松手一次落盘
        },
        onDoubleTap: _reset,
        child: Tooltip(
          message: '拖动调整宽度 · 双击复位', // TODO(l10n): 补 arb
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
                  _nudge(-16),
              const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
                  _nudge(16),
            },
            child: Focus(
              focusNode: _handleFocus,
              child: SizedBox(
                width: UtenSplitView.gutterWidth,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 120),
                      width: active ? 2 : 1,
                      color: active
                          ? theme.colorScheme.primary
                          : theme.colorScheme.outlineVariant,
                    ),
                    // 握把：常驻可见的「可拖」标记（贴满命中区宽的圆角小块 + 抓握纹），
                    // 不再只在 hover 浮现——触屏无悬停也能一眼看出可拖。悬停/拖动时
                    // 染主色并轻微放大，强化「点这里拖」的反馈。
                    AnimatedScale(
                      scale: active ? 1.08 : 1.0,
                      duration: const Duration(milliseconds: 120),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 120),
                        width: UtenSplitView.gutterWidth,
                        height: 38,
                        decoration: BoxDecoration(
                          color: active
                              ? theme.colorScheme.primaryContainer
                              : theme.colorScheme.surfaceContainerHigh,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: active
                                ? theme.colorScheme.primary
                                : theme.colorScheme.outlineVariant,
                            width: active ? 1.5 : 1,
                          ),
                        ),
                        child: Center(
                          child: _gripDots(
                            active
                                ? theme.colorScheme.primary
                                : theme.colorScheme.onSurfaceVariant,
                          ),
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
    );
  }
}
