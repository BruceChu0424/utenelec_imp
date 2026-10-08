// 委外出仓工作台(可嵌入; ADR-143 §4.3)：一行 = 委外人员在委外任务中心提交、
// 仓库还没发出的一张委外领料单(按调用者仓库范围)。仓库核对实际仓与库位后审核
// 出仓; 数量只能改少不能改多。仓库视角只有数量/重量/库位/委外商名，无价格金额。
//
// 「出库任务中心 · 委外出库」分段内嵌本组件(embedded=true 时不带搜索框——
// 关键字由任务中心页级工具条统一下发)；独立路由 /warehouse/subcontract-outbound
// 由对应页面以 embedded=false 包一层继续承接。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/l10n/gen/app_localizations_zh.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/paged_result.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/subcontract_outbound.dart';
import '../pages/warehouse_subcontract_outbound_batch_page.dart';
import '../repositories/warehouse_subcontract_outbound_repository.dart';
import '../navigation/warehouse_subcontract_outbound_navigation.dart';
import '../../../shared/badges/badge_registry.dart';
import '../../../shared/warehouse/warehouse_task_scope.dart';

class WarehouseSubcontractOutboundWorkbench extends ConsumerStatefulWidget {
  const WarehouseSubcontractOutboundWorkbench({
    super.key,
    this.keyword = '',
    this.refreshTick = 0,
    this.embedded = false,
    this.externalHeader,
    this.showHintBanner = true,
  });

  /// 任务中心页级搜索关键字（embedded 模式生效）。
  final String keyword;

  /// 父页面「返回即刷新」信号。
  final int refreshTick;

  /// true = 嵌在出库任务中心分段内（表格，无搜索框）。
  final bool embedded;

  /// 宿主（任务中心大类行 + 小类行/复合分段行）：挂进折叠头随页滚走
  /// （2026-09-24 用户口径「表格完全置顶」）。
  final Widget? externalHeader;

  /// 是否显示业务口径提示条。
  final bool showHintBanner;

  @override
  ConsumerState<WarehouseSubcontractOutboundWorkbench> createState() =>
      _WarehouseSubcontractOutboundWorkbenchState();
}

