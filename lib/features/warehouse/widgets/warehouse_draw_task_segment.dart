// 生产领料任务中心 · 待领任务分段：仓库履约（备料/领取）任务队列。
//
// 数据源与 /operations/workbench/warehouse 履约工作台同源（生产物料需求 ×
// DRAW 领料单的 open_qty 投影，按单据归组：一行=一张领料单，多物料单显示
// 「N 种物料」规模摘要，物料明细在领料单详情内逐行办理）；本分段只保留仓库
// 日常所需的紧凑表格：状态分段 + 双击进入对应领料单（/warehouse/DRAW/:id）
// 办理分批出库。读取走仓库侧轻量读模型（WarehouseDrawTask），
// 不依赖 operations_workbench feature。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/models/paged_result.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/warehouse_draw_task.dart';
import '../providers/production_draw_count_provider.dart';
import '../repositories/production_draw_task_repository.dart';

/// 「待完成」分段的后端口径（open_qty > 0），与履约工作台同义。
const _kOpenAnyStatus = 'OPEN_ANY';

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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load(1));
  }

  @override
  void didUpdateWidget(WarehouseDrawTaskSegment oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.keyword != widget.keyword ||
        oldWidget.refreshTick != widget.refreshTick) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _load(1));
    }
  }

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
          );
      if (!mounted || version != _requestVersion) return;
      setState(() {
        _result = result;
        _loading = false;
      });
      ref.invalidate(warehouseProductionDrawPendingCountProvider);
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

  Future<void> _openTask(WarehouseDrawTask task) async {
    final path = task.drawDocPath;
    if (path == null) {
      // 服务端判定当前账号不可见对应领料单（对象范围裁剪）；只读行不提供入口。
      return;
    }
    await context.push(path);
    if (mounted) await _load(_result?.page ?? 1);
  }

  @override
  Widget build(BuildContext context) {
    final tasks = _result?.items ?? const <WarehouseDrawTask>[];
    final theme = Theme.of(context);
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
            segments: const [
              UtenFilterSegment(value: _kOpenAnyStatus, label: '待完成'),
              UtenFilterSegment(value: 'READY_TO_PICK', label: '待备料 / 待领取'),
              UtenFilterSegment(value: 'PARTIAL', label: '部分领取'),
              UtenFilterSegment(value: 'DONE', label: '已领取'),
            ],
            selected: {_status},
            onSelectionChanged: (value) {
              setState(() => _status = value);
              _load(1);
            },
            trailing: Text(
              '共 ${_result?.total ?? 0} 项 · 双击进入领料单',
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
            onRowTap: _openTask,
            canOpenRow: (task) => task.drawDocPath != null,
            rowMenuBuilder: (task) => task.drawDocPath == null
                ? const <UtenMenuItem>[]
                : [
                    UtenMenuItem(
                      label: '进入领料单办理出库',
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
      label: '生产计划',
      width: 170,
      value: (task) => task.planNo,
    ),
    MasterColumnDef(
      key: 'drawBillNo',
      label: '领料单号',
      width: 150,
      value: (task) => task.drawBillLabel,
    ),
    MasterColumnDef(
      key: 'goods',
      label: '货品',
      width: 260,
      value: (task) => task.goodsLabel,
    ),
    MasterColumnDef(
      key: 'warehouseName',
      label: '发料仓',
      width: 150,
      value: (task) => task.warehouseName.isEmpty ? '—' : task.warehouseName,
    ),
    MasterColumnDef(
      key: 'openQty',
      label: '待领数量',
      width: 130,
      type: 'number',
      value: (task) => task.quantityText,
    ),
    MasterColumnDef(
      key: 'status',
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
      label: '需求日期',
      width: 120,
      type: 'date',
      value: (task) => task.dueDate,
    ),
  ];
}
