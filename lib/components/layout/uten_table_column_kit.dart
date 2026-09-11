// 表格表头列管理共用套件（MasterDataTableView / UtenEditableGrid 共用，2026-09-05 抽取）：
//
// 全站表格的「表头设置」与「表头拖出隐藏」此前在主数据表与编辑明细表各养了一份，
// 入口观感、弹层形态、拖拽跟手效果渐行渐远。本套件把两套交互收敛为同一实现：
//
// 1. [UtenColumnChooserButton] ——「表头设置 x/y」深绿实心按钮 + **按钮处锚定的浮层
//    勾选列表**（CompositedTransform 锚定、点外部/TapRegion 关闭、全选行、可选
//    「必填列锁定」「拖拽排序」「恢复默认」）。主数据表与编辑明细表同一弹层形态。
// 2. [UtenColumnHeaderDragHost] —— 表头拖拽手势 mixin，**按下即拖、按方向分流**
//    （2026-09-11 起换位不再需要长按）：
//    - 横拖 = 换位：跟手浮层 + 插入位指示线，松手落位；
//    - 竖拖 = 移除：累计纵向位移过阈值（10px）arm——浮层红底红×徽标、原格变淡
//      留原位；拖回阈值内取消，松开不隐藏。
//    两种跟手浮层都挂 root Overlay **最顶层**（拖出表头范围也始终可见、压在整表
//    之上、不被表体裁切）。单指契约：并发第二指的 start/update/end 因 index 不匹配 no-op。
//
// 两张表只各自提供：列链接（LayerLink）、列宽/列名取值、「该列可否隐藏」判定
// （如「至少留一列」「必填列锁定」）与「松手隐藏」回调。

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../core/theme/uten_colors.dart';
import '../../core/theme/uten_tokens.dart';
import '../buttons/uten_button.dart';
import '../inputs/uten_field_hint_icon.dart';

/// 列头「标签 + ⓘ 说明」（MasterDataTableView / UtenEditableGrid 共用，2026-09-10）。
///
/// 全站列级通用说明（数量/单价/币种/税率等对所有行相同的口径）统一放列头 ⓘ，
/// 格内只保留行特有的错误/预填图标。此前两张表各自用 Material `Tooltip`
/// （默认长按触发，触屏与「长按拎起排序列」打架；无点按/键盘入口），输入框
/// 用的却是 [UtenFieldHintIcon]，三套实现并存——现收敛为同一份：
/// 悬停/点按/键盘同一行为，并吞掉长按避免 arm 排序。
class UtenColumnHeaderInfo extends StatelessWidget {
  const UtenColumnHeaderInfo({
    super.key,
    required this.label,
    required this.message,
  });

  /// 列头文案控件（调用方已按自己的样式/必填星号构好）。
  final Widget label;

  /// 说明文案（悬停/点按弹出）。
  final String message;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(child: label),
        UtenColumnHintIcon(message: message),
      ],
    );
  }
}

/// 列头说明图标（只有 ⓘ，不带文案）：列头已自行渲染标签、只想在其后补一个说明
/// 图标时用它（如 MasterDataTableView 的列头 Row 内）。行为与 [UtenColumnHeaderInfo]
/// 完全一致：悬停/点按/键盘同一入口。opaque + 吞长按，让 ⓘ 上的按压只开说明、
/// 不触发列换位/移除拖拽（换位改成按下即拖之后，这层隔离更要紧）。
class UtenColumnHintIcon extends StatelessWidget {
  const UtenColumnHintIcon({super.key, required this.message});

  /// 说明文案（悬停/点按弹出）。
  final String message;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPress: () {},
      // 列头走紧凑态（28×28 命中区）：表单的 44×44 会把稠密列头 Row 顶出溢出
      //（2026-09-11 实测物料分析等 26 个用例报 1px 溢出）。
      child: UtenFieldHintIcon(info: message, dense: true),
    );
  }
}

/// 行首多选列「横滚时钉在视口左缘」的通用包裹（主数据表 / 编辑明细表共用，2026-09-11）。
///
/// 用户诉求：左右拖表格时勾选框列不能被滚走，一直看得见。
///
/// 做法：勾选格照常留在 Row 里（列位与行高天然对齐、原交互不变）；同一行的 Stack 上
/// 常挂一份跟手副本，按横向滚动偏移同向平移贴在视口左缘、盖住底下的数据格。
///
/// **未横滚时副本必须 [IgnorePointer] + 不可见**：一个 48×行高的定位子节点即使内容
/// 为空，也会把落在首列的点击吃掉（2026-09-11 实测把 BOM 树的展开箭头点不动了）；
/// 而这份挂载又不能靠宿主 setState 去增删——滚动回调里重建整行会让
/// `ensureVisible` 之后的点击落空（同日实测 4 个用例炸在这上面）。故：**只切
/// IgnorePointer/Visibility，不动挂载**，重建全部收敛在 AnimatedBuilder 内部。
///
/// 为什么不拆成「左固定窗格 + 右滚动窗格」：这两张表的行高由内容决定（备注列会换行、
/// 多选态用 IntrinsicHeight 拉齐），两个窗格各自布局必然对不齐行高，还要再做一套
/// 竖向滚动同步——同一个 Row 里做平移是唯一天然对齐的解法。
class UtenFrozenLeadingColumn extends StatelessWidget {
  const UtenFrozenLeadingColumn({
    super.key,
    required this.horizontal,
    required this.width,
    required this.cell,
    required this.row,
  });

