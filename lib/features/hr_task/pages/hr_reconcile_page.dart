// 员工资料核对更正页(ADR-160)：证件核对页(列表页)勾选 N 人「批量核对(N)」进入，
// ?employeeIds=…&returnTo=/hr/tasks/identity。
//
// 流程：
//  1) 带 employeeIds 进入 → busy「正在生成核对计划…」POST /plans/id-repair，
//     成功后 pushReplacement 换成 ?planId=…&employeeIds=…&returnTo=…(保留
//     employeeIds 供过期后「重新核对」；State 随换参保留，已生成的计划不重读)；
//  2) 带 planId 进入(生成后的深链/核对记录回看) → GET /plans/{id}；
//  3) 每人一行：旧证件号(UtenRevisionCell 红删除线) + 修复建议/候选/需人工，
//     人事逐行确认——采用建议(HIGH 预选)/点候选 chip/手输号码(即时校验红字)；
//     行草稿(手输 controller + 采用状态)存页面 State，滚动/分段不丢；
//  4) 右下角「确认更正 N 人 M 处」→ UtenDialog 确认 → 输登录密码由网络层
//     StepUpInterceptor 自动弹(apply 先回 403 REAUTH_REQUIRED，拦截器弹
//     ReauthDialog 并重放，ReauthDialog 内部用 UtenBusyOverlay.yieldWhile
//     让忙碌遮罩让位——本页只在 Stack 的 Positioned.fill 挂 UtenBusyOverlay，
//     不叠裸遮罩) → postLongRunning(3min) 逐人执行 → 顶部通知 summary →
//     重读计划渲染结果列 → 人事手动返回 pop(true)，列表页清勾选并静默刷新。
//
// 错误口径：404=计划不存在或无权看(错误态)；409 且 fieldErrors.errorCode ∈
// {RECONCILE_PLAN_CHANGED(自动重取,尽量保留草稿), RECONCILE_PLAN_BUSY(稍候),
//  RECONCILE_PLAN_EXPIRED(过期空态)}。计划 24 小时有效，超时未执行的改动自动清除。
//
// 文档：docs/03-页面/HR任务中心.md；接口契约见 ADR-160。
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_error.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/ui/capsule_nav_metrics.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/hr_reconcile_plan.dart';
import '../repositories/hr_reconcile_repository.dart';
import '../widgets/hr_reconcile_cells.dart';

class HrReconcilePage extends ConsumerStatefulWidget {
  const HrReconcilePage({super.key});

  @override
  ConsumerState<HrReconcilePage> createState() => _HrReconcilePageState();
}

class _HrReconcilePageState extends ConsumerState<HrReconcilePage> {
  HrReconcilePlan? _plan;

  /// 深链里带来的员工 UUID（生成后保留，供过期「重新核对」）。
  List<String> _employeeIds = const [];

  /// 深链 returnTo（栈空离开时兜底去向）。
  String? _returnTo;

  /// 正在执行的当前计划 id（错误态「重试」用）。
  String? _activePlanId;

  bool _loading = false;
  bool _generating = false;
  bool _applying = false;
  bool _expired = false;

  /// 本次进入已成功执行过 apply：离开时 pop(true) 让列表刷新。
  bool _appliedOnce = false;

  String? _error;
  int _loadGeneration = 0;
  String? _routeIdentity;

  Set<String> _selectedIds = {};

  /// 行草稿：rowNo → 手输 controller + 采用状态（滚动/分段不丢，dispose 释放）。
  final Map<int, HrReconcileRowDraft> _drafts = {};

  bool get _busy => _generating || _applying;

  bool get _dirty =>
      !_appliedOnce && _drafts.values.any((draft) => draft.isDirty);

