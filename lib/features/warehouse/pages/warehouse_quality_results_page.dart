import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_app_bar_action_button.dart';
import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/feedback/uten_segment_badge_label.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../components/layout/uten_history_time_filter.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/paged_result.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/warehouse_iqc_stock_in.dart';
import '../models/warehouse_quality_result.dart';
import '../providers/warehouse_quality_result_count_provider.dart';
import '../repositories/warehouse_quality_result_repository.dart';
import '../widgets/warehouse_quality_slice_table.dart'
    show warehouseQualityDateTime;

/// 品质部检查结果：原「IQC 合格待入库」+「IQC 不合格实物退回」的合并任务中心。
/// 与预计到货任务中心同款表格工作台——列表按收货单聚合作业状态（等待检查结果 /
/// 全部合格待入库 / 部分合格 / 全部不合格需退回 / 已完结），行按状态着色；
/// 可多选批量入库（整批同事务），双击行进入完整详情页办理入库或登记退回。
///
/// 2026-09-03 分类范式收口：来源大类行不再有「全部来源」段，状态小类行不再有
/// 「全部」段；两行默认都不选（不加载，引导占位），末尾新增「历史记录」段
///（时间段/全部时间门控，未选时间不请求）。
class WarehouseQualityResultsPage extends ConsumerStatefulWidget {
  const WarehouseQualityResultsPage({super.key});

  @override
  ConsumerState<WarehouseQualityResultsPage> createState() =>
      _WarehouseQualityResultsPageState();
}

/// 状态小类分段值：真实作业状态或历史记录哨兵。
class _QStatusSeg {
  const _QStatusSeg.stage(WarehouseQualityWorkStatus this.status)
    : history = false;
  const _QStatusSeg.history() : status = null, history = true;

  final WarehouseQualityWorkStatus? status;
  final bool history;

  @override
  bool operator ==(Object other) =>
      other is _QStatusSeg &&
      other.status == status &&
      other.history == history;

  @override
  int get hashCode => Object.hash(status, history);
}

