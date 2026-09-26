// 委外出仓工作台（可嵌入）：财务批准委外订货后，服务端逐行判断准备路线——
// 无子层级核对并预留目标件合格库存；有子层级完成完整前置自制、FQC 与仓库实收
// 入仓。只有已备齐并释放的目标件才出现在本列表。仓库视角只有数量/重量/库位/
// 委外商名，无价格金额。
//
// 2026-09-01 起「出库任务中心 · 委外出库」分段内嵌本组件（embedded=true 时不带
// 搜索框——关键字由任务中心页级工具条统一下发）；独立路由
// /warehouse/subcontract-outbound 由对应页面以 embedded=false 包一层继续承接。
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
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../../basic_data/models/master_facet.dart';
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

  /// 表头列筛选（2026-09-16）：委外商（dict 桶，value=UUID）+ 任务状态（派生固定枚举）。
  String? _supplierIdFilter;
  String? _statusFilter;
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

  // 无草稿且服务端明说可发 0(等子件到货)的行不给勾: 勾了进批量页也只会撞 409。
  bool _selectable(OutboundTask task) => task.selectable;

  @override
  void initState() {
    super.initState();
    _keyword = widget.keyword;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // dict 装载完成后补一次 setState：内部缓存变化不触发 provider 通知。
      ref
          .read(masterNameServiceProvider)
          .ensureLoaded()
          .then((_) => mounted ? setState(() {}) : null);
      _load(1);
    });
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
        supplierId: _supplierIdFilter,
        status: _statusFilter,
        scope: WarehouseListScope.of(context),
      );
      if (!mounted || version != _requestVersion) return;
      setState(() {
        _result = result;
        _loading = false;
        final availableIds = result.items
            .where(_selectable)
            .map((item) => item.planId)
            .toSet();
        _selectedIds = _selectedIds.intersection(availableIds);
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
        _error = '委外出仓任务加载失败，请检查网络后重试';
        _loading = false;
      });
    }
  }

  Future<void> _openTask(OutboundTask task) async {
    if (_loading || _openingBatch) return;
    // 保存返回时补刷列表；出仓成功会定位任务中心，由父页刷新。
    final version = _requestVersion;
    await context.push<bool>('/warehouse/subcontract-outbound/${task.planId}');
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
            planIds: ids.toList(),
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
          if (widget.showHintBanner) _OutboundHintBanner(l10n: l10n),
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
        // primary:true → 表体拾取联动容器注入的 PrimaryScrollController。
        primary: true,
        key: const Key('subcontract-outbound-task-table'),
        columns: _columns,
        items: result.items,
        // 表头筛选桶（2026-09-16）：委外商走主档 dict；任务状态为派生三档
        // （有草稿=待拣货 / 无草稿有可发=已备齐待出仓 / 无草稿可发 0=等子件到货），
        // 与服务端 tasks() 的状态桶及行 stage 同口径(ADR-103 §2.4)。
        facets: {
          'supplierName': masterDictionaryFacets(
            ref.watch(masterNameServiceProvider).supplierEntries,
          ),
          'status': [
            MasterFacetBucket(
              value: 'DRAFT_PICKING',
              count: 0,
              label: l10n.warehouseSubcontractOutboundStageDraftPicking,
            ),
            MasterFacetBucket(
              value: 'READY_OUTBOUND',
              count: 0,
              label: l10n.warehouseSubcontractOutboundStageReadyPlain,
            ),
            MasterFacetBucket(
              value: 'WAITING_COMPONENT',
              count: 0,
              label: l10n.warehouseSubcontractOutboundWaitingComponent,
            ),
          ],
        },
        nullCounts: const {},
        filters: {'supplierName': _supplierIdFilter, 'status': _statusFilter},
        onFilterChanged: (key, value) {
          setState(() {
            if (key == 'supplierName') {
              _supplierIdFilter = value;
            } else if (key == 'status') {
              _statusFilter = value;
            }
          });
          _load(1);
        },
        onRowTap: _openTask,
        selectable: _canExecute,
        idOf: (task) => _selectable(task) ? task.planId : null,
        rowKeyOf: (task) => task.planId,
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
            ? '没有匹配「$_keyword」的出仓任务'
            : '目前没有待出仓任务',
        currentPage: result.page,
        totalPages: result.totalPages,
        onPageChange: _load,
      ),
    );
  }

  Widget _buildStandaloneSearch(PagedResult<OutboundTask> result) {
    final search = UtenSearchBar(
      key: const Key('subcontract-outbound-search'),
      hint: '搜索委外订货单号 / 委外商',
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
            SizedBox(width: 360, child: search),
            const Spacer(),
            summary,
          ],
        );
      },
    );
  }

  /// 行阶段 → 文案。「已备齐」带可发合计: 单一子件分批到货时仓库一眼看到这次能发多少。
  String _stageLabel(AppLocalizations l10n, OutboundTask item) =>
      switch (item.stage) {
        OutboundTaskStage.draftPicking =>
          l10n.warehouseSubcontractOutboundStageDraftPicking,
        OutboundTaskStage.readyOutbound =>
          item.issuableTotal == null
              ? l10n.warehouseSubcontractOutboundStageReadyPlain
              : l10n.warehouseSubcontractOutboundStageReady(
                  _quantity(item.issuableTotal!),
                ),
        OutboundTaskStage.waitingComponent =>
          l10n.warehouseSubcontractOutboundWaitingComponent,
        OutboundTaskStage.blockedPreparation =>
          l10n.warehouseSubcontractOutboundStageBlockedPreparation,
        OutboundTaskStage.waitingPreparation =>
          l10n.warehouseSubcontractOutboundStageWaitingPreparation,
        OutboundTaskStage.pendingDraft =>
          l10n.warehouseSubcontractOutboundStagePendingDraft,
      };

  static String _quantity(double value) => value == value.roundToDouble()
      ? value.toStringAsFixed(0)
      : value.toString();

  List<MasterColumnDef<OutboundTask>> get _columns => [
    MasterColumnDef(
      key: 'status',
      label: '任务状态',
      width: 170,
      value: (item) => _stageLabel(
        Localizations.of<AppLocalizations>(context, AppLocalizations) ??
            AppLocalizationsZh(),
        item,
      ),
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
      key: 'deliverDate',
      label: '交货日期',
      width: 120,
      type: 'date',
      value: (item) => item.deliverDate ?? '—',
    ),
    MasterColumnDef(
      key: 'lineCount',
      label: '目标件行数',
      width: 100,
      type: 'number',
      value: (item) => item.lineCount.toString(),
    ),
    MasterColumnDef(
      key: 'draftBillNo',
      label: '出仓草稿单',
      width: 180,
      value: (item) => item.draftBillNo ?? '—',
    ),
  ];
}

class _OutboundHintBanner extends StatelessWidget {
  const _OutboundHintBanner({required this.l10n});

  final AppLocalizations l10n;

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
        '仓库只看到已经备齐并由服务端放行的委外目标件。无子层级时先预留合格库存；'
        '有子层级时必须完成物料分析、领料、自制报工、FQC 和成品入仓后才会出现在这里。'
        '历史 BOM 子件发料单仍按原单据只读兼容。'
        '${l10n.warehouseSubcontractOutboundBannerComponent}',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
