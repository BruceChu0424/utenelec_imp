import 'package:flutter/foundation.dart' show setEquals;
import '../../../core/network/server_config.dart';
import '../../../core/ui/human_error_message.dart';
import '../../../shared/providers/authenticated_scope_provider.dart';
import '../../../shared/drafts/review_task_draft.dart';
import '../../../shared/concurrency/task_claim_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/buttons/uten_refresh_button.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_inline_notice.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/data_display/uten_status_cell_color.dart';
import '../../../core/network/api_client.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/badges/badge_registry.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/providers/session_provider.dart';
import '../../../shared/widgets/finance_review_claim_notice.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/sales_review/sales_order_review_repository.dart';

class SalesManagerReviewTask {
  SalesManagerReviewTask.fromJson(Map<String, dynamic> json)
    : id = json['id'] as String,
      kind = json['kind'] as String? ?? 'order',
      state = json['state'] as String? ?? 'PENDING',
      billNo = json['billNo'] as String? ?? '',
      billDate = json['billDate'] as String? ?? '',
      client = json['clientName'] as String? ?? '',
      seller = json['sellerName'] as String? ?? '',
      currency = json['currencyName'] as String? ?? '',
      amount = json['totalOriginal']?.toString() ?? '',
      revision = (json['revision'] as num).toInt(),
      reason = json['reason'] as String? ?? '',
      approver = json['approvedByName'] as String? ?? '',
      approvedAt = json['approvedAt'] as String? ?? '';
  final String id,
      kind,
      state,
      billNo,
      billDate,
      client,
      seller,
      currency,
      amount;
  String get stateLabel => switch (state) {
    'APPROVED' => '负责人已通过',
    'REJECTED' => '负责人已驳回',
    _ => '等待销售负责人审核',
  };
  final String reason, approver, approvedAt;
  final int revision;
  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind,
    'state': state,
    'billNo': billNo,
    'billDate': billDate,
    'clientName': client,
    'sellerName': seller,
    'currencyName': currency,
    'totalOriginal': amount,
    'revision': revision,
    'reason': reason,
    'approvedByName': approver,
    'approvedAt': approvedAt,
  };
}

/// One queue for management's two document types; details share the established review pages.
class SalesManagerReviewPage extends ConsumerStatefulWidget {
  const SalesManagerReviewPage({
    super.key,
    this.initialKind = 'quote',
    this.embedded = false,
    this.initialHistory = false,
    this.historyOnly = false,
  });
  final String initialKind;
  final bool embedded;
  final bool initialHistory;
  final bool historyOnly;
  @override
  ConsumerState<SalesManagerReviewPage> createState() =>
      _SalesManagerReviewPageState();
}

