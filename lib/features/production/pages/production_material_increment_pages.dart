import '../../../core/responsive/compact_presentation.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/inputs/uten_field_hint_icon.dart';
import 'package:uten_imp/components/buttons/uten_refresh_button.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../shared/drafts/form_draft_mixin.dart';
import '../../../shared/drafts/form_draft_field_codec.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/data_display/uten_revision_table.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/data_display/uten_status_cell_color.dart';
import '../../../components/feedback/uten_reviewer_responsibility_notice.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/route_names.dart';
import '../../../core/ui/capsule_nav_metrics.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/measurement/document_quantity.dart';
import '../../../shared/paging/scoped_paged_read_view_mixin.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/list_refresh_provider.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../providers/production_execution_refresh.dart';
import '../models/production_exact_quantity.dart';
import '../widgets/production_review_reason_dialog.dart';
import '../repositories/production_material_increment_repository.dart';
import 'package:uten_imp/components/layout/uten_page_layout.dart';

part 'production_material_increment_create.dart';

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
    extends ConsumerState<ProductionMaterialIncrementListPage>
    with ScopedPagedReadViewMixin<ProductionMaterialIncrementListPage> {
  Future<void> Function()? _activityReturnRead;
  @override
  Future<void> onReadViewResumed() =>
      _activityReturnRead?.call() ?? Future<void>.value();

  PagedResult<ProductionMaterialIncrementRequest>? _data;
  final _tableRows =
      MasterDataTableRowsController<ProductionMaterialIncrementRequest>();
  Object? _acceptedReadQuery;
  String _status = 'PENDING';
  String? _error;
  bool _loading = true;
  int _request = 0;

  @override
  void scopedPagedReadOwnerChanged() => setState(() {
    _request++;
    _tableRows.update(const []);
    _acceptedReadQuery = null;
    _data = null;
    _error = scopedPagedReadRejection?.message;
    _loading = false;
  });
  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  Future<void> _load([int? page, bool useCache = false]) async {
    final request = ++_request;
    final repository = ref.read(productionMaterialIncrementRepositoryProvider);
    final status = _status;
    page ??= _acceptedReadQuery == status
        ? _tableRows.visiblePage ?? _data?.page ?? 1
        : 1;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await readScopedPage<ProductionMaterialIncrementRequest>(
        page,
        query: (repository, status),
        currentQuery: () =>
            (ref.read(productionMaterialIncrementRepositoryProvider), _status),
        useCache: useCache,
        fetchPage: (target) => repository.list(status: status, page: target),
      );
      if (mounted && request == _request) {
        setState(() {
          _data = data;
          _acceptedReadQuery = status;
        });
      }
    } on ApiException catch (error) {
      if (isRetiredViewRead(error)) return;
      if (mounted && request == _request) {
        setState(() => _error = error.message);
      }
    } catch (retiredReadError) {
      if (isRetiredViewRead(retiredReadError)) return;
      if (mounted && request == _request) {
        setState(() => _error = '追加用料申请读取失败，请重试');
      }
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    Future<void> visibleReadReturn() => _load();
    _activityReturnRead = () async {
      await Future<void>.sync(visibleReadReturn);
    };
    ref.onPageResume(
      RouteName.productionMaterialIncrementRequests,
      visibleReadReturn,
      refreshKeys: [productionMaterialIncrementRefreshKey],
    );
    return Scaffold(
      appBar: UtenAppBar(
        title: '追加用料申请',
        leading: UtenBackButton(
          onPressed: () =>
              popOrBackTo(context, defaultPath: RouteName.productionPlanList),
        ),
        actions: [UtenRefreshButton(onRefresh: () => _load())],
      ),
      body: SafeArea(
        child: UtenContentContainer.wide(
          child: Column(
            children: [
              UtenFilterToolbar<String>(
                segments: const [
                  UtenFilterSegment(value: 'ALL', label: '全部'),
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
                  rowsController: _tableRows,
                  expensiveRowMounts: false,
                  tableKey:
                      'features.production.pages.production_material_increment_pages.IncrementListState.build.1',
                  columns: [
                    MasterColumnDef(
                      key: 'status',
                      label: '状态',
                      width: 72,
                      value: (row) => materialIncrementStatus(row.status),
                      // 状态整格底色（ADR-169 逐页显式映射）：待计划部审批=黄
                      // （等外部审批，无异常）/ 已批准=绿 / 已退回=红（驳回）/
                      // 授权已撤销=灰（中性终态）；待核对保持无色纯文本。
                      cellColor: (context, row) {
                        final type = switch (row.status) {
                          'PENDING' => UtenStatusBadgeType.warning,
                          'APPROVED' => UtenStatusBadgeType.success,
                          'RETURNED' => UtenStatusBadgeType.danger,
                          'CANCELLED' => UtenStatusBadgeType.neutral,
                          _ => null,
                        };
                        return type == null
                            ? null
                            : utenStatusBadgeCellColor(type);
                      },
                    ),
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
                  paginationScope: _status,
                  onPageChange: (page) => _load(page, true),
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

  Future<void> _refresh() =>
      UtenBusyOverlay.run(context, title: '正在读取追加用料申请', action: _load);

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
    final compact = UtenCompactPresentation.of(context);
    final decisionActions = <Widget>[
      if (detail != null) ...[
        if (detail.status == 'APPROVED' && workshop)
          OutlinedButton(
            onPressed: () => context.push(RouteName.productionWorkshopTasks),
            child: const Text('查看车间任务'),
          ),
        if (detail.status == 'APPROVED' && !workshop && planner)
          OutlinedButton(
            onPressed: () =>
                context.push(RouteName.productionMaterialIncrementRequests),
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
            onPressed: _busy || !validSnapshots ? null : () => _decide(true),
            child: const Text('审批通过'),
          ),
      ],
    ];
    return Scaffold(
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButtonAnimator: FloatingActionButtonAnimator.noAnimation,
      floatingActionButton: compact && decisionActions.isNotEmpty
          ? UtenFloatingActionGroup(children: decisionActions)
          : null,
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
        actions: [UtenRefreshButton(enabled: !(_busy), onRefresh: _refresh)],
      ),
      body: Stack(
        children: [
          SafeArea(
            child: UtenContentContainer.wide(
              child: detail == null
                  ? Center(
                      child: _error == null
                          ? const CircularProgressIndicator()
                          : TextButton(
                              onPressed: _refresh,
                              child: Text('$_error · 重试'),
                            ),
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        UtenPageEdgePadding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      '${detail.text('planNo')} · ${detail.text('segmentCode')} · ${materialIncrementStatus(detail.status)}',
                                      style: Theme.of(
                                        context,
                                      ).textTheme.titleMedium,
                                    ),
                                  ),
                                  UtenFieldHintIcon(
                                    info: switch (detail.status) {
                                      'APPROVED' =>
                                        '追加用料已批准；到车间任务核对备料与领料进度，实际发料后登记真实耗用。',
                                      'CANCELLED' =>
                                        '本次追加用料授权已撤销；原定额、历史实发与退料记录保留。',
                                      _ => '审批前仍按原有额度领料。',
                                    },
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Text(
                                '申请人：${detail.text('submittedByName')} · 原因：${detail.text('reason')}',
                              ),
                              Text(
                                '本次追加：${detail.text('deltaQty')} ${detail.text('unitName')}',
                              ),
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
                              ? const Center(child: Text('审批时的数据不完整，请刷新核对'))
                              : UtenRevisionTable<Map<String, dynamic>>(
                                  tableKey:
                                      'features.production.pages.production_material_increment_pages.IncrementDetailState.build.1',
                                  bottomContentPadding: compact
                                      ? UtenFloatingActionGroup.scrollClearance
                                      : 0,
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
                        if (!compact)
                          UtenPageEdgePadding(
                            padding: const EdgeInsets.all(16),
                            child: Wrap(
                              alignment: WrapAlignment.end,
                              spacing: 12,
                              runSpacing: 12,
                              children: [...decisionActions],
                            ),
                          ),
                      ],
                    ),
            ),
          ),
          if (_busy) const UtenBusyOverlay(title: '正在处理追加用料申请'),
        ],
      ),
    );
  }
}
