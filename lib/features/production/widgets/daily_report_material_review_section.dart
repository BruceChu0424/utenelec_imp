import 'package:flutter/material.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/uten_table_surface.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/layout/uten_collapsible_section.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/daily_report_material_review.dart';

class DailyReportMaterialReviewSection extends StatelessWidget {
  const DailyReportMaterialReviewSection({
    super.key,
    required this.review,
    required this.actions,
    required this.editable,
    required this.historical,
    required this.expanded,
    required this.onExpandedChanged,
    required this.onChanged,
    required this.onRefresh,
    this.attempted = false,
    this.originalIntent = false,
    this.originalResultConfirmed = false,
  });
  final DailyReportMaterialReview review;
  final Map<String, DailyReportMaterialAction> actions;
  final bool editable, historical, expanded, attempted, originalIntent;
  final bool originalResultConfirmed;
  final ValueChanged<bool> onExpandedChanged;
  final void Function(String demandId, DailyReportMaterialAction action)
  onChanged;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final selectable = review.rows
        .where((row) => row.requiresDecision)
        .toList();
    final missing = selectable
        .where((row) => actions[row.demandId] == null)
        .length;
    Widget text(String? value, {String? tooltip}) {
      final display = value?.trim().isNotEmpty == true ? value! : '—';
      return Tooltip(
        message: tooltip ?? display,
        child: Text(display, maxLines: 1, overflow: TextOverflow.ellipsis),
      );
    }

