import 'package:flutter/material.dart';

import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../core/theme/uten_tokens.dart';
import '../models/warehouse_sales_outbound.dart';

/// Local review intent only; the warehouse command validates real reservations.
class WarehouseSalesPickingDraft {
  WarehouseSalesPickingDraft(this.detail) {
    final eligible = detail.warehouseOptions
        .where((option) => option.canFulfill)
        .toList();
    final original = detail.header.warehouseId;
    warehouseId = detail.canSelectWarehouse
        ? (detail.warehouseOptions.any(
                (option) => option.warehouseId == original,
              )
              ? original
              : eligible.length == 1
              ? eligible.single.warehouseId
              : null)
        : original;
    for (final line in detail.lines) {
      places[line.id] = TextEditingController(
        text: warehouseId == original ? line.actualStockPlace ?? '' : '',
      );
    }
  }
  final WarehouseSalesOutboundDetail detail;
  late String? warehouseId;
  String? error;
  final Map<String, TextEditingController> places = {};
  Map<String, String> get stockPlaces => {
    for (final entry in places.entries) entry.key: entry.value.text.trim(),
  };
  WarehouseSalesWarehouseOption? get selected {
    for (final option in detail.warehouseOptions) {
      if (option.warehouseId == warehouseId) return option;
    }
    return null;
  }

  String? get warehouseName => detail.canSelectWarehouse
      ? selected?.warehouseName
      : detail.header.warehouseName;

  void changeWarehouse(String? value) {
    if (value != warehouseId) {
      warehouseId = value;
      // Previous location remains in the read model as history; it does not
      // establish a location in a different warehouse for this operation.
      for (final controller in places.values) {
        controller.clear();
      }
    }
    error = null;
  }

  bool validate() {
    error = detail.canSelectWarehouse && selected?.canFulfill != true
        ? '请选择能满足本单数量的实际发货仓'
        : null;
    return error == null;
  }

  void dispose() {
    for (final controller in places.values) {
      controller.dispose();
    }
  }
}

class WarehouseSalesPickingFields extends StatelessWidget {
  const WarehouseSalesPickingFields({
    super.key,
    required this.draft,
    required this.onChanged,
    this.enabled = true,
  });
  final WarehouseSalesPickingDraft draft;
  final VoidCallback onChanged;
  final bool enabled;
  @override
  Widget build(BuildContext context) {
    if (!draft.detail.canSelectWarehouse) return const SizedBox.shrink();
    final option = draft.selected;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<String>(
          key: ValueKey('sales-picking-warehouse-${draft.detail.header.id}'),
          initialValue: draft.warehouseId,
          isExpanded: true,
          decoration: UtenInputDecoration(
            InputDecoration(
              labelText: '实际发货仓库',
              error: draft.error == null
                  ? null
                  : UtenFieldMessage.error(draft.error!),
            ),
          ),
          items: [
            for (final warehouse in draft.detail.warehouseOptions)
              DropdownMenuItem(
                value: warehouse.warehouseId,
                enabled: warehouse.canFulfill,
                child: Text(
                  '${warehouse.warehouseName}${warehouse.canFulfill ? '' : ' · 可发量不足'}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: !enabled
              ? null
              : (value) {
                  draft.changeWarehouse(value);
                  onChanged();
                },
        ),
        if (draft.detail.warehouseOptions.isEmpty) ...[
          const SizedBox(height: UtenSpacing.s8),
          const Text('暂无可供货仓库，请刷新核对入库和预留进度。'),
        ],
        if (option != null) ...[
          const SizedBox(height: UtenSpacing.s8),
          for (final line in option.lines)
            Text(
              '${_goods(line.shipmentItemId)}：本仓可发 ${line.availableQty ?? '0'} / 本单需发 ${line.requiredQty ?? '0'}',
            ),
        ],
      ],
    );
  }

  String _goods(String id) {
    for (final line in draft.detail.lines) {
      if (line.id == id) return line.goodsName ?? line.goodsCode ?? '产品';
    }
    return '产品';
  }
}
