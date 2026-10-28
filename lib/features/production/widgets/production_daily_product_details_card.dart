import 'package:uten_imp/components/inputs/uten_editor_tooltip.dart';
import '../../../components/inputs/uten_field_hint_icon.dart';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_inline_notice.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../../components/layout/uten_table_column_kit.dart';
import '../../../components/layout/uten_collapsible_content.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../shared/formatters/exact_decimal.dart';
import '../models/production_exact_quantity.dart';
import '../models/production_direct_transfer_candidate.dart'
    show directTransferLoadFailedText;
import 'production_daily_grid_columns.dart';

/// A product's details occupy their own full-width grid row. The page owns every
/// row/controller, expansion state and business action; this widget only lays out
/// those facts and delegates edits to the existing cells and allocation engine.
class ProductionDailyProductDetailsCard extends StatefulWidget {
  const ProductionDailyProductDetailsCard({
    super.key,
    required this.product,
    required this.allocationRows,
    required this.materialRows,
    required this.allocationsExpanded,
    required this.materialsExpanded,
    required this.onToggleGroup,
    required this.unitEntries,
    required this.allocationQuantityBuilder,
    required this.materialUsageBuilder,
    this.onAllocationDestinationChanged,
    this.onAddAllocation,
    this.onRemoveAllocation,
    this.enabled = true,
    this.destinationsEditable = true,
    this.leadingInset = 0,
  }) : assert(leadingInset >= 0 && leadingInset < double.infinity);

  final DailyGridRow product;
  final List<DailyGridRow> allocationRows, materialRows;
  final bool allocationsExpanded, materialsExpanded, enabled;
  final bool destinationsEditable;

  /// Outer card alignment supplied by the main table's leading selection column.
  final double leadingInset;
  final ValueChanged<DailyRowGroup> onToggleGroup;
  final Map<String, String> unitEntries;
  final Widget Function(BuildContext, DailyGridRow) allocationQuantityBuilder,
      materialUsageBuilder;
  final void Function(DailyGridRow row, String? demandId)?
  onAllocationDestinationChanged;
  final VoidCallback? onAddAllocation;
  final ValueChanged<DailyGridRow>? onRemoveAllocation;

  @override
  State<ProductionDailyProductDetailsCard> createState() =>
      _ProductionDailyProductDetailsCardState();
}

