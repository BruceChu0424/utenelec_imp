// UtenFilterToolbar - 「分类分段 + 搜索」统一筛选工具条。
//
// 2026-09-01 全平台 UI 统一的标准范式：凡是页面上有「分类/状态筛选」的地方，
// 一律用本组件呈现，不再手写各种筛选按钮、Chip 行或自成一套的分段样式——
//
// - 分段导航：胶囊 StadiumBorder、与搜索框**严格同高**（两侧共用下限令牌
//   UtenFilterRow.minHeight，见 UtenSearchBar 头部机制说明）、
//   选中只变背景色不出 ✓ 图标；2026-10-04 起分段行用 UtenSegmentRow 渲染
//   （每格宽度跟随自身内容，字少的格不再被撑到最宽格的宽度）；
// - 层级规则：大类分类（来源/方向/单据类型）在上、小类分类（状态）在下；
//   小类行默认 [enabled]=false 置灰，选中大类后才由页面解锁；
// - 进页面默认选中（2026-10-04 用户口径，[autoSelectBadge]）：
//   计数到位后若有「红色待办徽章 > 0」的分类段就直接选中它（第一条红段）；
//   没有红再看「黄色在办徽章 > 0」的段（红的计数还有 null 未到齐时先等，
//   不提前跳黄）；红黄都没有才保持默认不选。用户一旦选中过任何分段（手动
//   或自动），本条不再自动改选。小类行同样适用：大类解锁 + 计数到位后
//   自动选中带红徽章的小类；
// - 「全部」段保留为显式选项——单选点击已选段不会回调，选中后
//   只能靠「全部」段回到全量视图；
// - 视图切换例外：切换内容区的工具条（如应付工作区/报表变体）必须始终有
//   选中项，不适用「默认不选」；
// - 计数口径：分段计数有三种形态，**默认中性括号数字 `(N)`**，两种徽章都要显式挑
//   （[UtenFilterSegment.countForm]，见 docs/00-项目准则/14-徽章与计数口径.md）：
//   · 待办型(待审/待确认/待收货/待出库/待检/被驳回/超期/异常/等待物料/本人草稿，
//     且**这段确实在等本页用户动手**)→ `actionable` 红徽章，0/null 不显示，>99 显 99+；
//   · 在办型(生产中/加工中/在途/等待财务审核/财务已通过待执行/等待检查结果，
//     即「已经在办、还没完、现在不用我动手」)→ `inProgress` 黄徽章，同样 0/null 不显示
//     (2026-09-21 ADR-100 新增；此前这一类被判成中性括号)；
//   · 浏览型(已完成/已审/已出库/红冲/历史/全部)→ `(N)`，0 显示 `(0)` 保持队形；
//   · 同一条工具条里已有一段红徽章覆盖了这批活的总量时，细分切片走括号
//     （同一批活不在一行里红两遍）；
//   · 「全部」与终态(已完结/已决定)一律不传 count；
//   · 分段计数**永不**登记为徽章入口(服务端 WorkbenchBadgeCatalog, ADR-108)
//     ——累加只认入口，分段是页面内的切片。
// - 搜索框：全平台唯一组件 UtenSearchBar（胶囊圆角 + 清除 + 300ms 防抖），
//   药丸描边与分类栏共用 40 下限恒同高；宽度 2026-10-07 起减半为 180
//   （用户口径「搜索栏长度缩小一半」）；
// - 响应式：搜索和行尾按局部宽度换行；所有宽度下分段均按真实内容测量。
//   放不下时显示当前分类入口，打开完整纵向面板；长名与计数不缩字、不横滚。
// - 纯分类无搜索的页面只传 [segments]（searchHint 不传即不渲染搜索框）；
// - 纯搜索+行尾的页面（筛选下沉到列头/下拉，如即时库存）不传 [segments]
//   （2026-09-10 起 segments/selected/onSelectionChanged 均可省略）。
//
// 计数的数值口径由调用方负责：取该分段的「全量」计数（非当前页推算），与后端
// counts 类接口同源；加载中传 null（两种形态都不渲染数字）。

import 'package:flutter/material.dart';

import '../../../core/theme/uten_tokens.dart';
import '../feedback/uten_in_progress_badge.dart';
import '../feedback/uten_notification_badge.dart';
import '../feedback/uten_segment_badge_label.dart';
import '../inputs/uten_search_bar.dart';
import 'uten_segment_row.dart';

