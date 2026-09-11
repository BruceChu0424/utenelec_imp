// UtenRackGrid - 货架图（库行 × 层 × 位 网格）。
// 文档：docs/02-组件库/UtenRackGrid.md
//
// 目的：把「库位号」从一串文本变成看得见的货架——现场按 库行→层→位 找东西，
// 屏幕上就按 库行→层→位 摆格子（高层在上、贴近实物）。
//
// - 数据契约自持（[UtenRackGridRack] 布局 + [UtenRackGridItem] 行），组件不依赖
//   任何 feature 模型：货架清单页把 ShelfLayoutRack/ShelfLabelRow 映射进来即可；
// - 一格 = 一个库位号，可聚合同库位多货品（首件出正文 + 「+n」计数徽章）；
// - 点格 = [onCellTap] 回传库位号（宿主页据此过滤/高亮表格）；[selectedPlace]
//   受控高亮，宿主页反查（点表格行）时把库位号写回来，组件自动滚到该格；
// - 空位弱化（弱色边框 + 「—」），不可点、不进无障碍焦点；
// - 「未分层」（库位号不符合三段格式的残值）不画网格，单独一段平铺列表；
// - 颜色全部取自 ColorScheme / UtenColors，无裸色；lite 档不做任何动画。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/performance/performance_tier.dart';
import '../../core/theme/uten_tokens.dart';
import '../../shared/providers/performance_provider.dart';
import '../cards/uten_card.dart';
import '../layout/uten_h_scroll_area.dart';
import '../layout/uten_section_header.dart';

/// 货架图一格里的一条货品（同一 [place] 可有多条）。
@immutable
class UtenRackGridItem {
  const UtenRackGridItem({
    required this.id,
    required this.place,
    this.level,
    this.slot,
    this.code,
    this.name,
    this.qtyLabel,
    this.disabled = false,
  });

  /// 行唯一键（货品 id 等），仅用于稳定 key。
  final String id;

  /// 库位号原值（如 A31-3-1；未分层桶里是残值原文）。
  final String place;

  /// 层 / 位；null = 未分层（进未分层桶）。
  final int? level;
  final int? slot;

  /// 物料编码 / 名称 / 库存量展示文本（由宿主页格式化，组件不做数字格式化）。
  final String? code;
  final String? name;
  final String? qtyLabel;

  /// 货品已禁用：文字弱化，仍占格（现场货还在货架上）。
  final bool disabled;
}

/// 一个库行的网格维度（[rack] 为空串 = 未分层桶）。
@immutable
class UtenRackGridRack {
  const UtenRackGridRack({
    required this.rack,
    this.maxLevel,
    this.maxSlot,
    this.count = 0,
  });

  final String rack;
  final int? maxLevel;
  final int? maxSlot;

  /// 该库行的货品行数（服务端计数，可能大于本次下发的 items）。
  final int count;

  bool get isUnparsed => rack.isEmpty;
}

/// 货架图：一库行一张卡，行=层（高层在上）、列=位、格=库位号。
class UtenRackGrid extends ConsumerStatefulWidget {
  const UtenRackGrid({
    super.key,
    required this.racks,
    required this.items,
    this.selectedPlace,
    this.onCellTap,
    this.emptyMessage = '暂无已维护库位号的货品', // TODO(l10n): 补 arb
    this.unparsedHint =
        '库位号不是「库行-层-位」三段格式，请在货品资料改正（如 A31-3-1）', // TODO(l10n): 补 arb
  });

  /// 库行布局（含 maxLevel/maxSlot）；缺维度时按 [items] 实际占用推导。
  final List<UtenRackGridRack> racks;

  /// 当前应画进货架图的行（已按宿主页筛选口径裁剪）。
  final List<UtenRackGridItem> items;

  /// 受控选中库位号：高亮该格并自动滚入视口（表格反查用）。
  final String? selectedPlace;

  /// 点格回调（空位不回调）。宿主页自行决定「再点一次取消」。
  final void Function(String place)? onCellTap;

  final String emptyMessage;
  final String unparsedHint;

  /// 网格最多画多少层/位（超出的维度只画真实占用的层/位，避免空壳撑爆布局）。
  static const int levelRenderCap = 20;
  static const int slotRenderCap = 30;

  @override
  ConsumerState<UtenRackGrid> createState() => _UtenRackGridState();
}

class _UtenRackGridState extends ConsumerState<UtenRackGrid> {
  /// 库位号 → 该格货品（同格多货按入参顺序）。
  Map<String, List<UtenRackGridItem>> _byPlace = const {};