class _WarehouseQualityResultsPageState
    extends ConsumerState<WarehouseQualityResultsPage> {
  PagedResult<WarehouseQualityResultTask>? _result;
  bool _loading = false;
  String? _error;
  int _requestVersion = 0;
  int _statusCountRequestVersion = 0;

  // 分类层级：来源类型=大类（上）、作业状态=小类（下）。两行都没有「全部」段，
  // 默认都不选（不加载）；选中来源后状态行才解锁，状态行末尾是历史记录段。
  WarehouseIqcStockInReceiptType? _receiptType;
  _QStatusSeg? _statusSeg;

  /// 历史记录段的时间门控值；none = 尚未选择（历史段下同样不发请求）。
  UtenHistoryTimeValue _historyTime = const UtenHistoryTimeValue.none();
  String _keyword = '';

  /// 状态分段计数（后端全量口径）；null = 尚未返回，分段显示 '—'。
  Map<WarehouseQualityWorkStatus, int>? _statusCounts;

  /// 表格多选：键为「receiptType:receiptId」，跨页保留。
  Set<String> _selectedIds = {};

  bool get _isSuperAdmin => ref.read(isSuperAdminProvider);

  bool get _shouldLoad {
    if (_receiptType == null) return false;
    final seg = _statusSeg;
    if (seg == null) return false;
    if (seg.history && _historyTime.isNone) return false;
    return true;
  }

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
    // 默认不选分类：进页面不发列表请求，等用户选来源+状态（或历史+时间）。
    // 但状态小类徽章与列表加载解耦（与父类 type-counts provider 同口径）：
    // 进页面即拉一次全来源计数，选中来源后重拉——否则徽章要等点中某个小类
    // 才随列表加载出现（ADR-066 双选门控的回归）。
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshStatusCounts());
  }

  /// 状态小类计数（后端全量口径；null = 尚未返回，分段按钮显示 '—'）。
  /// 独立于列表加载：进页面（全来源）/ 切换来源时主动刷新，列表加载时联动刷新。
  void _refreshStatusCounts() {
    final version = ++_statusCountRequestVersion;
    final receiptType = _receiptType;
    final keyword = _keyword;
    ref
        .read(warehouseQualityResultRepositoryProvider)
        .statusCounts(
          receiptType: receiptType,
          keyword: keyword.isEmpty ? null : keyword,
        )
        .then((counts) {
          if (mounted && version == _statusCountRequestVersion) {
            setState(() => _statusCounts = counts);
          }
        })
        .catchError((_) {});
  }

  void _selectStatus(_QStatusSeg seg) {
    // 状态行是来源（大类）未选时的锁定态；防御性兜底，正常不可点。
    if (_receiptType == null) return;
    if (seg == _statusSeg) return;
    setState(() {
      _statusSeg = seg;
      if (!seg.history) _historyTime = const UtenHistoryTimeValue.none();
    });
    if (!seg.history || !_historyTime.isNone) _load(1);
  }

  void _selectType(WarehouseIqcStockInReceiptType type) {
    if (_receiptType == type) return;
    setState(() {
      _receiptType = type;
      _statusSeg = null;
      _historyTime = const UtenHistoryTimeValue.none();
      // 切换来源后旧计数口径失效，清空待新值（避免显示上一来源的数字）。
      _statusCounts = null;
    });
    _refreshStatusCounts();
  }

  void _onHistoryTime(UtenHistoryTimeValue value) {
    if (value == _historyTime) return;
    setState(() => _historyTime = value);
    _load(1);
  }

  void _applyKeyword(String value) {
    final normalized = value.trim();
    if (normalized == _keyword) return;
    setState(() => _keyword = normalized);
    _load(1);
  }

  Future<void> _load(int page) async {
    if (!_shouldLoad) return;
    final version = ++_requestVersion;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final repo = ref.read(warehouseQualityResultRepositoryProvider);
      final seg = _statusSeg!;
      final range = seg.history ? _historyTime.range : null;
      final result = await repo.list(
        page: page,
        receiptType: _receiptType,
        workStatus: seg.history ? null : seg.status,
        keyword: _keyword.isEmpty ? null : _keyword,
        dateFrom: range == null ? null : ChinaDateTime.formatDate(range.start),
        dateTo: range == null ? null : ChinaDateTime.formatDate(range.end),
      );
      // 状态计数失败不阻断列表（分段按钮降级为 '—'）。
      _refreshStatusCounts();
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

  /// 多选批量入库（2026-09-12 弹窗改页）：进批量入库页——所选任务的放行切片
  /// 集中成一张表，可勾选、可改数量/库位，整批同事务提交。
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
    // 只选中一张时不进批量页——那是一张单据，直接进它自己的详情页办理
    // （用户 2026-09-11：「只选中一个的情况，点击批量入库也应该去到对应的详情页」）。
    // 详情页信息全、能逐行核对，批量页是为「跨多张单一次过」才存在的。
    if (targets.length == 1) {
      await _openDetail(targets.single);
      return;
    }
    final done = await context.push<bool>(
      RouteName.warehouseQualityBatchStockIn,
      extra: targets,
    );
    if (!mounted) return;
    if (done == true) {
      setState(() => _selectedIds = {});
      await _load(_result?.page ?? 1);
    }
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
          UtenAppBarActionButton(
            key: const Key('warehouse-quality-result-refresh'),
            label: '刷新',
            icon: Icons.refresh_rounded,
            isLoading: _loading && _result != null,
            onPressed: _loading ? null : () => _load(1),
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
                  child: !_shouldLoad
                      ? (_statusSeg != null && _statusSeg!.history
                            ? const UtenHistoryTimePlaceholder()
                            : const UtenFilterPlaceholder(
                                message: '在上方选择来源和状态后开始办理',
                                description: '来源与状态都默认不选中，选择后才加载对应任务',
                              ))
                      : MasterDataTableView<WarehouseQualityResultTask>(
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
    if (_statusSeg?.history == true) return '该时间段内暂无检查结果记录';
    return switch (_statusSeg?.status) {
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
        type: UtenButtonType.danger,
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
    final seg = _statusSeg;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 第一条（大类）：来源类型分段 + 搜索框。进页面不预选；无「全部来源」段，
        // 各来源段挂未完结计数。
        UtenFilterToolbar<WarehouseIqcStockInReceiptType>(
          segmentsKey: const Key('warehouse-quality-result-type'),
          searchKey: const Key('warehouse-quality-result-search'),
          segments: [
            for (final type in WarehouseIqcStockInReceiptType.values)
              UtenFilterSegment(
                value: type,
                label: type.label,
                count: typeCounts?[type],
                // 来源段计数 = 该来源未完结任务数（仓库待办）→ 红徽章。
                countForm: UtenSegmentCountForm.actionable,
              ),
          ],
          selected: _receiptType == null ? const {} : {_receiptType!},
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
        // 第二条（小类）：作业状态分段（计数为后端全量），选中来源后解锁；
        // 无「全部」段，末尾是「历史记录」段；进页面不预选。
        // 计数形态：红徽章只挂需要仓库下一步操作的状态（全部合格/部分合格/
        // 不合格退回，见 WarehouseQualityWorkStatus.actionable）；「等待结果」
        // 由品质部推进、仓库只是预判工作量 → 中性括号；
        // 「已完结」「历史记录」不传 count。
        UtenFilterToolbar<_QStatusSeg>(
          segmentsKey: const Key('warehouse-quality-result-status'),
          enabled: _receiptType != null,
          segments: [
            for (final status in WarehouseQualityWorkStatus.values)
              UtenFilterSegment(
                value: _QStatusSeg.stage(status),
                label: status.shortLabel,
                count: status.isCompleted ? null : _statusCount(status),
                countForm: status.actionable
                    ? UtenSegmentCountForm.actionable
                    : UtenSegmentCountForm.browsing,
              ),
            const UtenFilterSegment(
              value: _QStatusSeg.history(),
              label: '历史记录',
            ),
          ],
          selected: seg == null ? const {} : {seg},
          onSelectionChanged: _selectStatus,
        ),
        if (seg?.history == true) ...[
          const SizedBox(height: UtenSpacing.s8),
          UtenHistoryTimeFilter(
            key: const Key('warehouse-quality-result-history-time'),
            value: _historyTime,
            onChanged: _onHistoryTime,
          ),
        ],
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
      label: '待入库切片',
      width: 110,
      type: 'number',
      value: (task) =>
          task.pendingSliceCount > 0 ? '${task.pendingSliceCount} 个' : '—',
    ),
    MasterColumnDef(
      key: 'pendingReturnCount',
      label: '待退回笔数',
      width: 104,
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
