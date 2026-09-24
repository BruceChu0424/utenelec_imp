import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../components/feedback/uten_reviewer_responsibility_notice.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/route_names.dart';
import '../../../core/router/route_access_policy.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/list_refresh_provider.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../providers/production_execution_refresh.dart';
import '../widgets/production_review_reason_dialog.dart';
import '../repositories/production_overproduction_rate_repository.dart';
import '../widgets/production_overproduction_rate_revision.dart';

class ProductionOverproductionRateListPage extends ConsumerStatefulWidget {
  const ProductionOverproductionRateListPage({super.key});
  @override
  ConsumerState<ProductionOverproductionRateListPage> createState() =>
      _RateListState();
}

class _RateListState
    extends ConsumerState<ProductionOverproductionRateListPage> {
  PagedResult<ProductionOverproductionRateRequest>? _data;
  String _status = 'PENDING';
  bool _loading = true;
  String? _error;
  int _request = 0;
  @override
  void initState() {
    super.initState();
    Future.microtask(() => _load());
  }

  Future<void> _load([int page = 1]) async {
    final request = ++_request;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await ref
          .read(productionOverproductionRateRepositoryProvider)
          .list(status: _status, page: page);
      if (mounted && request == _request) setState(() => _data = data);
    } on ApiException catch (error) {
      if (mounted && request == _request) {
        setState(() => _error = error.message);
      }
    } catch (_) {
      if (mounted && request == _request) {
        setState(() => _error = '申请列表读取失败，请重试');
      }
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.onPageResume(
      RouteName.productionOverproductionRateRequests,
      () => _load(_data?.page ?? 1),
      refreshKeys: [productionOverproductionRateRefreshKey],
    );
    return Scaffold(
      appBar: UtenAppBar(
        title: '允许超产比例申请',
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
                  UtenFilterSegment(value: 'APPROVED', label: '已通过'),
                  UtenFilterSegment(value: 'RETURNED', label: '已退回'),
                ],
                selected: {_status},
                onSelectionChanged: (value) {
                  setState(() => _status = value);
                  _load();
                },
              ),
              Expanded(
                child: MasterDataTableView<ProductionOverproductionRateRequest>(
                  columns: [
                    MasterColumnDef(
                      key: 'plan',
                      label: '计划号',
                      width: 150,
                      value: (row) => row.planNo,
                    ),
                    MasterColumnDef(
                      key: 'segment',
                      label: '工单号',
                      width: 145,
                      value: (row) => row.segmentCode,
                    ),
                    MasterColumnDef(
                      key: 'goods',
                      label: '货品名称',
                      width: 240,
                      value: (row) => row.goodsName,
                    ),
                    MasterColumnDef(
                      key: 'before',
                      label: '申请前比例',
                      width: 115,
                      value: (row) => productionRateText(row.beforeRate),
                    ),
                    MasterColumnDef(
                      key: 'after',
                      label: '申请比例',
                      width: 115,
                      value: (row) => productionRateText(row.requestedRate),
                    ),
                    MasterColumnDef(
                      key: 'status',
                      label: '状态',
                      width: 140,
                      value: (row) => productionRateStatus(row.status),
                    ),
                    MasterColumnDef(
                      key: 'maker',
                      label: '申请人',
                      width: 120,
                      value: (row) => row.submittedByName,
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
                    RoutePath.productionOverproductionRateRequest(row.id),
                  ),
                  currentPage: _data?.page ?? 1,
                  totalPages: _data?.totalPages ?? 0,
                  onPageChange: _load,
                  emptyMessage: '没有符合条件的比例申请',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ProductionOverproductionRateDetailPage extends ConsumerStatefulWidget {
  const ProductionOverproductionRateDetailPage({super.key, required this.id});
  final String id;
  @override
  ConsumerState<ProductionOverproductionRateDetailPage> createState() =>
      _RateDetailState();
}

class _RateDetailState
    extends ConsumerState<ProductionOverproductionRateDetailPage> {
  ProductionOverproductionRateRequest? _detail;
  String? _error;
  bool _busy = false;
  int _loadGeneration = 0;
  String _returnReason = '';
  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    try {
      final result = await ref
          .read(productionOverproductionRateRepositoryProvider)
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
        setState(() => _error = '申请读取失败，请刷新重试');
      }
    }
  }

  Future<void> _decide(bool approve) async {
    final detail = _detail;
    if (_busy || detail == null || productionRateRevisionRows(detail) == null) {
      return;
    }
    String reason = '';
    if (approve) {
      final confirmed = await showUtenReviewerConfirmDialog(
        context,
        message: '请核对红色原内容与绿色申请内容。审批通过后允许超产比例才会生效。',
      );
      if (confirmed != true || !mounted) return;
    } else {
      final response = await showProductionReviewReasonDialog(
        context,
        title: '退回比例申请',
        initialValue: _returnReason,
        onDraftChanged: (value) => _returnReason = value,
      );
      if (response == null || !mounted) return;
      reason = response;
    }
    setState(() {
      ++_loadGeneration;
      _busy = true;
    });
    try {
      final updated = await ref
          .read(productionOverproductionRateRepositoryProvider)
          .decide(detail, approve: approve, reason: reason);
      if (!mounted) return;
      setState(() => _detail = updated);
      bumpListRefresh(ref, productionOverproductionRateRefreshKey);
      bumpListRefresh(ref, productionExecutionRefreshKey);
      context.appSuccess(
        updated.status == 'APPROVED' ? '审批已通过，允许超产比例已生效' : '申请已退回，原有效比例保持不变',
      );
    } on ApiException catch (error) {
      await _load();
      if (mounted) {
        if (_detail?.status != detail.status) {
          bumpListRefresh(ref, productionOverproductionRateRefreshKey);
          context.appInfo('申请状态已更新，请核对当前审批结果');
        } else {
          context.appError(error.message);
        }
      }
    } catch (_) {
      await _load();
      if (mounted) context.appWarning('请核对当前申请状态后再重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final detail = _detail;
    return Scaffold(
      appBar: UtenAppBar(
        title: '允许超产比例审批',
        leading: UtenBackButton(
          onPressed: () => popOrBackTo(
            context,
            defaultPath:
                locationAllowedFor(
                  ref.read(currentPermissionsProvider),
                  ref.read(isSuperAdminProvider),
                  RouteName.productionOverproductionRateRequests,
                )
                ? RouteName.productionOverproductionRateRequests
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
                            '${detail.planNo ?? '—'} · ${detail.segmentCode ?? '—'} · ${productionRateStatus(detail.status)}',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '申请人：${detail.submittedByName ?? '—'}  ·  原因：${detail.reason ?? '—'}',
                          ),
                          if (detail.status == 'PENDING')
                            Text(
                              '当前仍按 ${productionRateText(detail.beforeRate)} 执行，申请 ${productionRateText(detail.requestedRate)} 尚未生效。',
                            ),
                          if (detail.decisionReason?.isNotEmpty == true)
                            Text('处理说明：${detail.decisionReason}'),
                          if (detail.blockingReason?.isNotEmpty == true)
                            Text(
                              detail.blockingReason!,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          const SizedBox(height: 8),
                          const Text('红色删除线为申请前内容，绿色新增行为申请内容。'),
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
                      child: ProductionOverproductionRateRevision(
                        request: detail,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          if (detail.canReturn)
                            OutlinedButton(
                              onPressed:
                                  _busy ||
                                      productionRateRevisionRows(detail) == null
                                  ? null
                                  : () => _decide(false),
                              child: const Text('退回'),
                            ),
                          const SizedBox(width: 12),
                          if (detail.canApprove)
                            FilledButton(
                              onPressed:
                                  _busy ||
                                      productionRateRevisionRows(detail) == null
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