class _WarehouseSubcontractOutboundWorkbenchState
    extends ConsumerState<WarehouseSubcontractOutboundWorkbench> {
  PagedResult<OutboundTask>? _result;
  bool _loading = false;
  String? _error;
  int _requestVersion = 0;
  String _keyword = '';

  final _tableRows = MasterDataTableRowsController<OutboundTask>();
  Set<String> _selectedIds = {};
  bool _openingBatch = false;

  bool get _canExecute {
    final permissions = ref.read(currentPermissionsProvider);
    return [
      Perm.subcontractOutboundView,
      Perm.subcontractOutboundExecute,
      Perm.subcontractMaterialIssueView,
      Perm.subcontractMaterialIssueEdit,
      Perm.subcontractMaterialIssueApprove,
    ].every(permissions.contains);
  }

  @override
  void initState() {
    super.initState();
    _keyword = widget.keyword;
    WidgetsBinding.instance.addPostFrameCallback((_) => _load(1));
  }

  @override
  void didUpdateWidget(WarehouseSubcontractOutboundWorkbench oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.keyword != widget.keyword ||
        oldWidget.refreshTick != widget.refreshTick) {
      _keyword = widget.keyword;
      WidgetsBinding.instance.addPostFrameCallback((_) => _load(1));
    }
  }

  void _applySearch(String value) {
    if (value == _keyword) return;
    setState(() => _keyword = value);
    _load(1);
  }

  Future<void> _load(int page) async {
    final version = ++_requestVersion;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final repo = ref.read(warehouseSubcontractOutboundRepositoryProvider);
      final result = await repo.tasks(
        page: page,
        keyword: _keyword,
        scope: WarehouseListScope.of(context),
      );
      if (!mounted || version != _requestVersion) return;
      setState(() {
        _result = result;
        _loading = false;
      });
      // Reconcile after the table has combined any appended pages.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || version != _requestVersion) return;
        final visibleIds = _tableRows.items.map((item) => item.issueId).toSet();
        if (_selectedIds.any((id) => !visibleIds.contains(id))) {
          setState(() => _selectedIds = _selectedIds.intersection(visibleIds));
        }
      });
      refreshBadges(ref);
    } on ApiException catch (error) {
      if (!mounted || version != _requestVersion) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || version != _requestVersion) return;
      setState(() {
        _error = '委外领料单加载失败，请检查网络后重试';
        _loading = false;
      });
    }
  }

  Future<void> _openTask(OutboundTask task) async {
    if (_loading || _openingBatch) return;
    // 保存返回时补刷列表；出仓成功会定位任务中心，由父页刷新。
    final version = _requestVersion;
    await context.push<bool>(
      RouteName.warehouseSubcontractOutboundDetail(task.issueId),
    );
    await WidgetsBinding.instance.endOfFrame;
    if (mounted && _requestVersion == version) {
      await _load(_result?.page ?? 1);
    }
  }

  Future<void> _openBatch(Set<String> ids) async {
    if (_loading || _openingBatch || !_canExecute || ids.isEmpty) return;
    final l10n =
        Localizations.of<AppLocalizations>(context, AppLocalizations) ??
        AppLocalizationsZh();
    if (ids.length > 50) {
      context.appWarning(l10n.warehouseSubcontractOutboundSelectionLimit);
      return;
    }
    setState(() => _openingBatch = true);
    final version = _requestVersion;
    try {
      final completed = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (batchContext) => WarehouseSubcontractOutboundBatchPage(
            issueIds: ids.toList(),
            onCompleted: () => Navigator.of(batchContext).pop(true),
          ),
        ),
      );
      if (mounted) {
        setState(() => _selectedIds = {});
        if (completed == true && !widget.embedded) {
          returnToSubcontractOutboundTasks(context);
        } else {
          await WidgetsBinding.instance.endOfFrame;
          if (mounted && _requestVersion == version) {
            await _load(_result?.page ?? 1);
          }
        }
      }
    } finally {
      if (mounted) setState(() => _openingBatch = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(currentPermissionsProvider);
    final l10n =
        Localizations.of<AppLocalizations>(context, AppLocalizations) ??
        AppLocalizationsZh();
    final result =
        _result ??
        const PagedResult<OutboundTask>(
          items: [],
          page: 1,
          size: 20,
          total: 0,
          totalPages: 1,
        );
    // 2026-09-24 用户口径「表格完全置顶」：搜索/提示横幅/错误行全部进折叠头
    // 随页滚走，body 只剩表格（primary 拾取联动控制器）。
    return UtenCollapsingHeaderScrollView(
      collapsingHeader: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.externalHeader != null) ...[
            widget.externalHeader!,
            const SizedBox(height: UtenSpacing.s12),
          ],
          if (!widget.embedded) ...[
            _buildStandaloneSearch(result),
            const SizedBox(height: UtenSpacing.s8),
          ],
          if (widget.showHintBanner) const _OutboundHintBanner(),
          if (!widget.embedded) const SizedBox(height: UtenSpacing.s12),
          if (_error != null && result.items.isNotEmpty) ...[
            const SizedBox(height: UtenSpacing.s12),
            Semantics(
              liveRegion: true,
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          ],
          const SizedBox(height: UtenSpacing.s12),
        ],
      ),
      body: MasterDataTableView<OutboundTask>(
        rowsController: _tableRows,
        paginationRevision: _result,
        paginationScope: (_keyword, WarehouseListScope.of(context)),
        tableKey:
            'features.warehouse.widgets.warehouse_subcontract_outbound_workbench.WarehouseSubcontractOutboundWorkbenchState.build.1',
        // primary:true → 表体拾取联动容器注入的 PrimaryScrollController。
        primary: true,
        key: const Key('subcontract-outbound-task-table'),
        columns: _columns,
        items: result.items,
        // 列表只有一种状态(待发料); 委外商/订货单号走关键字搜索。
        facets: const {},
        nullCounts: const {},
        filters: const {},
        onFilterChanged: (_, _) {},
        onRowTap: _openTask,
        selectable: _canExecute,
        idOf: (task) => task.issueId,
        rowKeyOf: (task) => task.issueId,
        selectedIds: _selectedIds,
        onSelectedIdsChanged: (ids) {
          if (!_loading && !_openingBatch) {
            setState(() => _selectedIds = ids);
          }
        },
        preserveSelectionOnContextMenu: true,
        batchActionsBuilder: !_canExecute
            ? null
            : (context, ids) => [
                UtenButton(
                  key: const Key('subcontract-outbound-batch-action'),
                  type: UtenButtonType.danger,
                  size: UtenButtonSize.large,
                  icon: Icons.outbound_outlined,
                  isLoading: _openingBatch,
                  onPressed: ids.isEmpty || _loading || _openingBatch
                      ? null
                      : () => _openBatch(ids),
                  child: Text(
                    '${l10n.warehouseSubcontractOutboundBatchAction} (${ids.length})',
                  ),
                ),
              ],
        rowMenuBuilder: (item) => [
          UtenMenuItem(
            label: l10n.warehouseSubcontractOutboundOpenPicking,
            icon: Icons.outbound_outlined,
            onTap: () => _openTask(item),
          ),
        ],
        isLoading: _loading,
        loadingMore: _loading && _result != null,
        error: result.items.isEmpty ? _error : null,
        onRetry: () => _load(result.page),
        emptyMessage: _keyword.isNotEmpty
            ? '没有匹配「$_keyword」的委外领料单'
            : '目前没有待发料的委外领料单',
        currentPage: result.page,
        totalPages: result.totalPages,
        onPageChange: _load,
      ),
    );
  }

  Widget _buildStandaloneSearch(PagedResult<OutboundTask> result) {
    final search = UtenSearchBar(
      key: const Key('subcontract-outbound-search'),
      hint: '搜索领料单号 / 委外订货单号 / 委外商',
      initialValue: _keyword,
      onInputChanged: (_) => _requestVersion++,
      onChanged: _applySearch,
    );
    final summary = Text(
      '共 ${result.total} 项 · 单击选中，双击详情',
      key: const Key('subcontract-outbound-table-summary'),
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 720) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              search,
              const SizedBox(height: UtenSpacing.s8),
              Align(alignment: Alignment.centerRight, child: summary),
            ],
          );
        }
        return Row(
          children: [
            // 2026-10-07 用户口径：搜索栏宽度减半（与 UtenFilterToolbar 180 对齐）。
            SizedBox(width: 180, child: search),
            const Spacer(),
            summary,
          ],
        );
      },
    );
  }

  List<MasterColumnDef<OutboundTask>> get _columns => [
    MasterColumnDef(
      key: 'issueBillNo',
      label: '领料单号',
      width: 180,
      value: (item) => item.issueBillNo ?? '—',
    ),
    MasterColumnDef(
      key: 'orderBillNo',
      label: '委外订货单',
      width: 180,
      value: (item) => item.orderBillNo ?? '—',
    ),
    MasterColumnDef(
      key: 'supplierName',
      label: '委外商',
      width: 200,
      value: (item) => item.supplierName ?? '—',
    ),
    MasterColumnDef(
      key: 'warehouseName',
      label: '领料仓',
      width: 150,
      value: (item) => item.warehouseName ?? '—',
    ),
    MasterColumnDef(
      key: 'materialKindCount',
      label: '物料种数',
      width: 100,
      type: 'number',
      value: (item) => item.materialKindCount.toString(),
    ),
    MasterColumnDef(
      key: 'lineCount',
      label: '明细行数',
      width: 100,
      type: 'number',
      value: (item) => item.lineCount.toString(),
    ),
    MasterColumnDef(
      key: 'submittedAt',
      label: '提交时间',
      width: 170,
      value: (item) =>
          ChinaDateTime.formatIsoInstant(item.submittedAt, fallback: '—'),
    ),
    MasterColumnDef(
      key: 'submittedByName',
      label: '提交人',
      width: 120,
      value: (item) => item.submittedByName ?? '—',
    ),
  ];
}

class _OutboundHintBanner extends StatelessWidget {
  const _OutboundHintBanner();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s12,
        vertical: UtenSpacing.s8,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(UtenRadius.md),
      ),
      child: Text(
        '这里只列委外人员已提交、仓库还没发出的委外领料单(一张单 = 一个委外订货单在一个仓要发的直属物料)。'
        '核对实际仓与库位后审核出仓；数量只能改少不能改多，少发的部分委外下次领料时系统会自动补齐。'
        '委外商加工后交回的是委外件，回厂时按委外件登记。',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
