// 车间内料仓总览 (ADR-147): 唯一的车间清单。
//
// - 状态列是服务端给的三态: 未开通 (灰) / 已开通, 收车间直送 (蓝) / 整批领料中 (绿);
// - 行里不放按钮 (行高与平台普通表格一致): 单击选中、双击打开 (已开通进内料仓, 未开通打开开通面板),
//   右键/长按菜单放开通、开启整批领料、改来源仓、撤销;
// - 有开通设置权限时表头三态多选, 右下悬浮「开通(N)」「开启整批领料(N)」「撤销(N)」,
//   N 只数勾选里这一步适用的车间; 没有设置权限不显示勾选列 (隐藏而不是禁用)。
// 库存只在用户明确打开某个车间的内料仓之后才读。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../../components/buttons/uten_button.dart';
import '../../../../components/data_display/uten_status_badge.dart';
import '../../../../components/data_display/uten_status_cell_color.dart';
import '../../../../components/feedback/uten_busy_overlay.dart';
import '../../../../components/feedback/uten_context_menu.dart';
import '../../../../components/feedback/uten_dialog.dart';
import '../../../../components/feedback/uten_inline_notice.dart';
import '../../../../components/layout/uten_filter_toolbar.dart';
import '../../../../components/layout/uten_floating_action_group.dart';
import '../../../../core/l10n/gen/app_localizations.dart';
import '../../../../core/network/api_exception.dart';
import '../../../../core/theme/uten_tokens.dart';
import '../../../../core/ui/app_notification.dart';
import '../../../basic_data/widgets/master_data_table_view.dart';
import '../models/workshop_material_models.dart';
import '../repositories/workshop_material_repository.dart';
import 'workshop_material_enable_panel.dart';
import 'workshop_material_labels.dart';

class WorkshopMaterialOverview extends ConsumerStatefulWidget {
  const WorkshopMaterialOverview({
    super.key,
    required this.settings,
    required this.canViewStock,
    required this.canSetup,
    required this.onOpen,
    required this.onChanged,
    required this.onRetry,
    this.onOpenMachines,
    this.loading = false,
    this.error,
  });

  final List<WmSetting> settings;
  final bool canViewStock;
  final bool canSetup;
  final bool loading;
  final String? error;

  /// 打开某个已开通车间的内料仓。
  final ValueChanged<WmSetting> onOpen;

  /// 开通/撤销办成后重新读清单。
  final Future<void> Function() onChanged;
  final VoidCallback onRetry;

  /// 进机台与容器、上线准备 (设置页)。
  final VoidCallback? onOpenMachines;

  @override
  ConsumerState<WorkshopMaterialOverview> createState() =>
      _WorkshopMaterialOverviewState();
}