class _ProductionDailyProductDetailsCardState
    extends State<ProductionDailyProductDetailsCard> {
  DailyGridRow get product => widget.product;
  List<DailyGridRow> get allocationRows => widget.allocationRows;
  List<DailyGridRow> get materialRows => widget.materialRows;
  bool get allocationsExpanded => widget.allocationsExpanded;
  bool get materialsExpanded => widget.materialsExpanded;
  bool get enabled => widget.enabled;
  bool get destinationsEditable => widget.destinationsEditable;
  double get leadingInset => widget.leadingInset;
  ValueChanged<DailyRowGroup> get onToggleGroup => widget.onToggleGroup;
  Map<String, String> get unitEntries => widget.unitEntries;
  Widget Function(BuildContext, DailyGridRow) get allocationQuantityBuilder =>
      widget.allocationQuantityBuilder;
  Widget Function(BuildContext, DailyGridRow) get materialUsageBuilder =>
      widget.materialUsageBuilder;
  void Function(DailyGridRow, String?)? get onAllocationDestinationChanged =>
      widget.onAllocationDestinationChanged;
  VoidCallback? get onAddAllocation => widget.onAddAllocation;
  ValueChanged<DailyGridRow>? get onRemoveAllocation =>
      widget.onRemoveAllocation;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([
      product.qty,
      product.allocationRevision,
      for (final row in allocationRows) ...[
        row.allocationQty,
        row.allocationDemandNotifier,
        row.allocationIssue,
        row.allocationAutofilled,
      ],
      for (final row in materialRows) row.materialUsed,
    ]),
    builder: (context, _) => _buildCard(context),
  );

  Widget _buildCard(BuildContext context) {
    final showAllocations =
        !showsWarehouseOnlyDestination(product) &&
        (allocationRows.isNotEmpty ||
            product.directTransferCandidates.isNotEmpty ||
            product.directTransferLoadFailed ||
            product.directTransferPrecisionIssue != null ||
            (enabled && onAddAllocation != null) ||
            product.directTransferBlockedText != null);
    if (!showAllocations && materialRows.isEmpty) {
      return const SizedBox.shrink();
    }
    final allocationIssues = <String>{
      if (product.directTransferLoadFailed)
        product.directTransferBlockedText ?? directTransferLoadFailedText,
      ?product.directTransferPrecisionIssue,
      for (final row in allocationRows) ?row.allocationIssue.value,
    }.where((reason) => reason.trim().isNotEmpty).toList();
    final materialIssues = [
      for (final row in materialRows)
        if (row.materialEditable && row.materialInvalid) _materialIssue(row),
    ];
    final materialEditable = materialRows
        .where((row) => row.materialEditable)
        .toList();
    final materialFilled = materialEditable
        .where((row) => !row.materialInvalid)
        .length;
    final groups = <Widget>[
      if (showAllocations)
        _groupCard(
          context,
          DailyRowGroup.allocations,
          _DetailGroupHeader(
            toggleKey: ValueKey(
              'daily-product-allocation-toggle-${product.localRowId}',
            ),
            title: '产出去向',
            info: '填写完工申报量后，系统按可接收的工单分配，其余送入仓库；自行添加去向后，未分配余量自动送仓库。',
            icon: Icons.alt_route_outlined,
            count: '${allocationRows.length} 笔',
            status: _allocationStatus(allocationIssues),
            detail: allocationIssues.isEmpty
                ? null
                : allocationIssues.join('\n'),
            issue: allocationIssues.isNotEmpty,
            expanded: allocationsExpanded,
            onToggle: () =>
                _toggleGroup(DailyRowGroup.allocations, allocationsExpanded),
          ),
          [
            if (allocationRows.isNotEmpty)
              _allocationTable(context)
            else if (product.directTransferLoadFailed)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: UtenSpacing.s12),
                child: Text('原去向保留，重新读取候选后再核对分配。'),
              ),
            if (allocationIssues.isNotEmpty) _issues(allocationIssues),
            if (enabled && onAddAllocation != null)
              Padding(
                padding: const EdgeInsets.only(top: UtenSpacing.s4),
                child: Wrap(
                  spacing: UtenSpacing.s12,
                  runSpacing: UtenSpacing.s4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    UtenButton(
                      key: ValueKey(
                        'daily-product-add-allocation-${product.localRowId}',
                      ),
                      type: UtenButtonType.secondary,
                      size: UtenButtonSize.small,
                      height: 36,
                      icon: Icons.add,
                      onPressed: onAddAllocation,
                      child: const Text('添加去向'),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: UtenSpacing.s4),
          ],
        ),
      if (materialRows.isNotEmpty)
        _groupCard(
          context,
          DailyRowGroup.materials,
          _DetailGroupHeader(
            toggleKey: ValueKey(
              'daily-product-material-toggle-${product.localRowId}',
            ),
            title: '子件用料',
            icon: Icons.inventory_2_outlined,
            count: '${materialRows.length} 项',
            status: materialEditable.isEmpty
                ? '只读对照'
                : materialIssues.isNotEmpty
                ? '${materialIssues.length} 项待核对'
                : '已填写 $materialFilled / ${materialEditable.length} 项',
            issue: materialIssues.isNotEmpty,
            detail: materialIssues.isEmpty ? null : materialIssues.join('\n'),
            expanded: materialsExpanded,
            onToggle: () =>
                _toggleGroup(DailyRowGroup.materials, materialsExpanded),
          ),
          [
            _materialTable(context),
            if (materialIssues.isNotEmpty) _issues(materialIssues),
            const SizedBox(height: UtenSpacing.s4),
          ],
        ),
    ];
    return Padding(
      padding: EdgeInsets.fromLTRB(
        leadingInset,
        UtenSpacing.s4,
        UtenSpacing.s8,
        UtenSpacing.s4,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var index = 0; index < groups.length; index++) ...[
            if (index > 0) const SizedBox(height: UtenSpacing.s4),
            groups[index],
          ],
        ],
      ),
    );
  }

  Widget _groupCard(
    BuildContext context,
    DailyRowGroup group,
    Widget header,
    List<Widget> body,
  ) {
    final colors = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final background = group == DailyRowGroup.allocations
        ? Color.alphaBlend(
            (dark ? UtenColors.violetOnDark : UtenColors.violetBg).withValues(
              alpha: dark ? 0.16 : 0.85,
            ),
            colors.surface,
          )
        : Color.alphaBlend(
            (dark ? UtenColors.infoOnDark : UtenColors.infoBg).withValues(
              alpha: dark ? 0.13 : 0.85,
            ),
            colors.surface,
          );
    return Card(
      key: ValueKey(
        'daily-product-${group == DailyRowGroup.allocations ? 'allocations' : 'materials'}-card-${product.localRowId}',
      ),
      margin: EdgeInsets.zero,
      color: background,
      elevation: 0,
      shape: const RoundedRectangleBorder(borderRadius: UtenRadius.lgAll),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: UtenSpacing.s12,
          vertical: UtenSpacing.s2,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            header,
            UtenCollapsibleContent(
              expanded: group == DailyRowGroup.allocations
                  ? allocationsExpanded
                  : materialsExpanded,
              maintainState: false,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: body,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _allocationStatus(List<String> issues) {
    if (product.directTransferLoadFailed) return '去向读取失败，请核对';
    if (issues.isNotEmpty) return '${issues.length} 项待核对';
    final expected = _units(product.qty.text);
    final quantities = allocationRows
        .map((row) => _units(row.allocationQty.text))
        .toList();
    if (expected == null || expected <= BigInt.zero) return '待填写有效完工量';
    if (quantities.any((qty) => qty == null)) return '有数量待填写';
    final total = quantities.fold(BigInt.zero, (sum, qty) => sum + qty!);
    final suffix = unitEntries[product.unitId]?.trim();
    final unit = suffix?.isNotEmpty == true ? ' $suffix' : '';
    if (total == expected) {
      return '已分配 ${_number(total)} / ${_number(expected)}$unit';
    }
    if (total < expected) return '待分配 ${_number(expected - total)}$unit';
    return '超出完工量 ${_number(total - expected)}$unit';
  }

  Widget _allocationTable(BuildContext context) {
    final removeExtent = UtenControlMetrics.minimumHitExtent(
      context,
      desktop: 36,
    );
    final actionWidth = removeExtent + UtenSpacing.s4;
    final removable =
        enabled &&
        onRemoveAllocation != null &&
        allocationRows.any((row) => row.allocationDemandId != null);
    return _ProductDetailsTable(
      key: ValueKey('daily-product-allocation-table-${product.localRowId}'),
      tableKey: 'production.daily_report.product_details.allocations',
      columnKeys: [
        'order',
        'name',
        'code',
        'color',
        'quantity',
        if (removable) 'actions',
      ],
      columnLabels: ['去向工单', '接收名称', '编号', '颜色', '去向数量', if (removable) ''],
      minimumWidths: [64, 148, 64, 64, 140, if (removable) actionWidth],
      compactColumns: removable ? const {5} : const {},
      widths: [
        _nameWidth(
          context,
          header: '去向工单',
          names: allocationRows.map(_destinationCode),
        ),
        _nameWidth(
          context,
          header: '接收名称',
          names: allocationRows.map(_destinationName),
          dropdown: allocationRows.any(
            (row) =>
                !((product.directTransferUnavailable ||
                        (product.allocationManual && !product.isFqcRecovery)) &&
                    row.allocationDemandId == null),
          ),
          hasDisclosure: allocationRows.any(
            (row) =>
                row.allocationAutofilled.value ||
                row.allocationIssue.value != null,
          ),
        ),
        _nameWidth(
          context,
          header: '编号',
          names: allocationRows.map(_receivingCode),
        ),
        _nameWidth(
          context,
          header: '颜色',
          names: allocationRows.map(_receivingColor),
        ),
        164,
        if (removable) actionWidth,
      ],
      headers: [
        const Text('去向工单'),
        const Text('接收名称'),
        const Text('编号'),
        const Text('颜色'),
        const UtenColumnHeaderInfo(
          label: Text('去向数量'),
          message: '数量与完工申报量同单位，未分配余量自动送入仓库。',
        ),
        if (removable) const SizedBox.shrink(),
      ],
      rows: [
        for (final row in allocationRows)
          _ProductDetailRow(
            key: ValueKey('daily-product-allocation-row-${row.localRowId}'),
            cells: [
              _singleLine(_destinationCode(row)),
              _destinationCell(context, row),
              _singleLine(_receivingCode(row)),
              _singleLine(_receivingColor(row)),
              _editable(allocationQuantityBuilder(context, row)),
              if (removable)
                if (row.allocationDemandId != null)
                  IconButton(
                    key: ValueKey('daily-remove-allocation-${row.localRowId}'),
                    tooltip: '移除此去向',
                    icon: const Icon(Icons.close, size: 18),
                    padding: EdgeInsets.zero,
                    style: IconButton.styleFrom(
                      minimumSize: Size.square(removeExtent),
                      maximumSize: Size.square(removeExtent),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    constraints: BoxConstraints.tightFor(
                      width: removeExtent,
                      height: removeExtent,
                    ),
                    visualDensity: VisualDensity.standard,
                    onPressed: () => onRemoveAllocation?.call(row),
                  )
                else
                  const SizedBox.shrink(),
            ],
          ),
      ],
    );
  }

  void _toggleGroup(DailyRowGroup group, bool expanded) {
    if (expanded) {
      final focus = FocusManager.instance.primaryFocus;
      final table = focus?.context
          ?.findAncestorWidgetOfExactType<_ProductDetailsTable>();
      final key = ValueKey(
        'daily-product-${group == DailyRowGroup.allocations ? 'allocation' : 'material'}-table-${product.localRowId}',
      );
      // Removing a Focus widget alone does not send its old blur callback. Let
      // the existing allocation engine finish the edit before hiding that table.
      if (table?.key == key) focus?.unfocus();
    }
    onToggleGroup(group);
  }

  Widget _materialTable(BuildContext context) => _ProductDetailsTable(
    key: ValueKey('daily-product-material-table-${product.localRowId}'),
    tableKey: 'production.daily_report.product_details.materials',
    columnKeys: const ['name', 'code', 'color', 'issued', 'usage'],
    columnLabels: const ['子件名称', '编号', '颜色', '领料量', '本次实际用料'],
    minimumWidths: const [72, 64, 64, 96, 160],
    widths: [
      _nameWidth(
        context,
        header: '子件名称',
        names: materialRows.map((row) => row.material?.goodsName ?? '—'),
      ),
      _nameWidth(
        context,
        header: '编号',
        names: materialRows.map((row) => row.material?.goodsCode ?? '—'),
      ),
      _nameWidth(
        context,
        header: '颜色',
        names: materialRows.map((row) => row.material?.colorName ?? '—'),
      ),
      _nameWidth(
        context,
        header: '领料量',
        names: materialRows.map(_issuedQuantity),
      ),
      192,
    ],
    headers: const [
      Text('子件名称'),
      Text('编号'),
      Text('颜色'),
      Text('领料量'),
      Text('本次实际用料 *'),
    ],
    rows: [
      for (final row in materialRows)
        _ProductDetailRow(
          key: ValueKey('daily-product-material-row-${row.localRowId}'),
          cells: [
            _singleLine(
              row.material?.goodsName,
              extra: row.materialShared
                  ? '沿用 ${row.materialSegmentLabel} 的领料'
                  : null,
            ),
            _singleLine(row.material?.goodsCode),
            _singleLine(row.material?.colorName),
            _singleLine(_issuedQuantity(row)),
            _editable(materialUsageBuilder(context, row)),
          ],
        ),
    ],
  );

  Widget _destinationCell(BuildContext context, DailyGridRow row) {
    if (product.allocationManual &&
        !product.isFqcRecovery &&
        row.allocationDemandId == null) {
      return _singleLine('送入仓库', extra: '未分配余量自动送入仓库，调整上面工单的数量即可');
    }
    final selected = row.allocationDemandId ?? outputAllocationWarehouseValue;
    final originalItems = outputAllocationOptions(row);
    final items = [
      for (final item in originalItems)
        UtenDropdownItem(
          value: item.value,
          label: item.value == outputAllocationWarehouseValue
              ? '送入仓库'
              : _receivingName(item.value) ?? '原接收产品（待核对）',
          enabled: item.enabled,
          indent: item.indent,
          visible: item.visible,
          error: item.error,
          tooltip: [
            item.label,
            if (_receivingColorName(item.value)?.isNotEmpty == true)
              '接收颜色：${_receivingColorName(item.value)}',
          ].join('\n'),
        ),
    ];
    final fullName =
        originalItems
            .where((item) => item.value == selected)
            .firstOrNull
            ?.label ??
        '原去向暂时无法核对';
    final issue = row.allocationIssue.value;
    final tooltip = <String>{
      fullName,
      if (issue?.isNotEmpty == true) issue!,
      if (product.directTransferBlockedText?.isNotEmpty == true)
        product.directTransferBlockedText!,
    }.join('\n');
    if (product.directTransferUnavailable && row.allocationDemandId == null) {
      return _singleLine('送入仓库', extra: product.directTransferBlockedText);
    }
    return UtenEditorTooltip(
      message: tooltip,
      child: UtenDropdownField(
        key: ValueKey('daily-allocation-destination-${identityHashCode(row)}'),
        dense: true,
        allowClear: false,
        enabled:
            enabled &&
            widget.destinationsEditable &&
            onAllocationDestinationChanged != null,
        value: selected,
        selectedLabel: _destinationName(row),
        items: items,
        menuMatchContentWidth: true,
        errorMessage: issue == null ? null : '$fullName\n$issue',
        autofilled: row.allocationAutofilled.value && issue == null,
        warningMessage: row.allocationAutofilled.value
            ? '$fullName\n系统按先急后缓给出的建议去向，请核对'
            : null,
        onChanged: (value) {
          if (!enabled || !widget.destinationsEditable || value == null) return;
          onAllocationDestinationChanged?.call(
            row,
            value == outputAllocationWarehouseValue ? null : value,
          );
        },
      ),
    );
  }

  String _destinationName(DailyGridRow row) {
    final id = row.allocationDemandId;
    if (id == null) return '送入仓库';
    return _receivingName(id) ?? '原接收产品（待核对）';
  }

  String? _receivingName(String? id) {
    if (id == null) return null;
    final candidate = product.directTransferCandidates
        .where((entry) => entry.demandId == id)
        .firstOrNull;
    final blocked = product.directTransferBlockedTargets
        .where((entry) => entry.demandId == id)
        .firstOrNull;
    for (final name in [
      candidate?.receivingGoodsName,
      blocked?.receivingGoodsName,
    ]) {
      if (name?.trim().isNotEmpty == true) return name!.trim();
    }
    return null;
  }

  String _receivingCode(DailyGridRow row) {
    final id = row.allocationDemandId;
    if (id == null) return '—';
    return product.directTransferCandidates
            .where((entry) => entry.demandId == id)
            .firstOrNull
            ?.receivingGoodsCode ??
        product.directTransferBlockedTargets
            .where((entry) => entry.demandId == id)
            .firstOrNull
            ?.receivingGoodsCode ??
        '—';
  }

  String _receivingColor(DailyGridRow row) {
    final id = row.allocationDemandId;
    if (id == null) return '—';
    return _receivingColorName(id) ?? '—';
  }

  String? _receivingColorName(String? id) {
    if (id == null) return null;
    return product.directTransferCandidates
            .where((entry) => entry.demandId == id)
            .firstOrNull
            ?.receivingColorName ??
        product.directTransferBlockedTargets
            .where((entry) => entry.demandId == id)
            .firstOrNull
            ?.receivingColorName;
  }

  String _destinationCode(DailyGridRow row) {
    final id = row.allocationDemandId;
    if (id == null) return '—';
    final candidate = product.directTransferCandidates
        .where((entry) => entry.demandId == id)
        .firstOrNull;
    final blocked = product.directTransferBlockedTargets
        .where((entry) => entry.demandId == id)
        .firstOrNull;
    return candidate?.executionSegmentCode ??
        candidate?.planNo ??
        blocked?.executionSegmentCode ??
        blocked?.planNo ??
        '原去向工单（待核对）';
  }

  Widget _editable(Widget child) {
    final input = UtenTableCellInputTheme(child: child);
    return enabled ? input : ExcludeFocus(child: IgnorePointer(child: input));
  }

  double _nameWidth(
    BuildContext context, {
    required String header,
    required Iterable<String> names,
    bool dropdown = false,
    bool hasDisclosure = false,
  }) {
    final theme = Theme.of(context);
    double measure(String text, TextStyle style) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      )..layout();
      final width = painter.width;
      painter.dispose();
      return width;
    }

    final headerWidth =
        measure(header, UtenTableHeader.textStyle(theme)) + UtenSpacing.s12 * 2;
    final style = dropdown
        ? theme.textTheme.bodyLarge!
        : theme.textTheme.bodyMedium!;
    var width = headerWidth;
    // Dense dropdowns reserve their input padding and arrow. A warning/error
    // disclosure can also occupy the existing 44px adornment alongside it.
    final chrome =
        UtenSpacing.s12 * 2 +
        (dropdown
            ? UtenEditableGridCellSpec.contentPadding.horizontal +
                  UtenEditableGridCellSpec.dropdownChevronWidth +
                  (hasDisclosure ? 44 : 0) +
                  2
            : 0);
    for (final name in names) {
      width = math.max(width, measure(name, style) + chrome);
    }
    // Default widths show the complete name; a user's narrower width remains
    // authoritative and can be restored by double-clicking the column edge.
    return width.ceilToDouble();
  }

  Widget _singleLine(String? value, {String? extra}) {
    final display = value?.trim().isNotEmpty == true ? value!.trim() : '—';
    return Tooltip(
      message: [display, if (extra?.isNotEmpty == true) extra!].join('\n'),
      child: Text(display, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
  }

  String _issuedQuantity(DailyGridRow row) {
    final quantity = row.material?.issuedQtyText;
    if (quantity == null) return '领料量待核对';
    final unit = row.material?.unitName?.trim();
    return '${_number(financeExactDecimalUnits(quantity)!)}${unit?.isNotEmpty == true ? ' $unit' : ''}';
  }

  String _materialIssue(DailyGridRow row) {
    final name = row.material?.goodsName ?? row.material?.goodsCode ?? '物料';
    final quantity = _units(row.materialUsed.text);
    if (quantity == null) return '$name：请填写有效的本次实际用料，没用填 0';
    if (quantity > productionQuantityMaxUnits) {
      return '$name：本次实际用料超过系统计量范围，请核对原输入';
    }
    final cap = row.materialCapText;
    if (cap == null) return '$name：可登记用料量待核对，请重新读取材料台账';
    return '$name：本次实际用料 ${row.materialUsed.text} 超过可登记 $cap ${row.material?.unitName ?? ''}';
  }

  Widget _issues(List<String> issues) => Padding(
    padding: const EdgeInsets.only(top: UtenSpacing.s8),
    child: UtenInlineNotice(
      level: UtenInlineNoticeLevel.warning,
      message: issues.join('；'),
    ),
  );

  static BigInt? _units(String text) => financeExactDecimalUnits(
    productionExactQuantityText(text.trim().replaceFirst(RegExp(r'\.$'), '')),
  );

  static String _number(BigInt units) {
    final text = productionExactQuantityText(
      financeExactDecimalFromUnits(units),
    )!;
    final parts = text.split('.');
    final integer = parts.first.replaceAllMapped(
      RegExp(r'\B(?=(\d{3})+(?!\d))'),
      (_) => ',',
    );
    return parts.length == 1 ? integer : '$integer.${parts.last}';
  }
}

class _DetailGroupHeader extends StatelessWidget {
  const _DetailGroupHeader({
    required this.toggleKey,
    required this.title,
    required this.icon,
    required this.count,
    required this.status,
    required this.issue,
    required this.expanded,
    required this.onToggle,
    this.detail,
    this.info,
  });
  final Key toggleKey;
  final String title, count, status;
  final String? detail, info;
  final IconData icon;
  final bool issue, expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: expanded ? UtenSpacing.s2 : 0),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final symbol = Icon(icon, size: 18, color: colors.primary);
          final heading = Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              if (info != null) UtenFieldHintIcon(info: info, dense: true),
            ],
          );
          final countLabel = DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: UtenRadius.xsAll,
              border: Border.all(color: colors.outlineVariant),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: UtenSpacing.s6,
                vertical: UtenSpacing.s2,
              ),
              child: Text(count, style: Theme.of(context).textTheme.bodySmall),
            ),
          );
          final compact = constraints.maxWidth < 480;
          final statusLabel = Tooltip(
            message: detail ?? status,
            child: Text(
              status,
              textWidthBasis: TextWidthBasis.longestLine,
              maxLines: compact ? null : 1,
              overflow: compact ? null : TextOverflow.ellipsis,
              style: TextStyle(color: issue ? colors.error : colors.primary),
            ),
          );
          final toggle = Tooltip(
            message: '${expanded ? '收起' : '展开'}$title',
            child: Semantics(
              expanded: expanded,
              child: UtenButton(
                key: toggleKey,
                size: UtenButtonSize.small,
                height: math.max(
                  36,
                  MediaQuery.textScalerOf(context).scale(18) + 12,
                ),
                onPressed: onToggle,
                icon: expanded
                    ? Icons.keyboard_arrow_up
                    : Icons.keyboard_arrow_down,
                child: Text(expanded ? '收起' : '展开'),
              ),
            ),
          );
          if (compact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: UtenSpacing.s6,
                  runSpacing: UtenSpacing.s4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [symbol, heading, countLabel],
                ),
                statusLabel,
                Align(alignment: Alignment.centerRight, child: toggle),
              ],
            );
          }
          return Row(
            children: [
              symbol,
              const SizedBox(width: UtenSpacing.s6),
              heading,
              const SizedBox(width: UtenSpacing.s6),
              countLabel,
              const SizedBox(width: UtenSpacing.s8),
              Flexible(child: statusLabel),
              const SizedBox(width: UtenSpacing.s8),
              toggle,
            ],
          );
        },
      ),
    );
  }
}

