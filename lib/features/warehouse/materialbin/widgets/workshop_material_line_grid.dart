// 车间内料仓发料 / 申请 / 退回共用的"料 × 袋数 × 公斤 (× 出库叶仓)"明细表 (ADR-131)。
//
// - 袋数 ↔ 公斤联动: 改袋数按每袋净重算公斤 (可再改); 改公斤反算袋数。
// - 勾选多行后改任一勾选行的单元格 = 对全部勾选行生效 (看到的勾选 = 提交的内容);
//   没勾选的行只改自己。
// - 每行提示"仓库还有 X 公斤 / 内料仓估计还剩 Y 公斤" (数字全部来自服务端)。
import 'package:flutter/material.dart';

import '../../../../components/inputs/uten_dropdown_field.dart';
import '../../../../components/layout/uten_editable_grid.dart';
import '../../../../core/l10n/gen/app_localizations.dart';
import '../models/workshop_material_models.dart';
import 'workshop_material_labels.dart';

/// 一行: 选的料、出库叶仓、袋数、公斤。按申请发料时带着原申请行。
class WmIssueLineRow extends EditableGridRow {
  WmIssueLineRow({
    required this.id,
    WmMaterialOption? material,
    String? leafWarehouseId,
    this.requisitionLine,
  }) : material = ValueNotifier<WmMaterialOption?>(material),
       leafWarehouseId = ValueNotifier<String?>(
         leafWarehouseId ?? material?.defaultLeafWarehouseId,
       );

  /// 页面内的行号 (测试与语义锚点用, 如 wm-line-qty-r1)。
  final String id;
  final ValueNotifier<WmMaterialOption?> material;
  final ValueNotifier<String?> leafWarehouseId;
  final TextEditingController bags = TextEditingController();
  final TextEditingController qty = TextEditingController();

  /// 按申请发料 / 收退回时对应的申请行 (料不可改)。
  final WmRequisitionLine? requisitionLine;

  String? get goodsId => material.value?.goodsId ?? requisitionLine?.goodsId;
  String? get colorId => material.value?.colorId ?? requisitionLine?.colorId;

  double? get bagNet =>
      material.value?.bulkPackageQty ?? requisitionLine?.bulkPackageQty;
  double? get qtyValue => wmParseQty(qty.text);
  double? get bagsValue => wmParseQty(bags.text);

  /// 袋数改了: 按每袋净重算公斤 (没设每袋净重时不动公斤)。
  void bagsEdited() {
    final net = bagNet;
    if (net == null || net <= 0) return;
    final b = bagsValue;
    qty.text = b == null ? '' : wmQty(b * net, maxDecimals: 4);
  }

  /// 公斤改了: 反算袋数。
  void qtyEdited() {
    final net = bagNet;
    if (net == null || net <= 0) return;
    final q = qtyValue;
    bags.text = q == null ? '' : wmQty(q / net);
  }

  /// 换料后按新料的默认叶仓与每袋净重重新对齐。
  void applyMaterial(WmMaterialOption? next) {
    material.value = next;
    final leaves = next?.leafWarehouses ?? const <WmLeafStock>[];
    final current = leafWarehouseId.value;
    if (current == null || !leaves.any((w) => w.warehouseId == current)) {
      leafWarehouseId.value = next?.defaultLeafWarehouseId;
    }
    if (bags.text.trim().isNotEmpty) bagsEdited();
  }

  bool get isBlank =>
      material.value == null &&
      requisitionLine == null &&
      qty.text.trim().isEmpty &&
      bags.text.trim().isEmpty;

  @override
  void dispose() {
    material.dispose();
    leafWarehouseId.dispose();
    bags.dispose();
    qty.dispose();
    super.dispose();
  }
}

/// 可选叶仓 (该料有库存的叶仓 + 默认归属仓)。
List<WmLeafStock> wmLeafOptions(WmMaterialOption? material) {
  if (material == null) return const [];
  final list = [...material.leafWarehouses];
  final defaultId = material.defaultLeafWarehouseId;
  if (defaultId != null && !list.any((w) => w.warehouseId == defaultId)) {
    list.insert(
      0,
      WmLeafStock(
        warehouseId: defaultId,
        warehouseName: material.defaultLeafWarehouseName ?? '',
      ),
    );
  }
  return list;
}

