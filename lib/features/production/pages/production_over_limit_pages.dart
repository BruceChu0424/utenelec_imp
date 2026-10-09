import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/data_display/uten_status_cell_color.dart';
import '../../../components/feedback/uten_reviewer_responsibility_notice.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/server_config.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/route_names.dart';
import '../../../core/router/route_access_policy.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/providers/authenticated_scope_provider.dart';
import '../../../shared/providers/list_refresh_provider.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../providers/production_execution_refresh.dart';
import '../repositories/production_over_limit_repository.dart';
import '../widgets/production_review_reason_dialog.dart';

String _quantity(String? value) => value ?? '—';

String _decisionTime(String? value) {
  final parsed = ChinaDateTime.tryParse(value);
  return parsed == null ? '—' : ChinaDateTime.formatDateTime(parsed);
}

class ProductionOverLimitListPage extends ConsumerStatefulWidget {
  const ProductionOverLimitListPage({super.key});
  @override
  ConsumerState<ProductionOverLimitListPage> createState() =>
      _OverLimitListState();
}

class _OverLimitListState extends ConsumerState<ProductionOverLimitListPage> {
  PagedResult<ProductionOverLimitDisposition>? _data;
  String _status = 'PENDING';
  String? _error;
  bool _loading = true;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  void _identityChanged() {
    _request++;
    setState(() {
      _data = null;
      _error = null;
    });
    Future.microtask(_load);
  }

