// UtenFilterToolbar - 「分类分段 + 搜索」统一筛选工具条。
//
// 2026-09-01 全平台 UI 统一的标准范式：凡是页面上有「分类/状态筛选」的地方，
// 一律用本组件呈现，不再手写各种筛选按钮、Chip 行或自成一套的分段样式——
//
// - 分段导航：胶囊 StadiumBorder、与搜索框结构化同高（IntrinsicHeight+stretch）、
//   选中只变背景色不出 ✓ 图标；
// - 层级规则：大类分类（来源/方向/单据类型）在上、小类分类（状态）在下；
//   小类行默认 [enabled]=false 置灰，选中大类后才由页面解锁；
// - 默认不选：进页面 [selected] 传空集（不预选「全部」段），数据等价于不过滤；
//   「全部」段保留为显式选项——SegmentedButton 点击已选段不会回调，选中后
//   只能靠「全部」段回到全量视图；
// - 视图切换例外：切换内容区的工具条（如应付工作区/报表变体）必须始终有
//   选中项，不适用「默认不选」；
// - 计数口径：分段计数有两种形态，**默认中性括号数字 `(N)`**，红徽章要显式挑
//   （[UtenFilterSegment.countForm]，见 docs/00-项目准则/14-徽章与计数口径.md）：
//   · 浏览型（阶段/状态监控、草稿、历史、来源细分）→ `(N)`，0 显示 `(0)` 保持队形；
//   · 待办型（待审/待确认/待收货/待出库/待检/被驳回/超期/异常，且**这段确实在等
//     本页用户动手**）→ 红徽章，0/null 不显示，>99 显 99+；
//   · 同一条工具条里已有一段红徽章覆盖了这批活的总量时，细分切片走括号
//     （同一批活不在一行里红两遍）；
//   · 「全部」、终态（已完结/终态/已决定）与「下一步是别人操作」的状态一律不传 count；
//   · 分段计数**永不**登记进 lib/shared/badges/todo_badge_registry.dart（累加只认入口）。
// - 搜索框：全平台唯一组件 UtenSearchBar（胶囊圆角 + 清除 + 300ms 防抖）；
// - 响应式：宽屏一行（分段 | 搜索 | 行尾有界右对齐，超宽自动换行），窄屏
//   （< [compactBreakpoint]）分段横向滚动一行 + 搜索换行；
// - 纯分类无搜索的页面只传 [segments]（searchHint 不传即不渲染搜索框）；
// - 纯搜索+行尾的页面（筛选下沉到列头/下拉，如即时库存）不传 [segments]
//   （2026-09-10 起 segments/selected/onSelectionChanged 均可省略）。
//
// 计数的数值口径由调用方负责：取该分段的「全量」计数（非当前页推算），与后端
// counts 类接口同源；加载中传 null（两种形态都不渲染数字）。

import 'package:flutter/material.dart';

import '../../../core/theme/uten_tokens.dart';
import '../feedback/uten_segment_badge_label.dart';
import '../inputs/uten_search_bar.dart';

/// 一个分类分段：值 + 文字 + 可选计数（中性括号数字 / 红色待办徽章）。
class UtenFilterSegment<T> {
  const UtenFilterSegment({
    required this.value,
    required this.label,
    this.count,
    this.countForm = UtenSegmentCountForm.browsing,
  });

  final T value;
  final String label;

  /// 该分段的计数；null = 加载中/未知（不渲染，不把未知伪装成 0）。
  /// 应取该分段的「全量」计数（非当前页推算），与后端 counts 类接口同源。
  final int? count;

  /// 计数呈现形态；**默认中性括号 `(N)`**。只有「这一段确实在等本页用户动手」
  /// 时才显式传 [UtenSegmentCountForm.actionable]（见组件头部计数口径）。
  final UtenSegmentCountForm countForm;
}

class UtenFilterToolbar<T> extends StatelessWidget {
  const UtenFilterToolbar({
    super.key,
    this.segments = const [],
    this.selected = const {},
    this.onSelectionChanged,
    this.enabled = true,
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
    this.searchWidth = 360,
  });

  /// 分类分段（进页面默认不选；「全部」段是显式选项）。**传空列表 = 纯「搜索 +
  /// 行尾」工具条**（筛选已下沉到列头/下拉的页面，如即时库存分类下拉化后），
  /// 此时不渲染分段条，也无需传 [selected]/[onSelectionChanged]。
  final List<UtenFilterSegment<T>> segments;

  /// 当前选中分段集合（单选）。空集 = 进页面未选任何分段（数据不过滤）；
  /// 「全部」类分段只是显式选项，不再是默认选中态。
  final Set<T> selected;

