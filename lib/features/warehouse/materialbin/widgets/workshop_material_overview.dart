import 'package:flutter/material.dart';

import '../../../../components/data_display/uten_status_badge.dart';
import '../../../../components/data_display/uten_status_cell_color.dart';
import '../../../../components/feedback/uten_inline_notice.dart';
import '../../../../components/layout/uten_filter_toolbar.dart';
import '../../../../components/layout/uten_floating_action_group.dart';
import '../../../../core/theme/uten_tokens.dart';
import '../../../basic_data/widgets/master_data_table_view.dart';
import '../models/workshop_material_models.dart';
import 'workshop_material_labels.dart';

/// General entry: show every workshop in the server's authorized metadata scope.
/// Stock is loaded only after the user explicitly opens a workshop.
class WorkshopMaterialOverview extends StatefulWidget {
  const WorkshopMaterialOverview({
    super.key,
    required this.settings,
    required this.canViewStock,
    required this.canSetup,
    required this.onOpen,
    required this.onConfigure,
    required this.onRetry,
    this.loading = false,
    this.error,
  });
  final List<WmSetting> settings;
  final bool canViewStock;
  final bool canSetup;
  final bool loading;
  final String? error;
  final ValueChanged<WmSetting> onOpen;
  final ValueChanged<WmSetting> onConfigure;
  final VoidCallback onRetry;

  @override
  State<WorkshopMaterialOverview> createState() =>
      _WorkshopMaterialOverviewState();
}

class _WorkshopMaterialOverviewState extends State<WorkshopMaterialOverview> {
  String _status = 'all';
  String _keyword = '';
  bool _enabled(WmSetting setting) =>
      setting.periodicEnabled && setting.binWarehouseId != null;

  bool _canConfigure(WmSetting setting) =>
      widget.canSetup && setting.can(WmAction.setup);

  @override
  Widget build(BuildContext context) {
    final enabledCount = widget.settings.where(_enabled).length;
    final rows = widget.settings.where((setting) {
      if (_status == 'enabled' && !_enabled(setting)) return false;
      if (_status == 'disabled' && _enabled(setting)) return false;
      return [
        setting.workshopName,
        setting.binWarehouseName,
        setting.mainWarehouseName,
      ].whereType<String>().join(' ').toLowerCase().contains(_keyword);
    }).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        UtenFilterToolbar<String>(
          segmentsKey: const Key('wm-overview-status'),
          searchKey: const Key('wm-overview-search'),
          segments: [
            UtenFilterSegment(
              value: 'all',
              label: '全部车间',
              count: widget.settings.length,
            ),
            UtenFilterSegment(
              value: 'enabled',
              label: '已启用',
              count: enabledCount,
            ),
            UtenFilterSegment(
              value: 'disabled',
              label: '未启用',
              count: widget.settings.length - enabledCount,
            ),
          ],
          selected: {_status},
          onSelectionChanged: (value) => setState(() => _status = value),
          searchHint: '搜索车间或仓库',
          onSearchChanged: (value) =>
              setState(() => _keyword = value.trim().toLowerCase()),
        ),
        const SizedBox(height: UtenSpacing.s12),
        if (widget.error != null) ...[
          UtenInlineNotice(
            message: widget.error!,
            level: UtenInlineNoticeLevel.error,
            trailing: TextButton(
              onPressed: widget.loading ? null : widget.onRetry,
              child: const Text('重试'),
            ),
          ),
          const SizedBox(height: UtenSpacing.s8),
        ],
        Expanded(
          child: MasterDataTableView<WmSetting>(
            key: const Key('wm-overview-table'),
            tableKey: 'warehouse.workshop-material-overview',
            columns: [
              MasterColumnDef(
                key: 'workshop',
                label: '车间',
                width: 170,
                value: (s) => s.workshopName,
              ),
              MasterColumnDef(
                key: 'enabled',
                label: '状态',
                width: 100,
                value: (s) => _enabled(s) ? '已启用' : '未启用',
                // 2026-10-01 口径「不同状态不同颜色」：已启用绿 / 未启用灰。
                cellColor: (context, s) => udenStatusBadgeCellColor(
                  context,
                  _enabled(s)
                      ? UtenStatusBadgeType.success
                      : UtenStatusBadgeType.neutral,
                ),
              ),
              MasterColumnDef(
                key: 'bin',
                label: '内料仓',
                width: 190,
                value: (s) => s.binWarehouseName,
              ),
              MasterColumnDef(
                key: 'main',
                label: '所属主仓',
                width: 160,
                value: (s) => s.mainWarehouseName,
              ),
              MasterColumnDef(
                key: 'period',
                label: '本期',
                width: 250,
                value: (s) => s.currentPeriod == null
                    ? null
                    : wmPeriodLabel(s.currentPeriod!),
              ),
              MasterColumnDef(
                key: 'actions',
                label: '操作',
                width: 230,
                value: (_) => '',
                cellBuilderHandlesSemantics: true,
                cellBuilder: (_, setting) => Wrap(
                  spacing: UtenSpacing.s8,
                  children: [
                    if (_enabled(setting) && widget.canViewStock)
                      TextButton(
                        key: ValueKey(
                          'wm-overview-open-${setting.workshopDepartmentId}',
                        ),
                        onPressed: widget.loading
                            ? null
                            : () => widget.onOpen(setting),
                        child: const Text('查看库存'),
                      ),
                    if (_canConfigure(setting))
                      TextButton(
                        key: ValueKey(
                          'wm-overview-setup-${setting.workshopDepartmentId}',
                        ),
                        onPressed: widget.loading
                            ? null
                            : () => widget.onConfigure(setting),
                        child: Text(_enabled(setting) ? '设置' : '去开通'),
                      ),
                  ],
                ),
              ),
            ],
            items: rows,
            facets: const {},
            nullCounts: const {},
            filters: const {},
            onFilterChanged: (_, _) {},
            rowKeyOf: (s) => s.workshopDepartmentId,
            onRowTap: (setting) {
              if (widget.loading) return;
              if (_enabled(setting) && widget.canViewStock) {
                widget.onOpen(setting);
              } else if (_canConfigure(setting)) {
                widget.onConfigure(setting);
              }
            },
            isLoading: widget.loading,
            onRetry: widget.onRetry,
            bottomContentPadding: UtenFloatingActionGroup.scrollClearance,
            emptyMessage: widget.settings.isEmpty ? '暂无可查看的车间' : '没有符合条件的车间',
          ),
        ),
      ],
    );
  }
}