  Future<void> _load([int page = 1]) async {
    if (!mounted) return;
    final request = ++_request;
    final scope = ref.read(authenticatedScopeProvider);
    final server = ref.read(apiBaseUrlProvider);
    bool current() =>
        mounted &&
        request == _request &&
        ref.read(authenticatedScopeProvider) == scope &&
        ref.read(apiBaseUrlProvider) == server;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await ref
          .read(productionOverLimitRepositoryProvider)
          .list(status: _status, page: page);
      if (current()) setState(() => _data = data);
    } on ApiException catch (error) {
      if (current()) setState(() => _error = error.message);
    } catch (_) {
      if (current()) setState(() => _error = '超限产出列表读取失败，请重试');
    } finally {
      if (current()) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(authenticatedScopeProvider, (_, _) => _identityChanged());
    ref.listen(apiBaseUrlProvider, (_, _) => _identityChanged());
    ref.onPageResume(
      RouteName.productionOverLimitDispositions,
      () => _load(_data?.page ?? 1),
      refreshKeys: [productionOverLimitRefreshKey],
    );
    return Scaffold(
      appBar: UtenAppBar(
        title: '超限产出处置',
        leading: UtenBackButton(
          onPressed: () =>
              popOrBackTo(context, defaultPath: RouteName.productionPlanList),
        ),
        actions: [
          IconButton(
            onPressed: _loading ? null : () => _load(_data?.page ?? 1),
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
                  UtenFilterSegment(value: 'PENDING', label: '待处理'),
                  UtenFilterSegment(value: 'ACCEPTED', label: '已批准'),
                  UtenFilterSegment(value: 'WITHDRAWN', label: '已撤回'),
                  UtenFilterSegment(value: 'ALL', label: '全部'),
                ],
                selected: {_status},
                onSelectionChanged: (value) {
                  setState(() {
                    _status = value;
                    _data = null;
                  });
                  _load();
                },
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text('额度内产出继续原流程。这里处理同批超出有效额度的实物，批准不代表品质合格或已入库。'),
              ),
              Expanded(
                child: MasterDataTableView<ProductionOverLimitDisposition>(
                  tableKey: 'production.over-limit-dispositions',
                  facets: const {},
                  filters: const {},
                  nullCounts: const {},
                  onFilterChanged: (_, _) {},
                  columns: [
                    MasterColumnDef(
                      key: 'status',
                      label: '状态',
                      width: 125,
                      value: (row) => productionOverLimitStatus(row.status),
                      // 状态整格底色（ADR-169 逐页显式映射，按本页处置流语义）：
                      // 待处理=黄（等计划部处置，无异常）/ 继续待处理=橙（处置人
                      // 已过手仍保留待处理——超限悬而未决的风险中间态，与待处理
                      // 黄区分）/ 待核实=红（退回申报方核实，退回家族）/ 已批准
                      // 转公共=绿 / 日报草稿·已撤回=灰（中性）；未知文案无色。
                      cellColor: (context, row) {
                        final type = switch (row.status) {
                          'PENDING' => UtenStatusBadgeType.warning,
                          'HELD' => UtenStatusBadgeType.orange,
                          'RETURNED' => UtenStatusBadgeType.danger,
                          'ACCEPTED' => UtenStatusBadgeType.success,
                          'DRAFT' || 'WITHDRAWN' => UtenStatusBadgeType.neutral,
                          _ => null,
                        };
                        return type == null
                            ? null
                            : utenStatusBadgeCellColor(type);
                      },
                    ),
                    MasterColumnDef(
                      key: 'reportNo',
                      label: '日报号',
                      width: 170,
                      value: (row) => row.reportNo,
                    ),
                    MasterColumnDef(
                      key: 'planNo',
                      label: '计划号',
                      width: 150,
                      value: (row) => row.planNo,
                    ),
                    MasterColumnDef(
                      key: 'segmentCode',
                      label: '工单号',
                      width: 150,
                      value: (row) => row.segmentCode,
                    ),
                    MasterColumnDef(
                      key: 'goodsName',
                      label: '货品名称',
                      width: 210,
                      value: (row) => row.goodsName,
                    ),
                    MasterColumnDef(
                      key: 'goodsCode',
                      label: '编号',
                      width: 130,
                      value: (row) => row.goodsCode,
                    ),
                    MasterColumnDef(
                      key: 'colorName',
                      label: '颜色',
                      width: 90,
                      value: (row) => row.colorName,
                    ),
                    MasterColumnDef(
                      key: 'unitName',
                      label: '单位',
                      width: 75,
                      value: (row) => row.unitName,
                    ),
                    MasterColumnDef(
                      key: 'actual',
                      label: '本批实际',
                      width: 115,
                      type: 'number',
                      value: (row) => _quantity(row.actualBatchQty),
                    ),
                    MasterColumnDef(
                      key: 'within',
                      label: '额度内',
                      width: 110,
                      type: 'number',
                      value: (row) => _quantity(row.withinAuthorizationQty),
                    ),
                    MasterColumnDef(
                      key: 'over',
                      label: '本次超限',
                      width: 110,
                      type: 'number',
                      value: (row) => _quantity(row.overLimitQty),
                    ),
                    MasterColumnDef(
                      key: 'reason',
                      label: '超限原因',
                      width: 240,
                      value: (row) => row.overLimitReason,
                    ),
                  ],
                  items: _data?.items ?? const [],
                  isLoading: _loading,
                  error: _error,
                  onRetry: () => _load(_data?.page ?? 1),
                  onRowTap: (row) => context.push(
                    RoutePath.productionOverLimitDisposition(row.id),
                  ),
                  currentPage: _data?.page ?? 1,
                  totalPages: _data?.totalPages ?? 0,
                  paginationScope: _status,
                  onPageChange: _load,
                  emptyMessage: '没有符合条件的超限产出',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ProductionOverLimitDetailPage extends ConsumerStatefulWidget {
  const ProductionOverLimitDetailPage({super.key, required this.id});
  final String id;
  @override
  ConsumerState<ProductionOverLimitDetailPage> createState() =>
      _OverLimitDetailState();
}

class _OverLimitDetailState
    extends ConsumerState<ProductionOverLimitDetailPage> {
  ProductionOverLimitDisposition? _detail;
  String? _error;
  String _reason = '';
  bool _loading = true;
  bool _busy = false;
  int _request = 0;
  int _identityRevision = 0;

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  @override
  void didUpdateWidget(covariant ProductionOverLimitDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.id != widget.id) _identityChanged();
  }

  void _identityChanged() {
    _request++;
    _identityRevision++;
    setState(() {
      _detail = null;
      _reason = '';
      _error = null;
      _busy = false;
    });
    Future.microtask(_load);
  }

  Future<void> _load() async {
    if (!mounted) return;
    final request = ++_request;
    final id = widget.id;
    final scope = ref.read(authenticatedScopeProvider);
    final server = ref.read(apiBaseUrlProvider);
    bool current() =>
        mounted &&
        request == _request &&
        id == widget.id &&
        ref.read(authenticatedScopeProvider) == scope &&
        ref.read(apiBaseUrlProvider) == server;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final detail = await ref
          .read(productionOverLimitRepositoryProvider)
          .detail(id);
      if (current() && detail.id == id) setState(() => _detail = detail);
    } on ApiException catch (error) {
      if (current()) setState(() => _error = error.message);
    } catch (_) {
      if (current()) setState(() => _error = '超限产出读取失败，请重试');
    } finally {
      if (current()) setState(() => _loading = false);
    }
  }

  bool get _canDecide =>
      _detail?.canDecide == true &&
      ref.read(authenticatedScopeProvider) != null &&
      ref.read(authenticatedScopeProvider)?.readOnly != true &&
      (ref.read(isSuperAdminProvider) ||
          ref
              .read(currentPermissionsProvider)
              .contains(Perm.productionPlanApprove));

  Future<void> _decide(String action) async {
    final detail = _detail;
    if (_busy || _loading || detail == null || !_canDecide) return;
    final scope = ref.read(authenticatedScopeProvider);
    final server = ref.read(apiBaseUrlProvider);
    final identityRevision = _identityRevision;
    bool current() =>
        mounted &&
        identityRevision == _identityRevision &&
        widget.id == detail.id &&
        ref.read(authenticatedScopeProvider) == scope &&
        ref.read(apiBaseUrlProvider) == server;
    final reason = await showProductionReviewReasonDialog(
      context,
      title: productionOverLimitAction(action),
      initialValue: _reason,
      onDraftChanged: (value) {
        if (current()) _reason = value;
      },
    );
    if (reason == null ||
        !mounted ||
        !current() ||
        !_canDecide ||
        _detail?.rowVersion != detail.rowVersion) {
      return;
    }
    final accepted = action == 'ACCEPT_PUBLIC';
    final confirmed = await showUtenReviewerConfirmDialog(
      context,
      message: accepted
          ? '接收本批超限 ${_quantity(detail.overLimitQty)} ${detail.unitName ?? ''} 为公共产出，之后仍须按原品质和实收流程办理。原需求和有效比例不变。'
          : '本批超限 ${_quantity(detail.overLimitQty)} ${detail.unitName ?? ''} 继续待处理。${action == 'RETURN_FOR_REVIEW' ? '通知申报方核实；实际数量不变，修正仍走原单反向流程。' : '记录继续待处理的原因，不增加可用库存。'}',
    );
    if (confirmed != true ||
        !mounted ||
        !current() ||
        !_canDecide ||
        _detail?.rowVersion != detail.rowVersion) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final updated = await ref
          .read(productionOverLimitRepositoryProvider)
          .decide(detail, action: action, reason: reason);
      if (!mounted || !current()) return;
      setState(() {
        _detail = updated;
        _reason = '';
      });
      bumpListRefresh(ref, productionOverLimitRefreshKey);
      refreshAfterProductionPlanGenerated(ref);
      context.appInfo(accepted ? '已批准为公共产出，后续按品质与实收结果办理' : '处理意见已记录，超限产出继续待处理');
    } on ApiException catch (error) {
      if (!current()) return;
      await _load();
      if (current()) setState(() => _error = '${error.message}；处理原因已保留');
    } catch (_) {
      if (!current()) return;
      await _load();
      if (current()) setState(() => _error = '处理结果尚未确认，请核对当前状态后重试；处理原因已保留');
    } finally {
      if (current()) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(authenticatedScopeProvider, (_, _) => _identityChanged());
    ref.listen(apiBaseUrlProvider, (_, _) => _identityChanged());
    ref.watch(currentPermissionsProvider);
    final detail = _detail;
    final canDecide = _canDecide;
    final permissions = ref.watch(currentPermissionsProvider);
    final admin = ref.watch(isSuperAdminProvider);
    final backRoute =
        [
              RouteName.productionOverLimitDispositions,
              RouteName.productionWorkshopTasks,
              RouteName.productionDailyReportList,
              RouteName.productionPlanList,
            ]
            .where((route) => locationAllowedFor(permissions, admin, route))
            .firstOrNull ??
        RouteName.dashboard;
    return Scaffold(
      appBar: UtenAppBar(
        title: '超限产出处置',
        leading: UtenBackButton(
          onPressed: () => popOrBackTo(context, defaultPath: backRoute),
        ),
        actions: [
          IconButton(
            onPressed: _busy || _loading ? null : _load,
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
          ),
        ],
      ),
      body: SafeArea(
        child: UtenContentContainer.wide(
          child: detail == null
              ? Center(
                  child: _loading
                      ? const CircularProgressIndicator()
                      : TextButton(
                          onPressed: _load,
                          child: Text('${_error ?? '记录未读取'} · 重试'),
                        ),
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_loading || _busy) const LinearProgressIndicator(),
                      Text(
                        '${detail.goodsName ?? '产出'} · ${productionOverLimitStatus(detail.status)}',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        '编号 ${detail.goodsCode ?? '—'} · 颜色 ${detail.colorName ?? '—'}',
                      ),
                      Text(
                        '日报 ${detail.reportNo ?? '—'} · 计划 ${detail.planNo ?? '—'} · 工单 ${detail.segmentCode ?? '—'}',
                      ),
                      const SizedBox(height: 16),
                      Text(
                        '原计划 ${_quantity(detail.quantity('plannedQty'))} · 报工时允许超产比例 ${detail.allowedRatePercent == null ? '—' : '${detail.allowedRatePercent}%'}',
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '本批实际 ${_quantity(detail.actualBatchQty)} · 额度内 ${_quantity(detail.withinAuthorizationQty)} · 本次超限 ${_quantity(detail.overLimitQty)} ${detail.unitName ?? ''}',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 12),
                      Text('超限原因：${detail.overLimitReason ?? '—'}'),
                      if (detail.text('decisionReason')?.isNotEmpty ==
                          true) ...[
                        const SizedBox(height: 12),
                        Text('最新处理：${detail.text('decisionReason')}'),
                        Text(
                          '处理人：${detail.text('decidedByName') ?? '—'} · ${_decisionTime(detail.text('decidedAt'))}',
                        ),
                      ],
                      const SizedBox(height: 12),
                      const Text(
                        '额度内产出继续原品质和交接流程。超限部分在批准前保持待处理；批准后仍以品质结果与仓库实收形成库存。',
                      ),
                      if (detail.blockingReason?.isNotEmpty == true)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text(detail.blockingReason!),
                        ),
                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text(
                            _error!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
                      const SizedBox(height: 24),
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          if (detail.reportId != null &&
                              locationAllowedFor(
                                permissions,
                                admin,
                                '/production/daily-reports/${detail.reportId}',
                              ))
                            OutlinedButton(
                              onPressed: _busy
                                  ? null
                                  : () => context.push(
                                      '/production/daily-reports/${detail.reportId}',
                                    ),
                              child: const Text('查看原日报'),
                            ),
                          if (canDecide) ...[
                            FilledButton(
                              onPressed: _busy || _loading
                                  ? null
                                  : () => _decide('ACCEPT_PUBLIC'),
                              child: const Text('接收为公共产出'),
                            ),
                            OutlinedButton(
                              onPressed: _busy || _loading
                                  ? null
                                  : () => _decide('HOLD'),
                              child: const Text('继续待处理'),
                            ),
                            OutlinedButton(
                              onPressed: _busy || _loading
                                  ? null
                                  : () => _decide('RETURN_FOR_REVIEW'),
                              child: const Text('要求核实（保持待处理）'),
                            ),
                          ],
                        ],
                      ),
                      if (detail.decisionHistory.isNotEmpty) ...[
                        const SizedBox(height: 24),
                        Text(
                          '处理记录',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        for (final decision in detail.decisionHistory)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Text(
                              '${productionOverLimitAction(decision['action'] as String? ?? '')} · ${decision['decidedByName'] ?? '—'} · ${_decisionTime(decision['decidedAt'] as String?)}\n${decision['reason'] ?? ''}',
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
        ),
      ),
    );
  }
}
