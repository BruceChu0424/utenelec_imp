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
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/uten_goods_identity_cell.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/feedback/uten_segment_badge_label.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
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
  });

  /// 任务中心页级搜索关键字（300ms 防抖后的值）。
  final String keyword;

  /// 父页面「返回即刷新」信号。
  final int refreshTick;

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
            scope: WarehouseListScope.of(context),
          );
      if (!mounted || version != _requestVersion) return;
      setState(() {
        _result = result;
        _loading = false;
        for (final task in result.items) {
          _knownTasks[_idOf(task)] = task;
        }
        _pruneSelection(result);
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

  /// 刷新后修剪勾选：本页已领完/不可出库的单剔除；整个结果只有一页时，
  /// 不在页内的单也剔除（已不是当前分段的待领任务）。多页结果不臆断其它页，
  /// 翻到该页再修剪。
  void _pruneSelection(PagedResult<WarehouseDrawTask> result) {
    if (_selectedIds.isEmpty) return;
    final onPage = <String, WarehouseDrawTask>{
      for (final task in result.items) _idOf(task): task,
    };
    _selectedIds.removeWhere((id) {
      final task = onPage[id];
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

  /// 当前勾选中真正可批量出库的领料单（挂有可见 DRAW 且未领完），跨页。
  List<WarehouseDrawTask> get _issuableSelection => [
    for (final id in _selectedIds)
      if (_knownTasks[id] case final task? when task.canBatchIssue) task,
  ];

  /// 批量全额出库：选中多张领料单按剩余量逐单出库（跨页勾选全部提交）。
  Future<void> _batchIssue() async {
    if (_batchIssuing || _selectedIds.isEmpty) return;
    final tasks = _issuableSelection;
    if (tasks.isEmpty) {
      context.appWarning('选中任务没有可出库的领料单');
      return;
    }
    const limit = ProductionDrawTaskRepository.batchIssueLimit;
    if (tasks.length > limit) {
      context.appWarning(
        '一次最多批量出库 $limit 张领料单，当前已选 ${tasks.length} 张，请先取消部分勾选',
      );
      return;
    }
    setState(() => _batchIssuing = true);
    try {
      final ids = tasks.map((task) => task.actionDocId!).toSet().toList()
        ..sort();
      final changed = await context.push<bool>(
        Uri(
          path: RouteName.warehouseProductionDrawBatchIssue,
          queryParameters: {'documentIds': ids.join(',')},
        ).toString(),
      );
      if (!mounted) return;
      if (changed == true) _selectedIds.clear();
      await _load(_result?.page ?? 1);
    } finally {
      if (mounted) setState(() => _batchIssuing = false);
    }
  }

  Future<void> _openTask(WarehouseDrawTask task) async {
    if (task.isMaterialDiscovery) {
      await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) =>
              ProductionMaterialDiscoveryPage(requestId: task.actionDocId!),
        ),
      );
      if (mounted) await _load(_result?.page ?? 1);
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

  List<Widget> _batchActions(
    BuildContext context,
    Set<String> selectedIds, {
    required bool canApprove,
  }) {
    final issuable = _issuableSelection;
    final draftsNeedApprove =
        !canApprove && issuable.any((task) => task.isDraftDoc);
    final String? blocked = selectedIds.isEmpty
        ? '请先勾选要出库的领料单'
        : draftsNeedApprove
        ? '选中含草稿领料单：出库即审核，当前账号还需要审核权限'
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
    final tasks = _result?.items ?? const <WarehouseDrawTask>[];
    final theme = Theme.of(context);
    // 批量出库按钮按会话权限门控：stock_doc:issue 才渲染；草稿单还需 approve
    //（出库即审核），无审核权限时按钮置灰并提示。
    final permissions = ref.watch(currentPermissionsProvider);
    final canIssue = permissions.contains(Perm.stockDocIssue);
    final canApprove = permissions.contains(Perm.stockDocApprove);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
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
        Expanded(
          child: MasterDataTableView<WarehouseDrawTask>(
            key: const Key('warehouse-draw-task-table'),
            columns: _columns,
            items: tasks,
            facets: const {},
            nullCounts: const {},
            filters: const {},
            onFilterChanged: (_, _) {},
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
                ? (context, selectedIds) => _batchActions(
                    context,
                    selectedIds,
                    canApprove: canApprove,
                  )
                : null,
            onRowTap: _openTask,
            canOpenRow: (task) => task.canOpen,
            rowMenuBuilder: (task) => !task.canOpen
                ? const <UtenMenuItem>[]
                : [
                    UtenMenuItem(
                      label: task.isMaterialDiscovery
                          ? AppLocalizations.of(context).materialDiscoveryTitle
                          : '进入领料单办理出库',
                      icon: Icons.outbound_outlined,
                      onTap: () => _openTask(task),
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
            onPageChange: _load,
          ),
        ),
      ],
    );
  }

  List<MasterColumnDef<WarehouseDrawTask>> get _columns => [
    MasterColumnDef(
      key: 'planNo',
      sortable: true,
      label: '生产计划',
      width: 170,
      value: (task) => task.planNo,
    ),
    MasterColumnDef(
      key: 'drawBillNo',
      sortable: true,
      label: '领料单号',
      width: 150,
      value: (task) => task.drawBillLabel,
    ),
    // 2026-09-14 用户口径（全站表格统一）：名称 / 编号 / 颜色各占一列——
    // 仓库正是靠名称 + 颜色对位拣货，三个属性挤成一串时列一窄就先被省略号吃掉。
    // 规格没有独立列，仍留在名称格副行；归组行（N 种物料）没有单一货品身份，
    // 名称列沿用规模摘要、编号/颜色列如实显示「—」。
    MasterColumnDef(
      key: 'goods',
      label: '货品名称',
      width: 200,
      value: (task) =>
          task.isDocumentGrouped ? task.goodsLabel : task.goodsName,
      cellBuilderHandlesSemantics: true,
      cellBuilder: (context, task) => task.isDocumentGrouped
          ? Text(task.goodsLabel, maxLines: 1, overflow: TextOverflow.ellipsis)
          : UtenGoodsIdentityCell(name: task.goodsName, spec: task.spec),
    ),
    MasterColumnDef(
      key: 'goodsCode',
      label: '编号',
      width: 130,
      value: (task) => task.isDocumentGrouped
          ? null
          : UtenGoodsAttributeCell.text(task.goodsCode),
      cellBuilder: (context, task) => UtenGoodsAttributeCell(
        task.isDocumentGrouped ? null : task.goodsCode,
      ),
    ),
    MasterColumnDef(
      key: 'colorName',
      label: '颜色',
      width: 96,
      value: (task) => task.isDocumentGrouped
          ? null
          : UtenGoodsAttributeCell.text(task.colorName),
      cellBuilder: (context, task) => UtenGoodsAttributeCell(
        task.isDocumentGrouped ? null : task.colorName,
      ),
    ),
    MasterColumnDef(
      key: 'warehouseName',
      sortable: true,
      label: '发料仓',
      width: 150,
      value: (task) => task.warehouseName.isEmpty ? '—' : task.warehouseName,
    ),
    MasterColumnDef(
      key: 'openQty',
      sortable: true,
      label: '待领数量',
      width: 130,
      type: 'number',
      value: (task) => task.quantityText,
    ),
    MasterColumnDef(
      key: 'status',
      sortable: true,
      label: '状态',
      width: 150,
      value: (task) => task.statusLabel,
    ),
    MasterColumnDef(
      key: 'exception',
      label: '异常',
      width: 110,
      value: (task) => task.exceptionLabel,
    ),
    MasterColumnDef(
      key: 'dueDate',
      sortable: true,
      label: '需求日期',
      width: 120,
      type: 'date',
      value: (task) => task.dueDate,
    ),
  ];
}
