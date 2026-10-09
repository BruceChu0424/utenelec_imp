// 生产领料任务中心 · 待领任务分段：仓库履约（备料/领取）任务队列。
//
// 数据源与 /operations/workbench/warehouse 履约工作台同源（生产物料需求 ×
// DRAW 领料单的 open_qty 投影，按单据归组：一行=一张领料单，多物料单显示
// 「N 种物料」规模摘要，物料明细在领料单详情内逐行办理）；本分段只保留仓库
// 日常所需的紧凑表格：状态分段 + 双击进入对应领料单（/warehouse/DRAW/:id）
// 办理分批出库。读取走仓库侧轻量读模型（WarehouseDrawTask），
// 不依赖 operations_workbench feature。
//
// 批量出库（2026-09-09；2026-09-10 修订）：勾选跨页保留（集合归本分段，表格从不
// 自行清空），一次最多 50 张；草稿单在服务端「出库即审核」故需 approve ∩ issue；
// 任一单失败整批回滚，错误带单号；同批重放时提示「本批此前已完成」。
//
// 表头排序（2026-09-24 用户口径「生产计划那里表头加个排序，能够快速排序」）：
// 生产计划 / 领料单号 / 发料仓 / 待领数量 / 状态 / 需求日期 可点表头排序，
// 排序在服务端整个结果集上做(分页前)，换排序回第 1 页；切换状态与搜索保留排序。
// 2026-09-25 单号列统一：领料单号列另加表头值筛选（桶=f.docNo 服务端分组，
// 值筛选走 f.docNo 精确匹配，与列表同一响应带回）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/data_display/uten_goods_identity_cell.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/data_display/uten_status_cell_color.dart';
import '../../../components/feedback/uten_segment_badge_label.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/paged_result.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/warehouse_draw_task.dart';
import '../pages/production_material_discovery_page.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../repositories/production_draw_task_repository.dart';
import '../../../shared/warehouse/warehouse_task_scope.dart';

/// 「待完成」分段的后端口径（open_qty > 0），与履约工作台同义。
const _kOpenAnyStatus = 'OPEN_ANY';

/// 可排序列 → 服务端排序字段(FulfillmentWorkbenchTableQuery 白名单)。
const _kSortFields = <String, String>{
  'planNo': 'planNo',
  'drawBillNo': 'docNo',
  'warehouseName': 'warehouseName',
  'openQty': 'openQty',
  'status': 'status',
  'dueDate': 'needDate',
};

class WarehouseDrawTaskSegment extends ConsumerStatefulWidget {
  const WarehouseDrawTaskSegment({
    super.key,
    this.keyword = '',
    this.refreshTick = 0,
    this.externalHeader,
  });

  /// 任务中心页级搜索关键字（300ms 防抖后的值）。
  final String keyword;

  /// 父页面「返回即刷新」信号。
  final int refreshTick;

  /// 宿主（任务中心大类行 + 小类行）：挂进折叠头随页滚走
  /// （2026-09-24 用户口径「表格完全置顶」）。
  final Widget? externalHeader;

  @override
  ConsumerState<WarehouseDrawTaskSegment> createState() =>
      _WarehouseDrawTaskSegmentState();
}