/// 明细列。[grid] 用于"勾选多行后改一格 = 批量生效"; [positionByKey] 给"内料仓估计还剩"。
List<EditableGridColumn<WmIssueLineRow>> wmIssueLineColumns({
  required AppLocalizations l10n,
  required UtenEditableGridController<WmIssueLineRow> grid,
  required List<WmMaterialOption> materials,
  required bool enabled,
  bool materialEditable = true,
  bool showLeafWarehouse = false,
  String? leafLabel,
  bool showWarehouseAvailable = true,
  Map<String, WmPositionRow> positionByKey = const {},
  String? qtyLabel,

  /// 申请可从分页清单选首次物料；其他发料/退回继续使用现有下拉。
  Future<WmMaterialOption?> Function(BuildContext context)? pickMaterial,
  bool useMaterialUnit = false,
  VoidCallback? onChanged,
}) {
  final byKey = {for (final m in materials) m.key: m};

  /// 本行已勾选且还有别的勾选行 → 返回全部勾选行 (含本行); 否则只有本行。
  List<WmIssueLineRow> targets(WmIssueLineRow row) {
    final selected = grid.selectedRows;
    if (!grid.isSelected(row) || selected.length < 2) return [row];
    return selected;
  }

  WmLeafStock? leafOf(WmIssueLineRow row) {
    final id = row.leafWarehouseId.value;
    for (final w in wmLeafOptions(row.material.value)) {
      if (w.warehouseId == id) return w;
    }
    return null;
  }

  return [
    EditableGridColumn<WmIssueLineRow>(
      key: 'material',
      label: '料',
      width: 220,
      required: true,
      textOf: (row) =>
          row.material.value?.displayName ??
          row.requisitionLine?.displayName ??
          '',
      listenableOf: (row) => row.material,
      cellBuilder: (context, row) {
        if (!materialEditable || row.requisitionLine != null) {
          return Text(
            row.requisitionLine?.displayName ??
                row.material.value?.displayName ??
                '',
          );
        }
        return ValueListenableBuilder<WmMaterialOption?>(
          valueListenable: row.material,
          builder: (context, value, _) => RequiredCellFrame(
            listenable: row.material,
            isEmpty: () => row.material.value == null,
            child: pickMaterial != null
                ? InkWell(
                    key: ValueKey('wm-line-material-${row.id}'),
                    onTap: !enabled
                        ? null
                        : () async {
                            final next = await pickMaterial(context);
                            if (!context.mounted ||
                                next == null ||
                                !grid.rows.contains(row)) {
                              return;
                            }
                            for (final target in targets(row)) {
                              target.applyMaterial(next);
                            }
                            onChanged?.call();
                          },
                    child: InputDecorator(
                      decoration: InputDecoration(
                        isDense: true,
                        enabled: enabled,
                        suffixIcon: const Icon(Icons.search),
                      ),
                      child: Text(value?.displayName ?? '选择物料'),
                    ),
                  )
                : UtenDropdownField(
                    key: ValueKey('wm-line-material-${row.id}'),
                    dense: true,
                    enabled: enabled,
                    allowClear: false,
                    value: value?.key,
                    hintText: '选择料',
                    items: [
                      for (final m in materials)
                        UtenDropdownItem(value: m.key, label: m.displayName),
                    ],
                    onChanged: (key) {
                      final next = key == null ? null : byKey[key];
                      for (final target in targets(row)) {
                        target.applyMaterial(next);
                      }
                      onChanged?.call();
                    },
                  ),
          ),
        );
      },
    ),
    if (useMaterialUnit)
      EditableGridColumn<WmIssueLineRow>(
        key: 'unit',
        label: '单位',
        width: 70,
        textOf: (row) => row.material.value?.unitName ?? '',
        listenableOf: (row) => row.material,
        cellBuilder: (context, row) =>
            ValueListenableBuilder<WmMaterialOption?>(
              valueListenable: row.material,
              builder: (context, material, _) => Text(material?.unitName ?? ''),
            ),
      ),
    if (showLeafWarehouse)
      EditableGridColumn<WmIssueLineRow>(
        key: 'leaf',
        label: leafLabel ?? '出库仓库',
        width: 180,
        required: true,
        textOf: (row) => leafOf(row)?.warehouseName ?? '',
        listenableOf: (row) => row.leafWarehouseId,
        cellBuilder: (context, row) => ValueListenableBuilder<String?>(
          valueListenable: row.leafWarehouseId,
          builder: (context, value, _) => ValueListenableBuilder<WmMaterialOption?>(
            valueListenable: row.material,
            builder: (context, material, _) {
              final options = row.requisitionLine != null
                  ? _requisitionLeafOptions(row, materials)
                  : wmLeafOptions(material);
              return RequiredCellFrame(
                listenable: row.leafWarehouseId,
                isEmpty: () => row.leafWarehouseId.value == null,
                child: UtenDropdownField(
                  key: ValueKey('wm-line-leaf-${row.id}'),
                  dense: true,
                  enabled: enabled && options.isNotEmpty,
                  allowClear: false,
                  value: value,
                  hintText: '选择仓库',
                  items: [
                    for (final w in options)
                      UtenDropdownItem(
                        value: w.warehouseId,
                        label: w.availableQty > 0
                            ? '${w.warehouseName} (${wmQty(w.availableQty)} ${l10n.wmKg})'
                            : w.warehouseName,
                      ),
                  ],
                  onChanged: (id) {
                    for (final target in targets(row)) {
                      final allowed = target.requisitionLine != null
                          ? _requisitionLeafOptions(target, materials)
                          : wmLeafOptions(target.material.value);
                      if (target == row ||
                          allowed.any((w) => w.warehouseId == id)) {
                        target.leafWarehouseId.value = id;
                      }
                    }
                    onChanged?.call();
                  },
                ),
              );
            },
          ),
        ),
      ),
    EditableGridColumn<WmIssueLineRow>(
      key: 'bags',
      exactValueOf: (r) => r.bags.text,
      exactListenableOf: (r) => r.bags,
      label: l10n.wmBags,
      width: 100,
      numeric: true,
      frozenTextOf: (row) => row.bags.text,
      cellBuilder: (context, row) => TextField(
        key: ValueKey('wm-line-bags-${row.id}'),
        controller: row.bags,
        enabled: enabled,
        textAlign: TextAlign.right,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: const InputDecoration(isDense: true, hintText: '0'),
        onChanged: (text) {
          for (final target in targets(row)) {
            if (target != row) target.bags.text = text;
            target.bagsEdited();
          }
          onChanged?.call();
        },
      ),
    ),
    EditableGridColumn<WmIssueLineRow>(
      key: 'qty',
      exactValueOf: (r) => r.qty.text,
      exactListenableOf: (r) => r.qty,
      label: qtyLabel ?? l10n.wmKg,
      width: 120,
      numeric: true,
      required: true,
      frozenTextOf: (row) => row.qty.text,
      cellBuilder: (context, row) => RequiredCellFrame(
        listenable: row.qty,
        isEmpty: () => (row.qtyValue ?? 0) <= 0,
        child: TextField(
          key: ValueKey('wm-line-qty-${row.id}'),
          controller: row.qty,
          enabled: enabled,
          textAlign: TextAlign.right,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(isDense: true, hintText: '0'),
          onChanged: (text) {
            for (final target in targets(row)) {
              if (target != row) target.qty.text = text;
              target.qtyEdited();
            }
            onChanged?.call();
          },
        ),
      ),
    ),
    EditableGridColumn<WmIssueLineRow>(
      key: 'hint',
      label: '参考',
      width: 260,
      textOf: (row) => _hintText(
        l10n,
        row,
        positionByKey,
        atLeaf: showLeafWarehouse,
        showWarehouseAvailable: showWarehouseAvailable,
        useMaterialUnit: useMaterialUnit,
      ),
      cellBuilder: (context, row) => ValueListenableBuilder<String?>(
        valueListenable: row.leafWarehouseId,
        builder: (context, _, _) => ValueListenableBuilder<WmMaterialOption?>(
          valueListenable: row.material,
          builder: (context, _, _) => Text(
            _hintText(
              l10n,
              row,
              positionByKey,
              atLeaf: showLeafWarehouse,
              showWarehouseAvailable: showWarehouseAvailable,
              useMaterialUnit: useMaterialUnit,
            ),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    ),
  ];
}

List<WmLeafStock> _requisitionLeafOptions(
  WmIssueLineRow row,
  List<WmMaterialOption> materials,
) {
  final line = row.requisitionLine!;
  WmMaterialOption? material;
  for (final m in materials) {
    if (m.key == line.key) material = m;
  }
  final list = wmLeafOptions(material);
  final suggested = line.suggestedLeafWarehouseId;
  if (suggested != null && !list.any((w) => w.warehouseId == suggested)) {
    return [
      WmLeafStock(
        warehouseId: suggested,
        warehouseName: line.suggestedLeafWarehouseName ?? '',
      ),
      ...list,
    ];
  }
  return list;
}

String _hintText(
  AppLocalizations l10n,
  WmIssueLineRow row,
  Map<String, WmPositionRow> positionByKey, {
  required bool atLeaf,
  required bool showWarehouseAvailable,
  required bool useMaterialUnit,
}) {
  final material = row.material.value;
  final key = material?.key ?? row.requisitionLine?.key;
  final parts = <String>[];
  final unit = useMaterialUnit ? material?.unitName ?? '' : l10n.wmKg;
  if (material != null && showWarehouseAvailable) {
    var available = material.warehouseAvailableQty;
    if (atLeaf) {
      for (final w in wmLeafOptions(material)) {
        if (w.warehouseId == row.leafWarehouseId.value) {
          available = w.availableQty;
        }
      }
    }
    parts.add(
      useMaterialUnit
          ? '仓库还有 ${wmQty(available)} $unit'
          : l10n.wmWarehouseAvailable(wmQty(available)),
    );
  }
  final position = key == null ? null : positionByKey[key];
  if (position != null) {
    parts.add(
      useMaterialUnit
          ? '内料仓估计还剩 ${wmQty(position.estimatedRemainingQty)} $unit'
          : l10n.wmEstimatedRemaining(wmQty(position.estimatedRemainingQty)),
    );
  }
  final net = row.bagNet;
  if (net != null && net > 0) parts.add('每袋 ${wmQty(net)} $unit');
  return parts.join(' · ');
}