  /// 该表的横向滚动控制器（表头用表头那只，表体用表体那只；两者本就双向同步）。
  final ScrollController horizontal;

  /// 冻结列宽（= 行首格的宽度）。
  final double width;

  /// 冻结列的格子内容（与行首格同一份构建结果）。
  final Widget cell;

  /// 整行（首格照常在内）。
  final Widget row;

  /// 当前横向偏移；无 client 或全屏路由双挂导致多个 position 时回落 0
  /// （`.offset` 在多 position 下会断言失败）。
  double get _offset =>
      horizontal.hasClients && horizontal.positions.length == 1
      ? horizontal.offset
      : 0;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        row,
        // ⚠️ 定位块必须是**整行大小**（Positioned.fill），不能只占左边 48px：
        // `Transform.translate` 只搬绘制，命中测试仍被父级 RenderBox 的 size 挡住——
        // 定位块只有 48 宽时，平移到视口左缘的那份副本**画得出来却点不动**
        // （2026-09-11 用户反馈「拖动后最顶上的多选框就失灵，必须拖回最左边才管用」）。
        // 整行大小 + 内部 Align(48 宽) 后，命中只落在那 48px 上，其余位置照常穿透到行。
        Positioned.fill(
          child: AnimatedBuilder(
            animation: horizontal,
            builder: (_, child) {
              final dx = _offset;
              final frozen = dx > 0;
              return IgnorePointer(
                ignoring: !frozen,
                child: Visibility(
                  visible: frozen,
                  child: Transform.translate(
                    offset: Offset(dx, 0),
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: SizedBox(
                        width: width,
                        height: double.infinity,
                        child: child,
                      ),
                    ),
                  ),
                ),
              );
            },
            child: cell,
          ),
        ),
      ],
    );
  }
}

/// 一个待选列：[key]（稳定标识）、[label]（展示名）、[required]（必填锁定）。
class UtenColumnChooserEntry {
  const UtenColumnChooserEntry({
    required this.key,
    required this.label,
    this.required = false,
  });

  final String key;
  final String label;

  /// 必填列锁定：弹层勾选禁用并标注「必填列，不可隐藏」，表头拖出隐藏对其无效
  /// （必填项不允许从界面上消失）。主数据表不传（无必填语义）。
  final bool required;
}

/// 「表头设置 x/y」按钮 + 按钮处锚定的浮层勾选列表。
///
/// 弹层内容全部由 props 驱动（宿主持状态）；本组件内的交互回调只转发宿主并请求
/// 浮层重绘（OverlayEntry 不随父重建，[didUpdateWidget] 里 post-frame 再补一次，
/// 覆盖宿主 setState 后 props 迟到一帧的时序）。
class UtenColumnChooserButton extends StatefulWidget {
  const UtenColumnChooserButton({
    super.key,
    required this.entries,
    required this.hiddenKeys,
    required this.onToggle,
    required this.onToggleAll,
    this.order,
    this.onReorder,
    this.onReset,
  });

  /// 全部列（按表格默认列序）。
  final List<UtenColumnChooserEntry> entries;

  /// 当前隐藏的列 key 集合（宿主持有，这里只读展示）。
  final Set<String> hiddenKeys;

  /// 切换单列显隐；「至少保留一列」与「必填锁定」由本组件按 entries 判定禁用。
  final ValueChanged<String> onToggle;

  /// 全选(true=全部显示) / 取消全选(false=仅留首列；必填列始终保留)。
  final ValueChanged<bool> onToggleAll;

  /// 当前列显示顺序（含隐藏列）。null = 不支持拖拽排序（主数据表）。
  final List<String>? order;

  /// 拖拽排序回调（提供 [order] 时弹层行尾显拖拽把手）。
  final void Function(int oldIndex, int newIndex)? onReorder;

  /// 恢复默认（清隐藏 + 回默认序）。null = 不显示「恢复默认」行。
  final VoidCallback? onReset;

  @override
  State<UtenColumnChooserButton> createState() =>
      _UtenColumnChooserButtonState();
}

class _UtenColumnChooserButtonState extends State<UtenColumnChooserButton> {
  final LayerLink _link = LayerLink();
  final ScrollController _scroll = ScrollController();
  OverlayEntry? _overlay;

  /// 弹层内展示顺序：order 优先（未知 key 忽略、缺列按默认序补齐），否则 entries 原序。
  List<UtenColumnChooserEntry> get _orderedEntries {
    final byKey = {for (final e in widget.entries) e.key: e};
    if (widget.order == null) return widget.entries;
    final seen = <String>{};
    final result = <UtenColumnChooserEntry>[
      for (final key in widget.order!)
        if (byKey.containsKey(key) && seen.add(key)) byKey[key]!,
    ];
    for (final e in widget.entries) {
      if (!seen.contains(e.key)) result.add(e);
    }
    return result;
  }