/// 一个分类分段：值 + 文字 + 可选计数（中性括号数字 / 红色待办徽章）。
class UtenFilterSegment<T> {
  const UtenFilterSegment({
    required this.value,
    required this.label,
    this.count,
    this.countForm = UtenSegmentCountForm.browsing,
    this.inProgressCount,
  });

  final T value;
  final String label;

  /// 大类分段专用的第二枚计数：黄色在办数，画在 [count] 那枚**左边**。
  /// 只在一个大类里同时装着「等我动手」和「在办中」两批活时才传，
  /// 见 [UtenSegmentBadgeLabel.inProgressCount]。
  final int? inProgressCount;

  /// 该分段的计数；null = 加载中/未知（不渲染，不把未知伪装成 0）。
  /// 应取该分段的「全量」计数（非当前页推算），与后端 counts 类接口同源。
  final int? count;

  /// 计数呈现形态；**默认中性括号 `(N)`**。只有「这一段确实在等本页用户动手」
  /// 时才显式传 [UtenSegmentCountForm.actionable]（见组件头部计数口径）。
  final UtenSegmentCountForm countForm;
}

class UtenFilterToolbar<T> extends StatefulWidget {
  const UtenFilterToolbar({
    super.key,
    this.segments = const [],
    this.selected = const {},
    this.onSelectionChanged,
    this.enabled = true,
    this.autoSelectBadge = true,
    this.segmentsKey,
    this.searchKey,
    this.searchHint,
    this.initialSearchValue,
    this.searchController,
    this.onSearchInputChanged,
    this.onSearchChanged,
    this.onSearchSubmitted,
    this.trailing,
    this.compactBreakpoint = 840,
    this.searchWidth = 180,
  });

  /// 分类分段（进页面默认不选；带红/黄徽章的段由 [autoSelectBadge] 自动选）。
  /// **传空列表 = 纯「搜索 + 行尾」工具条**（筛选已下沉到列头/下拉的页面，
  /// 如即时库存分类下拉化后），此时不渲染分段条，也无需传
  /// [selected]/[onSelectionChanged]。
  final List<UtenFilterSegment<T>> segments;

  /// 当前选中分段集合（单选）。空集 = 尚未选中任何分段（数据不过滤）；
  /// 「全部」类分段只是显式选项，不再是默认选中态。
  final Set<T> selected;

  /// 点击某个分段时回调其值。分段行单选点击已选段不会触发回调，
  /// 因此不会出现空集回调。[segments] 非空时必须提供。
  final ValueChanged<T>? onSelectionChanged;

  /// false = 整条置灰不可点（小类行在大类未选时的锁定态）。
  final bool enabled;

  /// 进页面默认选中（2026-10-04 用户口径）：计数到位后有红徽章(>0)的分类段
  /// 直接自动选中；没有红再看黄徽章(>0)；红黄都没有保持不选。选中一旦发生
  /// （自动或手动）永不再次自动改选。视图切换类工具条恒有选中项，本开关自然
  /// 空转；个别不想要默认选中的页面显式传 false 关闭。
  final bool autoSelectBadge;

  /// 分段按钮 key（页面既有测试/语义锚点透传，如 iqc-type-segments）。
  final Key? segmentsKey;

  /// 搜索框 key（透传）。
  final Key? searchKey;

  /// 搜索提示文案；不传且无 [searchController] 时不渲染搜索框（纯分类工具条）。
  final String? searchHint;

  final String? initialSearchValue;
  final TextEditingController? searchController;

  /// 每次输入同步回调（本地即时过滤用），先于防抖。
  final ValueChanged<String>? onSearchInputChanged;

  /// 300ms 防抖后的回调（发起异步检索用）。
  final ValueChanged<String>? onSearchChanged;

  /// 回车提交回调（不等防抖立刻检索）；报表页要求「回车即查询」。
  final ValueChanged<String>? onSearchSubmitted;

  /// 宽屏行尾内容（如「共 N 条」统计文案）。
  final Widget? trailing;

  /// 低于该宽度切窄屏布局（分类自适应 + 搜索换行）。
  final double compactBreakpoint;

  /// 宽屏搜索框宽度；2026-10-07 用户口径「搜索栏长度缩小一半」：360 → 180。
  final double searchWidth;