  /// 库行 → 「层-位」→ 该格货品；未分层行不进这里。
  Map<String, Map<String, List<UtenRackGridItem>>> _byCell = const {};

  /// 库行 → 实际占用的层 / 位（布局缺维度或维度超上限时用）。
  Map<String, Set<int>> _levelsOf = const {};
  Map<String, Set<int>> _slotsOf = const {};

  /// 未分层桶货品。
  List<UtenRackGridItem> _unparsed = const [];

  /// 每格滚动锚点（仅已渲染的格）。
  final Map<String, GlobalKey> _cellKeys = {};

  @override
  void initState() {
    super.initState();
    _index();
    _scheduleScrollToSelected();
  }

  @override
  void didUpdateWidget(covariant UtenRackGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.items, widget.items) ||
        !identical(oldWidget.racks, widget.racks)) {
      _index();
    }
    if (oldWidget.selectedPlace != widget.selectedPlace) {
      _scheduleScrollToSelected();
    }
  }

  /// 一次 O(n) 建索引（每次数据换引用才重建，build 不重复聚合）。
  void _index() {
    final byPlace = <String, List<UtenRackGridItem>>{};
    final byCell = <String, Map<String, List<UtenRackGridItem>>>{};
    final levels = <String, Set<int>>{};
    final slots = <String, Set<int>>{};
    final unparsed = <UtenRackGridItem>[];
    for (final item in widget.items) {
      byPlace.putIfAbsent(item.place, () => []).add(item);
      final level = item.level;
      final slot = item.slot;
      if (level == null || slot == null) {
        unparsed.add(item);
        continue;
      }
      final rack = _rackOf(item);
      byCell
          .putIfAbsent(rack, () => {})
          .putIfAbsent('$level-$slot', () => [])
          .add(item);
      levels.putIfAbsent(rack, () => <int>{}).add(level);
      slots.putIfAbsent(rack, () => <int>{}).add(slot);
    }
    _byPlace = byPlace;
    _byCell = byCell;
    _levelsOf = levels;
    _slotsOf = slots;
    _unparsed = unparsed;
  }

  /// 库位号首段 = 库行（与后端 ShelfPlaceParser 同口径：已分层行必有首段）。
  static String _rackOf(UtenRackGridItem item) {
    final dash = item.place.indexOf('-');
    return dash <= 0 ? item.place : item.place.substring(0, dash);
  }

  void _scheduleScrollToSelected() {
    final place = widget.selectedPlace;
    if (place == null || place.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final anchor = _cellKeys[place]?.currentContext;
      if (anchor == null) return;
      Scrollable.ensureVisible(
        anchor,
        alignment: 0.5,
        duration: _animation,
        curve: Curves.easeOut,
      );
    });
  }

  /// lite 档不做动画（Duration.zero = ensureVisible 直接跳、格子不补间）。
  Duration get _animation => ref.read(performanceProvider).isLite
      ? Duration.zero
      : const Duration(milliseconds: 180);

  /// 层列表：布局 maxLevel 与实际占用取并集，降序（高层在上，贴近实物）。
  List<int> _levels(UtenRackGridRack rack) {
    final used = _levelsOf[rack.rack] ?? const <int>{};
    final declared = rack.maxLevel ?? 0;
    final out = <int>{
      for (var i = 1; i <= declared && i <= UtenRackGrid.levelRenderCap; i++) i,
      ...used,
    }.toList()..sort((a, b) => b.compareTo(a));
    return out;
  }

  /// 位列表：布局 maxSlot 与实际占用取并集，升序。
  List<int> _slots(UtenRackGridRack rack) {
    final used = _slotsOf[rack.rack] ?? const <int>{};
    final declared = rack.maxSlot ?? 0;
    final out = <int>{
      for (var i = 1; i <= declared && i <= UtenRackGrid.slotRenderCap; i++) i,
      ...used,
    }.toList()..sort();
    return out;
  }

  @override
  Widget build(BuildContext context) {
    // 布局缺项时按数据兜底：只要有行就画得出货架（后端 layout 挂了也不空屏）。
    final racks = widget.racks.where((r) => !r.isUnparsed).toList();
    final declared = {for (final r in racks) r.rack};
    for (final rack in _byCell.keys) {
      if (!declared.contains(rack)) {
        racks.add(UtenRackGridRack(rack: rack));
      }
    }
    racks.sort((a, b) => a.rack.compareTo(b.rack));

    final unparsedLayout = widget.racks.where((r) => r.isUnparsed).toList();
    final unparsedCount = unparsedLayout.isEmpty
        ? _unparsed.length
        : unparsedLayout.first.count;

    if (racks.isEmpty && _unparsed.isEmpty) {
      final theme = Theme.of(context);
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s24),
        child: Center(
          child: Text(
            widget.emptyMessage,
            key: const Key('rack-grid-empty'),
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final rack in racks) _rackCard(context, rack),
        if (_unparsed.isNotEmpty) _unparsedCard(context, unparsedCount),
      ],
    );
  }

  Widget _rackCard(BuildContext context, UtenRackGridRack rack) {
    final theme = Theme.of(context);
    final levels = _levels(rack);
    final slots = _slots(rack);
    final cells =
        _byCell[rack.rack] ?? const <String, List<UtenRackGridItem>>{};
    final count = rack.count > 0 ? rack.count : _countOf(cells);
    final metrics = _RackGridMetrics.of(context);
    return UtenCard(
      key: Key('rack-card-${rack.rack}'),
      margin: const EdgeInsets.only(bottom: UtenSpacing.s12),
      padding: const EdgeInsets.all(UtenSpacing.s12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          UtenSectionHeader(
            title: '${rack.rack} 库行', // TODO(l10n): 补 arb
            accentColor: theme.colorScheme.primary,
            trailing: Text(
              '$count 项', // TODO(l10n): 补 arb
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: UtenSpacing.s8),
          UtenHScrollArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // 位号表头（与格子同宽，列对齐）
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(width: metrics.labelWidth),
                    for (final slot in slots)
                      SizedBox(
                        width: metrics.cellWidth,
                        child: Padding(
                          padding: const EdgeInsets.only(
                            left: UtenSpacing.s4,
                            bottom: UtenSpacing.s4,
                          ),
                          child: Text(
                            '$slot 位', // TODO(l10n): 补 arb
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                for (final level in levels)
                  IntrinsicHeight(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          width: metrics.labelWidth,
                          child: Center(
                            child: Text(
                              '$level 层', // TODO(l10n): 补 arb
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                        for (final slot in slots)
                          _cell(
                            context,
                            rack: rack.rack,
                            level: level,
                            slot: slot,
                            items:
                                cells['$level-$slot'] ??
                                const <UtenRackGridItem>[],
                            metrics: metrics,
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static int _countOf(Map<String, List<UtenRackGridItem>> cells) {
    var total = 0;
    for (final list in cells.values) {
      total += list.length;
    }
    return total;
  }

  /// 一格：空位弱化不可点；有货显首件 + 「+n」；选中走 primaryContainer。
  Widget _cell(
    BuildContext context, {
    required String rack,
    required int level,
    required int slot,
    required List<UtenRackGridItem> items,
    required _RackGridMetrics metrics,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final place = items.isEmpty ? '$rack-$level-$slot' : items.first.place;
    final selected =
        widget.selectedPlace != null &&
        widget.selectedPlace == place &&
        items.isNotEmpty;

    if (items.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(
          right: UtenSpacing.s4,
          bottom: UtenSpacing.s4,
        ),
        child: Container(
          width: metrics.cellWidth - UtenSpacing.s4,
          alignment: Alignment.center,
          constraints: BoxConstraints(minHeight: metrics.minCellHeight),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLowest,
            border: Border.all(
              color: scheme.outlineVariant.withValues(alpha: 0.5),
            ),
            borderRadius: UtenRadius.controlAll,
          ),
          child: Text(
            '—',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
            ),
          ),
        ),
      );
    }

    final key = _cellKeys.putIfAbsent(place, GlobalKey.new);
    final first = items.first;
    final extra = items.length - 1;
    final foreground = selected
        ? scheme.onPrimaryContainer
        : (first.disabled ? scheme.onSurfaceVariant : scheme.onSurface);
    return Padding(
      key: key,
      padding: const EdgeInsets.only(
        right: UtenSpacing.s4,
        bottom: UtenSpacing.s4,
      ),
      child: Semantics(
        button: true,
        selected: selected,
        label: _cellSemantics(place, items),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            key: Key('rack-cell-$place'),
            borderRadius: UtenRadius.controlAll,
            onTap: widget.onCellTap == null
                ? null
                : () => widget.onCellTap!(place),
            child: AnimatedContainer(
              duration: _animation,
              width: metrics.cellWidth - UtenSpacing.s4,
              constraints: BoxConstraints(minHeight: metrics.minCellHeight),
              padding: const EdgeInsets.symmetric(
                horizontal: UtenSpacing.s6,
                vertical: UtenSpacing.s6,
              ),
              decoration: BoxDecoration(
                color: selected
                    ? scheme.primaryContainer
                    : scheme.surfaceContainerHigh,
                border: Border.all(
                  color: selected ? scheme.primary : scheme.outlineVariant,
                  width: selected ? 1.5 : 1,
                ),
                borderRadius: UtenRadius.controlAll,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          first.code ?? place,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: foreground,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      if (extra > 0) ...[
                        const SizedBox(width: UtenSpacing.s4),
                        _CountBadge(label: '+$extra'),
                      ],
                    ],
                  ),
                  if ((first.name ?? '').isNotEmpty)
                    Text(
                      first.name!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: foreground,
                      ),
                    ),
                  if ((first.qtyLabel ?? '').isNotEmpty)
                    Text(
                      first.qtyLabel!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: selected
                            ? scheme.onPrimaryContainer
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  static String _cellSemantics(String place, List<UtenRackGridItem> items) {
    final first = items.first;
    final name = (first.name ?? first.code ?? '').trim();
    // TODO(l10n): 补 arb
    return items.length > 1
        ? '库位 $place，${items.length} 个货品，首件 $name'
        : '库位 $place，$name';
  }

  /// 未分层桶：不画网格（没有层/位可摆），平铺成一段列表并指路去改主档。
  Widget _unparsedCard(BuildContext context, int count) {
    final theme = Theme.of(context);
    final metrics = _RackGridMetrics.of(context);
    return UtenCard(
      key: const Key('rack-card-unparsed'),
      margin: const EdgeInsets.only(bottom: UtenSpacing.s12),
      padding: const EdgeInsets.all(UtenSpacing.s12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          UtenSectionHeader(
            title: '未分层（$count）', // TODO(l10n): 补 arb
            icon: Icons.help_outline_rounded,
            accentColor: theme.colorScheme.tertiary,
          ),
          Padding(
            padding: const EdgeInsets.only(
              top: UtenSpacing.s4,
              bottom: UtenSpacing.s8,
            ),
            child: Text(
              widget.unparsedHint,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Wrap(
            spacing: UtenSpacing.s8,
            runSpacing: UtenSpacing.s8,
            children: [
              for (final item in _unparsed)
                _unparsedTile(context, item, metrics),
            ],
          ),
        ],
      ),
    );
  }

  Widget _unparsedTile(
    BuildContext context,
    UtenRackGridItem item,
    _RackGridMetrics metrics,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final selected = widget.selectedPlace == item.place;
    final siblings = _byPlace[item.place] ?? <UtenRackGridItem>[item];
    final key = _cellKeys.putIfAbsent(item.place, GlobalKey.new);
    return Semantics(
      button: true,
      selected: selected,
      label: _cellSemantics(item.place, siblings),
      child: Material(
        key: key,
        color: Colors.transparent,
        child: InkWell(
          key: Key('rack-unparsed-${item.id}'),
          borderRadius: UtenRadius.controlAll,
          onTap: widget.onCellTap == null
              ? null
              : () => widget.onCellTap!(item.place),
          child: Container(
            width: metrics.cellWidth,
            padding: const EdgeInsets.symmetric(
              horizontal: UtenSpacing.s8,
              vertical: UtenSpacing.s6,
            ),
            decoration: BoxDecoration(
              color: selected
                  ? scheme.primaryContainer
                  : scheme.surfaceContainerHigh,
              border: Border.all(
                color: selected ? scheme.primary : scheme.outlineVariant,
                width: selected ? 1.5 : 1,
              ),
              borderRadius: UtenRadius.controlAll,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  item.place,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: selected
                        ? scheme.onPrimaryContainer
                        : scheme.onSurface,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  [
                    item.code ?? '',
                    item.name ?? '',
                  ].where((t) => t.isNotEmpty).join(' · '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: selected
                        ? scheme.onPrimaryContainer
                        : scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 同格多货计数徽章（「+1」= 本格还有 1 个货品）。
class _CountBadge extends StatelessWidget {
  const _CountBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: UtenRadius.pillAll,
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: scheme.onSecondaryContainer,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// 格子尺寸随字号档放大（超大字号下文字仍在格内，不溢出、不糊成一团）。
class _RackGridMetrics {
  const _RackGridMetrics({
    required this.cellWidth,
    required this.labelWidth,
    required this.minCellHeight,
  });

  final double cellWidth;
  final double labelWidth;
  final double minCellHeight;

  factory _RackGridMetrics.of(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 1.8);
    return _RackGridMetrics(
      cellWidth: 136 * scale,
      labelWidth: 52 * scale,
      minCellHeight: 62 * scale,
    );
  }
}
