import 'dart:async';
import 'package:flutter/material.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/inputs/uten_field_hint_icon.dart';
import '../../../components/inputs/uten_multi_value_cell.dart';
import '../../../shared/formatters/exact_decimal.dart';
import '../../../shared/formatters/quantity_display.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../production/delivery_processing/delivery_processing_tasks_button.dart';
import '../models/warehouse_sales_outbound.dart';
import 'warehouse_sales_picking_fields.dart';
import 'warehouse_component_processing_actions.dart';

/// Commercial parent quantities remain separate from the actual stock movements.
class WarehouseDeliveryComponentsTabs extends StatelessWidget {
  const WarehouseDeliveryComponentsTabs({
    super.key,
    required this.commercial,
    required this.details,
    required this.draftOf,
    required this.onChanged,
    this.editingEnabled = true,
    this.onFactsChanged,
    this.checkpointInput,
  });
  final Widget commercial;
  final List<WarehouseSalesOutboundDetail> details;
  final WarehouseSalesPickingDraft? Function(String shipmentId) draftOf;
  final VoidCallback onChanged;
  final bool editingEnabled;
  final FutureOr<void> Function()? onFactsChanged;
  final Future<void> Function()? checkpointInput;
  @override
  Widget build(BuildContext context) {
    final rows = [
      for (final detail in details)
        for (final component in detail.deliveryComponents)
          (detail: detail, component: component),
    ];
    if (rows.isEmpty) return commercial;
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          TabBar(
            tabs: [
              const Tab(text: '订单产品数量'),
              Tab(text: '实际交付散件 (${rows.length})'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                commercial,
                MasterDataTableView<
                  ({
                    WarehouseSalesOutboundDetail detail,
                    WarehouseDeliveryComponent component,
                  })
                >(
                  tableKey: 'warehouse.sales-outbound.delivery-components',
                  primary: true,
                  items: rows,
                  facets: const {},
                  nullCounts: const {},
                  filters: const {},
                  onFilterChanged: (_, _) {},
                  idOf: (row) => row.component.id,
                  toolbarActions: [
                    for (final detail in details)
                      if (detail.deliveryComponents.any(
                        (component) => component.operations.isNotEmpty,
                      ))
                        Tooltip(
                          message: detail.header.billNo ?? '出货单加工任务',
                          child: DeliveryProcessingTasksButton(
                            shipmentId: detail.header.id,
                            onChanged: onFactsChanged ?? onChanged,
                          ),
                        ),
                  ],
                  columns: [
                    MasterColumnDef(
                      key: 'shipment',
                      label: '出货单号',
                      width: 160,
                      value: (row) => row.detail.header.billNo,
                      filterFromRows: true,
                    ),
                    MasterColumnDef(
                      key: 'name',
                      label: '物料名称',
                      width: 220,
                      value: (row) => row.component.goodsName,
                      filterFromRows: true,
                    ),
                    MasterColumnDef(
                      key: 'code',
                      label: '编号',
                      width: 140,
                      value: (row) => row.component.goodsCode,
                      filterFromRows: true,
                    ),
                    MasterColumnDef(
                      key: 'qty',
                      label: '实际交付数量',
                      width: 150,
                      value: (row) => formatExactQtyWithUnit(
                        row.component.quantity,
                        row.component.unitName,
                      ),
                      cellBuilder: (_, row) => Row(
                        children: [
                          Flexible(
                            child: Text(
                              formatExactQtyWithUnit(
                                row.component.quantity,
                                row.component.unitName,
                              ),
                            ),
                          ),
                          if (row.component.originalQuantity != null &&
                              financeAmountUnits(
                                    row.component.originalQuantity,
                                  ) !=
                                  financeAmountUnits(row.component.quantity))
                            UtenFieldHintIcon(
                              dense: true,
                              info:
                                  '原始BOM要求 ${row.component.originalQuantity} ${row.component.unitName ?? ''}；经明确精度选择后采用 ${row.component.quantity} ${row.component.unitName ?? ''}，保留原值用于追溯。',
                            ),
                        ],
                      ),
                      filterFromRows: true,
                    ),
                    MasterColumnDef(
                      key: 'processingTargets',
                      label: '实际加工对象',
                      width: 280,
                      value: (row) => row.component.processingTargets
                          .map((target) => target.label)
                          .join('；'),
                      filterFromRows: true,
                      info:
                          '交付件数量与内部加工对象数量分别保留。对象数量按冻结BOM精确展开；分数原样显示，不折算或重复计入交付数量。',
                      cellBuilder: (_, row) => UtenMultiValueCell(
                        title: '实际加工对象',
                        values: row.component.processingTargets
                            .map((target) => target.label)
                            .toList(),
                        emptyText: row.component.operations.isEmpty
                            ? '无追加加工'
                            : '未提供加工对象快照',
                      ),
                    ),
                    MasterColumnDef(
                      key: 'process',
                      label: '必要加工状态',
                      width: 180,
                      value: (row) => row.component.processingLabel,
                      filterFromRows: true,
                      info: '加工数量及证据由服务端记录；完成必要加工后才可出库，不能在此勾选代替加工事实。',
                    ),
                    MasterColumnDef(
                      key: 'processing-actions',
                      label: '加工交接',
                      width: 300,
                      value: (row) => row.component.processingLabel,
                      info: '先派工，再由仓库发至加工；车间报工后由仓库收回，最后按真实散件出库。',
                      cellBuilder: (_, row) {
                        final draft = draftOf(row.detail.header.id);
                        if (draft == null || checkpointInput == null) {
                          return const SizedBox.shrink();
                        }
                        return WarehouseComponentProcessingActions(
                          key: ValueKey(
                            'delivery-processing-handover-${row.component.id}',
                          ),
                          detail: row.detail,
                          component: row.component,
                          draft: draft,
                          enabled: editingEnabled,
                          onInputChanged: onChanged,
                          checkpoint: checkpointInput!,
                          onFactsChanged: onFactsChanged ?? onChanged,
                        );
                      },
                    ),
                    MasterColumnDef(
                      key: 'processed',
                      label: '已加工数量',
                      width: 150,
                      value: (row) => formatExactQtyWithUnit(
                        row.component.processedQty,
                        row.component.unitName,
                      ),
                      filterFromRows: true,
                    ),
                    MasterColumnDef(
                      key: 'warehouse',
                      label: '实际发出仓',
                      width: 220,
                      info:
                          '可用预览不代表本单实物已齐套；尚未转交的原订单或分析权益由提交时按真实来源、完整数量及权限权威核对。',
                      value: (row) {
                        final draft = draftOf(row.detail.header.id);
                        final selected =
                            draft?.componentWarehouses[row.component.id] ??
                            row.component.warehouseId;
                        return row.component.warehouseChoices
                            .where((choice) => choice.warehouseId == selected)
                            .firstOrNull
                            ?.warehouseName;
                      },
                      cellBuilder: (_, row) {
                        final draft = draftOf(row.detail.header.id);
                        final editable =
                            editingEnabled &&
                            draft?.selectable == true &&
                            draft?.componentRequests[row.component.id] ==
                                null &&
                            row.component.processingIssuedAt == null;
                        final selected =
                            draft?.componentWarehouses[row.component.id] ??
                            row.component.warehouseId;
                        if (!editable) {
                          return Text(
                            row.component.warehouseChoices
                                    .where(
                                      (choice) =>
                                          choice.warehouseId == selected,
                                    )
                                    .firstOrNull
                                    ?.warehouseName ??
                                '—',
                          );
                        }
                        return UtenDropdownField(
                          key: ValueKey(
                            'delivery-component-warehouse-${row.component.id}',
                          ),
                          value: selected,
                          dense: true,
                          required: true,
                          items: [
                            for (final choice in row.component.warehouseChoices)
                              UtenDropdownItem(
                                value: choice.warehouseId,
                                label: choice.label,
                                enabled: choice.selectableForComponent,
                              ),
                          ],
                          errorMessage:
                              draft?.componentErrors[row.component.id],
                          onChanged: (value) {
                            draft!.changeComponentWarehouse(
                              row.component.id,
                              value,
                            );
                            onChanged();
                          },
                        );
                      },
                    ),
                    MasterColumnDef(
                      key: 'place',
                      label: '实际库位',
                      width: 180,
                      value: (row) =>
                          draftOf(
                            row.detail.header.id,
                          )?.componentPlaces[row.component.id]?.text ??
                          row.component.stockPlace,
                      cellBuilder: (_, row) {
                        final draft = draftOf(row.detail.header.id);
                        final controller =
                            draft?.componentPlaces[row.component.id];
                        if (controller == null ||
                            !editingEnabled ||
                            draft?.selectable != true ||
                            draft?.componentRequests[row.component.id] !=
                                null ||
                            row.component.processingIssuedAt != null) {
                          return Text(row.component.stockPlace ?? '—');
                        }
                        return TextField(
                          key: ValueKey(
                            'delivery-component-place-${row.component.id}',
                          ),
                          controller: controller,
                          decoration: const UtenInputDecoration(
                            InputDecoration(isDense: true, hintText: '实际库位'),
                          ),
                        );
                      },
                    ),
                    MasterColumnDef(
                      key: 'path',
                      label: '原BOM路径',
                      width: 300,
                      value: (row) => row.component.path.join(' / '),
                      filterFromRows: true,
                      info: '按订单明细及BOM边身份追溯，父产品不与这些散件重复扣库存。',
                    ),
                    MasterColumnDef(
                      key: 'evidence',
                      label: '加工证据',
                      width: 220,
                      value: (row) => row.component.processingEvidence,
                      filterFromRows: true,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
