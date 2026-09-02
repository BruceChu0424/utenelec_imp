import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/feedback/uten_reviewer_responsibility_notice.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/idempotency_key.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/paged_result.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/warehouse_iqc_stock_in.dart';
import '../models/warehouse_quality_result.dart';
import '../providers/warehouse_quality_result_count_provider.dart';
import '../repositories/warehouse_quality_result_repository.dart';
import '../widgets/warehouse_quality_slice_table.dart';

/// 品质部检查结果：原「IQC 合格待入库」+「IQC 不合格实物退回」的合并任务中心。
/// 与预计到货任务中心同款表格工作台——列表按收货单聚合作业状态（等待检查结果 /
/// 全部合格待入库 / 部分合格 / 全部不合格需退回 / 已完结），行按状态着色；
/// 可多选批量入库（整批同事务），双击行进入完整详情页办理入库或登记退回。
class WarehouseQualityResultsPage extends ConsumerStatefulWidget {
  const WarehouseQualityResultsPage({super.key});

  @override
  ConsumerState<WarehouseQualityResultsPage> createState() =>
      _WarehouseQualityResultsPageState();
}

class _WarehouseQualityResultsPageState
    extends ConsumerState<WarehouseQualityResultsPage> {
  PagedResult<WarehouseQualityResultTask>? _result;
  bool _loading = false;
  String? _error;
  int _requestVersion = 0;

  // 分类层级：来源类型=大类（上）、作业状态=小类（下）。进页面两行都不选
  //（数据等价于不过滤）；选中来源后状态行才解锁。
  WarehouseIqcStockInReceiptType? _receiptType;
  bool _receiptTypeSelected = false;
  WarehouseQualityWorkStatus? _workStatus;
  bool _workStatusSelected = false;
  String _keyword = '';

  /// 状态分段计数（后端全量口径）；null = 尚未返回，分段显示 '—'。
  Map<WarehouseQualityWorkStatus, int>? _statusCounts;

  /// 表格多选：键为「receiptType:receiptId」，跨页保留。
  Set<String> _selectedIds = {};

  bool get _isSuperAdmin => ref.read(isSuperAdminProvider);

  /// 入库确认：与旧 IQC 待入库详情同口径——查看 + 确认双权限。
  bool get _canConfirmStockIn {
    if (_isSuperAdmin) return true;
    final permissions = ref.read(currentPermissionsProvider);
    return permissions.contains(Perm.warehouseIqcStockInView) &&
        permissions.contains(Perm.warehouseIqcStockInConfirm);
  }

  /// 登记实物退回：V440 拒收案件的仓库退回凭证动作权限。
  bool get _canRecordReturn {
    if (_isSuperAdmin) return true;
    return ref
        .read(currentPermissionsProvider)
        .contains(Perm.procurementIqcRejectionRecordReturn);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load(1));
  }

  void _selectStatus(WarehouseQualityWorkStatus? status) {
    // 状态行是来源（大类）未选时的锁定态；防御性兜底，正常不可点。
    if (!_receiptTypeSelected) return;
    if (_workStatus == status && _workStatusSelected) return;
    setState(() {
      _workStatus = status;
      _workStatusSelected = true;
    });
    _load(1);
  }

  void _selectType(WarehouseIqcStockInReceiptType? type) {
    if (_receiptType == type && _receiptTypeSelected) return;
    setState(() {
      _receiptType = type;
      _receiptTypeSelected = true;
    });
    _load(1);
  }

  void _applyKeyword(String value) {
    final normalized = value.trim();
    if (normalized == _keyword) return;
    setState(() => _keyword = normalized);
    _load(1);
  }

  Future<void> _load(int page) async {
    final version = ++_requestVersion;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final repo = ref.read(warehouseQualityResultRepositoryProvider);
      final result = await repo.list(
        page: page,
        receiptType: _receiptType,
        workStatus: _workStatus,
        keyword: _keyword.isEmpty ? null : _keyword,
      );
      // 状态计数失败不阻断列表（分段按钮降级为 '—'）。
      repo
          .statusCounts(receiptType: _receiptType, keyword: _keyword)
          .then((counts) {
            if (mounted) setState(() => _statusCounts = counts);
          })
          .catchError((_) {});
      if (!mounted || version != _requestVersion) return;
      setState(() {
        _result = result;
        _loading = false;
      });
      ref.invalidate(warehouseQualityResultPendingCountProvider);
      ref.invalidate(warehouseQualityResultTypeCountsProvider);
    } on ApiException catch (error) {
      if (!mounted || version != _requestVersion) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || version != _requestVersion) return;
      setState(() {
        _error = '品质检查结果加载失败，请检查网络后重试';
        _loading = false;
      });
    }
  }

  int? _statusCount(WarehouseQualityWorkStatus status) {
    final counts = _statusCounts;
    if (counts == null) return null;
    return counts[status] ?? 0;
  }

  List<WarehouseQualityResultTask> get _pageTasks =>
      _result?.items ?? const <WarehouseQualityResultTask>[];

  WarehouseQualityResultTask? _taskById(String id) {
    for (final task in _pageTasks) {
      if (_taskId(task) == id) return task;
    }
    return null;
  }

  static String _taskId(WarehouseQualityResultTask task) =>
      '${task.receiptTypeValue}:${task.receiptId}';

  /// 当前选中且仍有待入库切片的任务（批量入库目标）。
  List<WarehouseQualityResultTask> get _selectedStockInTasks => [
    for (final id in _selectedIds)
      if (_taskById(id) case final task?
          when task.pendingSliceCount > 0 &&
              task.workStatus != WarehouseQualityWorkStatus.completed)
        task,
  ];

  /// 多选批量入库：加载所选任务的放行切片，弹统一确认表（可改数量/库位，做部分入库）。
  Future<void> _openBatchStockIn([WarehouseQualityResultTask? single]) async {
    final targets = single == null
        ? _selectedStockInTasks
        : (single.pendingSliceCount > 0
              ? [single]
              : <WarehouseQualityResultTask>[]);
    if (targets.isEmpty) {
      context.appWarning('请先选择有「品质放行待入库」的任务');
      return;
    }
    if (!_canConfirmStockIn) {
      context.appWarning(
        '当前账号没有仓库入库确认权限（需要 IQC 待入库查看 + 确认入库），'
        '请联系管理员在权限管理中授权',
      );
      return;
    }
    final repo = ref.read(warehouseQualityResultRepositoryProvider);
    final List<WarehouseQualityResultDetail> details;
    try {
      // 并行拉取所选任务的放行切片（串行 await 时 N 张单要排 N 个往返，
      // 弹窗要等全部完成才出现）。
      final fetched = await Future.wait(
        targets.map(
          (task) => repo.detail(task.receiptTypeValue, task.receiptId),
        ),
        eagerError: true,
      );
      details = [
        for (final detail in fetched)
          if (detail.canConfirm) detail,
      ];
    } on ApiException catch (error) {
      if (mounted) context.appError(error.message);
      return;
    } catch (_) {
      if (mounted) context.appError('待入库明细加载失败，请稍后重试');
      return;
    }
    if (details.isEmpty) {
      await _load(_result?.page ?? 1);
      if (mounted) {
        context.appWarning('所选任务当前均不可确认（可能已由同事处理完，或已无待入库明细）');
      }
      return;
    }
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => _BatchStockInDialog(details: details),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _selectedIds = {});
    await _load(_result?.page ?? 1);
  }

  /// 双击行 / 右键「查看检查结果」：进入完整详情页（单据信息 + 逐行判定表 +
  /// 就地办理入库 / 退回 / 查看历史），返回后重拉列表。
  Future<void> _openDetail(WarehouseQualityResultTask task) async {
    await context.push(
      RouteName.warehouseQualityResultDetail(
        task.receiptTypeValue,
        task.receiptId,
      ),
    );
    if (!mounted) return;
    await _load(_result?.page ?? 1);
  }

  @override
  Widget build(BuildContext context) {
    final result =
        _result ??
        const PagedResult<WarehouseQualityResultTask>(
          items: [],
          page: 1,
          size: 40,
          total: 0,
          totalPages: 0,
        );
    return Scaffold(
      appBar: UtenAppBar(
        title: '品质部检查结果',
        subtitle: '检查结论 · 待入库与退回一站式办理',
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.warehouse),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: UtenSpacing.s8),
            child: UtenButton(
              key: const Key('warehouse-quality-result-refresh'),
              size: UtenButtonSize.large,
              type: UtenButtonType.tonal,
              icon: Icons.refresh_rounded,
              isLoading: _loading && _result != null,
              onPressed: _loading ? null : () => _load(result.page),
              child: const Text('刷新'),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: UtenContentContainer.wide(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _QualityResultBoundaryBanner(),
                const SizedBox(height: UtenSpacing.s12),
                _buildToolbars(result),
                if (_error != null && result.items.isNotEmpty) ...[
                  const SizedBox(height: UtenSpacing.s8),
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      '刷新失败：$_error',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: UtenSpacing.s12),
                Expanded(
                  child: MasterDataTableView<WarehouseQualityResultTask>(
                    key: const Key('warehouse-quality-result-table'),
                    columns: _columns,
                    items: result.items,
                    facets: const {},
                    nullCounts: const {},
                    filters: const {},
                    onFilterChanged: (_, _) {},
                    selectable: true,
                    idOf: _taskId,
                    rowKeyOf: _taskId,
                    selectedIds: _selectedIds,
                    onSelectedIdsChanged: (next) =>
                        setState(() => _selectedIds = next),
                    batchActionsBuilder: _batchActions,
                    rowColor: (task) =>
                        _statusRowColor(context, task.workStatus),
                    onRowTap: _openDetail,
                    rowMenuBuilder: _rowMenu,
                    isLoading: _loading && _result == null,
                    loadingMore: _loading && _result != null,
                    error: result.items.isEmpty ? _error : null,
                    onRetry: () => _load(result.page),
                    emptyMessage: _emptyMessage,
                    currentPage: result.page,
                    totalPages: result.totalPages,
                    onPageChange: _load,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String get _emptyMessage {
    if (_keyword.isNotEmpty) return '没有匹配“$_keyword”的检查结果任务';
    return switch (_workStatus) {
      WarehouseQualityWorkStatus.waitingInspection => '没有等待检查结果的收货单',
      WarehouseQualityWorkStatus.allPassed => '没有全部合格待入库的任务',
      WarehouseQualityWorkStatus.partialPassed => '没有部分合格的任务',
      WarehouseQualityWorkStatus.returnRequired => '没有待退回的不合格任务',
      WarehouseQualityWorkStatus.completed => '暂无已完结记录',
      _ => '目前没有品质检查结果任务',
    };
  }

  List<Widget> _batchActions(BuildContext context, Set<String> selectedIds) {
    final stockInCount = _selectedStockInTasks.length;
    return [
      UtenButton(
        key: const Key('warehouse-quality-result-batch-stock-in'),
        size: UtenButtonSize.large,
        icon: Icons.move_to_inbox_rounded,
        onPressed: _loading ? null : () => _openBatchStockIn(),
        child: Text(stockInCount > 0 ? '批量入库($stockInCount 单)' : '批量入库'),
      ),
    ];
  }

  List<UtenContextMenuEntry> _rowMenu(WarehouseQualityResultTask task) {
    return [
      UtenMenuItem(
        label: '查看检查结果详情',
        icon: Icons.open_in_new_rounded,
        onTap: () => _openDetail(task),
      ),
      if (task.pendingSliceCount > 0)
        UtenMenuItem(
          label: '本单入库',
          icon: Icons.move_to_inbox_rounded,
          onTap: () => _openBatchStockIn(task),
        ),
      if (task.pendingReturnCount > 0 && _canRecordReturn)
        UtenMenuItem(
          label: '登记实物退回',
          icon: Icons.assignment_return_outlined,
          onTap: () => _openDetail(task),
        ),
    ];
  }

  Widget _buildToolbars(PagedResult<WarehouseQualityResultTask> result) {
    // 父分类徽章 = 该来源未完结任务数（等待+待入库+需退回，后端 type-counts
    // 全量口径，与 hub 卡/工作台角标同源）。
    final typeCounts = ref
        .watch(warehouseQualityResultTypeCountsProvider)
        .valueOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 第一条（大类）：来源类型分段 + 搜索框。进页面不预选（不过滤）。
        // 「全部来源」不挂徽章；各来源段挂未完结计数。
        UtenFilterToolbar<WarehouseIqcStockInReceiptType?>(
          segmentsKey: const Key('warehouse-quality-result-type'),
          searchKey: const Key('warehouse-quality-result-search'),
          segments: [
            const UtenFilterSegment(value: null, label: '全部来源'),
            for (final type in WarehouseIqcStockInReceiptType.values)
              UtenFilterSegment(
                value: type,
                label: type.label,
                count: typeCounts?[type],
              ),
          ],
          selected: _receiptTypeSelected ? {_receiptType} : const {},
          onSelectionChanged: _selectType,
          searchHint: '搜索收货单 / 供应商 / 仓库 / 货品',
          initialSearchValue: _keyword,
          onSearchInputChanged: (_) => _requestVersion++,
          onSearchChanged: _applyKeyword,
          trailing: Semantics(
            liveRegion: true,
            label: '共 ${result.total} 项品质检查结果任务',
            child: Text(
              '共 ${result.total} 项 · 单击勾选，双击详情',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
        const SizedBox(height: UtenSpacing.s8),
        // 第二条（小类）：作业状态分段（每个状态一种颜色口径，计数为后端全量），
        // 选中来源后解锁；进页面不预选。
        // 徽章口径：只挂在需要仓库下一步操作的分段——「等待结果」由品质部
        // 推进但仓库需预判工作量，保留数量；「全部」「已完结」不挂徽章。
        UtenFilterToolbar<WarehouseQualityWorkStatus?>(
          segmentsKey: const Key('warehouse-quality-result-status'),
          enabled: _receiptTypeSelected,
          segments: [
            const UtenFilterSegment(value: null, label: '全部'),
            for (final status in WarehouseQualityWorkStatus.values)
              UtenFilterSegment(
                value: status,
                label: status.shortLabel,
                count: status.isCompleted ? null : _statusCount(status),
              ),
          ],
          selected: _workStatusSelected ? {_workStatus} : const {},
          onSelectionChanged: _selectStatus,
        ),
      ],
    );
  }

  List<MasterColumnDef<WarehouseQualityResultTask>> get _columns => [
    MasterColumnDef(
      key: 'workStatus',
      label: '作业状态',
      width: 190,
      value: (task) => task.workStatus.label,
    ),
    MasterColumnDef(
      key: 'receiptType',
      label: '来源类型',
      width: 100,
      value: (task) => task.receiptType.label,
    ),
    MasterColumnDef(
      key: 'billNo',
      label: '收货单号',
      width: 160,
      value: (task) => task.billNo ?? '—',
    ),
    MasterColumnDef(
      key: 'billDate',
      label: '收货日期',
      width: 110,
      type: 'date',
      value: (task) => task.billDate ?? '—',
    ),
    MasterColumnDef(
      key: 'supplierName',
      label: '供应商 / 委外商',
      width: 180,
      value: (task) => task.supplierName ?? '—',
    ),
    MasterColumnDef(
      key: 'warehouseName',
      label: '目标仓库',
      width: 130,
      value: (task) => task.warehouseName ?? '—',
    ),
    MasterColumnDef(
      key: 'verdict',
      label: '品质结论',
      width: 200,
      value: (task) => task.verdictLabel,
    ),
    MasterColumnDef(
      key: 'pendingSliceCount',
      label: '待入库批次',
      width: 110,
      type: 'number',
      value: (task) =>
          task.pendingSliceCount > 0 ? '${task.pendingSliceCount} 个' : '—',
    ),
    MasterColumnDef(
      key: 'pendingReturnCount',
      label: '待退回',
      width: 90,
      type: 'number',
      value: (task) =>
          task.pendingReturnCount > 0 ? '${task.pendingReturnCount} 笔' : '—',
    ),
    MasterColumnDef(
      key: 'lastActivityAt',
      label: '最近动态',
      width: 150,
      value: (task) => warehouseQualityDateTime(task.lastActivityAt),
    ),
  ];
}

/// 作业状态 → 整行填充色（状态不能只靠颜色：列文案始终同时在场）。
Color? _statusRowColor(
  BuildContext context,
  WarehouseQualityWorkStatus status,
) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return switch (status) {
    WarehouseQualityWorkStatus.waitingInspection =>
      dark ? Colors.lightBlue.withValues(alpha: 0.14) : const Color(0xFFE8F4FD),
    WarehouseQualityWorkStatus.allPassed =>
      dark ? UtenColors.success.withValues(alpha: 0.16) : UtenColors.successBg,
    WarehouseQualityWorkStatus.partialPassed =>
      dark ? UtenColors.warning.withValues(alpha: 0.16) : UtenColors.warningBg,
    WarehouseQualityWorkStatus.returnRequired =>
      dark ? UtenColors.error.withValues(alpha: 0.14) : UtenColors.errorBg,
    WarehouseQualityWorkStatus.completed =>
      dark ? Colors.grey.withValues(alpha: 0.12) : UtenColors.slate100,
  };
}

class _QualityResultBoundaryBanner extends StatelessWidget {
  const _QualityResultBoundaryBanner();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      container: true,
      label: '品质合格只形成待入库任务，仓库确认后才增加可用库存。',
      child: Container(
        key: const Key('warehouse-quality-result-boundary'),
        padding: const EdgeInsets.all(UtenSpacing.s12),
        decoration: BoxDecoration(
          color: theme.colorScheme.primaryContainer.withValues(alpha: 0.45),
          borderRadius: UtenRadius.lgAll,
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Text(
          '品质部检查结果 · 按收货单跟踪 等待检查结果 → 全部合格/部分合格（待入库）→ '
          '全部不合格（需退回）→ 已完结。合格品由仓库核对实物数量与实际库位后确认入库；'
          '不合格品登记真实退回凭证。本页不显示单价、金额、币种或结算信息。',
          style: theme.textTheme.bodySmall?.copyWith(height: 1.45),
        ),
      ),
    );
  }
}

// ———————————————————————— 批量入库弹窗 ————————————————————————

/// 跨收货单批量入库：所有选中任务的放行切片集中成一张表，可勾选、可改数量
/// （默认全额 =「批量全部入库」，改小即「批量部分入库」）；整批同事务提交。
class _BatchStockInDialog extends ConsumerStatefulWidget {
  const _BatchStockInDialog({required this.details});

  final List<WarehouseQualityResultDetail> details;

  @override
  ConsumerState<_BatchStockInDialog> createState() =>
      _BatchStockInDialogState();
}

class _BatchStockInDialogState extends ConsumerState<_BatchStockInDialog> {
  late final List<WarehouseQualitySliceDraft> _drafts;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _drafts = [
      for (final detail in widget.details)
        for (final slice in detail.items)
          WarehouseQualitySliceDraft(
            slice,
            receiptTypeValue: detail.receiptType.apiValue,
            receiptId: detail.receiptId,
            receiptNo: detail.billNo,
          ),
    ];
  }

  @override
  void dispose() {
    for (final draft in _drafts) {
      draft.dispose();
    }
    super.dispose();
  }

  List<WarehouseQualitySliceDraft> get _selected =>
      _drafts.where((draft) => draft.selected).toList();

  Future<void> _submit() async {
    if (_saving) return;
    final selected = _selected;
    if (selected.isEmpty) {
      setState(() => _error = '请至少勾选一条待入库明细');
      return;
    }
    for (final draft in selected) {
      final error = draft.validate();
      if (error != null) {
        setState(() => _error = error);
        return;
      }
    }
    // 按收货单分组成批量命令；每张单独立幂等键（服务端按 用户+键 去重）。
    final byReceipt = <String, List<WarehouseQualitySliceDraft>>{};
    for (final draft in selected) {
      byReceipt.putIfAbsent(draft.receiptKey, () => []).add(draft);
    }
    final entries = <WarehouseQualityBatchConfirmEntry>[];
    for (final mapEntry in byReceipt.entries) {
      final group = mapEntry.value;
      final items = [
        for (final draft in group)
          WarehouseIqcStockInConfirmItem(
            passEventId: draft.slice.passEventId,
            baseQty: double.parse(draft.quantity.text.trim()),
            expectedRemainingBaseQty: draft.slice.remainingBaseQty,
            place: draft.place.text.trim(),
          ),
      ];
      entries.add(
        WarehouseQualityBatchConfirmEntry(
          receiptType: group.first.receiptTypeValue!,
          receiptId: group.first.receiptId!,
          idempotencyKey: businessIdempotencyKey(
            'warehouse-iqc-stock-in',
            '${mapEntry.key}|${warehouseQualitySliceFingerprint(items)}',
          ),
          items: items,
        ),
      );
    }
    final approved = await showUtenReviewerConfirmDialog(
      context,
      title: '批量确认 IQC 合格品入库',
      actionLabel: '仓库批量入库确认',
      confirmLabel: '确认批量入库',
      message:
          '将按 ${entries.length} 张收货单 / ${selected.length} 条放行切片确认实收数量'
          '与实际库位；整批同事务提交，任一单冲突时全部回滚。',
    );
    if (!approved || !mounted) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final result = await ref
          .read(warehouseQualityResultRepositoryProvider)
          .batchConfirm(WarehouseQualityBatchConfirmCommand(batches: entries));
      if (!mounted) return;
      context.appSuccess(
        '已批量入库 ${result.confirmedReceipts} 张收货单 / '
        '${result.confirmedItemCount} 条明细',
      );
      Navigator.of(context).pop(true);
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(
        () => _error = error.code == 'CONFLICT'
            ? '${error.message}（整批已回滚，未产生任何入库；请刷新后重新核对）'
            : error.message,
      );
    } catch (_) {
      if (mounted) {
        setState(() => _error = '批量入库失败，请稍后重试');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text('批量入库 · ${widget.details.length} 张收货单'),
      content: SizedBox(
        width: 980,
        height: 560,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '默认勾选全部待入库明细并按剩余量全额入库（批量全部入库）；'
              '可取消勾选或改小数量做批量部分入库。实际库位必填，已按货品建议库位预填。',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: UtenSpacing.s8),
            Expanded(
              child: SingleChildScrollView(
                child: WarehouseQualitySliceTable(
                  drafts: _drafts,
                  editable: true,
                  saving: _saving,
                  onChanged: () => setState(() {}),
                  showReceipt: true,
                ),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: UtenSpacing.s8),
              _MessagePanel(
                message: _error!,
                icon: Icons.error_outline_rounded,
              ),
            ],
          ],
        ),
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        UtenButton(
          key: const Key('warehouse-quality-batch-confirm'),
          size: UtenButtonSize.large,
          icon: Icons.move_to_inbox_rounded,
          isLoading: _saving,
          onPressed: _saving ? null : _submit,
          child: Text('确认批量入库(${_selected.length} 条)'),
        ),
      ],
    );
  }
}

// ———————————————————————— 通用小组件 ————————————————————————

class _MessagePanel extends StatelessWidget {
  const _MessagePanel({required this.message, required this.icon});

  final String message;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        decoration: BoxDecoration(
          color: theme.colorScheme.errorContainer.withValues(alpha: 0.45),
          borderRadius: UtenRadius.mdAll,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20, color: theme.colorScheme.error),
            const SizedBox(width: UtenSpacing.s8),
            Expanded(child: Text(message)),
          ],
        ),
      ),
    );
  }
}