  /// 点击某个分段时回调其值。SegmentedButton 单选点击已选段不会触发回调，
  /// 因此不会出现空集回调。[segments] 非空时必须提供。
  final ValueChanged<T>? onSelectionChanged;

  /// false = 整条置灰不可点（小类行在大类未选时的锁定态）。
  final bool enabled;

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

  /// 低于该宽度切窄屏布局（分段横滚 + 搜索换行）。
  final double compactBreakpoint;

  /// 宽屏搜索框宽度。
  final double searchWidth;

  @override
  Widget build(BuildContext context) {
    // segments 为空 = 纯「搜索 + 行尾」工具条（筛选已下沉到列头/下拉的页面，
    // 如即时库存分类下拉化后）——不渲染空分段条。
    final button = segments.isEmpty
        ? null
        : SegmentedButton<T>(
            key: segmentsKey,
            // 统一范式：选中只变背景色，不出现 ✓ 图标。高度不在此设置——
            // 分段与搜索框的「严格同高」由下方 IntrinsicHeight+stretch 结构保证
            //（visualDensity 对两侧的折减不一致，minimumSize 各自算高度算不平，
            //  且本 SDK 版本的分段样式会丢弃 minimumSize）。
            showSelectedIcon: false,
            // 进页面不预选（selected 空集）是官方支持形态，放开空选中断言。
            emptySelectionAllowed: true,
            segments: [
              for (final segment in segments)
                ButtonSegment(
                  value: segment.value,
                  enabled: enabled,
                  label: UtenSegmentBadgeLabel(
                    label: segment.label,
                    count: segment.count,
                    countForm: segment.countForm,
                  ),
                ),
            ],
            selected: selected,
            onSelectionChanged: (selection) {
              // 单选：SegmentedButton 点击已选段不会回调，这里恒非空。
              // 整条置灰时各分段 disabled，不会进入此回调。
              if (selection.isNotEmpty) {
                onSelectionChanged?.call(selection.first);
              }
            },
          );
    final showSearch = searchHint != null || searchController != null;
    final search = showSearch
        ? UtenSearchBar(
            key: searchKey,
            hint: searchHint ?? '搜索',
            initialValue: initialSearchValue,
            controller: searchController,
            onInputChanged: onSearchInputChanged,
            onChanged: onSearchChanged,
            onSubmitted: onSearchSubmitted,
          )
        : null;
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < compactBreakpoint) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (button != null) _SegmentsScrollArea(child: button),
              if (search != null) ...[
                if (button != null) const SizedBox(height: UtenSpacing.s8),
                search,
              ],
              if (trailing != null) ...[
                const SizedBox(height: UtenSpacing.s8),
                trailing!,
              ],
            ],
          );
        }
        // IntrinsicHeight + stretch：分段与搜索框谁高就都拉到同一高度，
        // 密度/字号档变化下两侧永远一致。
        return IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 分段条必须是**有界可滚**的：分类多（其他入库明细表等十几个分类）
              // 时 SegmentedButton 在 Row 里拿到的是无界宽，会直接顶出黄黑溢出条
              // ——宽屏也一样，只是要分类更多才撞上（2026-09-11 用户反馈
              //「分类内容多的时候小屏会显示不全」）。Flexible(loose)：分类少时
              // 仍按自然宽度贴着搜索框，分类多时收进滚动区并显示滚动条。
              if (button != null)
                Flexible(child: _SegmentsScrollArea(child: button)),
              if (search != null) ...[
                if (button != null) const SizedBox(width: UtenSpacing.s12),
                SizedBox(width: searchWidth, child: search),
              ],
              // 2026-09-10：行尾内容放进有界的 Expanded 里右对齐——此前用 Spacer +
              // 裸 trailing，Row 主轴无界导致行尾 Wrap 永不换行，在 840~1000px
              // 宽度带（下拉+开关+计数合计 ≈ 600px）直接溢出黄黑条。
              if (trailing != null)
                Expanded(
                  child: Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: trailing,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// 分段条的横向滚动区：内容超宽时可横滚，并常驻一条细滚动条作为「右边还有」的
/// 明示（滚动条是覆盖层，不占布局高度，分段与搜索框的同高结构不受影响）。
class _SegmentsScrollArea extends StatefulWidget {
  const _SegmentsScrollArea({required this.child});

  final Widget child;

  @override
  State<_SegmentsScrollArea> createState() => _SegmentsScrollAreaState();
}

class _SegmentsScrollAreaState extends State<_SegmentsScrollArea> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scrollbar(
      controller: _controller,
      thumbVisibility: true,
      child: SingleChildScrollView(
        controller: _controller,
        scrollDirection: Axis.horizontal,
        child: widget.child,
      ),
    );
  }
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
