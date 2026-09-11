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
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/feedback/uten_segment_badge_label.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';
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

  /// 跨页选择集合：翻页保留（表格从不自行清空），切换分段/关键字时重置。
  final Set<String> _selectedIds = <String>{};

  /// 本分段生命周期内加载过的行（行键 → 行）：跨页确认框列单号、判草稿。
  final Map<String, WarehouseDrawTask> _knownTasks =
      <String, WarehouseDrawTask>{};
  Map<String, int> _statusCounts = const {};
  bool _batchIssuing = false;

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
      ref.invalidate(warehouseProductionDrawPendingCountProvider);
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
          .statusBreakdown();
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
    final ignored = _selectedIds.length - tasks.length;
    // 备注输入框的控制器由弹窗自己持有（随路由销毁）；在 showDialog 返回后立刻
    // dispose 会撞上退场动画期间的重建。
    final remark = await showDialog<String>(
      context: context,
      builder: (_) => _BatchIssueConfirmDialog(
        billNos: tasks.map((t) => t.actionDocNo).toList(),
        ignored: ignored,
      ),
    );
    if (remark == null || !mounted) return;
    setState(() => _batchIssuing = true);
    try {
      final result = await ref
          .read(productionDrawTaskRepositoryProvider)
          .issueFullBatch(
            idempotencyKey: const Uuid().v4(),
            docIds: tasks.map((t) => t.actionDocId!).toList(),
            reason: remark.isEmpty ? null : remark,
          );
      if (!mounted) return;
      if (result.replayed) {
        context.appInfo('本批此前已完成（${result.replayedCount} 张领料单），未重复出库');
      } else {
        context.appSuccess(
          result.skippedCount > 0
              ? '已出库 ${result.issuedCount} 张领料单（${result.skippedCount} 张已出完自动跳过）'
              : '已出库 ${result.issuedCount} 张领料单',
        );
      }
      setState(() => _selectedIds.clear());
      await _load(1);
    } on ApiException catch (error) {
      if (mounted) context.appError(_batchFailureMessage(error));
    } catch (_) {
      if (mounted) context.appError('批量出库失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _batchIssuing = false);
    }
  }

  /// 服务端逐单错误已带单号（「领料单 X：原因」）；422 参数校验（如超过 50 张）
  /// 的顶层 message 只是「参数校验失败」，改取字段级说明。
  static String _batchFailureMessage(ApiException error) {
    final fields = error.fieldErrors;
    if (fields != null &&
        fields.isNotEmpty &&
        fields.first.message.isNotEmpty) {
      return fields.first.message;
    }
    return error.message;
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
            // 已领取为终态不传 count）。形态按「同一批活不在一行里红两遍」——
            // 「待完成」是总量段挂红徽章，它的两个细分切片走中性括号。
            segments: [
              UtenFilterSegment(
                value: _kOpenAnyStatus,
                label: '待完成',
                count: _statusCounts['OPEN_ANY'],
                countForm: UtenSegmentCountForm.actionable,
              ),
              UtenFilterSegment(
                value: 'READY_TO_PICK',
                label: '待备料 / 待领取',
                count: _statusCounts['READY_TO_PICK'],
              ),
              UtenFilterSegment(
                value: 'PARTIAL',
                label: '部分领取',
                count: _statusCounts['PARTIAL'],
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

/// 批量出库确认框：列出单号 + 统一备注（选填 ≤200 字）。
/// 返回 null=取消；返回字符串（可为空）=确认，内容为去空白后的统一备注。
class _BatchIssueConfirmDialog extends StatefulWidget {
  const _BatchIssueConfirmDialog({
    required this.billNos,
    required this.ignored,
  });

  final List<String> billNos;

  /// 勾选中不可出库（无可见领料单 / 已领完）而被忽略的项数。
  final int ignored;

  @override
  State<_BatchIssueConfirmDialog> createState() =>
      _BatchIssueConfirmDialogState();
}

class _BatchIssueConfirmDialogState extends State<_BatchIssueConfirmDialog> {
  final TextEditingController _remark = TextEditingController();

  @override
  void dispose() {
    _remark.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('批量出库（${widget.billNos.length} 张领料单）'),
      content: SizedBox(
        width: 420,
        child: ListView(
          shrinkWrap: true,
          children: [
            Text(
              '将按剩余量全额出库：${widget.billNos.join('、')}。'
              '草稿单出库即审核；出库在同一事务完成，任一单失败整批回滚。',
            ),
            if (widget.ignored > 0) ...[
              const SizedBox(height: UtenSpacing.s8),
              Text('另有 ${widget.ignored} 项勾选不是可出库的领料单，已自动忽略。'),
            ],
            const SizedBox(height: UtenSpacing.s8),
            TextField(
              key: const Key('warehouse-draw-batch-remark'),
              controller: _remark,
              maxLength: 200,
              minLines: 1,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: '统一备注(选填)',
                hintText: '随本批每张领料单追加到单据备注留痕',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('warehouse-draw-batch-confirm'),
          onPressed: () => Navigator.of(context).pop(_remark.text.trim()),
          child: const Text('确认出库'),
        ),
      ],
    );
  }
}