class _SalesManagerReviewPageState extends ConsumerState<SalesManagerReviewPage>
    with
        FormDraftMixin<SalesManagerReviewPage>,
        ReviewTaskDraftMixin<SalesManagerReviewPage> {
  List<SalesManagerReviewTask> _batchTasks = [];
  TaskClaimSession? _batchClaim;
  final _batchRemark = TextEditingController();
  final _taskCache = <String, SalesManagerReviewTask>{};
  @override
  bool get formDraftBusy => _busy;
  @override
  FormDraftDescriptor get reviewDraftDescriptor =>
      FormDraftCatalog.salesManagerOrderBatch;
  @override
  String get reviewDraftRoute => '/sales/manager-review?kind=order';
  @override
  Map<String, dynamic> get reviewDraftSource => {
    'subjectId': 'sales-manager-order-batch',
    'orders': _batchTasks.map((row) => row.toJson()).toList(),
  };
  @override
  bool get reviewDraftEditable =>
      _batchTasks.isNotEmpty && _allowed('order', 'confirm');
  @override
  bool canDispatchReviewCommand(String action) =>
      action == 'confirmBatch' &&
      reviewDraftEditable &&
      formDraftIdentityIsCurrent &&
      !formDraftRestorationBlocked &&
      _batchClaim?.isReady == true;
  @override
  Map<String, dynamic> captureReviewInputs() => {'remark': _batchRemark.text};
  @override
  Iterable<Listenable> get formDraftListenables => [_batchRemark];
  @override
  void restoreReviewInputs(Map<String, dynamic> inputs) {
    _batchRemark.text = inputs['remark'] as String? ?? '';
  }

  @override
  Future<void> restoreFormDraft(Map<String, dynamic> data) async {
    final source = data['source'];
    if (source is Map &&
        source['subjectId'] == 'sales-manager-order-batch' &&
        source['orders'] is List) {
      _batchTasks = (source['orders'] as List)
          .map(
            (row) => SalesManagerReviewTask.fromJson(
              Map<String, dynamic>.from(row as Map),
            ),
          )
          .toList();
    }
    await super.restoreFormDraft(data);
  }

  @override
  Future<void> reloadReviewSource() => _reload();
  @override
  Future<bool> recoverReviewCommand(Map<String, dynamic> command) async {
    if (command['action'] != 'confirmBatch' || command['request'] is! Map) {
      return false;
    }
    final request = command['request'] as Map;
    final revisions = request['expectedRevisions'],
        leases = request['expectedClaimIds'],
        ids = request['orderIds'];
    if (ids is! List || revisions is! Map || leases is! Map || ids.isEmpty) {
      return false;
    }
    final repo = ref.read(salesManagerOrderReviewRepositoryProvider);
    for (final id in ids.cast<String>()) {
      final result = await repo.review(id);
      if (!result.financeConfirmed ||
          result.financeReviewRevision != (revisions[id] as int) + 1 ||
          result.managerDecisionClaimId == null ||
          result.managerDecisionClaimId != leases[id] ||
          (result.financeConfirmRemark ?? '').trim() !=
              (request['remark'] as String? ?? '').trim()) {
        return false;
      }
    }
    return true;
  }

  @override
  void closeRecoveredReview() {
    _batchTasks = [];
    _reload();
  }

  final _search = TextEditingController();
  final String _kind = 'all';
  String _state = 'PENDING';
  final Map<String, String> _filters = {};
  PagedResult<SalesManagerReviewTask>? _result;
  final Set<String> _selected = {};
  int _generation = 0;
  int _tableRevision = 0;
  bool _loading = false, _busy = false;
  bool _buttonReading = false, _batchWaiting = false;
  bool get _unknownSubmission => formDraftHasUnknownSubmission;
  String? _error;
  bool _allowed(String kind, String action) =>
      (action == 'view' || !ref.read(sessionProvider).impersonationReadOnly) &&
      (ref.read(isSuperAdminProvider) ||
          ref
              .read(currentPermissionsProvider)
              .contains('sales_${kind}_manager:$action'));
  @override
  void initState() {
    super.initState();
    _state = widget.initialHistory ? 'HISTORY' : 'PENDING';
    startFormDraftIdentityGuard();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _reload(clear: true);
      if (mounted) await bindReviewDraft();
    });
  }

  @override
  void dispose() {
    ++_generation;
    _batchClaim?.releaseAll().ignore();
    _batchRemark.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _reload({int page = 1, bool clear = false}) async {
    if (!mounted) return;
    final generation = ++_generation;
    final identity = ref.read(sessionProvider);
    final server = ref.read(apiBaseUrlProvider);
    final scope = ref.read(authenticatedScopeProvider);
    final permissions = Set<String>.of(ref.read(currentPermissionsProvider));
    bool current() =>
        mounted &&
        generation == _generation &&
        ref.read(sessionProvider).isSameIdentity(identity) &&
        ref.read(apiBaseUrlProvider) == server &&
        ref.read(authenticatedScopeProvider) == scope &&
        setEquals(permissions, ref.read(currentPermissionsProvider));
    final kind = _kind, state = _state;
    setState(() {
      _loading = true;
      _error = null;
      if (clear) {
        _result = null;
        _selected.clear();
        _taskCache.clear();
      }
    });
    try {
      final json = await ref
          .read(apiClientProvider)
          .get(
            '/sales/manager-review',
            query: {
              'kind': kind,
              'state': state,
              'keyword': _search.text.trim(),
              'page': page,
              'size': 30,
              ..._filters,
            },
          );
      final result = await PagedResult.fromJsonResponsive(
        json,
        SalesManagerReviewTask.fromJson,
      );
      if (!current() ||
          !(_allowed('quote', 'view') || _allowed('order', 'view'))) {
        return;
      }
      setState(() {
        _result = result;
        for (final row in result.items.where((row) => row.kind == 'order')) {
          if (_selected.contains(row.id) &&
              _taskCache[row.id]?.revision != row.revision) {
            _selected.remove(row.id);
          }
          _taskCache[row.id] = row;
        }
        final visible = result.items.map((row) => row.id).toSet();
        while (_taskCache.length > 1000) {
          final removable = _taskCache.keys
              .where((id) => !_selected.contains(id) && !visible.contains(id))
              .firstOrNull;
          if (removable == null) {
            break;
          }
          _taskCache.remove(removable);
        }
      });
    } catch (error) {
      if (current()) {
        setState(() => _error = humanErrorMessage(error) ?? '读取审核队列失败，请重试');
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _reloadFromButton() async {
    if (_buttonReading || _busy) return;
    setState(() => _buttonReading = true);
    try {
      await _reload(page: _result?.page ?? 1);
    } finally {
      if (mounted) setState(() => _buttonReading = false);
    }
  }

  Future<void> _open(SalesManagerReviewTask task) async {
    await context.push(
      '/sales/manager-review/${task.kind}s/${Uri.encodeComponent(task.id)}',
    );
    if (mounted) {
      if (task.kind == 'order') {
        _selected.remove(task.id);
        _taskCache.remove(task.id);
      }
      _tableRevision++;
      refreshBadges(ref);
      await _reload(page: _result?.page ?? 1);
    }
  }

  Future<void> _batch() async {
    if (_busy ||
        _loading ||
        _unknownSubmission ||
        !formDraftIdentityIsCurrent ||
        !_allowed('order', 'confirm')) {
      return;
    }
    if (_selected.length > 100) {
      context.appWarning('一次最多批准 100 笔订单，请减少选择后重试');
      return;
    }
    final idsToReview = _selected.toList()..sort();
    final tasks = idsToReview
        .map((id) => _taskCache[id])
        .whereType<SalesManagerReviewTask>()
        .toList();
    if (tasks.length != _selected.length) {
      context.appWarning('所选单据的内容需要重新读取，请刷新后核对');
      return;
    }
    if (tasks.isEmpty) return;
    final container = ProviderScope.containerOf(context, listen: false);
    final identity = container.read(sessionProvider);
    final server = container.read(apiBaseUrlProvider);
    final scope = container.read(authenticatedScopeProvider);
    bool current() =>
        mounted &&
        formDraftIdentityIsCurrent &&
        container.read(sessionProvider).isSameIdentity(identity) &&
        container.read(apiBaseUrlProvider) == server &&
        container.read(authenticatedScopeProvider) == scope;
    final claim = financeReviewClaim(container);
    _batchTasks = tasks;
    _batchClaim = claim;
    await bindReviewDraft();
    if (!mounted ||
        formDraftHasUnknownSubmission ||
        formDraftRestorationBlocked) {
      return;
    }
    setState(() {
      _busy = true;
      _batchWaiting = true;
    });
    try {
      await claim.claimAll(
        'SALES_ORDER_MANAGER_REVIEW',
        tasks.map((row) => row.id).toList(),
      );
      if (!mounted || !claim.isCurrent || !claim.isReady) {
        if (mounted) {
          context.appWarning(claim.failureMessage ?? '未取得全部订单的审核占用，请刷新');
        }
        return;
      }
      final accepted = await UtenBusyOverlay.yieldWhile(
        () => showDialog<bool>(
          context: context,
          builder: (context) => UtenAlertDialog(
            title: const Text('批量批准订货单'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '确认已经逐单核对所选 ${tasks.length} 笔订货单？全部通过后才会转交财务；任一单据冲突时整批不提交。',
                ),
                const SizedBox(height: UtenSpacing.s12),
                TextField(
                  key: const Key('manager-batch-remark'),
                  controller: _batchRemark,
                  maxLength: 500,
                  decoration: const InputDecoration(labelText: '审核备注（选填）'),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('返回核对'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('批准并转交财务'),
              ),
            ],
          ),
        ),
      );
      if (accepted != true ||
          !mounted ||
          !current() ||
          !_allowed('order', 'confirm')) {
        return;
      }
      if (!await claim.validateForDecision()) return;
      if (!mounted || !claim.isCurrent || !claim.isReady) return;
      final revisions = {for (final row in tasks) row.id: row.revision};
      final leases = {
        for (final row in tasks)
          row.id: claim.claimIdFor('SALES_ORDER_MANAGER_REVIEW', row.id)!,
      };
      final ids = tasks.map((row) => row.id).toList();
      final remark = _batchRemark.text.trim();
      await submitReviewCommand(
        'confirmBatch',
        () => container
            .read(salesManagerOrderReviewRepositoryProvider)
            .confirmBatch(
              ids,
              expectedRevisions: revisions,
              expectedClaimIds: leases,
              remark: remark,
            ),
        request: {
          'orderIds': ids,
          'expectedRevisions': revisions,
          'expectedClaimIds': leases,
          'remark': remark,
        },
      );
      if (!current()) {
        return;
      }
      _selected.clear();
      _tableRevision++;
      _batchTasks = [];
      _batchRemark.clear();
      await finishReviewDraft(keepEditing: true);
      if (!mounted || !current()) {
        return;
      }
      setState(() => _batchWaiting = false);
      context.appSuccess('所选订单已批准，已转交财务');
      refreshBadges(ref);
      await _reload();
    } catch (error) {
      if (mounted && current()) {
        setState(() {
          _error = humanErrorMessage(error) ?? '审核暂未完成，请核对当前结果';
        });
        setState(() => _batchWaiting = false);
        context.appWarning(
          formDraftHasUnknownSubmission
              ? '尚未确认批量审核结果，请刷新并核对已通过记录后继续。'
              : humanErrorMessage(error) ?? '审核暂未完成，请核对当前结果',
        );
      }
    } finally {
      await claim.releaseAll();
      if (mounted) {
        setState(() {
          _busy = false;
          _batchWaiting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(sessionProvider, (previous, next) {
      if (previous != null && !next.isSameIdentity(previous)) {
        _reload(clear: true);
      }
    });
    ref.listen(currentPermissionsProvider, (previous, next) {
      if (!setEquals(previous, next)) {
        _reload(clear: true);
      }
    });
    ref.listen(apiBaseUrlProvider, (previous, next) {
      if (previous != next) {
        _reload(clear: true);
      }
    });
    ref.listen(authenticatedScopeProvider, (previous, next) {
      if (previous != next) {
        _reload(clear: true);
      }
    });
    final columns = <MasterColumnDef<SalesManagerReviewTask>>[
      MasterColumnDef(
        key: 'state',
        label: '状态',
        width: 180,
        columnSearchEnabled: true,
        value: (r) => r.stateLabel,
        cellColor: (_, r) => utenStatusBadgeCellColor(switch (r.state) {
          'APPROVED' => UtenStatusBadgeType.success,
          'REJECTED' => UtenStatusBadgeType.danger,
          _ => UtenStatusBadgeType.warning,
        }),
      ),
      MasterColumnDef(
        key: 'kind',
        label: '单据类型',
        width: 100,
        columnSearchEnabled: true,
        value: (r) => r.kind == 'quote' ? '报价单' : '订货单',
      ),
      MasterColumnDef(
        key: 'billNo',
        label: '单据号',
        width: 165,
        value: (r) => r.billNo,
      ),
      MasterColumnDef(
        key: 'client',
        label: '客户',
        width: 190,
        value: (r) => r.client,
      ),
      MasterColumnDef(
        key: 'seller',
        label: '业务员',
        width: 100,
        value: (r) => r.seller,
      ),
      MasterColumnDef(
        key: 'billDate',
        type: 'date',
        columnSearchEnabled: true,
        label: '单据日期',
        width: 110,
        value: (r) => r.billDate,
      ),
      MasterColumnDef(
        key: 'amount',
        label: '单据金额',
        type: 'money',
        columnSearchEnabled: true,
        width: 145,
        value: (r) => '${r.currency} ${r.amount}',
        aiSensitive: true,
      ),
      if (_state == 'HISTORY')
        MasterColumnDef(
          key: 'reason',
          label: '驳回原因',
          width: 300,
          value: (r) => r.reason,
        ),
      if (_state == 'HISTORY') ...[
        MasterColumnDef(
          key: 'approver',
          label: '负责人审核人',
          width: 120,
          value: (r) => r.approver,
        ),
        MasterColumnDef(
          key: 'approvedAt',
          type: 'date',
          columnSearchEnabled: true,
          label: '批准时间',
          width: 190,
          value: (r) => r.approvedAt,
        ),
      ],
    ];
    return withFormDraft(
      Scaffold(
        appBar: widget.embedded
            ? null
            : UtenAppBar(
                title: '订单审批',
                info: '销售提交后由销售负责人审核，再交财务审核。驳回时须填写修改原因。',
                leading: const UtenBackButton(),
                actions: [
                  UtenRefreshButton(
                    key: const Key('sales-manager-review-refresh'),
                    busy: _loading,
                    enabled: !_busy,
                    onRefresh: _reloadFromButton,
                  ),
                ],
              ),
        body: Stack(
          children: [
            Padding(
              // 嵌入审批中心时水平边距由页面容器统一提供（父分类行与正文同缘），
              // 顶部间距走父行统一 rowGap；独立页保留四周 16。
              padding: widget.embedded
                  ? const EdgeInsets.only(bottom: UtenSpacing.s16)
                  : const EdgeInsets.all(UtenSpacing.s16),
              child: UtenCollapsingHeaderScrollView(
                collapsingHeader: Column(
                  children: [
                    UtenFilterToolbar<String>(
                      enabled: !_busy,
                      autoSelectBadge: false,
                      segmentsKey: const Key('sales-review-categories'),
                      trailing: widget.embedded
                          ? UtenRefreshButton(
                              onRefresh: _reloadFromButton,
                              busy: _buttonReading,
                              enabled: !_busy,
                            )
                          : null,
                      searchKey: const Key('sales-review-search'),
                      segments: const [
                        UtenFilterSegment(value: 'PENDING', label: '待审核'),
                        UtenFilterSegment(value: 'HISTORY', label: '历史记录'),
                      ],
                      selected: {_state},
                      onSelectionChanged: (value) {
                        if (_busy) return;
                        _state = value;
                        _filters.clear();
                        _reload(clear: true);
                      },
                      searchController: _search,
                      searchHint: '搜索单据号、客户或业务员',
                      onSearchInputChanged: (_) {
                        if (!_busy) ++_generation;
                      },
                      onSearchChanged: (_) {
                        if (!_busy) _reload(clear: true);
                      },
                    ),
                    const SizedBox(height: UtenSpacing.s12),
                  ],
                ),
                body: Column(
                  children: [
                    if (_unknownSubmission)
                      const UtenInlineNotice(
                        message: '提交结果尚未确认。请刷新核对，当前不会重复提交。',
                      ),
                    Expanded(
                      child: MasterDataTableView<SalesManagerReviewTask>(
                        primary: true,
                        columns: columns,
                        items: _result?.items ?? [],
                        facets: const {},
                        nullCounts: const {},
                        filters: _filters,
                        serverColumnSearch: true,
                        onFilterChanged: (key, value) {
                          if (_busy || !key.startsWith('search.')) return;
                          if (value == null || value.isEmpty) {
                            _filters.remove(key);
                          } else {
                            _filters[key] = value;
                          }
                          _reload(clear: true);
                        },
                        rowKeyOf: (r) => '${r.kind}:${r.id}',
                        idOf: (r) =>
                            r.kind == 'order' &&
                                r.state == 'PENDING' &&
                                _allowed('order', 'confirm')
                            ? r.id
                            : null,
                        selectable:
                            _state == 'PENDING' && _allowed('order', 'confirm'),
                        batchActionsBuilder:
                            _state == 'PENDING' && _allowed('order', 'confirm')
                            ? (_, ids) => [
                                UtenButton(
                                  key: const Key('sales-manager-batch-approve'),
                                  type: UtenButtonType.danger,
                                  size: UtenButtonSize.large,
                                  onPressed:
                                      _busy ||
                                          _loading ||
                                          _unknownSubmission ||
                                          ids.isEmpty
                                      ? null
                                      : _batch,
                                  icon: Icons.done_all,
                                  child: const Text('批量批准'),
                                ),
                              ]
                            : null,
                        selectedIds: _selected,
                        onSelectedIdsChanged: _busy
                            ? null
                            : (ids) => setState(() {
                                _selected
                                  ..clear()
                                  ..addAll(ids);
                              }),
                        onRowTap: _open,
                        onRowDoubleTap: _open,
                        isLoading: _loading && _result == null,
                        isRefreshing: _loading && _result != null,
                        error: _result == null ? _error : null,
                        refreshError: _result != null ? _error : null,
                        onRetry: _reloadFromButton,
                        paginationRevision: _tableRevision,
                        paginationScope: (
                          _kind,
                          _state,
                          _search.text.trim(),
                          Object.hashAll(
                            _filters.entries.map((e) => '${e.key}:${e.value}'),
                          ),
                          ref.watch(apiBaseUrlProvider),
                          ref.watch(authenticatedScopeProvider),
                          _allowed('quote', 'view'),
                          _allowed('order', 'view'),
                        ),
                        currentPage: _result?.page ?? 1,
                        totalPages: _result?.totalPages ?? 1,
                        onPageChange: _busy
                            ? null
                            : (page) => _reload(page: page),
                        emptyMessage: '当前分类没有需要处理的单据',
                        tableKey: 'sales_manager_review_all.2',
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (_buttonReading || _batchWaiting)
              const UtenBusyOverlay(
                title: '正在处理订单审批',
                showDoNotLeaveHint: false,
              ),
          ],
        ),
      ),
    );
  }
}