class _WarehouseDrawTaskSegmentState
    extends ConsumerState<WarehouseDrawTaskSegment> {
  PagedResult<WarehouseDrawTask>? _result;
  bool _loading = false;
  String? _error;
  int _requestVersion = 0;
  String _status = _kOpenAnyStatus;

  /// 跨页选择集合：翻页保留（表格从不自行清空），切换分段/关键字时重置。
  final Set<String> _selectedIds = <String>{};

  /// 本分段生命周期内加载过的行(行键 → 行)：跨页详情取单据 UUID、判草稿。
  final Map<String, WarehouseDrawTask> _knownTasks =
      <String, WarehouseDrawTask>{};
  Map<String, int> _statusCounts = const {};
  bool _batchIssuing = false;

  /// 表头排序：列 key(见 [_kSortFields])；null = 服务端默认顺序。
  String? _sortColumn;
  bool _sortAscending = true;

  /// 领料单号表头值筛选（2026-09-25 单号列统一）：服务端 f.docNo 精确匹配；
  /// 桶随列表响应带回（_result.facets['docNo']，与列表同一过滤口径）。
  String? _drawBillNoFilter;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load(1));
  }

  @override
  void didUpdateWidget(WarehouseDrawTaskSegment oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.keyword != widget.keyword) {
      // 关键字变了=结果集变了，跨页勾选不再有意义。
      _selectedIds.clear();
    }
    if (oldWidget.keyword != widget.keyword ||
        oldWidget.refreshTick != widget.refreshTick) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _load(1));
    }
  }

  static String _idOf(WarehouseDrawTask task) =>
      task.actionDocId ?? task.taskId;

  /// 展示粒度（2026-09-27 用户口径）：行=「批次 × 货品」——先按行级明细把每张单
  /// 拆成货品行，再同批次同货品跨单合并数量；无批次单只拆不跨单合并。
  List<WarehouseDrawTask> _expandForView(List<WarehouseDrawTask> items) => [
    for (final task in items) ...task.expandToGoodsRows(),
  ];

  List<WarehouseDrawTask> _viewItemsOf(PagedResult<WarehouseDrawTask> result) =>
      WarehouseDrawTask.mergeGoodsRows(_expandForView(result.items));

  Future<void> _load(int page) async {
    final version = ++_requestVersion;
    setState(() {
      _loading = true;
      _error = null;
    });
    final keyword = widget.keyword.trim();
    try {
      final result = await ref
          .read(productionDrawTaskRepositoryProvider)
          .tasks(
            page: page,
            keyword: keyword.isEmpty ? null : keyword,
            status: _status,
            sort: _kSortFields[_sortColumn],
            ascending: _sortAscending,
            drawBillNo: _drawBillNoFilter,
            scope: WarehouseListScope.of(context),
          );
      if (!mounted || version != _requestVersion) return;
      final viewItems = _viewItemsOf(result);
      setState(() {
        _result = result;
        _loading = false;
        // 底层单据行（勾选展开/出库跳转用）与视图行（表格勾选 id）都登记。
        for (final task in result.items) {
          _knownTasks[_idOf(task)] = task;
        }
        for (final task in viewItems) {
          _knownTasks[task.taskId] = task;
        }
        _pruneSelection(viewItems, result);
      });
      _loadStatusCounts();
    } on ApiException catch (error) {
      if (!mounted || version != _requestVersion) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || version != _requestVersion) return;
      setState(() {
        _error = '待领任务加载失败，请检查网络后重试';
        _loading = false;
      });
    }
  }

  /// 表头排序变化：服务端重排整个结果集，回第 1 页(勾选跨页保留, 不清)。
  void _onSortChange(String? column, bool ascending) {
    final next = _kSortFields.containsKey(column) ? column : null;
    if (next == _sortColumn && (next == null || ascending == _sortAscending)) {
      return;
    }
    setState(() {
      _sortColumn = next;
      _sortAscending = next == null ? true : ascending;
    });
    _load(1);
  }

  /// 领料单号表头值筛选（2026-09-25 单号列统一）：服务端精确匹配整个结果集，
  /// 回第 1 页；结果集变了，跨页勾选不再有意义，与关键字变化同样清空。
  void _onColumnFilterChanged(String key, String? value) {
    if (key != 'drawBillNo') return;
    setState(() {
      _drawBillNoFilter = (value == null || value.isEmpty) ? null : value;
      _selectedIds.clear();
    });
    _load(1);
  }

  /// 刷新后修剪勾选：本页已领完/不可出库的行剔除；整个结果只有一页时，
  /// 不在页内的行也剔除（已不是当前分段的待领任务）。多页结果不臆断其它页，
  /// 翻到该页再修剪。视图行（聚合行）的 canBatchIssue 已按底层单聚合判断。
  void _pruneSelection(
    List<WarehouseDrawTask> viewItems,
    PagedResult<WarehouseDrawTask> result,
  ) {
    if (_selectedIds.isEmpty) return;
    final onPage = <String, WarehouseDrawTask>{
      for (final task in viewItems) task.taskId: task,
    };
    _selectedIds.removeWhere((id) {
      final task = onPage[id] ?? _knownTasks[id];
      if (task != null) return !task.canBatchIssue;
      return result.totalPages <= 1;
    });
  }

  Future<void> _loadStatusCounts() async {
    try {
      final counts = await ref
          .read(productionDrawTaskRepositoryProvider)
          .statusBreakdown(scope: WarehouseListScope.of(context));
      if (!mounted) return;
      setState(() => _statusCounts = counts);
    } catch (error) {
      // 计数失败不阻塞列表，但不能静默留旧值：清空徽章并留日志，下次刷新重试
      //（此前 catch(_) 吞掉一切，端点 404 看起来像「没有徽章」）。
      debugPrint('待领任务子分类计数加载失败：$error');
      if (mounted) setState(() => _statusCounts = const {});
    }
  }

  /// 可在同一批量页核对的正式领料单和已知材料申请，跨页保留。
  /// 聚合/拆分行按 members 展开为底层单据。
  List<WarehouseDrawTask> get _issuableSelection => [
    for (final id in _selectedIds)
      if (_knownTasks[id] case final task?)
        if (task.isBatchMerged)
          ...task.members!.where((d) => d.canBatchIssue)
        else if (task.canBatchIssue)
          task,
  ];

  /// 批量全额出库：选中多张领料单按剩余量逐单出库（跨页勾选全部提交）。
  Future<void> _batchIssue() async {
    if (_batchIssuing || _selectedIds.isEmpty) return;
    final unsupported = _selectedIds.where((id) {
      final task = _knownTasks[id];
      if (task == null) return false;
      // 聚合行按底层单判断；底层单 id（跨页勾选）自身判断。
      if (task.isBatchMerged) return task.members!.any((d) => !d.canBatchIssue);
      return !task.canBatchIssue;
    });
    if (unsupported.isNotEmpty) {
      context.appWarning('选中任务含尚未确定材料或已失效的任务，请先进入“填写实际领料”确认材料，再选择批量出库');
      return;
    }
    final tasks = _issuableSelection;
    if (tasks.isEmpty) {
      context.appWarning('选中任务没有可出库的领料单');
      return;
    }
    const limit = ProductionDrawTaskRepository.batchIssueLimit;
    if (tasks.length > limit) {
      context.appWarning(
        '一次最多批量办理 $limit 项领料任务，当前已选 ${tasks.length} 项，请先取消部分勾选',
      );
      return;
    }
    setState(() => _batchIssuing = true);
    try {
      final changed = await context.push<bool>(_batchPath(tasks));
      if (!mounted) return;
      if (changed == true) _selectedIds.clear();
      await _load(_result?.page ?? 1);
    } finally {
      if (mounted) setState(() => _batchIssuing = false);
    }
  }

  String _batchPath(List<WarehouseDrawTask> tasks) {
    final documentIds =
        tasks
            .where((task) => !task.isMaterialDiscovery)
            .map((task) => task.actionDocId!)
            .toSet()
            .toList()
          ..sort();
    final requestIds =
        tasks
            .where((task) => task.isMaterialDiscovery)
            .map((task) => task.actionDocId!)
            .toSet()
            .toList()
          ..sort();
    return Uri(
      path: RouteName.warehouseProductionDrawBatchIssue,
      queryParameters: {
        if (documentIds.isNotEmpty) 'documentIds': documentIds.join(','),
        if (requestIds.isNotEmpty) 'discoveryRequestIds': requestIds.join(','),
      },
    ).toString();
  }

  Future<void> _openTask(WarehouseDrawTask task) async {
    // 聚合行（同批次同货品多张单）：进批量出库页一起核对；单成员行回落到底层单
    // 的既有入口（单张详情 / 填写材料）。
    if (task.isBatchMerged) {
      final members = task.members!;
      if (members.length == 1) return _openTask(members.single);
      if (members.every((d) => d.canBatchIssue)) {
        await context.push<bool>(_batchPath(members));
        if (mounted) await _load(_result?.page ?? 1);
        return;
      }
      context.appWarning('本批任务里有尚未确定材料或已失效的领料单，请先逐单处理');
      return;
    }
    if (task.isMaterialDiscovery) {
      if (task.materialsDefined) {
        await context.push<bool>(_batchPath([task]));
        if (mounted) await _load(_result?.page ?? 1);
        return;
      }
      await _openMaterialDefinition(task);
      return;
    }
    final path = task.drawDocPath;
    if (path == null) {
      // 服务端判定当前账号不可见对应领料单（对象范围裁剪）；只读行不提供入口。
      return;
    }
    await context.push(path);
    if (mounted) await _load(_result?.page ?? 1);
  }

  Future<void> _openMaterialDefinition(WarehouseDrawTask task) async {
    await context.push<bool>(
      ProductionMaterialDiscoveryPage.route.replaceFirst(
        ':requestId',
        task.actionDocId!,
      ),
    );
    if (mounted) await _load(_result?.page ?? 1);
  }

  List<Widget> _batchActions(
    BuildContext context,
    Set<String> selectedIds, {
    required bool canApprove,
  }) {
    final issuable = _issuableSelection;
    final draftsNeedApprove =
        !canApprove && issuable.any((task) => task.batchRequiresApproval);
    final hasUnknown = selectedIds.any(
      (id) => _knownTasks[id]?.needsMaterialEntry == true,
    );
    final hasUnavailable = selectedIds.any(
      (id) => _knownTasks[id]?.canBatchIssue != true,
    );
    final String? blocked = selectedIds.isEmpty
        ? '请先勾选要出库的领料单'
        : hasUnknown
        ? '选中任务尚未确定材料，请先进入“填写实际领料”选择材料'
        : hasUnavailable
        ? '选中任务已变化，请刷新后重新选择'
        : draftsNeedApprove
        ? '选中含待生成或草稿领料单：出库即审核，当前账号还需要审核权限'
        : null;
    return [
      UtenButton(
        key: const Key('warehouse-draw-batch-issue'),
        size: UtenButtonSize.large,
        type: UtenButtonType.danger,
        icon: Icons.outbound_outlined,
        isLoading: _batchIssuing,
        onPressed: blocked != null || _batchIssuing ? null : _batchIssue,
        onDisabledTap: () => context.appWarning(blocked ?? '正在批量出库，请稍候'),
        child: const Text('批量出库'),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    // 展示粒度=「批次 × 货品」（2026-09-27 用户口径）：同批次同货品合并数量、
    // 多货品单拆开一行一个货品；勾选/出库按底层单展开。
    final tasks = _result == null
        ? const <WarehouseDrawTask>[]
        : WarehouseDrawTask.mergeGoodsRows(_expandForView(_result!.items));
    final theme = Theme.of(context);
    // 批量出库按钮按会话权限门控：stock_doc:issue 才渲染；草稿单还需 approve
    //（出库即审核），无审核权限时按钮置灰并提示。
    final permissions = ref.watch(currentPermissionsProvider);
    final superAdmin = ref.watch(isSuperAdminProvider);
    final canIssue = superAdmin || permissions.contains(Perm.stockDocIssue);
    final canApprove = superAdmin || permissions.contains(Perm.stockDocApprove);
    // 2026-09-24 用户口径「表格完全置顶」：状态行/错误行进折叠头随页滚走，
    // body 只剩表格（primary 拾取联动控制器）。
    return UtenCollapsingHeaderScrollView(
      collapsingHeader: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.externalHeader != null) ...[
            widget.externalHeader!,
            const SizedBox(height: UtenSpacing.s12),
          ],
          Padding(
            padding: const EdgeInsets.only(
              bottom: UtenSpacing.s8,
              left: UtenSpacing.s4,
              right: UtenSpacing.s4,
            ),
            child: UtenFilterToolbar<String>(
              segmentsKey: const Key('warehouse-draw-task-status'),
              // 子分类计数：与列表同源的单据归组口径（待完成=READY+PARTIAL；
              // 已领取为终态不传 count)。未领与部分领取统一归入待完成。
              segments: [
                UtenFilterSegment(
                  value: _kOpenAnyStatus,
                  label: '待完成',
                  count: _statusCounts['OPEN_ANY'],
                  countForm: UtenSegmentCountForm.actionable,
                ),
                const UtenFilterSegment(value: 'DONE', label: '已领取'),
              ],
              selected: {_status},
              onSelectionChanged: (value) {
                setState(() {
                  _status = value;
                  _selectedIds.clear();
                });
                _load(1);
              },
              trailing: Text(
                '共 ${_result?.total ?? 0} 项 · 勾选跨页保留 · 双击进入领料单',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
          if (_error != null && tasks.isNotEmpty) ...[
            const SizedBox(height: UtenSpacing.s8),
            Semantics(
              liveRegion: true,
              child: Text(
                _error!,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
          ],
          const SizedBox(height: UtenSpacing.s8),
        ],
      ),
      body: MasterDataTableView<WarehouseDrawTask>(
        tableKey:
            'features.warehouse.widgets.warehouse_draw_task_segment.WarehouseDrawTaskSegmentState.build.1',
        // primary:true → 表体拾取联动容器注入的 PrimaryScrollController。
        primary: true,
        key: const Key('warehouse-draw-task-table'),
        columns: _columns,
        items: tasks,
        rowColor: (task) =>
            task.needsMaterialEntry ? theme.colorScheme.errorContainer : null,
        rowForegroundColor: (task) =>
            task.needsMaterialEntry ? theme.colorScheme.onErrorContainer : null,
        // 2026-09-25 单号列统一：领料单号桶来自同一响应的 facets['docNo']，
        // 桶值=单号，列 drawBillNo 直接映射。
        facets: {'drawBillNo': _result?.facets['docNo'] ?? const []},
        nullCounts: const {},
        filters: {'drawBillNo': _drawBillNoFilter},
        onFilterChanged: _onColumnFilterChanged,
        sortColumn: _sortColumn,
        sortAscending: _sortAscending,
        onSortChange: _onSortChange,
        // 批量出库：表头复选框多选 + 右下角悬浮批量按钮，
        // 与检验处置/成品入库任务中心同款范式。
        selectable: true,
        idOf: _idOf,
        selectedIds: _selectedIds,
        onSelectedIdsChanged: (next) => setState(() {
          _selectedIds
            ..clear()
            ..addAll(next);
        }),
        batchActionsBuilder: _status != 'DONE' && canIssue
            ? (context, selectedIds) =>
                  _batchActions(context, selectedIds, canApprove: canApprove)
            : null,
        onRowTap: _openTask,
        canOpenRow: (task) => task.canOpen,
        rowMenuBuilder: (task) => !task.canOpen
            ? const <UtenMenuItem>[]
            : [
                UtenMenuItem(
                  label: task.isMaterialDiscovery
                      ? task.materialsDefined
                            ? '核对实际领料并出库'
                            : AppLocalizations.of(
                                context,
                              ).materialDiscoveryTitle
                      : '进入领料单办理出库',
                  icon: Icons.outbound_outlined,
                  onTap: () => _openTask(task),
                ),
                if (task.isMaterialDiscovery && task.materialsDefined)
                  UtenMenuItem(
                    label: '调整领料材料',
                    icon: Icons.edit_outlined,
                    onTap: () => _openMaterialDefinition(task),
                  ),
              ],
        isLoading: _loading && _result == null,
        loadingMore: _loading && _result != null,
        error: tasks.isEmpty ? _error : null,
        onRetry: () => _load(_result?.page ?? 1),
        emptyMessage: widget.keyword.trim().isEmpty
            ? (_status == _kOpenAnyStatus ? '目前没有待领任务' : '当前状态下暂无任务')
            : '没有匹配的待领任务',
        currentPage: _result?.page ?? 1,
        totalPages: _result?.totalPages ?? 1,
        paginationScope: (
          widget.keyword,
          _status,
          WarehouseListScope.of(context),
        ),
        onPageChange: _load,
      ),
    );
  }

  // 2026-09-27 用户口径「领料页和批量出库页两个表头应该一样」：列序与列名对齐
  // 批量出库明细表（production_draw_detail_table），并补齐领料车间/领料负责人/
  // 单位/应领/已出库——两张表里有用的合起来，重复的（系列/实际重量/已申请领料）
  // 两边都不留。
  List<MasterColumnDef<WarehouseDrawTask>> get _columns => [
    MasterColumnDef(
      key: 'status',
      sortable: true,
      label: '状态',
      width: 72,
      value: (task) => task.statusLabel,
      // ADR-169 逐页显式映射（待领任务=履约备料队列，以仓库动作为准）：
      // 待备料/待领取、待完成、待核对领料/需要填写=绿（轮到仓库动手出库或补录，
      // 同一动作家族）/ 部分领取=紫（部分就绪：部分已出库、仍有余量）/
      // 已阻塞=红（硬阻断）/ 已完成=灰（办结，不再是本队列动作对象）。
      cellColor: (context, task) => switch (task.taskStatus.toUpperCase()) {
        'READY_TO_PICK' || 'OPEN_ANY' || 'MATERIALS_TO_DEFINE' =>
          utenStatusBadgeCellColor(UtenStatusBadgeType.success),
        'PARTIAL' => utenStatusBadgeCellColor(UtenStatusBadgeType.violet),
        'BLOCKED' => utenStatusBadgeCellColor(UtenStatusBadgeType.danger),
        'DONE' ||
        'COMPLETED' => utenStatusBadgeCellColor(UtenStatusBadgeType.neutral),
        _ => null,
      },
    ),
    MasterColumnDef(
      key: 'drawBillNo',
      sortable: true,
      label: '领料单号',
      width: 205,
      value: (task) => task.drawBillLabel,
      cellBuilder: (_, task) => Text(
        task.isMaterialDiscovery && task.drawBillLabel != '—'
            ? '申请 ${task.drawBillLabel}'
            : task.drawBillLabel,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    ),
    // 2026-09-27 用户口径「同一次批量领料仓库能看出是一批」：车间批量领料提交的
    // 多张单在服务端写同一批次号，这里可按批次筛选/识别同批。
    MasterColumnDef(
      key: 'drawBatchNo',
      // 2026-09-27 用户口径「申请号和批次一样就留一个」：本列是唯一的批标识——
      // 批量领料批次号优先；没有批次但挂了领料申请（LQ）的单显示申请号；
      // 申请行自身的申请号在「领料单号」列（带「申请」前缀），这里不重复。
      label: '领料批次',
      width: 190,
      filterFromRows: true,
      value: (task) => task.isBatchMerged
          ? task.drawBatchNo
          : task.drawBatchNo.isNotEmpty
          ? task.drawBatchNo
          : !task.isMaterialDiscovery && task.materialRequestNo.isNotEmpty
          ? task.materialRequestNo
          : '—',
    ),
    // 2026-09-14 用户口径（全站表格统一）：名称 / 编号 / 颜色各占一列；
    // 2026-09-27 用户口径：名称列只显示名称（规格副行下线）。归组行（N 种物料）
    // 没有单一货品身份，名称列沿用规模摘要、编号/颜色列如实显示「—」。
    MasterColumnDef(
      key: 'goods',
      label: '货品名称',
      width: 200,
      value: (task) => task.materialLabel,
      // 2026-10-06 行高统一口径：读表格内文本一律单行（完整名称挂 Tooltip），
      // 不用两行文本把行撑高。
      cellBuilder: (context, task) => Tooltip(
        message: task.materialLabel,
        child: Text(
          task.materialLabel,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    ),
    MasterColumnDef(
      key: 'goodsCode',
      label: '编号',
      width: 130,
      value: (task) => task.isDocumentGrouped || task.needsMaterialEntry
          ? null
          : UtenGoodsAttributeCell.text(task.goodsCode),
      cellBuilder: (context, task) => UtenGoodsAttributeCell(
        task.isDocumentGrouped || task.needsMaterialEntry
            ? null
            : task.goodsCode,
      ),
    ),
    MasterColumnDef(
      key: 'colorName',
      label: '颜色',
      width: 96,
      value: (task) => task.isDocumentGrouped || task.needsMaterialEntry
          ? null
          : UtenGoodsAttributeCell.text(task.colorName),
      cellBuilder: (context, task) => UtenGoodsAttributeCell(
        task.isDocumentGrouped || task.needsMaterialEntry
            ? null
            : task.colorName,
      ),
    ),
    MasterColumnDef(
      key: 'warehouseName',
      sortable: true,
      label: '仓库',
      width: 150,
      value: (task) => task.warehouseName.isEmpty ? '—' : task.warehouseName,
    ),
    MasterColumnDef(
      key: 'workshopName',
      label: '领料车间',
      width: 150,
      value: (task) => task.workshopName.isEmpty || task.isMaterialDiscovery
          ? '—'
          : task.workshopName,
    ),
    MasterColumnDef(
      key: 'workerName',
      label: '领料负责人',
      width: 140,
      value: (task) => task.workerName.isEmpty || task.isMaterialDiscovery
          ? '—'
          : task.workerName,
    ),
    MasterColumnDef(
      key: 'unitName',
      label: '单位',
      width: 80,
      value: (task) => task.isDocumentGrouped || task.needsMaterialEntry
          ? '—'
          : task.unitName,
    ),
    MasterColumnDef(
      key: 'requiredQty',
      label: '应领数量',
      width: 105,
      type: 'number',
      value: (task) => task.requiredQtyText,
    ),
    MasterColumnDef(
      key: 'fulfilledQty',
      label: '已出库',
      width: 105,
      type: 'number',
      value: (task) => task.fulfilledQtyText,
    ),
    MasterColumnDef(
      key: 'openQty',
      sortable: true,
      label: '待出库',
      width: 130,
      type: 'number',
      value: (task) => task.remainingQtyText,
    ),
    MasterColumnDef(
      key: 'planNo',
      sortable: true,
      label: '生产计划',
      width: 170,
      value: (task) => task.planNo,
    ),
    MasterColumnDef(
      key: 'productionPurpose',
      label: '用于生产',
      width: 220,
      value: (task) =>
          task.productionPurpose.isEmpty ? '—' : task.productionPurpose,
    ),
    MasterColumnDef(
      key: 'dueDate',
      sortable: true,
      label: '需求日期',
      width: 120,
      type: 'date',
      value: (task) => task.dueDate,
    ),
    MasterColumnDef(
      key: 'exception',
      label: '异常',
      width: 110,
      value: (task) => task.exceptionLabel,
      // ADR-169：逾期=红（异常档）；「正常」不铺色，避免整列皆红/皆绿的噪音。
      cellColor: (context, task) =>
          task.exceptionCode == null || task.exceptionCode!.isEmpty
          ? null
          : utenStatusBadgeCellColor(UtenStatusBadgeType.danger),
    ),
  ];
}