  @override
  State<UtenFilterToolbar<T>> createState() => _UtenFilterToolbarState<T>();
}

class _UtenFilterToolbarState<T> extends State<UtenFilterToolbar<T>> {
  /// 选中一旦发生（自动或手动）置位，之后不再自动改选。
  bool _everSelected = false;
  bool _autoSelectScheduled = false;

  @override
  void initState() {
    super.initState();
    _scheduleAutoSelect();
  }

  @override
  void didUpdateWidget(UtenFilterToolbar<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 计数异步到位/小类行解锁都会走这里，每帧重建后重估一次。
    _scheduleAutoSelect();
  }

  void _scheduleAutoSelect() {
    if (!widget.autoSelectBadge || _everSelected || _autoSelectScheduled) {
      return;
    }
    _autoSelectScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _autoSelectScheduled = false;
      _tryAutoSelect();
    });
  }

  void _tryAutoSelect() {
    if (!widget.autoSelectBadge || _everSelected) return;
    if (!widget.enabled || widget.segments.isEmpty) return;
    final onChanged = widget.onSelectionChanged;
    if (onChanged == null) return;
    if (widget.selected.isNotEmpty) {
      _everSelected = true;
      return;
    }
    final best = _bestBadgeSegment(widget.segments);
    if (best == null) return;
    _everSelected = true;
    onChanged(best.value);
  }

  /// 红 → 黄 的默认选中判序（2026-10-04 用户口径）：
  /// ① 第一条红徽章(待办)计数 > 0 的段；
  /// ② 第一条黄徽章(在办)计数 > 0 的段（含大类段挂的第二枚黄数）；
  /// ③ 都没有 → null（保持默认不选）。
  /// 计数 null = 加载中/服务端未回（GROUP BY 不产零键）→ 按 0 对待；计数
  /// 通常随同一次数据到位批量出现，快照内直接判序即可。
  UtenFilterSegment<T>? _bestBadgeSegment(List<UtenFilterSegment<T>> segments) {
    for (final segment in segments) {
      if (segment.countForm == UtenSegmentCountForm.actionable &&
          (segment.count ?? 0) > 0) {
        return segment;
      }
    }
    for (final segment in segments) {
      final yellow = segment.countForm == UtenSegmentCountForm.inProgress
          ? (segment.count ?? 0)
          : 0;
      if (yellow > 0 || (segment.inProgressCount ?? 0) > 0) {
        return segment;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled;
    final selected = widget.selected;
    // segments 为空 = 纯「搜索 + 行尾」工具条（筛选已下沉到列头/下拉的页面，
    // 如即时库存分类下拉化后）——不渲染空分段条。
    final button = widget.segments.isEmpty
        ? null
        : UtenSegmentRow<T>(
            key: widget.segmentsKey,
            compactSummary: _inProgressTotal == 0 && _actionableTotal == 0
                ? null
                : Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      if (_inProgressTotal > 0)
                        IntrinsicWidth(
                          child: UtenInProgressBadge(count: _inProgressTotal),
                        ),
                      if (_actionableTotal > 0)
                        IntrinsicWidth(
                          child: UtenNotificationBadge(count: _actionableTotal),
                        ),
                    ],
                  ),
            // 统一范式：选中只变背景色，不出现 ✓ 图标。高度不设参数——分类栏与
            // 搜索框药丸的「严格同高」靠两侧共用同一枚下限令牌（见 UtenFilterRow
            // 注释）：InputDecorator 描边只按内容高绘制、不吃 minHeight 约束，
            // 单靠 IntrinsicHeight+stretch 在「搜索内容高 < 分段下限」的密度/字号
            // 下会出现分类栏厚、搜索药丸矮（2026-10-07 根因）。
            showSelectedIcon: false,
            // 进页面不预选（selected 空集）是支持形态，自动选中走
            // _tryAutoSelect 的 post-frame 回调。
            emptySelectionAllowed: true,
            segments: [
              for (final segment in widget.segments)
                ButtonSegment(
                  value: segment.value,
                  enabled: enabled,
                  label: UtenSegmentBadgeLabel(
                    label: segment.label,
                    count: segment.count,
                    countForm: segment.countForm,
                    inProgressCount: segment.inProgressCount,
                  ),
                ),
            ],
            selected: selected,
            onSelectionChanged: (selection) {
              // 单选：点击已选段不会回调，这里恒非空。
              // 整条置灰时各分段 disabled，不会进入此回调。
              if (selection.isNotEmpty) {
                widget.onSelectionChanged?.call(selection.first);
              }
            },
          );
    final showSearch =
        widget.searchHint != null || widget.searchController != null;
    // 搜索框不加高度包装：InputDecorator 的药丸描边只认内容高与 maxHeight，
    // 外部 minHeight 拉不高描边（拉高的只是盒子）。同高由 UtenSearchBar 的
    // 图标约束下限与分段 minCellHeight 共用 UtenFilterRow.minHeight 保证。
    final search = showSearch
        ? UtenSearchBar(
            key: widget.searchKey,
            hint: widget.searchHint ?? '搜索',
            initialValue: widget.initialSearchValue,
            controller: widget.searchController,
            onInputChanged: widget.onSearchInputChanged,
            onChanged: widget.onSearchChanged,
            onSubmitted: widget.onSearchSubmitted,
          )
        : null;
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < widget.compactBreakpoint) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (button != null)
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: button,
                ),
              if (search != null) ...[
                if (button != null) const SizedBox(height: UtenSpacing.s8),
                search,
              ],
              if (widget.trailing != null) ...[
                const SizedBox(height: UtenSpacing.s8),
                widget.trailing!,
              ],
            ],
          );
        }
        // 只让分段与搜索框互相对齐高度。行尾按钮通常高 44，Wrap 还可能多行；
        // 若把它们一起放进 IntrinsicHeight，会拉高分段描边，而搜索装饰仍按
        // 内容高度绘制，出现「分类条变厚、搜索框却没变」的不一致。
        // 宽度仍沿用原 Row 的分配：先扣搜索与间距，剩余宽度在分类/行尾等分；
        // 没有分类时行尾独占剩余宽度，保留 Wrap 的有界换行与横向滚动行为。
        final fixedWidth =
            (search != null ? widget.searchWidth : 0.0) +
            (button != null && search != null ? UtenSpacing.s12 : 0.0);
        final trailingWidth = widget.trailing == null
            ? 0.0
            : ((constraints.maxWidth - fixedWidth) / (button == null ? 1 : 2))
                  .clamp(0.0, constraints.maxWidth);
        return Row(
          // 分类较少时字段组自然收窄，空白留在搜索与行尾之间，动作仍贴右。
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            if (button != null || search != null)
              Flexible(
                child: IntrinsicHeight(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // 分类少时按自然宽度贴着搜索框；放不下时收为完整分类面板。
                      if (button != null) Flexible(child: button),
                      if (search != null) ...[
                        if (button != null)
                          const SizedBox(width: UtenSpacing.s12),
                        SizedBox(width: widget.searchWidth, child: search),
                      ],
                    ],
                  ),
                ),
              ),
            if (widget.trailing != null)
              SizedBox(
                width: trailingWidth,
                child: Align(
                  alignment: AlignmentDirectional.centerEnd,
                  heightFactor: 1,
                  child: widget.trailing,
                ),
              ),
          ],
        );
      },
    );
  }

  int get _actionableTotal => widget.segments
      .where((segment) => segment.countForm == UtenSegmentCountForm.actionable)
      .fold(0, (sum, segment) => sum + (segment.count ?? 0));

  int get _inProgressTotal => widget.segments.fold(
    0,
    (sum, segment) =>
        sum +
        (segment.inProgressCount ?? 0) +
        (segment.countForm == UtenSegmentCountForm.inProgress
            ? segment.count ?? 0
            : 0),
  );
}

/// 分类未选时的内容区引导占位（任务中心「在上方选择分类后开始办理」的通用版；
/// 2026-09-03 起单据列表/工作台页统一「默认不选、点击后才加载」范式共用）。
class UtenFilterPlaceholder extends StatelessWidget {
  const UtenFilterPlaceholder({
    super.key,
    this.message = '在上方选择分类后开始浏览',
    this.description = '分类默认不选中，选择后才加载对应数据',
  });

  final String message;
  final String description;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      label: message,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.touch_app_outlined,
              size: 40,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: UtenSpacing.s12),
            Text(message, style: theme.textTheme.titleSmall),
            const SizedBox(height: UtenSpacing.s4),
            Text(
              description,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