class _WorkshopMaterialOverviewState
    extends ConsumerState<WorkshopMaterialOverview> {
  static const _all = 'all';
  final _nonce = const Uuid().v4();
  String _status = _all;
  String _keyword = '';
  Set<String> _selected = {};
  bool _busy = false;

  WorkshopMaterialRepository get _repo =>
      ref.read(workshopMaterialRepositoryProvider);

  @override
  void didUpdateWidget(covariant WorkshopMaterialOverview oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 清单刷新后只保留仍然存在的车间 (看到的勾选 = 提交的内容)。
    final ids = widget.settings.map((s) => s.workshopDepartmentId).toSet();
    if (!_selected.every(ids.contains)) {
      _selected = _selected.where(ids.contains).toSet();
    }
  }

  List<WmSetting> get _selectedSettings => [
    for (final s in widget.settings)
      if (_selected.contains(s.workshopDepartmentId)) s,
  ];

  List<WmSetting> _applicable(String action) => [
    for (final s in _selectedSettings)
      if (s.can(action)) s,
  ];

  /// 撤销按钮数的是勾选里已开通的车间 (能不能撤销由服务端判定, 确认框里说明)。
  List<WmSetting> get _revocable => [
    for (final s in _selectedSettings)
      if (s.status != WmBinStatus.notOpen) s,
  ];

  Future<void> _openPanel(List<WmSetting> targets, WmBinPanelMode mode) async {
    if (targets.isEmpty || _busy) return;
    final saved = await showWorkshopBinOpeningPanel(
      context,
      settings: targets,
      mode: mode,
    );
    if (saved == null || !mounted) return;
    setState(() => _selected = {});
    await widget.onChanged();
  }

  Future<void> _revoke(List<WmSetting> targets) async {
    if (targets.isEmpty || _busy) return;
    final l10n = AppLocalizations.of(context);
    final allowed = [
      for (final s in targets)
        if (s.can(WmAction.revoke)) s,
    ];
    final blocked = [
      for (final s in targets)
        if (!s.can(WmAction.revoke)) s,
    ];
    if (allowed.isEmpty) {
      context.appWarning(
        blocked
            .map(
              (s) => l10n.wmBinRevokeBlockedLine(
                s.workshopName,
                s.revokeBlockers.join('; '),
              ),
            )
            .join('\n'),
      );
      return;
    }
    final theme = Theme.of(context);
    final ok = await UtenDialog.show(
      context,
      title: l10n.wmBinRevokeTitle(allowed.length),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final s in allowed) Text(wmBinRevokeLine(l10n, s)),
          const SizedBox(height: UtenSpacing.s8),
          Text(
            l10n.wmBinRevokeHint,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (blocked.isNotEmpty) ...[
            const SizedBox(height: UtenSpacing.s8),
            for (final s in blocked)
              Text(
                l10n.wmBinRevokeBlockedLine(
                  s.workshopName,
                  s.revokeBlockers.join('; '),
                ),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
          ],
        ],
      ),
      confirmLabel: l10n.wmBinRevokeConfirm,
      danger: true,
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    final items = [for (final s in allowed) WmBinItem.of(s)];
    try {
      final saved = await _repo.batchDisable(
        items: items,
        idempotencyKey: wmIdempotencyKey('bin-revoke', _nonce, {
          'items': [for (final i in items) i.toJson()],
        }),
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _selected = {};
      });
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      context.appSuccess(l10n.wmBinRevokeDone(saved.length));
      await widget.onChanged();
    } on ApiException catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        context.appWarning(e.message);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _busy = false);
        context.appWarning(l10n.wmBinNetworkRetry);
      }
    }
  }

  void _openRow(WmSetting setting) {
    if (widget.loading || _busy) return;
    if (setting.opened && widget.canViewStock) {
      widget.onOpen(setting);
    } else if (!setting.opened && setting.can(WmAction.open)) {
      _openPanel([setting], WmBinPanelMode.open);
    }
  }

  bool _canOpenRow(WmSetting setting) =>
      (setting.opened && widget.canViewStock) ||
      (!setting.opened && setting.can(WmAction.open));

  List<UtenContextMenuEntry> _rowMenu(
    AppLocalizations l10n,
    WmSetting setting,
  ) => [
    if (setting.opened && widget.canViewStock)
      UtenMenuItem(
        label: l10n.wmBinMenuViewStock,
        icon: Icons.inventory_2_outlined,
        onTap: () => widget.onOpen(setting),
      ),
    if (setting.can(WmAction.open))
      UtenMenuItem(
        label: l10n.wmBinMenuOpen,
        icon: Icons.add_business_outlined,
        onTap: () => _openPanel([setting], WmBinPanelMode.open),
      ),
    if (setting.can(WmAction.enablePeriodic))
      UtenMenuItem(
        label: l10n.wmEnable,
        icon: Icons.inventory_outlined,
        onTap: () => _openPanel([setting], WmBinPanelMode.periodic),
      ),
    if (setting.can(WmAction.changeSource))
      UtenMenuItem(
        label: l10n.wmBinMenuChangeSource,
        icon: Icons.warehouse_outlined,
        onTap: () => _openPanel([setting], WmBinPanelMode.source),
      ),
    if (widget.canSetup && setting.status != WmBinStatus.notOpen)
      UtenMenuItem(
        label: l10n.wmBinMenuRevoke,
        icon: Icons.undo_rounded,
        destructive: true,
        enabled: setting.can(WmAction.revoke),
        onTap: () => _revoke([setting]),
      ),
  ];

  List<Widget> _batchActions(
    AppLocalizations l10n,
    BuildContext context,
    Set<String> selectedIds,
  ) {
    final toOpen = _applicable(WmAction.open);
    final toPeriodic = _applicable(WmAction.enablePeriodic);
    final toRevoke = _revocable;
    return [
      UtenButton(
        key: const Key('wm-overview-batch-open'),
        size: UtenButtonSize.large,
        icon: Icons.add_business_outlined,
        onPressed: toOpen.isEmpty || _busy
            ? null
            : () => _openPanel(toOpen, WmBinPanelMode.open),
        child: Text(l10n.wmBinOpenAction(toOpen.length)),
      ),
      UtenButton(
        key: const Key('wm-overview-batch-periodic'),
        type: UtenButtonType.success,
        size: UtenButtonSize.large,
        icon: Icons.inventory_outlined,
        onPressed: toPeriodic.isEmpty || _busy
            ? null
            : () => _openPanel(toPeriodic, WmBinPanelMode.periodic),
        child: Text(l10n.wmBinPeriodicAction(toPeriodic.length)),
      ),
      UtenButton(
        key: const Key('wm-overview-batch-revoke'),
        type: UtenButtonType.danger,
        size: UtenButtonSize.large,
        icon: Icons.undo_rounded,
        onPressed: toRevoke.isEmpty || _busy ? null : () => _revoke(toRevoke),
        child: Text(l10n.wmBinRevokeAction(toRevoke.length)),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    int count(String status) =>
        widget.settings.where((s) => s.status == status).length;
    final rows = widget.settings.where((setting) {
      if (_status != _all && setting.status != _status) return false;
      return [
        setting.workshopName,
        setting.binWarehouseName,
        setting.sourceWarehouseName,
      ].whereType<String>().join(' ').toLowerCase().contains(_keyword);
    }).toList();
    return Stack(
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            UtenFilterToolbar<String>(
              segmentsKey: const Key('wm-overview-status'),
              searchKey: const Key('wm-overview-search'),
              segments: [
                UtenFilterSegment(
                  value: _all,
                  label: l10n.wmBinSegmentAll,
                  count: widget.settings.length,
                ),
                UtenFilterSegment(
                  value: WmBinStatus.notOpen,
                  label: l10n.wmBinStatusNotOpen,
                  count: count(WmBinStatus.notOpen),
                ),
                UtenFilterSegment(
                  value: WmBinStatus.open,
                  label: l10n.wmBinStatusOpen,
                  count: count(WmBinStatus.open),
                ),
                UtenFilterSegment(
                  value: WmBinStatus.periodic,
                  label: l10n.wmBinStatusPeriodic,
                  count: count(WmBinStatus.periodic),
                ),
              ],
              selected: {_status},
              onSelectionChanged: (value) => setState(() => _status = value),
              searchHint: l10n.wmBinSearchHint,
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
                  child: Text(l10n.commonRetry),
                ),
              ),
              const SizedBox(height: UtenSpacing.s8),
            ],
            Expanded(
              child: MasterDataTableView<WmSetting>(
                key: const Key('wm-overview-table'),
                tableKey: 'warehouse.workshop-material-overview',
                columns: _columns(l10n),
                items: rows,
                facets: const {},
                nullCounts: const {},
                filters: const {},
                onFilterChanged: (_, _) {},
                rowKeyOf: (s) => s.workshopDepartmentId,
                rowWidgetKeyOf: (s) =>
                    ValueKey('wm-overview-row-${s.workshopDepartmentId}'),
                selectable: widget.canSetup,
                idOf: (s) => s.workshopDepartmentId,
                selectedIds: _selected,
                onSelectedIdsChanged: (next) =>
                    setState(() => _selected = next),
                batchActionsBuilder: widget.canSetup
                    ? (context, ids) => _batchActions(l10n, context, ids)
                    : null,
                onRowTap: _openRow,
                canOpenRow: _canOpenRow,
                rowMenuBuilder: (setting) => _rowMenu(l10n, setting),
                canShowRowMenu: (setting) => _rowMenu(l10n, setting).isNotEmpty,
                toolbarActions: widget.onOpenMachines == null
                    ? null
                    : [
                        TextButton.icon(
                          key: const Key('wm-overview-machines'),
                          onPressed: widget.onOpenMachines,
                          icon: const Icon(
                            Icons.precision_manufacturing_outlined,
                          ),
                          label: Text(l10n.wmBinMachinesAndPrep),
                        ),
                      ],
                isLoading: widget.loading,
                onRetry: widget.onRetry,
                bottomContentPadding: UtenFloatingActionGroup.scrollClearance,
                emptyMessage: widget.settings.isEmpty
                    ? l10n.wmBinEmptyAll
                    : l10n.wmBinEmptyFiltered,
              ),
            ),
          ],
        ),
        if (_busy) UtenBusyOverlay(title: l10n.wmBinRevoking),
      ],
    );
  }

  List<MasterColumnDef<WmSetting>> _columns(AppLocalizations l10n) => [
    MasterColumnDef(
      key: 'status',
      label: l10n.wmBinColStatus,
      width: 72,
      value: (s) => wmBinStatusLabel(l10n, s.status),
      // 三态三色: 未开通灰 / 已开通蓝 / 整批领料中绿。
      cellColor: (context, s) => utenStatusBadgeCellColor(switch (s.status) {
        WmBinStatus.periodic => UtenStatusBadgeType.success,
        WmBinStatus.open => UtenStatusBadgeType.info,
        _ => UtenStatusBadgeType.neutral,
      }),
    ),
    MasterColumnDef(
      key: 'workshop',
      label: l10n.wmBinColWorkshop,
      width: 170,
      value: (s) => s.workshopName,
    ),
    MasterColumnDef(
      key: 'bin',
      label: l10n.wmBinColBin,
      width: 190,
      value: (s) => s.binWarehouseName,
    ),
    MasterColumnDef(
      key: 'source',
      label: l10n.wmBinColSource,
      width: 170,
      value: (s) =>
          !s.opened ? null : (s.sourceWarehouseName ?? l10n.wmBinSourceDefault),
    ),
    MasterColumnDef(
      key: 'period',
      label: l10n.wmBinColPeriod,
      width: 250,
      value: (s) =>
          s.currentPeriod == null ? null : wmPeriodLabel(s.currentPeriod!),
    ),
  ];
}