  HrReconcileRepository get _repo => ref.read(hrReconcileRepositoryProvider);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final uri = GoRouterState.of(context).uri;
    final identity = uri.toString();
    if (_routeIdentity == identity) return;
    _routeIdentity = identity;
    _resolveRoute(uri);
  }

  @override
  void dispose() {
    ++_loadGeneration;
    _disposeDrafts();
    super.dispose();
  }

  // ── 入口解析 ──────────────────────────────────────────────────────────────

  void _resolveRoute(Uri uri) {
    final query = uri.queryParameters;
    final planId = (query['planId'] ?? '').trim();
    _employeeIds = (query['employeeIds'] ?? '')
        .split(',')
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toList(growable: false);
    _returnTo = query['returnTo'];
    if (planId.isNotEmpty) {
      // 生成完计划后的自家换参：plan 已在手，不重读。
      if (_plan?.id == planId) return;
      _loadPlan(planId);
    } else if (_employeeIds.isNotEmpty) {
      _generatePlan();
    } else {
      _activePlanId = null;
      setState(() {
        _plan = null;
        _error = null;
        _loading = false;
        _expired = false;
      });
    }
  }

  Future<void> _generatePlan() async {
    final generation = ++_loadGeneration;
    final employeeIds = List<String>.of(_employeeIds);
    _activePlanId = null;
    setState(() {
      _generating = true;
      _error = null;
      _expired = false;
      _plan = null;
    });
    try {
      final plan = await _repo.createIdRepairPlan(employeeIds);
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _plan = plan;
        _generating = false;
        _appliedOnce = false;
      });
      _disposeDrafts();
      // 换成可恢复深链(planId 供刷新/分享/核对记录，employeeIds 供过期重核对)。
      // 查询参数只放 UUID，绝不放证件号。
      context.pushReplacement(
        RoutePath.hrReconcile(
          planId: plan.id,
          employeeIds: employeeIds,
          returnTo: _returnTo,
        ),
      );
    } on ApiException catch (e) {
      if (!mounted || generation != _loadGeneration) return;
      final l10n = AppLocalizations.of(context);
      setState(() {
        _generating = false;
        _error = e.message.isEmpty ? l10n.hrReconcileGenerateFailed : e.message;
      });
    } catch (_) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _generating = false;
        _error = AppLocalizations.of(context).hrReconcileGenerateFailed;
      });
    }
  }

  Future<void> _loadPlan(String planId, {bool keepDrafts = false}) async {
    final generation = ++_loadGeneration;
    _activePlanId = planId;
    setState(() {
      _loading = true;
      _error = null;
      _expired = false;
    });
    try {
      final plan = await _repo.getPlan(planId);
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _plan = plan;
        _loading = false;
        _expired = plan.expired;
      });
      if (!keepDrafts) {
        _disposeDrafts();
        _selectedIds.clear();
      }
    } on ApiException catch (e) {
      if (!mounted || generation != _loadGeneration) return;
      final l10n = AppLocalizations.of(context);
      setState(() {
        _loading = false;
        _error = e.message.isEmpty ? l10n.hrReconcileLoadFailed : e.message;
      });
    } catch (_) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _loading = false;
        _error = AppLocalizations.of(context).hrReconcileLoadFailed;
      });
    }
  }

  void _disposeDrafts() {
    for (final draft in _drafts.values) {
      draft.dispose();
    }
    _drafts.clear();
  }

  HrReconcileRowDraft _draftOf(int rowNo) =>
      _drafts.putIfAbsent(rowNo, HrReconcileRowDraft.new);

  // ── 提交 ─────────────────────────────────────────────────────────────────

  /// N=勾选且已给出最终值的行数；M=这些行的采用项数(本期每行≤1)。
  /// 已执行的行(有 result/outcome)不再计入——apply 成功后残留的旧选中不复活按钮。
  (int, int) _applyCounts(Set<String> selected) {
    var people = 0;
    var items = 0;
    for (final row in _plan?.rows ?? const <HrReconcileRow>[]) {
      if (!selected.contains(row.employee.id)) continue;
      if (!_rowPending(row)) continue;
      final item = row.idNumberItem;
      if (item == null) continue;
      if (hrReconcileFinalValue(item, _drafts[row.rowNo]) != null) {
        people++;
        items++;
      }
    }
    return (people, items);
  }

  /// 行还可被本次执行：未出结果、项未执行。
  bool _rowPending(HrReconcileRow row) =>
      row.result == null && row.items.every((item) => item.outcome == null);

  /// 勾选了但没给出最终值的行数（确认弹窗里说明「本次不改」）。
  int _selectedWithoutValue(Set<String> selected) {
    var count = 0;
    for (final row in _plan?.rows ?? const <HrReconcileRow>[]) {
      if (!selected.contains(row.employee.id)) continue;
      if (!_rowPending(row)) continue;
      final item = row.idNumberItem;
      if (item == null) continue;
      if (hrReconcileFinalValue(item, _drafts[row.rowNo]) == null) count++;
    }
    return count;
  }

  Future<void> _confirmApply() async {
    if (_busy) return;
    final selected = Set<String>.of(_selectedIds);
    final (people, items) = _applyCounts(selected);
    final l10n = AppLocalizations.of(context);
    if (people == 0) {
      context.appWarning(l10n.hrReconcileApplyHintFirst);
      return;
    }
    final skipped = _selectedWithoutValue(selected);
    final ok = await UtenDialog.show(
      context,
      title: l10n.hrReconcileConfirmTitle,
      danger: true,
      confirmLabel: l10n.hrReconcileConfirmButton,
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(l10n.hrReconcileConfirmBodyPeople(people, items)),
          const SizedBox(height: UtenSpacing.s8),
          Text(l10n.hrReconcileConfirmBodyDerived),
          const SizedBox(height: UtenSpacing.s8),
          Text(l10n.hrReconcileConfirmBodyPassword),
          if (skipped > 0) ...[
            const SizedBox(height: UtenSpacing.s8),
            Text(l10n.hrReconcileConfirmBodySkipped(skipped)),
          ],
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _apply(selected);
  }

  Future<void> _apply(Set<String> selected) async {
    final plan = _plan;
    if (plan == null || _applying) return;
    final rows = <HrReconcileApplyRow>[];
    for (final row in plan.rows) {
      if (!selected.contains(row.employee.id)) continue;
      final item = row.idNumberItem;
      if (item == null) continue;
      final finalValue = hrReconcileFinalValue(item, _drafts[row.rowNo]);
      if (finalValue == null) continue;
      rows.add(
        HrReconcileApplyRow(
          rowNo: row.rowNo,
          items: [
            HrReconcileApplyItem(
              itemNo: item.itemNo,
              // 语义：手输 > 候选 > 建议(都不带 = 采用建议 newValue)。
              candidateIndex:
                  finalValue.source == HrReconcileValueSource.candidate
                  ? finalValue.candidateIndex
                  : null,
              value: finalValue.source == HrReconcileValueSource.manual
                  ? finalValue.value
                  : null,
            ),
          ],
        ),
      );
    }
    if (rows.isEmpty) return;
    // 幂等键：planId(36) + '-' + 毫秒时间戳(13) = 50 字符 ≤ 64。
    final requestId = '${plan.id}-${DateTime.now().millisecondsSinceEpoch}';
    setState(() => _applying = true);
    try {
      final result = await _repo.apply(
        plan.id,
        planVersion: plan.version,
        requestId: requestId,
        rows: rows,
      );
      if (!mounted) return;
      _appliedOnce = true;
      // 顶部通知 summary（服务端一句人话）。
      context.appSuccess(result.summary);
      // 已执行行清出勾选，避免批量条残留旧计数。
      setState(() => _selectedIds.clear());
      // 重读计划：结果列渲染逐人 outcome；草稿保留给未执行行。
      await _loadPlan(plan.id, keepDrafts: true);
    } on ApiException catch (e) {
      if (!mounted) return;
      switch (_reconcileErrorCode(e)) {
        case 'RECONCILE_PLAN_CHANGED':
          context.appWarning(
            AppLocalizations.of(context).hrReconcilePlanChanged,
          );
          await _loadPlan(plan.id, keepDrafts: true);
        case 'RECONCILE_PLAN_BUSY':
          context.appWarning(
            AppLocalizations.of(context).hrReconcilePlanBusyConflict,
          );
        case 'RECONCILE_PLAN_EXPIRED':
          setState(() => _expired = true);
        case _:
          context.appApiError(e);
      }
    } catch (_) {
      if (!mounted) return;
      context.appError(AppLocalizations.of(context).hrReconcileApplyFailed);
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  /// 409 的业务错误码：fieldErrors 里 field=='errorCode' 的 message。
  String? _reconcileErrorCode(ApiException e) {
    for (final fieldError in e.fieldErrors ?? const <ApiFieldError>[]) {
      if (fieldError.field == 'errorCode') return fieldError.message;
    }
    const known = {
      'RECONCILE_PLAN_CHANGED',
      'RECONCILE_PLAN_BUSY',
      'RECONCILE_PLAN_EXPIRED',
    };
    if (known.contains(e.code)) return e.code;
    return null;
  }

  // ── 离开拦截 ─────────────────────────────────────────────────────────────

  Future<void> _handleLeave() async {
    if (_busy) return;
    final l10n = AppLocalizations.of(context);
    if (_dirty) {
      final ok = await UtenDialog.show(
        context,
        title: l10n.hrReconcileLeaveTitle,
        content: Text(l10n.hrReconcileLeaveBody),
        confirmLabel: l10n.hrReconcileLeaveConfirm,
        cancelLabel: l10n.hrReconcileLeaveCancel,
        danger: true,
      );
      if (ok != true || !mounted) return;
    }
    _close(_appliedOnce);
  }

  void _close(bool changed) {
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop(changed);
      return;
    }
    final target =
        sanitizeReturnTo(_returnTo, scope: ReturnToScope.employee) ??
        RouteName.home;
    context.go(target);
  }

  // ── 核对记录（顶栏入口） ─────────────────────────────────────────────────

  Future<void> _openRecords() async {
    final l10n = AppLocalizations.of(context);
    final HrReconcilePlanSummaryPage page;
    try {
      page = await _repo.listPlans();
    } on ApiException catch (e) {
      if (mounted) context.appApiError(e);
      return;
    }
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(sheetContext).height * 0.6,
          child: ListView(
            padding: const EdgeInsets.only(
              left: UtenSpacing.s16,
              right: UtenSpacing.s16,
              bottom: UtenSpacing.s16,
            ),
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
                child: Text(
                  l10n.hrReconcileRecordsTitle,
                  style: Theme.of(sheetContext).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (page.items.isEmpty)
                ListTile(title: Text(l10n.hrReconcileRecordsEmpty)),
              for (final summary in page.items)
                ListTile(
                  key: ValueKey('hr-reconcile-record-${summary.id}'),
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    '${_formatTime(summary.createdAt)} · '
                    '${l10n.hrReconcileRecordCount(summary.counts.rows)}',
                  ),
                  subtitle: Text(
                    '${summary.actorName} · ${_recordStatusLabel(l10n, summary)}',
                  ),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    context.push(RoutePath.hrReconcile(planId: summary.id));
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  String _recordStatusLabel(
    AppLocalizations l10n,
    HrReconcilePlanSummary summary,
  ) => switch (summary.status) {
    HrReconcilePlanStatus.closed => switch (summary.closedReason) {
      HrReconcileClosedReason.expired => l10n.hrReconcileStatusExpired,
      HrReconcileClosedReason.discarded => l10n.hrReconcileStatusDiscarded,
      null => l10n.hrReconcileStatusClosed,
    },
    HrReconcilePlanStatus.open ||
    HrReconcilePlanStatus.applying => l10n.hrReconcileStatusOpen,
  };

  String _formatTime(String? iso) {
    if (iso == null || iso.isEmpty) return '-';
    final parsed = DateTime.tryParse(iso);
    if (parsed == null) return iso;
    final local = parsed.isUtc ? parsed.toLocal() : parsed;
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  // ── UI ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    Widget body;
    if (_loading || _generating) {
      body = const UtenSkeletonList(itemCount: 6);
    } else if (_error != null) {
      body = UtenEmpty.error(
        message: _error,
        actionLabel: l10n.hrReconcileRetry,
        onAction: _retry,
      );
    } else if (_expired || _plan?.expired == true) {
      body = _expiredView(l10n);
    } else if (_plan == null) {
      body = UtenEmpty(
        icon: Icons.fact_check_outlined,
        message: l10n.hrReconcileEmptyEntry,
        actionLabel: l10n.hrReconcileRecords,
        onAction: _openRecords,
      );
    } else {
      body = _planView(context, l10n, _plan!);
    }
    if (context.breakpoint.isCompact) {
      body = UtenContentContainer(child: body);
    }
    return PopScope(
      canPop: !_dirty && !_busy && !_appliedOnce,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_busy) _handleLeave();
      },
      child: Scaffold(
        appBar: UtenAppBar(
          title: l10n.hrReconcileTitle,
          leading: UtenBackButton(onPressed: _busy ? null : _handleLeave),
          actions: [
            IconButton(
              tooltip: l10n.hrReconcileRecords,
              icon: const Icon(Icons.history_rounded),
              onPressed: _busy ? null : _openRecords,
            ),
            IconButton(
              tooltip: l10n.hrReconcileRefresh,
              icon: const Icon(Icons.refresh_rounded),
              onPressed: _busy || _activePlanId == null
                  ? null
                  : () => _loadPlan(_activePlanId!),
            ),
          ],
        ),
        body: SafeArea(
          // apply/生成期间整页忙碌遮罩照 finance 页模式挂 Stack 的 Positioned.fill；
          // 再认证密码框(StepUpInterceptor)由 UtenBusyOverlay.yieldWhile 自动让位。
          child: Stack(
            children: [
              Positioned.fill(child: body),
              if (_busy)
                Positioned.fill(
                  child: UtenBusyOverlay(
                    title: _generating
                        ? l10n.hrReconcileGenerating
                        : l10n.hrReconcileApplying,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _retry() {
    final planId = _activePlanId;
    if (planId != null) {
      _loadPlan(planId);
    } else if (_employeeIds.isNotEmpty) {
      _generatePlan();
    }
  }

  Widget _expiredView(AppLocalizations l10n) => UtenEmpty(
    icon: Icons.timer_off_rounded,
    message: l10n.hrReconcileExpiredTitle,
    description: l10n.hrReconcileValidity,
    actionLabel: _employeeIds.isNotEmpty
        ? l10n.hrReconcileExpiredRetry
        : l10n.hrReconcileBack,
    onAction: _employeeIds.isNotEmpty ? _generatePlan : _handleLeave,
  );

  Widget _planView(
    BuildContext context,
    AppLocalizations l10n,
    HrReconcilePlan plan,
  ) {
    return RefreshIndicator(
      onRefresh: () => _loadPlan(plan.id),
      child: Column(
        children: [
          _summaryHeader(context, l10n, plan),
          Expanded(child: _table(context, l10n, plan)),
        ],
      ),
    );
  }

  /// 摘要行 + 只读提示（他人核对只能查看，隐藏勾选与批量条）。
  Widget _summaryHeader(
    BuildContext context,
    AppLocalizations l10n,
    HrReconcilePlan plan,
  ) {
    final theme = Theme.of(context);
    final counts = plan.counts;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UtenSpacing.s12,
        UtenSpacing.s8,
        UtenSpacing.s12,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!plan.canApply)
            Padding(
              padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: UtenSpacing.s12,
                  vertical: UtenSpacing.s8,
                ),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer,
                  borderRadius: UtenRadius.lgAll,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.visibility_outlined,
                      size: 18,
                      color: theme.colorScheme.onErrorContainer,
                    ),
                    const SizedBox(width: UtenSpacing.s8),
                    Expanded(
                      child: Text(
                        l10n.hrReconcileReadOnlyNotice(plan.actorName),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onErrorContainer,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          Text(
            l10n.hrReconcileSummary(
              counts.rows,
              counts.update,
              counts.info,
              counts.same,
              counts.applied,
            ),
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            l10n.hrReconcileValidity,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: UtenSpacing.s4),
        ],
      ),
    );
  }

  Widget _table(
    BuildContext context,
    AppLocalizations l10n,
    HrReconcilePlan plan,
  ) {
    final editable = plan.canApply && plan.capabilities.piiEdit;
    return MasterDataTableView<HrReconcileRow>(
      tableKey:
          'features.hr_task.pages.hr_reconcile_page.HrReconcilePageState._table.1',
      key: const Key('hr-reconcile-table'),
      compactCards: true,
      bottomContentPadding: math.max(
        32,
        UtenCapsuleNavScope.occlusionOf(context),
      ),
      columns: _columns(l10n, plan),
      items: plan.rows,
      facets: const {},
      nullCounts: const {},
      filters: const {},
      onFilterChanged: (_, _) {},
      selectable: plan.canApply,
      // 他人认领/已执行/非 UPDATE 行不可勾选（已执行的不能再改）。
      idOf: (row) =>
          row.kind == HrReconcileRowKind.update &&
              !row.claimedByOther &&
              row.result == null &&
              plan.canApply
          ? row.employee.id
          : null,
      rowKeyOf: (row) => row.employee.id,
      unselectableLeadingBuilder: (context, row) =>
          row.claim != null && !row.claim!.byMe
          ? Tooltip(
              message: l10n.hrReconcileLockTooltip(row.claim!.byName),
              child: Icon(
                Icons.lock_outline_rounded,
                size: 20,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            )
          : const SizedBox.shrink(),
      selectedIds: _selectedIds,
      onSelectedIdsChanged: (next) => setState(() => _selectedIds = next),
      batchActionsBuilder: editable
          ? (context, ids) => _batchActions(context, l10n, ids)
          : null,
      emptyMessage: l10n.hrReconcilePlanEmpty,
    );
  }

  List<MasterColumnDef<HrReconcileRow>> _columns(
    AppLocalizations l10n,
    HrReconcilePlan plan,
  ) {
    final masked = !plan.capabilities.viewPii;
    return [
      MasterColumnDef(
        key: 'kind',
        label: l10n.hrReconcileColKind,
        width: 92,
        value: (row) => _kindLabel(l10n, row.kind),
        cellBuilder: (context, row) =>
            HrReconcileKindTag(rowNo: row.rowNo, kind: row.kind),
        cardRendersBuilder: true,
      ),
      MasterColumnDef(
        key: 'code',
        label: l10n.hrReconcileColCode,
        width: 110,
        value: (row) => row.employee.code,
        cardRole: MasterColumnCardRole.subtitle,
      ),
      MasterColumnDef(
        key: 'name',
        label: l10n.hrReconcileColName,
        width: 120,
        value: (row) => row.employee.name,
        cardRole: MasterColumnCardRole.title,
      ),
      MasterColumnDef(
        key: 'deptName',
        label: l10n.hrReconcileColDept,
        width: 150,
        value: (row) => row.employee.deptName,
      ),
      MasterColumnDef(
        key: 'reason',
        label: l10n.hrReconcileColReason,
        width: 320,
        value: (row) => _reasonOf(row),
        // 照列表页原因列：红字折行不截断（选中行换统一前景色）。
        cardRendersBuilder: true,
        cellBuilder: (context, row) {
          final scope = MasterDataTableCellScope.maybeOf(context);
          final reason = _reasonOf(row);
          return Text(
            reason ?? '—',
            style: TextStyle(
              color: scope?.selected == true
                  ? scope?.foregroundColor
                  : Theme.of(context).colorScheme.error,
              fontWeight: FontWeight.w600,
            ),
            softWrap: true,
          );
        },
      ),
      MasterColumnDef(
        key: 'idNumber',
        label: l10n.hrReconcileColIdNumber,
        width: 380,
        value: (row) => row.idNumberItem?.oldValue,
        cellBuilder: (context, row) {
          final item = row.idNumberItem;
          if (item == null) return const Text('—');
          // 草稿提前建好：手输框必须在 build 时就拿到 controller（后建会丢字）；
          // 只读计划不建（看一眼不该留 200 个 controller）。
          final draft = plan.canApply ? _draftOf(row.rowNo) : null;
          final editable =
              plan.canApply &&
              item.permitted &&
              row.kind == HrReconcileRowKind.update &&
              row.result == null;
          return HrReconcileIdNumberCell(
            rowNo: row.rowNo,
            item: item,
            masked: masked,
            editable: editable,
            draft: draft,
            onAdoptToggled: editable
                ? () => setState(() {
                    final d = _draftOf(row.rowNo);
                    // 建议与候选互斥：采用建议清候选。
                    d.adoptedOverride =
                        !(d.adoptedOverride ?? item.preselected);
                    d.candidateIndex = null;
                  })
                : null,
            onCandidateToggled: editable
                ? (index) => setState(() {
                    final d = _draftOf(row.rowNo);
                    d.candidateIndex = d.candidateIndex == index ? null : index;
                  })
                : null,
            onManualChanged: editable ? () => setState(() {}) : null,
          );
        },
        cardRendersBuilder: true,
      ),
      MasterColumnDef(
        key: 'basis',
        label: l10n.hrReconcileColBasis,
        width: 130,
        value: (row) => row.idNumberItem?.basis?.label,
      ),
      MasterColumnDef(
        key: 'tier',
        label: l10n.hrReconcileColTier,
        width: 92,
        value: (row) => row.idNumberItem == null
            ? null
            : _tierLabel(l10n, row.idNumberItem!.tier),
        cellBuilder: (context, row) => row.idNumberItem == null
            ? const SizedBox.shrink()
            : HrReconcileTierBadge(
                itemNo: row.idNumberItem!.itemNo,
                tier: row.idNumberItem!.tier,
              ),
        cardRendersBuilder: true,
      ),
      MasterColumnDef(
        key: 'notes',
        label: l10n.hrReconcileColNotes,
        width: 240,
        value: (row) =>
            row.items.isEmpty ? null : row.items.first.notes.join('；'),
        cellBuilder: (context, row) => HrReconcileNotesCell(row: row),
        cardRendersBuilder: true,
      ),
    ];
  }

  String? _reasonOf(HrReconcileRow row) =>
      row.reason ?? (row.notices.isEmpty ? null : row.notices.first.message);

  String _kindLabel(AppLocalizations l10n, HrReconcileRowKind kind) =>
      switch (kind) {
        HrReconcileRowKind.update => l10n.hrReconcileKindUpdate,
        HrReconcileRowKind.info => l10n.hrReconcileKindInfo,
        HrReconcileRowKind.same => l10n.hrReconcileKindSame,
      };

  String _tierLabel(AppLocalizations l10n, HrReconcileTier tier) =>
      switch (tier) {
        HrReconcileTier.high => l10n.hrReconcileTierHigh,
        HrReconcileTier.medium => l10n.hrReconcileTierMedium,
        HrReconcileTier.manual => l10n.hrReconcileTierManual,
        HrReconcileTier.none => l10n.hrReconcileTierNone,
      };

  List<Widget> _batchActions(
    BuildContext context,
    AppLocalizations l10n,
    Set<String> selected,
  ) {
    final (people, items) = _applyCounts(selected);
    return [
      UtenButton(
        key: const Key('hr-reconcile-apply'),
        type: UtenButtonType.danger,
        size: UtenButtonSize.large,
        icon: Icons.fact_check_outlined,
        isLoading: _applying,
        onPressed: people > 0 && !_busy ? _confirmApply : null,
        onDisabledTap: () => context.appWarning(l10n.hrReconcileApplyHintFirst),
        child: Text(l10n.hrReconcileApplyButton(people, items)),
      ),
    ];
  }
}