class _ProductDetailRow extends EditableGridRow {
  _ProductDetailRow({required this.key, required this.cells});
  final LocalKey key;
  List<Widget> cells;
}

/// Both detail sections use the same document grid as the owning report. This
/// adapter owns only presentation rows; editing controllers remain with the page.
class _ProductDetailsTable extends StatefulWidget {
  const _ProductDetailsTable({
    super.key,
    required this.tableKey,
    required this.widths,
    required this.columnKeys,
    required this.columnLabels,
    required this.minimumWidths,
    required this.headers,
    required this.rows,
    this.compactColumns = const {},
  });
  final String tableKey;
  final List<double> widths, minimumWidths;
  final List<String> columnKeys, columnLabels;
  final List<Widget> headers;
  final List<_ProductDetailRow> rows;
  final Set<int> compactColumns;

  @override
  State<_ProductDetailsTable> createState() => _ProductDetailsTableState();
}

class _ProductDetailsTableState extends State<_ProductDetailsTable> {
  late final _controller = UtenEditableGridController<_ProductDetailRow>(
    initial: widget.rows,
  );

  @override
  void didUpdateWidget(_ProductDetailsTable oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldRows = _controller.rows;
    final byKey = {for (final row in oldRows) row.key: row};
    final next = [
      for (final incoming in widget.rows)
        if (byKey[incoming.key] case final existing?)
          (() {
            existing.cells = incoming.cells;
            if (!identical(existing, incoming)) incoming.dispose();
            return existing;
          })()
        else
          incoming,
    ];
    final removed = oldRows.where((row) => !next.contains(row)).toList();
    if (removed.isNotEmpty) _controller.removeRows(removed);
    if (next.length != oldRows.length ||
        next.asMap().entries.any(
          (entry) => !identical(entry.value, oldRows[entry.key]),
        )) {
      _controller.swapRows(next);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => UtenEditableGrid<_ProductDetailRow>(
    tableKey: widget.tableKey,
    controller: _controller,
    showAddRow: false,
    showRowDelete: false,
    showColumnSettings: false,
    stickyHeader: false,
    columns: [
      for (var column = 0; column < widget.columnKeys.length; column++)
        EditableGridColumn<_ProductDetailRow>(
          key: widget.columnKeys[column],
          label: widget.columnLabels[column],
          width:
              widget.widths[column] +
              (widget.compactColumns.contains(column) ? 12 : 0),
          minimumWidthOf: (_) =>
              widget.minimumWidths[column] +
              (widget.compactColumns.contains(column) ? 12 : 0),
          headerInfo: widget.headers[column] is UtenColumnHeaderInfo
              ? (widget.headers[column] as UtenColumnHeaderInfo).message
              : null,
          required:
              widget.headers[column] is Text &&
              ((widget.headers[column] as Text).data?.endsWith(' *') ?? false),
          cellBuilder: (_, row) =>
              KeyedSubtree(key: row.key, child: row.cells[column]),
        ),
    ],
  );
}