  void _open() {
    if (_overlay != null) return;
    _overlay = OverlayEntry(builder: _buildOverlay);
    Overlay.of(context, rootOverlay: true).insert(_overlay!);
  }

  void _close() {
    _overlay?.remove();
    _overlay = null;
  }

  /// 勾选后浮层内勾选态需同步刷新（OverlayEntry 不随父组件自动重建）。
  void _toggle(String key) {
    widget.onToggle(key);
    _overlay?.markNeedsBuild();
  }

  void _toggleAll(bool selectAll) {
    widget.onToggleAll(selectAll);
    _overlay?.markNeedsBuild();
  }

  void _reorder(int oldIndex, int newIndex) {
    widget.onReorder?.call(oldIndex, newIndex);
    _overlay?.markNeedsBuild();
  }

  void _reset() {
    widget.onReset?.call();
    _close();
  }

  @override
  void didUpdateWidget(covariant UtenColumnChooserButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!setEquals(oldWidget.hiddenKeys, widget.hiddenKeys) ||
        oldWidget.order != widget.order ||
        oldWidget.entries.length != widget.entries.length) {
      // 宿主 setState → 新 props 就位后补一次浮层重建（本帧 build 期 Overlay 可能
      // 已先于本组件重建过，直接 mark 会撞「build 期 setState」断言，故 post-frame）。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _overlay?.markNeedsBuild();
      });
    }
  }

  @override
  void dispose() {
    _close();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final visible = widget.entries.length - widget.hiddenKeys.length;
    return CompositedTransformTarget(
      link: _link,
      // 深绿大号白字（UtenButton 默认 primary 实心深绿，与工具条「预览打印/下载表格」同款）。
      // 高度对齐表格工具条统一口径 48（UtenTableToolbar.controlHeight）。
      child: UtenButton(
        size: UtenButtonSize.large,
        height: UtenTableToolbar.controlHeight,
        icon: Icons.view_column_outlined,
        onPressed: _open,
        child: Text('表头设置 $visible/${widget.entries.length}'),
      ),
    );
  }

  Widget _buildOverlay(BuildContext ctx) {
    final theme = Theme.of(ctx);
    final entries = _orderedEntries;
    final hidden = widget.hiddenKeys;
    final allVisible = hidden.isEmpty;
    final visibleCount = entries.length - hidden.length;
    final maxHeight = (MediaQuery.sizeOf(ctx).height * 0.65)
        .clamp(240.0, 520.0)
        .toDouble();
    return Stack(
      children: [
        // 点菜单外空白关闭。
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _close,
          ),
        ),
        CompositedTransformFollower(
          link: _link,
          targetAnchor: Alignment.bottomLeft,
          offset: const Offset(0, 2),
          child: TapRegion(
            onTapOutside: (_) => _close(),
            child: Material(
              key: const ValueKey('uten-column-chooser'),
              color: theme.colorScheme.surfaceContainerHigh,
              elevation: 8,
              borderRadius: BorderRadius.circular(8),
              clipBehavior: Clip.antiAlias,
              child: Container(
                constraints: BoxConstraints(
                  maxHeight: maxHeight,
                  maxWidth: 260,
                ),
                child: Scrollbar(
                  controller: _scroll,
                  thumbVisibility: entries.length > 8,
                  child: _buildList(
                    theme,
                    entries,
                    hidden,
                    allVisible,
                    visibleCount,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildList(
    ThemeData theme,
    List<UtenColumnChooserEntry> entries,
    Set<String> hidden,
    bool allVisible,
    int visibleCount,
  ) {
    final columnRows = <Widget>[
      for (final entry in entries)
        _entryRow(theme, entry, hidden, visibleCount),
    ];
    // 首两行（全选+分隔）与末尾（恢复默认区）固定不参与排序：拖拽把手只挂列行；
    // ReorderableListView 契约要求全部子项带 key，固定行用稳定 key 补齐。
    final rows = <Widget>[
      KeyedSubtree(
        key: const ValueKey('uten-column-chooser-header'),
        child: _checkRow(
          // TODO(l10n): 补 arb
          label: '全选',
          checked: allVisible,
          enabled: true,
          bold: true,
          onTap: () => _toggleAll(!allVisible),
          theme: theme,
        ),
      ),
      const KeyedSubtree(
        key: ValueKey('uten-column-chooser-divider'),
        child: Divider(height: 1, thickness: 1),
      ),
      ...columnRows,
      if (widget.onReset != null) ...[
        const KeyedSubtree(
          key: ValueKey('uten-column-chooser-reset-divider'),
          child: Divider(height: 1, thickness: 1),
        ),
        KeyedSubtree(
          key: const ValueKey('uten-column-chooser-reset'),
          child: _resetRow(theme),
        ),
      ],
    ];
    if (widget.onReorder == null) {
      return ListView(
        key: const ValueKey('uten-column-chooser-scroll'),
        controller: _scroll,
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        children: rows,
      );
    }
    final fixedTail = widget.onReset != null ? 2 : 0;
    // onReorderItem 的 newIndex 已含下移补偿（等价 removeAt 后的最终插入位）。
    return ReorderableListView(
      key: const ValueKey('uten-column-chooser-scroll'),
      buildDefaultDragHandles: false,
      scrollController: _scroll,
      shrinkWrap: true,
      padding: EdgeInsets.zero,
      children: rows,
      onReorderItem: (oldIndex, newIndex) {
        // 固定行（全选/分隔/恢复默认）不可搬：只允许在列行区间内移动。
        if (oldIndex < 2) return;
        final lastColumnIndex = rows.length - fixedTail - 1;
        if (oldIndex > lastColumnIndex) return;
        var target = newIndex;
        if (target < 2) target = 2;
        if (target > lastColumnIndex) target = lastColumnIndex;
        if (target == oldIndex) return;
        _reorder(oldIndex - 2, target - 2);
      },
    );
  }

  /// 单个列行（勾选 + 名称 + 可选拖拽把手 + 锁定/兜底说明）。
  Widget _entryRow(
    ThemeData theme,
    UtenColumnChooserEntry entry,
    Set<String> hidden,
    int visibleCount,
  ) {
    final isHidden = hidden.contains(entry.key);
    final canHide = !entry.required && (isHidden || visibleCount > 1);
    final String? hint = entry.required
        ? '必填列，不可隐藏'
        : !canHide
        ? '至少保留一列'
        : null;
    final index = _orderedEntries.indexOf(entry);
    return KeyedSubtree(
      key: ValueKey('uten-column-option-${entry.key}'),
      child: _checkRow(
        label: entry.required ? '${entry.label} *' : entry.label,
        checked: !isHidden,
        enabled: canHide,
        subtitle: hint,
        trailing: widget.onReorder != null
            ? ReorderableDragStartListener(
                index: index + 2,
                child: const SizedBox(
                  width: 40,
                  height: 40,
                  child: Tooltip(
                    message: '拖动排序',
                    child: Icon(Icons.drag_handle_rounded, size: 20),
                  ),
                ),
              )
            : null,
        onTap: canHide ? () => _toggle(entry.key) : null,
        theme: theme,
      ),
    );
  }

  Widget _resetRow(ThemeData theme) {
    return InkWell(
      onTap: _reset,
      child: Container(
        constraints: const BoxConstraints(minHeight: 44),
        alignment: Alignment.center,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.restart_alt_rounded,
              size: 16,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: UtenSpacing.s4),
            Text(
              '恢复默认',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _checkRow({
    required String label,
    required bool checked,
    required bool enabled,
    required VoidCallback? onTap,
    required ThemeData theme,
    bool bold = false,
    String? subtitle,
    Widget? trailing,
  }) {
    final disabledColor = theme.colorScheme.onSurfaceVariant.withValues(
      alpha: 0.4,
    );
    return Semantics(
      button: true,
      checked: checked,
      enabled: enabled,
      label: label,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 44),
          padding: const EdgeInsets.symmetric(
            horizontal: UtenSpacing.s12,
            vertical: UtenSpacing.s8,
          ),
          child: Row(
            children: [
              Icon(
                checked
                    ? Icons.check_box_rounded
                    : Icons.check_box_outline_blank_rounded,
                size: 18,
                color: !enabled
                    ? disabledColor
                    : checked
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: UtenSpacing.s8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
                        color: enabled ? null : disabledColor,
                      ),
                    ),
                    if (subtitle != null)
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontSize: 11,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: UtenSpacing.s4),
                trailing,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 表头「按住纵向拖→隐藏列」手势态（不可变；经 [UtenColumnDragHideHost.columnDragHide]
/// ValueNotifier 通知表头视觉与跟手浮层重建）。
class UtenColumnDragHide {
  const UtenColumnDragHide({this.index, this.dy = 0.0, this.armed = false});

  /// 被拖列在宿主 columns 中的原始下标；null = 当前无进行中的拖拽。
  final int? index;

  /// 累计纵向增量，驱动跟手浮层 offset 跟手位移（显示时 clamp）。
  final double dy;

  /// 是否过阈值、松开将隐藏该列（arm 后浮层红底红×）。
  final bool armed;
}

/// 表头「按下即拖→横拖换位→松手落位」列排序手势态（不可变；经
/// [UtenColumnHeaderDragHost.columnReorder] 通知视觉重建）。
class UtenColumnReorderDrag {
  const UtenColumnReorderDrag({this.fromIndex, this.dx = 0.0, this.slot = 0});

  /// 被拎起列在宿主 columns 中的原始下标；null = 当前无进行中的排序拖拽。
  final int? fromIndex;

  /// 相对拎起位的水平位移（已 clamp 在表头范围内），驱动跟手浮层横移。
  final double dx;

  /// 当前插入槽位 = 可见列序列（剔除被拖列自身）中的插入下标。
  final int slot;
}

/// 表头列手势宿主：按下即拖，**按方向分流**——
/// - **横拖 = 换位**（root Overlay 跟手浮层 + 插入位指示线 → 松手落位）；
/// - **竖拖 = 移除**（同款浮层，过阈值变红底红× → 松手隐藏该列）。
///
/// 2026-09-11 改动：排序此前要「长按约 500ms 拎起」，用户反馈等太久，改为与隐藏
/// 同级的即时拖拽——GestureDetector 同时挂横/竖两个 drag 识别器，用户先往哪个方向
/// 走就由哪个方向的识别器赢下竞技场，方向判定不用自己写。
/// **代价**：表头本身不再能横拖滚动表格（该手势被换位吃掉）。表体横拖与底部横滚条
/// 都还在，滚动能力没丢。
///
/// 挂在表格 State 上提供完整手势机械（状态推进/单指契约/浮层挂载/原格变淡/arm 阈值），
/// 宿主只需实现抽象取值与回调。
///
/// 用法（表头格，一行搞定全部手势）：
/// ```
/// columnHeaderGestureArea(          // 横拖换位 + 竖拖移除的识别器（外层，拖拽中不重建）
///   i,
///   columnHeaderCell(i, headerCell), // 原格变淡 + 浮层锚点（两层手势共用同一 target）
/// )
/// ```
/// 表头行外再包 [columnHeaderIndicatorOverlay] 渲染排序插入位指示线。
mixin UtenColumnHeaderDragHost<T extends StatefulWidget> on State<T> {
  /// arm 阈值：累计纵向位移超过即变红（松开隐藏）；拖回阈值内取消。
  static const double kArmThreshold = 10.0;

  /// 跟手浮层最大纵移（原格不动、仅浮层跟随，可放宽到较大值）。
  static const double kMaxTranslate = 120.0;

  final ValueNotifier<UtenColumnDragHide> columnDragHide =
      ValueNotifier<UtenColumnDragHide>(const UtenColumnDragHide());

  /// 第 [index] 列表头的锚点（跟手浮层 CompositedTransformFollower 用）。
  /// 宿主按列下标缓存 LayerLink；列集合变化时清空重建。
  LayerLink columnDragLink(int index);

  /// 跟手浮层宽度 = 被拖列当前列宽（下标越界回落安全值）。
  double columnDragWidth(int index);

  /// 跟手浮层文案 = 被拖列表头名。
  String columnDragLabel(int index);

  /// 该列当前是否允许拖出隐藏（宿主管家：如「至少留一列」「必填列锁定」）。
  bool columnCanDragHide(int index);

  /// 松手且 armed：隐藏该列（宿主复用既有显隐切换守卫）。
  void onColumnDragHide(int index);

  /// 参与排序的可见列布局：按当前显示顺序给出（原始列下标, 当前列宽）。
  /// 槽位计算、指示线定位、浮层横移 clamp 全部由此推导。
  List<({int index, double width})> get reorderVisibleColumns;

  /// 横拖换位落位：把原始下标 [fromOriginalIndex] 的列插到可见序列的 [slot] 槽
  /// （宿主负责改自己的列序状态并触发持久化/重建）。
  void onColumnsReordered(int fromOriginalIndex, int slot);

  /// 是否启用「竖拖移除列」手势（编辑明细表跟随 showColumnSettings；默认开）。
  bool get columnHeaderHideEnabled => true;

  /// 是否启用「横拖换位」手势（编辑明细表跟随 showColumnSettings；默认开）。
  bool get columnHeaderReorderEnabled => true;

  final ValueNotifier<UtenColumnReorderDrag> columnReorder =
      ValueNotifier<UtenColumnReorderDrag>(const UtenColumnReorderDrag());

  /// 换位拖拽的累计横向位移（drag 识别器只给逐帧 delta，起点位移要自己攒）。
  double _reorderAccumDx = 0;

  OverlayEntry? _columnDragGhostEntry;
  OverlayEntry? _reorderGhostEntry;

  void columnDragHideStart(int index) {
    if (columnDragHide.value.index != null) return; // 单指：已有拖拽则忽略后指
    columnDragHide.value = UtenColumnDragHide(index: index);
    _ensureColumnDragGhost();
  }

  void columnDragHideUpdate(int index, double deltaDy) {
    final s = columnDragHide.value;
    if (s.index != index) return; // 非当前手势（被忽略的并发指）
    final dy = s.dy + deltaDy;
    final armed = dy.abs() > kArmThreshold && columnCanDragHide(index);
    columnDragHide.value = UtenColumnDragHide(
      index: index,
      dy: dy,
      armed: armed,
    );
  }

  void columnDragHideEnd(int index) {
    final s = columnDragHide.value;
    if (s.index != index) return; // 非当前手势
    final willHide = s.armed;
    columnDragHide.value = const UtenColumnDragHide(); // 先清态（浮层 VLB 重建为空）
    _removeColumnDragGhost(); // 卸跟手浮层
    if (willHide) onColumnDragHide(index);
  }

  /// 列集合变化/全屏切换：两类拖拽态都可能指向失效下标，统一重置并卸浮层。
  void columnHeaderDragReset() {
    if (columnDragHide.value.index != null || _columnDragGhostEntry != null) {
      columnDragHide.value = const UtenColumnDragHide();
      _removeColumnDragGhost();
    }
    columnReorderCancel();
  }

  // —— 横拖换位（按下即拖 → 横移 → 松手落位）——

  void columnReorderStart(int index) {
    if (columnReorder.value.fromIndex != null) return; // 单指契约
    if (reorderVisibleColumns.length < 2) return; // 单列无可排序
    _reorderAccumDx = 0;
    columnReorder.value = UtenColumnReorderDrag(
      fromIndex: index,
      slot: _reorderVisibleSlotOf(index),
    );
    _ensureReorderGhost();
  }

  /// 逐帧横向增量推进（drag 识别器的 `details.delta.dx`）。
  void columnReorderUpdateDelta(double deltaDx) {
    if (columnReorder.value.fromIndex == null) return;
    _reorderAccumDx += deltaDx;
    _applyReorderOffset(_reorderAccumDx);
  }

  void _applyReorderOffset(double rawDx) {
    final drag = columnReorder.value;
    if (drag.fromIndex == null) return;
    final dx = _clampedReorderDx(rawDx);
    final slot = _computeReorderSlot(rawDx);
    if (dx == drag.dx && slot == drag.slot) return;
    columnReorder.value = UtenColumnReorderDrag(
      fromIndex: drag.fromIndex,
      dx: dx,
      slot: slot,
    );
  }

  void columnReorderEnd() {
    final drag = columnReorder.value;
    columnReorder.value = const UtenColumnReorderDrag(); // 先清态卸浮层
    _reorderAccumDx = 0;
    _removeReorderGhost();
    final from = drag.fromIndex;
    if (from == null) return;
    if (drag.slot != _reorderVisibleSlotOf(from)) {
      onColumnsReordered(from, drag.slot);
    }
  }

  void columnReorderCancel() {
    _reorderAccumDx = 0;
    if (columnReorder.value.fromIndex == null && _reorderGhostEntry == null) {
      return;
    }
    columnReorder.value = const UtenColumnReorderDrag();
    _removeReorderGhost();
  }

  /// 可见序列中该原始下标的位置（不在可见列中返回 -1）。
  int _reorderVisibleSlotOf(int originalIndex) {
    var slot = 0;
    for (final c in reorderVisibleColumns) {
      if (c.index == originalIndex) return slot;
      slot++;
    }
    return -1;
  }

  /// 该列左缘在表头列区坐标系中的位置（不含行首选择列等前导宽度）。
  double _reorderLeftOf(int originalIndex) {
    var left = 0.0;
    for (final c in reorderVisibleColumns) {
      if (c.index == originalIndex) break;
      left += c.width;
    }
    return left;
  }

  /// 浮层横移 clamp：不出表头列区左右界（±4px 富余）。
  double _clampedReorderDx(double dx) {
    final from = columnReorder.value.fromIndex;
    if (from == null) return 0;
    final total = reorderVisibleColumns.fold(0.0, (s, c) => s + c.width);
    final left = _reorderLeftOf(from);
    final width = columnDragWidth(from);
    return dx.clamp(-left - 4, total - left - width + 4);
  }

  /// 槽位 = 中心点落在被拖列之前/之上的其他可见列个数（标准插入下标语义）。
  int _computeReorderSlot(double rawDx) {
    final from = columnReorder.value.fromIndex;
    if (from == null) return 0;
    final center =
        _reorderLeftOf(from) +
        _clampedReorderDx(rawDx) +
        columnDragWidth(from) / 2;
    var slot = 0;
    var left = 0.0;
    for (final c in reorderVisibleColumns) {
      if (c.index != from && left + c.width / 2 < center) slot++;
      left += c.width;
    }
    return slot;
  }

  /// 插入位指示线的 x（表头列区坐标系；宿主加自己的前导宽度）。
  double _reorderSlotX(int slot) {
    var x = 0.0;
    var counted = 0;
    for (final c in reorderVisibleColumns) {
      if (counted == slot) break;
      if (c.index != columnReorder.value.fromIndex) counted++;
      x += c.width;
    }
    return x;
  }

  void _ensureReorderGhost() {
    if (_reorderGhostEntry != null) return;
    if (!mounted) return;
    final overlay = Overlay.of(context, rootOverlay: true);
    _reorderGhostEntry = OverlayEntry(builder: _buildReorderGhost);
    overlay.insert(_reorderGhostEntry!);
  }

  void _removeReorderGhost() {
    _reorderGhostEntry?.remove();
    _reorderGhostEntry = null;
  }

  /// 排序跟手浮层：与隐藏浮层同一视觉语言（root Overlay 最顶层、列宽对齐、阴影
  /// 浮起），中性色（排序不是危险操作）；offset=(dx, 0) 横向跟手。
  Widget _buildReorderGhost(BuildContext ctx) {
    return ValueListenableBuilder<UtenColumnReorderDrag>(
      valueListenable: columnReorder,
      builder: (_, drag, _) {
        final i = drag.fromIndex;
        if (i == null) return const SizedBox.shrink();
        return Align(
          alignment: Alignment.topLeft,
          child: CompositedTransformFollower(
            link: columnDragLink(i),
            offset: Offset(drag.dx, 0),
            showWhenUnlinked: false,
            child: IgnorePointer(
              child: UtenColumnDragGhostCell(
                width: columnDragWidth(i),
                label: columnDragLabel(i),
                armed: false,
              ),
            ),
          ),
        );
      },
    );
  }

  /// 挂跟手浮层到 root Overlay（仅当尚未挂）。用 State 的 context 取 root overlay——
  /// 全屏路由也在 root Navigator 上，故同一 Overlay 兼容正常/全屏两种场景；浮层经
  /// LayerLink 锚定到（可能在全屏路由子树内的）target，跨子树跟随正常。
  void _ensureColumnDragGhost() {
    if (_columnDragGhostEntry != null) return;
    if (!mounted) return;
    final overlay = Overlay.of(context, rootOverlay: true);
    _columnDragGhostEntry = OverlayEntry(builder: _buildColumnDragGhost);
    overlay.insert(_columnDragGhostEntry!);
  }

  void _removeColumnDragGhost() {
    _columnDragGhostEntry?.remove();
    _columnDragGhostEntry = null;
  }

  /// 跟手浮层：root Overlay 最顶层 → 不被表头/表体裁切、压在整表之上，拖出表头也
  /// 可见。CompositedTransformFollower 锚定被拖列 target，offset=(0, dy) 跟手纵移；
  /// dy clamp 到 [UtenColumnDragHideHost.kMaxTranslate]。
  /// ⚠️ Overlay 台上条目拿的是 tight 全屏约束，follower 直接当根会被拉成全屏面板；
  /// 外层 Align(topLeft) 给出宽松约束，浮层才保持原表头格大小（列宽 × ~44）。
  Widget _buildColumnDragGhost(BuildContext ctx) {
    return ValueListenableBuilder<UtenColumnDragHide>(
      valueListenable: columnDragHide,
      builder: (_, drag, _) {
        final i = drag.index;
        if (i == null) return const SizedBox.shrink();
        final dy = drag.dy.clamp(-kMaxTranslate, kMaxTranslate);
        return Align(
          alignment: Alignment.topLeft,
          child: CompositedTransformFollower(
            link: columnDragLink(i),
            // 默认 target/followerAnchor 均为 topLeft：浮层左上角对齐列头左上角，
            // 再加 offset=(0, dy) 跟手纵移。
            offset: Offset(0, dy),
            showWhenUnlinked: false,
            child: IgnorePointer(
              child: UtenColumnDragGhostCell(
                width: columnDragWidth(i),
                label: columnDragLabel(i),
                armed: drag.armed,
              ),
            ),
          ),
        );
      },
    );
  }

  /// 表头格原位视觉包裹：CompositedTransformTarget 始终挂上（active 与否都包，
  /// 隐藏/排序两类浮层从拖拽开始就能锚定到位）；任一拖拽命中该列时原格变淡
  /// （配跟手浮层显"列已离位"）。手势识别器须包在本方法**外层**
  /// （[columnHeaderGestureArea]）：拖拽更新只重建内层视觉，不打断进行中的手势。
  Widget columnHeaderCell(int index, Widget cell) {
    return AnimatedBuilder(
      animation: Listenable.merge([columnDragHide, columnReorder]),
      builder: (_, _) => CompositedTransformTarget(
        link: columnDragLink(index),
        child:
            (columnDragHide.value.index == index ||
                columnReorder.value.fromIndex == index)
            ? Opacity(opacity: 0.35, child: cell)
            : cell,
      ),
    );
  }

  /// 表头格手势区：横拖换位 + 竖拖移除的识别器一套挂好，**都不需要长按**。
  ///
  /// 方向消歧交给竞技场：同一 GestureDetector 上的横/竖两个 drag 识别器，用户
  /// 先往哪个方向越过 slop，哪个就赢——不用自己算主轴。右边界 8px 的列宽手柄是
  /// Stack 兄弟且在上层，其横拖优先命中，与换位不打架。
  ///
  /// 本识别器嵌在表头横向 Scrollable 内层：手势事件从最深命中项往上派发，子识别器
  /// 先接受，故表头横拖归换位而不是滚动表格（表体横拖与底部横滚条仍可滚）。
  ///
  /// [DragStartBehavior.down]：识别器接受竞技场的那一拍位移默认会被吞掉
  /// （拖出去又拖回原位会误判 armed）——start=down 让首拍 delta 从按下点起算，
  /// 往返位移精确归零（2026-09-05 实测）。
  Widget columnHeaderGestureArea(int index, Widget child) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      dragStartBehavior: DragStartBehavior.down,
      onVerticalDragStart: columnHeaderHideEnabled
          ? (_) => columnDragHideStart(index)
          : null,
      onVerticalDragUpdate: columnHeaderHideEnabled
          ? (d) => columnDragHideUpdate(index, d.delta.dy)
          : null,
      onVerticalDragEnd: columnHeaderHideEnabled
          ? (_) => columnDragHideEnd(index)
          : null,
      onVerticalDragCancel: columnHeaderHideEnabled
          ? () => columnHeaderDragReset()
          : null,
      onHorizontalDragStart: columnHeaderReorderEnabled
          ? (_) => columnReorderStart(index)
          : null,
      onHorizontalDragUpdate: columnHeaderReorderEnabled
          ? (d) => columnReorderUpdateDelta(d.delta.dx)
          : null,
      onHorizontalDragEnd: columnHeaderReorderEnabled
          ? (_) => columnReorderEnd()
          : null,
      onHorizontalDragCancel: columnHeaderReorderEnabled
          ? columnReorderCancel
          : null,
      child: child,
    );
  }

  /// 表头行外包裹：换位拖动中在目标槽位渲染竖向插入指示线。
  /// [leadingInset] = 行首选择列等前导宽度（指示线 x 相对列区原点）。
  Widget columnHeaderIndicatorOverlay({
    double leadingInset = 0,
    required Widget child,
  }) {
    return Stack(
      children: [
        child,
        ValueListenableBuilder<UtenColumnReorderDrag>(
          valueListenable: columnReorder,
          builder: (context, drag, _) {
            if (drag.fromIndex == null) return const SizedBox.shrink();
            final theme = Theme.of(context);
            return Positioned(
              left: (leadingInset + _reorderSlotX(drag.slot) - 1.25).clamp(
                leadingInset,
                double.infinity,
              ),
              top: 2,
              bottom: 2,
              child: Container(
                width: 2.5,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary,
                  borderRadius: BorderRadius.circular(2),
                  boxShadow: const [
                    BoxShadow(color: Colors.black26, blurRadius: 3),
                  ],
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  @override
  void dispose() {
    _removeColumnDragGhost();
    _removeReorderGhost();
    columnDragHide.dispose();
    columnReorder.dispose();
    super.dispose();
  }
}

/// 跟手浮层单元：root Overlay 最顶层渲染的"被拎起的列头"——列宽与表头对齐、标签同款，
/// boxShadow 阴影显"浮起"；armed 后红底红×（松开即隐藏）。IgnorePointer 包裹纯展示、
/// 不抢手势（外层 GestureDetector 仍正常收纵向拖拽）。
class UtenColumnDragGhostCell extends StatelessWidget {
  const UtenColumnDragGhostCell({
    super.key,
    required this.width,
    required this.label,
    required this.armed,
  });

  final double width;
  final String label;
  final bool armed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const error = UtenColors.error;
    // Material(transparency) 在 Overlay 里提供 DefaultTextStyle / 文本方向上下文。
    return Material(
      type: MaterialType.transparency,
      child: Container(
        width: width,
        // minHeight:44 与表头格一致，浮层高度对齐原格。
        constraints: const BoxConstraints(minHeight: 44),
        padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s12),
        decoration: BoxDecoration(
          color: armed
              ? error.withValues(alpha: 0.16)
              : theme.colorScheme.surfaceContainerHigh,
          border: Border.all(
            color: armed ? error : theme.colorScheme.outline,
            width: armed ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(4),
          boxShadow: const [
            BoxShadow(
              color: UtenColors.floatingCellShadow,
              blurRadius: 10,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: Stack(
          children: [
            Align(
              alignment: Alignment.centerLeft,
              // heightFactor 收紧到文字高度：裸 Align 在宽松约束下会 expand 到
              // 上限（Overlay 里即全屏高），浮层必须保持原格 ~44 高。
              heightFactor: 1,
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: armed ? FontWeight.w700 : FontWeight.w600,
                  color: armed ? error : theme.colorScheme.onSurface,
                ),
              ),
            ),
            // Positioned 子节点不参与 Stack 尺寸计算：直接放 Center 会把浮层
            // 撑满宽松约束上限（Overlay 里即全屏高），浮层必须保持原表头格高度。
            if (armed)
              const Positioned.fill(child: Center(child: _DragHideBadge())),
          ],
        ),
      ),
    );
  }
}

/// 待隐藏徽标：红底白×（醒目，老人也能看清）。跟手浮层 armed 时居中显示。
class _DragHideBadge extends StatelessWidget {
  const _DragHideBadge();
  @override
  Widget build(BuildContext context) => const DecoratedBox(
    decoration: BoxDecoration(
      color: UtenColors.error,
      shape: BoxShape.circle,
      boxShadow: [
        BoxShadow(
          color: UtenColors.dragBadgeShadow,
          blurRadius: 4,
          offset: Offset(0, 1),
        ),
      ],
    ),
    child: Padding(
      padding: EdgeInsets.all(4),
      child: Icon(Icons.close, color: Colors.white, size: 18),
    ),
  );
}
