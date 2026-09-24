import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/data_display/uten_revision_table.dart';
import '../../../components/feedback/uten_reviewer_responsibility_notice.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/route_names.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/list_refresh_provider.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../providers/production_execution_refresh.dart';
import '../widgets/production_review_reason_dialog.dart';
import '../repositories/production_material_increment_repository.dart';

String materialIncrementStatus(String status) => switch (status) {
  'PENDING' => '待计划部审批',
  'APPROVED' => '已批准',
  'RETURNED' => '已退回',
  'CANCELLED' => '授权已撤销',
  _ => '待核对',
};

class ProductionMaterialIncrementListPage extends ConsumerStatefulWidget {
  const ProductionMaterialIncrementListPage({super.key});
  @override
  ConsumerState<ProductionMaterialIncrementListPage> createState() =>
      _IncrementListState();
}

class _IncrementListState
    extends ConsumerState<ProductionMaterialIncrementListPage> {
  PagedResult<ProductionMaterialIncrementRequest>? _data;
  String _status = 'PENDING';
  String? _error;
  bool _loading = true;
  int _request = 0;
  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  Future<void> _load([int page = 1]) async {
    final request = ++_request;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await ref
          .read(productionMaterialIncrementRepositoryProvider)
          .list(status: _status, page: page);
      if (mounted && request == _request) setState(() => _data = data);
    } on ApiException catch (error) {
      if (mounted && request == _request) {
        setState(() => _error = error.message);
      }
    } catch (_) {
      if (mounted && request == _request) {
        setState(() => _error = '追加用料申请读取失败，请重试');
      }
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.onPageResume(
      RouteName.productionMaterialIncrementRequests,
      () => _load(_data?.page ?? 1),
      refreshKeys: [productionMaterialIncrementRefreshKey],
    );
    return Scaffold(
      appBar: UtenAppBar(
        title: '追加用料申请',
        leading: UtenBackButton(
          onPressed: () =>
              popOrBackTo(context, defaultPath: RouteName.productionPlanList),
        ),
        actions: [
          IconButton(
            onPressed: () => _load(_data?.page ?? 1),
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
          ),
        ],
      ),
      body: SafeArea(
        child: UtenContentContainer.wide(
          child: Column(
            children: [
              UtenFilterToolbar<String>(
                segments: const [
                  UtenFilterSegment(value: 'PENDING', label: '待审批'),
                  UtenFilterSegment(value: 'APPROVED', label: '已批准'),
                  UtenFilterSegment(value: 'RETURNED', label: '已退回'),
                  UtenFilterSegment(value: 'CANCELLED', label: '授权已撤销'),
                ],
                selected: {_status},
                onSelectionChanged: (value) {
                  setState(() => _status = value);
                  _load();
                },
              ),
              Expanded(
                child: MasterDataTableView<ProductionMaterialIncrementRequest>(
                  columns: [
                    for (final field in const [
                      ('planNo', '计划号', 150.0),
                      ('segmentCode', '工单号', 145.0),
                      ('goodsName', '材料名称', 220.0),
                      ('originalRequiredQty', '原定额', 110.0),
                      ('deltaQty', '本次追加', 110.0),
                      ('submittedByName', '申请人', 110.0),
                    ])
                      MasterColumnDef(
                        key: field.$1,
                        label: field.$2,
                        width: field.$3,
                        value: (row) => row.text(field.$1),
                      ),
                    MasterColumnDef(
                      key: 'status',
                      label: '状态',
                      width: 140,
                      value: (row) => materialIncrementStatus(row.status),
                    ),
                  ],
                  items: _data?.items ?? const [],
                  facets: const {},
                  nullCounts: const {},
                  filters: const {},
                  onFilterChanged: (_, _) {},
                  isLoading: _loading,
                  error: _error,
                  onRetry: () => _load(),
                  onRowTap: (row) => context.push(
                    RoutePath.productionMaterialIncrementRequest(row.id),
                  ),
                  currentPage: _data?.page ?? 1,
                  totalPages: _data?.totalPages ?? 0,
                  onPageChange: _load,
                  emptyMessage: '没有符合条件的追加用料申请',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ProductionMaterialIncrementCreatePage extends ConsumerStatefulWidget {
  const ProductionMaterialIncrementCreatePage({
    super.key,
    required this.segmentId,
  });
  final String segmentId;
  @override
  ConsumerState<ProductionMaterialIncrementCreatePage> createState() =>
      _IncrementCreateState();
}

class _IncrementCreateState
    extends ConsumerState<ProductionMaterialIncrementCreatePage> {
  ProductionMaterialIncrementContext? _data;
  final _quantity = TextEditingController();
  final _reason = TextEditingController();
  String? _demandId;
  String? _error;
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  @override
  void dispose() {
    _quantity.dispose();
    _reason.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final data = await ref
          .read(productionMaterialIncrementRepositoryProvider)
          .context(widget.segmentId);
      if (!mounted) return;
      setState(() {
        _data = data;
        if (_demandId == null && data.demands.length == 1) {
          _demandId = data.demands.single['originalDemandId'] as String;
        }
        _error = null;
      });
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = '材料来源读取失败，请重试');
    }
  }

  Map<String, dynamic>? get _selected => _data?.demands
      .where((row) => row['originalDemandId'] == _demandId)
      .firstOrNull;
  Future<void> _submit() async {
    final data = _data, demand = _selected;
    if (_busy ||
        data == null ||
        demand == null ||
        !data.canSubmit ||
        demand['pendingRequestId'] != null) {
      return;
    }
    final qty = double.tryParse(_quantity.text.trim());
    final reason = _reason.text.trim();
    if (qty == null || !qty.isFinite || qty <= 0 || reason.isEmpty) {
      setState(() => _error = '请填写大于 0 的追加数量及申请原因');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final request = await ref
          .read(productionMaterialIncrementRepositoryProvider)
          .submit(context: data, demand: demand, deltaQty: qty, reason: reason);
      if (!mounted) return;
      bumpListRefresh(ref, productionMaterialIncrementRefreshKey);
      context.pushReplacement(
        RoutePath.productionMaterialIncrementRequest(request.id),
      );
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = '提交结果尚未确认，请保留原内容重试；同一申请不会重复创建');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = _data, selected = _selected;
    return Scaffold(
      appBar: UtenAppBar(
        title: '申请追加用料',
        leading: UtenBackButton(
          onPressed: () => popOrBackTo(
            context,
            defaultPath: RouteName.productionWorkshopTasks,
          ),
        ),
      ),
      body: SafeArea(
        child: UtenContentContainer.wide(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_busy) const LinearProgressIndicator(),
                if (data == null && _error == null)
                  const Center(child: CircularProgressIndicator()),
                if (data != null) ...[
                  Text(
                    '工单：${data.segmentCode ?? '—'}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 12),
                  const Text('填写这次还需补领的数量。计划部批准后，仓库按实际数量发料。'),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    initialValue:
                        data.demands.any(
                          (row) => row['originalDemandId'] == _demandId,
                        )
                        ? _demandId
                        : null,
                    isExpanded: true,
                    decoration: const UtenInputDecoration(
                      InputDecoration(labelText: '原工单材料'),
                    ),
                    items: [
                      for (final row in data.demands)
                        DropdownMenuItem(
                          value: row['originalDemandId'] as String,
                          child: Text(
                            '${row['goodsName']} · ${row['goodsCode']} · ${row['colorName'] ?? '—'}',
                          ),
                        ),
                    ],
                    onChanged: _busy
                        ? null
                        : (id) => setState(() => _demandId = id),
                  ),
                  if (selected != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        '原定额 ${selected['requiredQty']} · 已批准追加 ${selected['approvedIncrementQty']} · 实际净领 ${selected['netIssuedQty']} · 可用余料 ${selected['availableQty']} ${selected['unitName'] ?? ''}',
                      ),
                    ),
                  if (selected?['pendingRequestId'] != null)
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => context.push(
                              RoutePath.productionMaterialIncrementRequest(
                                selected!['pendingRequestId'] as String,
                              ),
                            ),
                      child: Text(
                        '已有追加 ${selected?['pendingDeltaQty']} 待审批 · 查看原申请',
                      ),
                    ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _quantity,
                    enabled: !_busy,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: UtenInputDecoration(
                      InputDecoration(
                        labelText: '本次追加数量',
                        suffixText: selected?['unitName']?.toString(),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _reason,
                    enabled: !_busy,
                    minLines: 2,
                    maxLines: 4,
                    decoration: const UtenInputDecoration(
                      InputDecoration(labelText: '申请原因（必填）'),
                    ),
                  ),
                  if (data.blockingReason?.isNotEmpty == true)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(data.blockingReason!),
                    ),
                ],
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                const SizedBox(height: 20),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    OutlinedButton(
                      onPressed: _busy ? null : _load,
                      child: const Text('重新核对来源'),
                    ),
                    FilledButton(
                      onPressed:
                          _busy ||
                              data?.canSubmit != true ||
                              selected == null ||
                              selected['pendingRequestId'] != null
                          ? null
                          : _submit,
                      child: const Text('提交计划部审批'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class ProductionMaterialIncrementDetailPage extends ConsumerStatefulWidget {
  const ProductionMaterialIncrementDetailPage({super.key, required this.id});
  final String id;
  @override
  ConsumerState<ProductionMaterialIncrementDetailPage> createState() =>
      _IncrementDetailState();
}

class _IncrementDetailState
    extends ConsumerState<ProductionMaterialIncrementDetailPage> {
  ProductionMaterialIncrementRequest? _detail;
  String? _error;
  bool _busy = false;
  int _loadGeneration = 0;
  String _returnReason = '';
  String _cancelReason = '';
  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    try {
      final result = await ref
          .read(productionMaterialIncrementRepositoryProvider)
          .detail(widget.id);
      if (mounted && generation == _loadGeneration) {
        setState(() {
          _detail = result;
          _error = null;
        });
      }
    } on ApiException catch (error) {
      if (mounted && generation == _loadGeneration) {
        setState(() => _error = error.message);
      }
    } catch (_) {
      if (mounted && generation == _loadGeneration) {
        setState(() => _error = '申请读取失败，请重试');
      }
    }
  }

  Future<void> _decide(bool approve) async {
    final detail = _detail;
    if (detail == null || _busy) return;
    String reason = '';
    if (approve) {
      final confirmed = await showUtenReviewerConfirmDialog(
        context,
        message: '请核对原定额、已批追加和本次追加量。批准后新增材料领用额度，仓库仍需实际发料。',
      );
      if (confirmed != true || !mounted) return;
    } else {
      final response = await showProductionReviewReasonDialog(
        context,
        title: '退回追加用料申请',
        initialValue: _returnReason,
        onDraftChanged: (value) => _returnReason = value,
      );
      if (response == null || !mounted) return;
      reason = response;
    }
    setState(() {
      ++_loadGeneration;
      _busy = true;
      _error = null;
    });
    try {
      final result = await ref
          .read(productionMaterialIncrementRepositoryProvider)
          .decide(detail, approve: approve, reason: reason);
      if (!mounted) return;
      setState(() => _detail = result);
      bumpListRefresh(ref, productionMaterialIncrementRefreshKey);
      refreshAfterProductionPlanGenerated(ref);
    } on ApiException catch (error) {
      await _load();
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      await _load();
      if (mounted) setState(() => _error = '请核对当前处理结果后再重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancel() async {
    final detail = _detail;
    if (_busy || detail == null || !detail.canCancel) return;
    final reason = await showProductionReviewReasonDialog(
      context,
      title: '撤销用料授权',
      initialValue: _cancelReason,
      onDraftChanged: (value) => _cancelReason = value,
    );
    if (reason == null || !mounted) return;
    setState(() {
      ++_loadGeneration;
      _busy = true;
      _error = null;
    });
    try {
      final result = await ref
          .read(productionMaterialIncrementRepositoryProvider)
          .cancel(detail, reason);
      if (!mounted) return;
      setState(() => _detail = result);
      bumpListRefresh(ref, productionMaterialIncrementRefreshKey);
      refreshAfterProductionPlanGenerated(ref);
    } on ApiException catch (error) {
      await _load();
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      await _load();
      if (mounted) setState(() => _error = '请核对授权当前状态后再重试；撤销原因仍保留');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final detail = _detail;
    final before = detail?.snapshotItems('beforeSnapshot'),
        after = detail?.snapshotItems('afterSnapshot');
    final validSnapshots = before != null && after != null;
    final permissions = ref.watch(currentPermissionsProvider);
    final admin = ref.watch(isSuperAdminProvider);
    final planner = admin || permissions.contains(Perm.productionPlanApprove);
    final workshop =
        admin || permissions.contains(Perm.productionExecutionView);
    return Scaffold(
      appBar: UtenAppBar(
        title: '追加用料审批',
        leading: UtenBackButton(
          onPressed: () => popOrBackTo(
            context,
            defaultPath: planner
                ? RouteName.productionMaterialIncrementRequests
                : RouteName.productionWorkshopTasks,
          ),
        ),
        actions: [
          IconButton(
            onPressed: _busy ? null : _load,
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
          ),
        ],
      ),
      body: SafeArea(
        child: UtenContentContainer.wide(
          child: detail == null
              ? Center(
                  child: _error == null
                      ? const CircularProgressIndicator()
                      : TextButton(
                          onPressed: _load,
                          child: Text('$_error · 重试'),
                        ),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_busy) const LinearProgressIndicator(),
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${detail.text('planNo')} · ${detail.text('segmentCode')} · ${materialIncrementStatus(detail.status)}',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '申请人：${detail.text('submittedByName')} · 原因：${detail.text('reason')}',
                          ),
                          Text(
                            '本次追加：${detail.text('deltaQty')} ${detail.text('unitName')}',
                          ),
                          if (detail.status == 'PENDING')
                            const Text('审批前仍按原有额度领料。'),
                          if (detail.status == 'APPROVED')
                            const Text('追加用料已批准；到车间任务核对备料与领料进度，实际发料后登记真实耗用。'),
                          if (detail.status == 'CANCELLED')
                            const Text('本次追加用料授权已撤销；原定额、历史实发与退料记录保留。'),
                          if (detail.data['decisionReason'] != null)
                            Text('处理说明：${detail.text('decisionReason')}'),
                          if (detail.data['blockingReason'] != null)
                            Text(detail.text('blockingReason')),
                          if (_error != null)
                            Text(
                              _error!,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: !validSnapshots
                          ? const Center(child: Text('审批快照不完整，请刷新核对'))
                          : UtenRevisionTable<Map<String, dynamic>>(
                              rows: [
                                UtenRevisionRow(
                                  value: before.single,
                                  kind: UtenRevisionKind.removed,
                                  label: '申请前',
                                ),
                                UtenRevisionRow(
                                  value: after.single,
                                  kind: UtenRevisionKind.added,
                                  label: '申请后',
                                ),
                              ],
                              columns: [
                                for (final field in const [
                                  ('goodsName', '材料名称', 210.0),
                                  ('goodsCode', '编号', 130.0),
                                  ('colorName', '颜色', 90.0),
                                  ('unitName', '单位', 80.0),
                                  ('requiredQty', '原定额', 100.0),
                                  ('approvedIncrementQty', '累计追加', 110.0),
                                  ('authorizedQty', '授权用量', 120.0),
                                ])
                                  MasterColumnDef(
                                    key: field.$1,
                                    label: field.$2,
                                    width: field.$3,
                                    value: (row) =>
                                        row[field.$1]?.toString() ?? '—',
                                  ),
                              ],
                            ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Wrap(
                        alignment: WrapAlignment.end,
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          if (detail.status == 'APPROVED' && workshop)
                            OutlinedButton(
                              onPressed: () => context.push(
                                RouteName.productionWorkshopTasks,
                              ),
                              child: const Text('查看车间任务'),
                            ),
                          if (detail.status == 'APPROVED' &&
                              !workshop &&
                              planner)
                            OutlinedButton(
                              onPressed: () => context.push(
                                RouteName.productionMaterialIncrementRequests,
                              ),
                              child: const Text('返回审批列表'),
                            ),
                          if (detail.canReturn)
                            OutlinedButton(
                              onPressed: _busy ? null : () => _decide(false),
                              child: const Text('退回'),
                            ),
                          if (detail.canCancel)
                            OutlinedButton(
                              onPressed: _busy ? null : _cancel,
                              child: const Text('撤销用料授权'),
                            ),
                          if (detail.canApprove)
                            FilledButton(
                              onPressed: _busy || !validSnapshots
                                  ? null
                                  : () => _decide(true),
                              child: const Text('审批通过'),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