    MasterColumnDef<DailyReportMaterialReviewRow> quantityColumn(
      String key,
      String label,
      String Function(DailyReportMaterialReviewRow) value, {
      String? info,
    }) => MasterColumnDef(
      key: key,
      label: label,
      width: 154,
      type: 'number',
      info: info,
      value: (row) => '${value(row)} ${row.unitName ?? '单位待核实'}',
    );
    Widget boundedTable(Widget table) =>
        review.rows.length <= 6 ? table : SizedBox(height: 380, child: table);
    return Card(
      key: const ValueKey('daily-report-material-review'),
      shape: utenTableCardShape(context),
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: UtenCollapsibleSection(
          title: originalIntent ? '原审核的用料与余料处理' : '用料与余料处理',
          expanded: expanded,
          onExpandedChanged: onExpandedChanged,
          titleTrailing: Text('${review.rows.length} 项'),
          trailing: Text(
            originalIntent
                ? (originalResultConfirmed ? '结果已核对' : '结果待核对')
                : historical
                ? '已登记处理结果'
                : editable
                ? (missing == 0 ? '处理方式已核对' : '$missing 项待选择')
                : '只读核对',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                originalIntent
                    ? (originalResultConfirmed
                          ? '原审核结果已核对，本机收尾待完成。以下保留原用料与余料处理记录。'
                          : '以下为本机保存的原审核内容，余额与处理方式不会随当前资料重算。')
                    : historical
                    ? '以下为审核时保存的用料与余料处理记录。'
                    : '本次实际用料采用已保存的表格数量。余料为账面余额；退仓先申请，仓库收料后完成退仓。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (editable) ...[
                const SizedBox(height: UtenSpacing.s8),
                Wrap(
                  spacing: UtenSpacing.s8,
                  runSpacing: UtenSpacing.s8,
                  children: [
                    if (selectable.isNotEmpty)
                      UtenButton(
                        key: const ValueKey('daily-material-return-all'),
                        type: UtenButtonType.secondary,
                        onPressed: () {
                          for (final row in selectable) {
                            onChanged(
                              row.demandId,
                              DailyReportMaterialAction.returnToWarehouse,
                            );
                          }
                        },
                        child: const Text('全部可退余料退仓'),
                      ),
                    if (selectable.isNotEmpty)
                      UtenButton(
                        key: const ValueKey('daily-material-keep-all'),
                        type: UtenButtonType.secondary,
                        onPressed: () {
                          for (final row in selectable) {
                            onChanged(
                              row.demandId,
                              DailyReportMaterialAction.keep,
                            );
                          }
                        },
                        child: const Text('全部留在车间'),
                      ),
                    UtenButton(
                      key: const ValueKey('daily-material-refresh'),
                      type: UtenButtonType.secondary,
                      onPressed: onRefresh,
                      child: const Text('刷新用料核对'),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: UtenSpacing.s8),
              boundedTable(
                MasterDataTableView<DailyReportMaterialReviewRow>(
                  tableKey: 'production.daily.material-review',
                  embedded: review.rows.length <= 6,
                  virtualized: review.rows.length > 6,
                  showColumnChooser: false,
                  showFullscreenToggle: false,
                  enableTextSelection: false,
                  columns: [
                    MasterColumnDef(
                      key: 'source',
                      label: '来源工单',
                      width: 150,
                      value: (row) => row.materialExecutionSegmentCode ?? '—',
                      cellBuilder: (_, row) =>
                          text(row.materialExecutionSegmentCode),
                    ),
                    MasterColumnDef(
                      key: 'goods',
                      label: '物料名称',
                      width: 240,
                      value: (row) => row.goodsName ?? '—',
                      cellBuilder: (_, row) => text(row.goodsName),
                    ),
                    MasterColumnDef(
                      key: 'code',
                      label: '编号',
                      width: 120,
                      value: (row) => row.goodsCode ?? '—',
                      cellBuilder: (_, row) => text(row.goodsCode),
                    ),
                    MasterColumnDef(
                      key: 'color',
                      label: '颜色',
                      width: 100,
                      value: (row) => row.colorName ?? '—',
                    ),
                    quantityColumn('usage', '本次实际用料', (row) => row.usageQty),
                    quantityColumn(
                      'available',
                      '审核前可用',
                      (row) => row.availableQty,
                      info: '原领料当前可登记量；已退、已耗和退料途中冻结均由服务端核对，不含未领直送料。',
                    ),
                    quantityColumn(
                      'remaining',
                      '预计已领余料',
                      (row) => row.remainingIssuedQty,
                      info: '本张日报实耗登记后的已领料账面结余，不代表实物清点或全部可退。',
                    ),
                    quantityColumn(
                      'undrawn',
                      '未领直送料',
                      (row) => row.undrawnDirectQty,
                      info: '车间直送但尚未领用的料，单独核对，不计入原领料余额。',
                    ),
                    quantityColumn(
                      'returnable',
                      '本次可申请退料',
                      (row) => row.returnableQty,
                      info: '服务端按原领料和直送批次的真实可退来源核对；后续批次承接或受限来源不计入。',
                    ),
                    MasterColumnDef(
                      key: 'action',
                      label: historical ? '处理结果' : '处理方式',
                      width: 180,
                      value: (row) =>
                          actions[row.demandId]?.label ??
                          (row.requiresDecision ? '待选择' : '留在车间'),
                      cellBuilder: (_, row) {
                        final action = actions[row.demandId];
                        if (originalIntent) {
                          return text(
                            !row.hasBalance
                                ? '无余料'
                                : '${(action ?? DailyReportMaterialAction.keep).label}（原选择）',
                          );
                        }
                        if (historical) {
                          return text(
                            !row.hasBalance
                                ? '无余料'
                                : action ==
                                      DailyReportMaterialAction
                                          .returnToWarehouse
                                ? '退仓申请已登记'
                                : '留在车间',
                            tooltip:
                                action ==
                                    DailyReportMaterialAction.returnToWarehouse
                                ? '退仓申请已登记，收料进度以退料单为准'
                                : null,
                          );
                        }
                        if (!row.requiresDecision) {
                          return text(
                            row.hasBalance ? '留在车间' : '无余料',
                            tooltip:
                                row.returnBlockedReason ??
                                (row.hasBalance
                                    ? '当前来源不可退料，保留在车间'
                                    : '本次没有余料，无需选择处理方式'),
                          );
                        }
                        if (!editable) return text(action?.label ?? '待审核员选择');
                        return Tooltip(
                          message:
                              row.returnBlockedReason?.trim().isNotEmpty == true
                              ? '只申请本次可退数量；${row.returnBlockedReason}，其余留在车间'
                              : '只申请本次可退数量，其余留在车间',
                          child: UtenDropdownField(
                            key: ValueKey(
                              'daily-material-action-${row.demandId}',
                            ),
                            dense: true,
                            allowClear: false,
                            value: action?.wire,
                            label: '处理方式',
                            hintText: '处理方式',
                            errorMessage: attempted && action == null
                                ? '请选择处理方式'
                                : null,
                            items: [
                              for (final value
                                  in DailyReportMaterialAction.values)
                                UtenDropdownItem(
                                  value: value.wire,
                                  label: value.label,
                                ),
                            ],
                            onChanged: (value) {
                              if (value != null) {
                                onChanged(
                                  row.demandId,
                                  DailyReportMaterialAction.parse(value),
                                );
                              }
                            },
                          ),
                        );
                      },
                    ),
                  ],
                  items: review.rows,
                  facets: const {},
                  nullCounts: const {},
                  filters: const {},
                  onFilterChanged: (_, _) {},
                  emptyMessage: '本张日报没有需要处理的物料',
                  idOf: (row) => row.demandId,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
