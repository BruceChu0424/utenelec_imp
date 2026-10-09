// 员工资料核对更正页(ADR-160)：证件核对页(列表页)勾选 N 人「批量处理(N)」进入，
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
// 2026-10-06 批量处理页重做：
//  - 摘要区改统计胶囊(待核对人数 + 把握分布 高/中/需人工)，替代原一行汇总文字；
//  - 员工三列(工号/姓名/部门)合并为「员工」一列(姓名主行 + 工号·部门副行)，
//    「依据」列退役并入把握徽章 Tooltip；
//  - 问题字段列改为 field_code 驱动的动态列(服务端下发的 items 决定建哪些列，
//    本期只有 idNumber；未来花名册/AI 来源扩展新字段时页面零改动)；
//  - 批量条新增「只选把握高的」快捷勾选(全部 HIGH 档未执行行)；
//  - 勾选计数/提交组装泛化为逐 item(本期每行≤1 项，行为不变，多字段自动成立)。
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
import '../../../components/data_display/uten_revision_cell.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_error.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_colors.dart';
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

  /// N=勾选且已给出最终值的行数；M=这些行的采用项数(本期每行≤1，多字段自动求和)。
  /// 已执行的行(有 result/outcome)不再计入——apply 成功后残留的旧选中不复活按钮。
  (int, int) _applyCounts(Set<String> selected) {
    var people = 0;
    var items = 0;
    for (final row in _plan?.rows ?? const <HrReconcileRow>[]) {
      if (!selected.contains(row.employee.id)) continue;
      if (!_rowPending(row)) continue;
      var rowItems = 0;
      for (final item in row.items) {
        if (hrReconcileFinalValue(item, _drafts[row.rowNo]) != null) {
          rowItems++;
        }
      }
      if (rowItems > 0) {
        people++;
        items += rowItems;
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
      final hasValue = row.items.any(
        (item) => hrReconcileFinalValue(item, _drafts[row.rowNo]) != null,
      );
      if (row.items.isNotEmpty && !hasValue) count++;
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
      // 与 _applyCounts/_selectedWithoutValue 同口径：已出结果的行不再进请求体
      // (409 CHANGED 自动重取后勾选可能残留已执行行，弹窗计数已排除它们)。
      if (!_rowPending(row)) continue;
      // 逐 item 组装(本期每行≤1 项；未来多字段时整行已给出值的项目全部带上)。
      // 手输值的合法性按字段类型校验——hrReconcileFinalValue 目前内置证件号
      // 校验(IdCardUtils)，扩展新字段时在该纯函数里按 field 分发校验器。
      final applyItems = <HrReconcileApplyItem>[];
      for (final item in row.items) {
        final finalValue = hrReconcileFinalValue(item, _drafts[row.rowNo]);
        if (finalValue == null) continue;
        applyItems.add(
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
        );
      }
      if (applyItems.isEmpty) continue;
      rows.add(HrReconcileApplyRow(rowNo: row.rowNo, items: applyItems));
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

  /// 摘要区(2026-10-06 重做)：待核对人数主行 + kind 副行 + 把握分布胶囊 + 有效期；
  /// 只读提示（他人核对只能查看，隐藏勾选与批量条）保留在最上。
  Widget _summaryHeader(
    BuildContext context,
    AppLocalizations l10n,
    HrReconcilePlan plan,
  ) {
    final theme = Theme.of(context);
    final counts = plan.counts;
    // 把握分布从「未执行的 item」现算（plan.counts 没有 tier 维度）。
    final tierCounts = <HrReconcileTier, int>{};
    for (final row in plan.rows) {
      if (!_rowPending(row)) continue;
      for (final item in row.items) {
        tierCounts[item.tier] = (tierCounts[item.tier] ?? 0) + 1;
      }
    }
    final pendingHigh = tierCounts[HrReconcileTier.high] ?? 0;
    final pendingMedium = tierCounts[HrReconcileTier.medium] ?? 0;
    final pendingManual = tierCounts[HrReconcileTier.manual] ?? 0;

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
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                // rows 含已处理行：主行只报「还没核对的」，已处理进副行。
                l10n.hrReconcileStatPeople(counts.rows - counts.applied),
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(width: UtenSpacing.s8),
              Flexible(
                child: Text(
                  [
                    if (counts.update > 0)
                      l10n.hrReconcileStatUpdate(counts.update),
                    if (counts.info > 0) l10n.hrReconcileStatInfo(counts.info),
                    if (counts.same > 0) l10n.hrReconcileStatSame(counts.same),
                    if (counts.applied > 0)
                      l10n.hrReconcileStatApplied(counts.applied),
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          if (pendingHigh + pendingMedium + pendingManual > 0) ...[
            const SizedBox(height: UtenSpacing.s4),
            Wrap(
              spacing: UtenSpacing.s8,
              runSpacing: UtenSpacing.s4,
              children: [
                if (pendingHigh > 0)
                  _tierCountChip(
                    context,
                    l10n.hrReconcileStatTierHigh(pendingHigh),
                    UtenColors.statusSuccess,
                  ),
                if (pendingMedium > 0)
                  _tierCountChip(
                    context,
                    l10n.hrReconcileStatTierMedium(pendingMedium),
                    UtenColors.statusOrange,
                  ),
                if (pendingManual > 0)
                  _tierCountChip(
                    context,
                    l10n.hrReconcileStatTierManual(pendingManual),
                    UtenColors.statusDanger,
                  ),
              ],
            ),
          ],
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

  /// 摘要里的把握分布小胶囊：与行内 HrReconcileTierBadge 同一色系(弱底)，
  /// 数字即该档未处理项数。
  Widget _tierCountChip(BuildContext context, String label, Color color) {
    final theme = Theme.of(context);
    return Container(
      key: ValueKey('hr-reconcile-stat-$label'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(UtenRadius.sm),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
        ),
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
        width: 76,
        value: (row) => _kindLabel(l10n, row.kind),
        cellBuilder: (context, row) =>
            HrReconcileKindTag(rowNo: row.rowNo, kind: row.kind),
        cardRendersBuilder: true,
      ),
      // 员工合并列：姓名主行 + 工号·部门副行(2026-10-06 重做，三列并一)。
      // cardRole=title：compact 卡片形态的标题位渲染本列 cellBuilder(姓名+
      // 工号·部门)，否则缺省会拿第一列「类型」当标题。
      MasterColumnDef(
        key: 'employee',
        label: l10n.hrReconcileColEmployee,
        width: 200,
        value: (row) => row.employee.name,
        cardRole: MasterColumnCardRole.title,
        cellBuilder: (context, row) {
          final theme = Theme.of(context);
          final sub = [
            row.employee.code,
            ?row.employee.deptName,
          ].where((s) => s.isNotEmpty).join(' · ');
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                row.employee.name,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (sub.isNotEmpty)
                Text(
                  sub,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          );
        },
        cardRendersBuilder: true,
      ),
      MasterColumnDef(
        key: 'reason',
        label: l10n.hrReconcileColReason,
        width: 300,
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
      // field_code 驱动的动态问题列：计划里出现哪些字段就建哪些列——
      // 未来花名册/AI 来源扩展新字段(部门/手机号/生日…)时本页零改动。
      ..._problemColumns(l10n, plan, masked),
      MasterColumnDef(
        key: 'tier',
        label: l10n.hrReconcileColTier,
        width: 92,
        value: (row) => _primaryItem(row)?.tier == null
            ? null
            : _tierLabel(l10n, _primaryItem(row)!.tier),
        cellBuilder: (context, row) {
          final item = _primaryItem(row);
          if (item == null) return const SizedBox.shrink();
          return HrReconcileTierBadge(
            itemNo: item.itemNo,
            tier: item.tier,
            basisLabel: item.basis?.label,
          );
        },
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

  /// 行的首要问题项：本期每行至多一项(items[0])；多字段时代为主展示项
  /// (把握徽章列只挂一个，行内所有字段列各自完整展示)。
  HrReconcileItem? _primaryItem(HrReconcileRow row) =>
      row.items.isEmpty ? null : row.items.first;

  /// 动态问题字段列(2026-10-06)：按 items 的 field 去重(保序)建列，列名用
  /// 服务端下发的字段 label。idNumber(写入口 CHANGE_IDENTITY)挂完整交互格
  /// (建议/候选/手输)；其余字段先用通用旧新对照只读展示，等后端放开对应
  /// source 后再补各自编辑器。
  List<MasterColumnDef<HrReconcileRow>> _problemColumns(
    AppLocalizations l10n,
    HrReconcilePlan plan,
    bool masked,
  ) {
    final fields = <String>[];
    final sampleItem = <String, HrReconcileItem>{};
    for (final row in plan.rows) {
      for (final item in row.items) {
        if (!sampleItem.containsKey(item.field)) {
          fields.add(item.field);
          sampleItem[item.field] = item;
        }
      }
    }
    HrReconcileItem? itemOf(HrReconcileRow row, String field) {
      for (final item in row.items) {
        if (item.field == field) return item;
      }
      return null;
    }

    return [
      for (final field in fields)
        MasterColumnDef<HrReconcileRow>(
          key: 'field-$field',
          label: sampleItem[field]!.label,
          width: 420,
          value: (row) => itemOf(row, field)?.oldValue,
          // 表头 ⓘ：向第一次用的人解释这格的「旧→新」视觉语法与三种改法。
          info: sampleItem[field]!.writePath == 'CHANGE_IDENTITY'
              ? l10n.hrReconcileIdNumberInfo
              : null,
          cellBuilder: (context, row) {
            final item = itemOf(row, field);
            if (item == null) return const Text('—');
            if (item.writePath == 'CHANGE_IDENTITY') {
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
                        d.candidateIndex = d.candidateIndex == index
                            ? null
                            : index;
                      })
                    : null,
                onManualChanged: editable ? () => setState(() {}) : null,
              );
            }
            // 通用字段(扩展占位)：旧新对照只读。
            return UtenRevisionCell(
              before: item.oldValue,
              after: item.newValue,
              masked: masked,
            );
          },
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
    final highCount = _selectableHighTierCount();
    return [
      // 快捷勾选：一键选中全部「高把握」未执行行(算法 p≥0.90 且 verified 的建议，
      // 蒙特卡洛保证正确)——大批量时先放行确定项，剩下的逐个看。
      if (highCount > 0)
        UtenButton(
          key: const Key('hr-reconcile-select-high'),
          type: UtenButtonType.secondary,
          size: UtenButtonSize.large,
          icon: Icons.bolt_rounded,
          onPressed: !_busy ? _selectHighTier : null,
          child: Text(l10n.hrReconcileSelectHigh),
        ),
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

  /// 可被「只选把握高的」勾中的行数：UPDATE、未执行、未被他人认领、
  /// 存在 tier=HIGH 的项，且当前未选中(重复点击不会反向取消)。
  int _selectableHighTierCount() {
    final plan = _plan;
    if (plan == null || !plan.canApply) return 0;
    var count = 0;
    for (final row in plan.rows) {
      if (_selectedIds.contains(row.employee.id)) continue;
      if (row.kind != HrReconcileRowKind.update ||
          row.claimedByOther ||
          row.result != null) {
        continue;
      }
      if (row.items.any((item) => item.tier == HrReconcileTier.high)) count++;
    }
    return count;
  }

  /// 勾选全部高把握未执行行(与表格 idOf 同一资格口径，叠加 tier=HIGH)。
  void _selectHighTier() {
    final plan = _plan;
    if (plan == null || !plan.canApply || _busy) return;
    final next = Set<String>.of(_selectedIds);
    for (final row in plan.rows) {
      if (row.kind != HrReconcileRowKind.update ||
          row.claimedByOther ||
          row.result != null) {
        continue;
      }
      if (row.items.any((item) => item.tier == HrReconcileTier.high)) {
        next.add(row.employee.id);
      }
    }
    setState(() => _selectedIds = next);
  }
}
