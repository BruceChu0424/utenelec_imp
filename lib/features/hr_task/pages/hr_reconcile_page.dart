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
// 2026-10-09 全站表格滚动口径：摘要区进 UtenCollapsingHeaderScrollView 折叠头——
//  上滑先收摘要(表头随之顶到视口顶)，继续滚动才滚表格内容；竖向滚动条联动门控。
//
// 错误口径：404=计划不存在或无权看(错误态)；409 且 fieldErrors.errorCode ∈
// {RECONCILE_PLAN_CHANGED(自动重取,尽量保留草稿), RECONCILE_PLAN_BUSY(稍候),
//  RECONCILE_PLAN_EXPIRED(只读记录)}。计划 24 小时有效，超时未执行的改动自动清除。
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
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_paged_grid.dart';
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
import '../../../shared/auth/permissions.dart';
import '../../../shared/drafts/form_draft_catalog.dart';
import '../../../shared/drafts/form_draft_mixin.dart';
import '../../../shared/drafts/form_draft_store.dart';
import '../../../shared/providers/master_name_provider.dart'
    show masterDataSessionKeyProvider;
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/hr_reconcile_plan.dart';
import '../models/hr_reconcile_form_draft.dart';
import '../repositories/hr_reconcile_repository.dart';
import '../widgets/hr_reconcile_cells.dart';

class HrReconcilePage extends ConsumerStatefulWidget {
  const HrReconcilePage({super.key});

  @override
  ConsumerState<HrReconcilePage> createState() => _HrReconcilePageState();
}

class _HrReconcilePageState extends ConsumerState<HrReconcilePage>
    with FormDraftMixin<HrReconcilePage> {
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
  bool _confirming = false;
  bool _checkingReceipt = false;
  bool _resumeUnknownSubmission = false;
  String? _draftPlanId;
  int? _draftPlanVersion;
  Map<String, dynamic>? _retainedDraftData;
  Map<String, dynamic>? _pendingSubmission;
  String? _resumeDraftId;
  bool _requiresSourceReload = false;
  bool _readOnlyRequested = false;
  Map<String, dynamic>? _knownInterruptedReceipt;
  bool _interruptionCheckpointSaved = false;

  /// 本次进入已成功执行过 apply：离开时 pop(true) 让列表刷新。
  bool _appliedOnce = false;

  String? _error;
  int _loadGeneration = 0;
  String? _routeIdentity;

  Set<String> _selectedIds = {};

  /// 行草稿：rowNo → 手输 controller + 采用状态（滚动/分段不丢，dispose 释放）。
  final Map<int, HrReconcileRowDraft> _drafts = {};

  bool get _busy => _generating || _applying || _checkingReceipt;

  bool get _dirty =>
      !_appliedOnce && _drafts.values.any((draft) => draft.isDirty);

  HrReconcileRepository get _repo => ref.read(hrReconcileRepositoryProvider);

  @override
  bool get formDraftEnabled =>
      !_readOnlyRequested &&
      _plan != null &&
      _plan!.rows.every(hrReconcileInputIsSupported) &&
      ((_plan!.status == HrReconcilePlanStatus.open &&
              _plan!.canApply &&
              _plan!.capabilities.piiEdit) ||
          _pendingSubmission != null ||
          _resumeUnknownSubmission);
  @override
  bool get formDraftBusy => _busy || _loading || _confirming;
  @override
  bool get formDraftUseCurrentRoute => false;
  @override
  bool get formDraftHasUnknownSubmission =>
      _pendingSubmission != null &&
      !(_knownInterruptedReceipt?['status'] == 'INTERRUPTED' &&
          _knownInterruptedReceipt?['planId'] ==
              _pendingSubmission?['planId'] &&
          _knownInterruptedReceipt?['requestId'] ==
              _pendingSubmission?['requestId'] &&
          _knownInterruptedReceipt?['sourcePlanVersion'] ==
              _pendingSubmission?['planVersion']);
  @override
  FormDraftSpec get formDraftSpec => FormDraftCatalog.employeeReconcile.spec(
    route: RoutePath.hrReconcile(
      planId: _plan!.id,
      employeeIds: [for (final row in _plan!.rows) row.employee.id],
      returnTo: _returnTo,
    ),
  );
  @override
  Iterable<Listenable> get formDraftListenables => [
    for (final draft in _drafts.values) draft.manual,
  ];
  @override
  Map<String, dynamic> captureFormDraft() => {
    ...?_retainedDraftData,
    if (_retainedDraftData == null && _plan != null)
      ...captureHrReconcileFormDraft(_plan!, _captureInputs()),
    'submission': _pendingSubmission,
    'knownInterruptedReceipt': _knownInterruptedReceipt,
  };

  Map<String, HrReconcileDraftInput> _captureInputs() => {
    for (final row in _plan?.rows ?? const <HrReconcileRow>[])
      row.employee.id: HrReconcileDraftInput(
        manual: _drafts[row.rowNo]?.manual.text ?? '',
        adopted: _drafts[row.rowNo]?.adoptedOverride,
        candidateValue: _selectedCandidateValue(row),
        selected: _selectedIds.contains(row.employee.id),
      ),
  };

  String? _selectedCandidateValue(HrReconcileRow row) {
    final index = _drafts[row.rowNo]?.candidateIndex;
    if (row.items.length != 1 ||
        index == null ||
        index < 0 ||
        index >= row.items.single.candidates.length) {
      return null;
    }
    return row.items.single.candidates[index].value;
  }

  @override
  Future<void> restoreFormDraft(Map<String, dynamic> data) async {
    _retainedDraftData = hrReconcileInputSnapshot(data);
    if (data['planId'] != _plan?.id) {
      throw const FormatException('原草稿属于另一份核对计划');
    }
    final submission = data['submission'];
    if (submission != null) {
      if (submission is! Map ||
          submission['planId'] != data['planId'] ||
          submission['requestId'] is! String ||
          (submission['requestId'] as String).isEmpty ||
          submission['planVersion'] is! int ||
          submission['rows'] is! List) {
        throw const FormatException('原更正请求身份不完整，请保留草稿');
      }
      _pendingSubmission = {
        'planId': submission['planId'],
        'requestId': submission['requestId'],
        'planVersion': submission['planVersion'],
        'rows': (submission['rows'] as List).map((row) {
          if (row is! Map) throw const FormatException('原更正请求行身份无效');
          HrReconcileApplyRow.fromJson(Map<String, dynamic>.from(row));
          return {
            'rowNo': row['rowNo'],
            'items': [
              for (final item in row['items'] as List)
                {
                  'itemNo': (item as Map)['itemNo'],
                  if (item.containsKey('candidateIndex'))
                    'candidateIndex': item['candidateIndex'],
                  if (item.containsKey('value')) 'value': item['value'],
                },
            ],
          };
        }).toList(),
      };
      final known = data['knownInterruptedReceipt'];
      if (data[formDraftUnknownSubmissionKey] == false &&
          known is Map &&
          known['status'] == 'INTERRUPTED' &&
          known['planId'] == submission['planId'] &&
          known['requestId'] == submission['requestId'] &&
          known['sourcePlanVersion'] == submission['planVersion']) {
        _knownInterruptedReceipt = {
          'planId': known['planId'],
          'requestId': known['requestId'],
          'status': 'INTERRUPTED',
          'sourcePlanVersion': known['sourcePlanVersion'],
          'observedPlanVersion': known['observedPlanVersion'],
        };
      } else {
        holdFormDraftForReadRecovery();
      }
      return;
    }
    final inputs = restoreHrReconcileFormDraft(_plan!, data);
    _restoreInputs(inputs);
    _retainedDraftData = null;
  }

  void _restoreInputs(Map<String, HrReconcileDraftInput> inputs) {
    _selectedIds.clear();
    for (final row in _plan!.rows) {
      final input = inputs[row.employee.id];
      if (input == null || !_rowPending(row)) continue;
      final draft = _draftOf(row.rowNo);
      draft.manual.text = input.manual;
      draft.adoptedOverride = input.adopted;
      draft.candidateIndex = input.candidateValue == null
          ? null
          : row.items.single.candidates.indexWhere(
              (item) => item.value == input.candidateValue,
            );
      if (input.selected) _selectedIds.add(row.employee.id);
    }
  }

  @override
  Future<void> Function()? get formDraftReloadSource => () async {
    await _loadPlan(_plan!.id, bindDraft: false);
    if (_error != null) throw StateError(_error!);
    _retainedDraftData = null;
    _draftPlanId = _plan!.id;
    _draftPlanVersion = _plan!.version;
  };

  @override
  Widget? get formDraftSubmissionRecoveryAction =>
      _pendingSubmission == null ? null : _originalReceiptActions();

  Widget _originalReceiptActions() => Wrap(
    spacing: UtenSpacing.s8,
    runSpacing: UtenSpacing.s8,
    children: [
      UtenButton(
        key: const Key('hr-reconcile-check-original-receipt'),
        icon: Icons.refresh_rounded,
        isLoading: _checkingReceipt,
        onPressed: _busy ? null : _checkOriginalReceipt,
        child: const Text('核对原更正结果'),
      ),
      if (_knownInterruptedReceipt != null)
        UtenButton(
          key: const Key('hr-reconcile-read-original-result'),
          onPressed: _busy
              ? null
              : () => context.push(
                  Uri(
                    path: RouteName.hrReconcile,
                    queryParameters: {
                      'planId': _pendingSubmission!['planId'] as String,
                      'readOnly': 'true',
                      'returnTo': ?_returnTo,
                    },
                  ).toString(),
                ),
          child: const Text('查看原核对结果'),
        ),
      if (_knownInterruptedReceipt != null && _interruptionCheckpointSaved)
        UtenButton(
          key: const Key('hr-reconcile-rebuild-interrupted'),
          onPressed: _busy ? null : _rebuildInterruptedPlan,
          child: const Text('重新核对'),
        ),
    ],
  );

  @override
  void initState() {
    super.initState();
    startFormDraftIdentityGuard();
  }

  bool get _canReadRecords =>
      ref.read(isSuperAdminProvider) ||
      (ref.read(currentPermissionsProvider).contains(Perm.employeeView) &&
          ref.read(currentPermissionsProvider).contains(Perm.employeeEdit));

  bool _canExecutePlan(HrReconcilePlan plan) =>
      !_readOnlyRequested &&
      plan.rows.every(hrReconcileInputIsSupported) &&
      formDraftIdentityIsCurrent &&
      !formDraftRestorationBlocked &&
      _pendingSubmission == null &&
      !_requiresSourceReload &&
      (ref.read(isSuperAdminProvider) ||
          (ref.read(currentPermissionsProvider).contains(Perm.employeeView) &&
              ref
                  .read(currentPermissionsProvider)
                  .contains(Perm.employeePiiEdit))) &&
      !_expired &&
      plan.status == HrReconcilePlanStatus.open &&
      plan.canApply &&
      plan.capabilities.piiEdit;

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
    _readOnlyRequested = query['readOnly'] == 'true';
    _resumeDraftId = query['draftId'];
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

  Future<void> _generatePlan({bool bindDraft = true}) async {
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
      if (!mounted ||
          generation != _loadGeneration ||
          !formDraftIdentityIsCurrent) {
        return;
      }
      setState(() {
        _plan = plan;
        _generating = false;
        _appliedOnce = false;
      });
      _disposeDrafts();
      _prepareInputControllers();
      // 换成可恢复深链(planId 供刷新/分享/核对记录，employeeIds 供过期重核对)。
      // 查询参数只放 UUID，绝不放证件号。
      context.pushReplacement(
        RoutePath.hrReconcile(
          planId: plan.id,
          employeeIds: employeeIds,
          returnTo: _returnTo,
        ),
      );
      if (bindDraft) await _bindFormDraft();
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

  Future<void> _loadPlan(
    String planId, {
    bool keepDrafts = false,
    bool bindDraft = true,
  }) async {
    final previousSnapshot = _plan != null && formDraftEnabled
        ? captureFormDraft()
        : null;
    final sourceChanged = _draftPlanId == planId;
    final generation = ++_loadGeneration;
    _activePlanId = planId;
    setState(() {
      _loading = true;
      _error = null;
      _expired = false;
    });
    try {
      final plan = await _repo.getPlan(planId);
      if (!mounted ||
          generation != _loadGeneration ||
          !formDraftIdentityIsCurrent) {
        return;
      }
      setState(() {
        _plan = plan;
        _loading = false;
        _expired = plan.expired;
      });
      if (!keepDrafts) {
        _disposeDrafts();
        _selectedIds.clear();
      }
      _prepareInputControllers();
      _requiresSourceReload = false;
      if (bindDraft &&
          sourceChanged &&
          _draftPlanVersion != plan.version &&
          previousSnapshot != null &&
          _pendingSubmission == null) {
        _retainedDraftData = previousSnapshot;
        holdFormDraftForSourceReload(StateError('核对计划版本已变化，请读取最新结果后继续'));
      } else if (bindDraft) {
        await _bindFormDraft();
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

  void _prepareInputControllers() {
    final plan = _plan;
    if (plan == null ||
        plan.status != HrReconcilePlanStatus.open ||
        !plan.canApply) {
      return;
    }
    for (final row in plan.rows) {
      if (row.kind == HrReconcileRowKind.update && _rowPending(row)) {
        _draftOf(row.rowNo);
      }
    }
  }

  Future<void> _bindFormDraft() async {
    if (!formDraftEnabled && _resumeDraftId != null) {
      await ref.read(formDraftsProvider.notifier).ready;
      if (!mounted || !formDraftIdentityIsCurrent) return;
      final stored = ref
          .read(formDraftsProvider)
          .where((draft) => draft.id == _resumeDraftId)
          .firstOrNull;
      _resumeUnknownSubmission = stored?.hasUnknownSubmission == true;
    }
    if (!formDraftEnabled) return;
    _draftPlanId = _plan!.id;
    _draftPlanVersion = _plan!.version;
    await initializeFormDraft();
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
    final plan = _plan;
    if (_busy || _confirming || plan == null || !_canExecutePlan(plan)) return;
    final selected = Set<String>.of(_selectedIds);
    final (people, items) = _applyCounts(selected);
    final l10n = AppLocalizations.of(context);
    if (people == 0) {
      context.appWarning(l10n.hrReconcileApplyHintFirst);
      return;
    }
    final skipped = _selectedWithoutValue(selected);
    setState(() => _confirming = true);
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
    if (mounted) setState(() => _confirming = false);
    if (ok != true ||
        !mounted ||
        !formDraftIdentityIsCurrent ||
        _plan?.id != plan.id ||
        _plan?.version != plan.version ||
        !_canExecutePlan(plan)) {
      return;
    }
    await _apply(selected);
  }

  Future<void> _apply(Set<String> selected) async {
    final plan = _plan;
    if (plan == null || _applying || !_canExecutePlan(plan)) return;
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
    final previousInput = captureFormDraft();
    _retainedDraftData = previousInput;
    _pendingSubmission = {
      'planId': plan.id,
      'planVersion': plan.version,
      'requestId': requestId,
      'rows': [for (final row in rows) row.toJson()],
    };
    var dispatched = false;
    setState(() => _applying = true);
    try {
      final result = await runFormDraftSubmission(
        () {
          dispatched = true;
          return _repo.apply(
            plan.id,
            planVersion: plan.version,
            requestId: requestId,
            rows: rows,
          );
        },
        isDefiniteRejection: (error) {
          final noWrite = _definiteNoApply(error);
          if (noWrite) {
            _pendingSubmission = null;
            _retainedDraftData = null;
          }
          return noWrite;
        },
      );
      if (!mounted || !formDraftIdentityIsCurrent) return;
      // 顶部通知 summary（服务端一句人话）。
      context.appSuccess(result.summary);
      await _acknowledgeSubmission(plan.id, previousInput);
    } on ApiException catch (e) {
      if (!mounted) return;
      if (!dispatched || _definiteNoApply(e)) {
        _pendingSubmission = null;
        _retainedDraftData = null;
      }
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
          await _loadPlan(plan.id);
        case _:
          context.appApiError(e);
      }
    } catch (error) {
      if (!dispatched) {
        _pendingSubmission = null;
        _retainedDraftData = null;
      }
      if (!mounted) return;
      context.appError(
        describeSubmitError(
          error,
          fallback: AppLocalizations.of(context).hrReconcileApplyFailed,
        ),
      );
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  bool _definiteNoApply(ApiException error) =>
      error.httpStatus == 400 ||
      error.httpStatus == 422 ||
      (error.httpStatus == 409 &&
          const {
            'RECONCILE_PLAN_CHANGED',
            'RECONCILE_PLAN_EXPIRED',
            'RECONCILE_PLAN_BUSY',
          }.contains(_reconcileErrorCode(error)));

  Future<void> _acknowledgeSubmission(
    String planId,
    Map<String, dynamic> previousInput,
  ) async {
    _appliedOnce = true;
    _requiresSourceReload = true;
    await resetFormDraftAfterSubmission(
      prepare: () async {
        _pendingSubmission = null;
        _knownInterruptedReceipt = null;
        _interruptionCheckpointSaved = false;
        _resumeUnknownSubmission = false;
        _retainedDraftData = null;
        await _loadPlan(planId, bindDraft: false);
        _draftPlanId = _plan?.id;
        _draftPlanVersion = _plan?.version;
      },
    );
    if (!mounted || !formDraftIdentityIsCurrent || _error != null) return;
    final plan = _plan!;
    if (plan.status == HrReconcilePlanStatus.open && plan.canApply) {
      final remaining = remainingHrReconcileDraftInputs(plan, previousInput);
      setState(() => _restoreInputs(remaining));
      await saveFormDraftNow();
    }
  }

  Future<void> _checkOriginalReceipt() async {
    final submission = _pendingSubmission;
    if (submission == null || _busy || !formDraftIdentityIsCurrent) return;
    final previousInput = captureFormDraft();
    final planId = submission['planId'] as String;
    final recoveryId = formDraftRecoveryId;
    final route = GoRouterState.of(context).uri.toString();
    final router = GoRouter.of(context);
    final navigation = router.routerDelegate.currentConfiguration;
    final loadGeneration = _loadGeneration;
    bool current() =>
        mounted &&
        formDraftIdentityIsCurrent &&
        identical(submission, _pendingSubmission) &&
        recoveryId == formDraftRecoveryId &&
        _plan?.id == planId &&
        identical(navigation, router.routerDelegate.currentConfiguration) &&
        route == GoRouterState.of(context).uri.toString() &&
        loadGeneration == _loadGeneration;
    setState(() => _checkingReceipt = true);
    try {
      final receipt = await _repo.getApplyReceipt(
        planId,
        submission['requestId'] as String,
      );
      if (!mounted || !current()) return;
      if (receipt.status == 'FINISHED' &&
          receipt.result != null &&
          hrReconcileReceiptMatchesSubmission(receipt.result!, submission)) {
        context.appSuccess(receipt.result!.summary);
        await _acknowledgeSubmission(planId, previousInput);
      } else if (receipt.status == 'INTERRUPTED') {
        final latest = await _repo.getPlan(planId);
        if (!mounted ||
            !current() ||
            latest.id != planId ||
            recoveryId == null) {
          return;
        }
        _knownInterruptedReceipt = {
          'planId': planId,
          'requestId': submission['requestId'],
          'status': 'INTERRUPTED',
          'sourcePlanVersion': submission['planVersion'],
          'observedPlanVersion': latest.version,
          'outcomes': [
            for (final row in latest.rows)
              {
                'employeeId': row.employee.id,
                'rowNo': row.rowNo,
                'sourceVersion': row.employeeVersion,
                'result': row.result?.status.name,
              },
          ],
        };
        await saveFormDraftNow();
        if (!mounted || !current()) return;
        final checkpoint = ref
            .read(formDraftsProvider)
            .where((draft) => draft.id == recoveryId)
            .firstOrNull;
        if (checkpoint == null || checkpoint.hasUnknownSubmission) {
          throw StateError('原中断记录尚未保存');
        }
        adoptFormDraftRecoveryCheckpoint(
          checkpoint,
          status: '原更正已中断，输入和处理记录已保留',
        );
        _disposeDrafts();
        setState(() {
          _plan = latest;
          _expired = latest.expired;
          _selectedIds.clear();
          _interruptionCheckpointSaved = true;
        });
        context.appWarning('原更正已中断，已完成记录可回看；重新核对需再次确认');
      } else {
        context.appWarning(
          receipt.status == 'FINISHED'
              ? '原回执与原请求尚未匹配，输入与原请求标识继续保留'
              : receipt.status == 'RUNNING'
              ? '原更正仍在执行，输入已保留，请稍后核对原结果'
              : '原更正已中断，输入已保留，请先核对已完成的记录',
        );
      }
    } catch (_) {
      if (mounted && formDraftIdentityIsCurrent) {
        context.appWarning('原更正结果尚未查明，输入和原请求标识继续保留');
      }
    } finally {
      if (mounted) setState(() => _checkingReceipt = false);
    }
  }

  Future<void> _rebuildInterruptedPlan() async {
    final submission = _pendingSubmission;
    final plan = _plan;
    if (_busy ||
        _confirming ||
        submission == null ||
        plan == null ||
        !_interruptionCheckpointSaved ||
        _knownInterruptedReceipt?['status'] != 'INTERRUPTED' ||
        plan.id != submission['planId'] ||
        !formDraftIdentityIsCurrent) {
      return;
    }
    final route = GoRouterState.of(context).uri.toString();
    final employeeIds = plan.rows.map((row) => row.employee.id).toList();
    setState(() => _confirming = true);
    final confirmed = await UtenDialog.show(
      context,
      title: '重新核对这批员工？',
      content: Text(
        '将按当前资料重新准备 ${employeeIds.length} 名员工的核对建议，原人工输入保留在本机历史。新核对需要重新填写并确认。',
      ),
      confirmLabel: '重新核对',
    );
    if (mounted) setState(() => _confirming = false);
    if (!mounted ||
        confirmed != true ||
        !formDraftIdentityIsCurrent ||
        !identical(submission, _pendingSubmission) ||
        _plan?.id != plan.id ||
        route != GoRouterState.of(context).uri.toString()) {
      return;
    }
    try {
      await saveFormDraftNow();
      final recoveryId = formDraftRecoveryId;
      final revision = formDraftRecoveryRevision;
      if (recoveryId == null || revision == null) throw StateError('原人工输入尚未保存');
      await ref
          .read(formDraftsProvider.notifier)
          .complete(recoveryId, expectedRevision: revision);
      if (!mounted || !formDraftIdentityIsCurrent) return;
      await resetFormDraftAfterSubmission(
        preserveCurrentDraft: true,
        prepare: () async {
          _pendingSubmission = null;
          _knownInterruptedReceipt = null;
          _interruptionCheckpointSaved = false;
          _resumeUnknownSubmission = false;
          _retainedDraftData = null;
          _resumeDraftId = null;
          _draftPlanId = null;
          _draftPlanVersion = null;
          _employeeIds = employeeIds;
          _requiresSourceReload = true;
          await _generatePlan(bindDraft: false);
          if (_error == null) _requiresSourceReload = false;
          _draftPlanId = _plan?.id;
          _draftPlanVersion = _plan?.version;
        },
      );
    } catch (error) {
      if (mounted && formDraftIdentityIsCurrent) {
        context.appError(
          describeSubmitError(error, fallback: '重新核对尚未准备好，原输入继续保留'),
        );
      }
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
    if (_busy || _confirming) return;
    if (formDraftEnabled) {
      if (!await confirmFormDraftExit() || !mounted) return;
      _close(_appliedOnce);
      return;
    }
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
    if (!_canReadRecords || _busy) return;
    final sessionKey = ref.read(masterDataSessionKeyProvider);
    final planId = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (_) => const _HrReconcileRecordsSheet(),
    );
    if (!mounted ||
        planId == null ||
        !_canReadRecords ||
        sessionKey != ref.read(masterDataSessionKeyProvider)) {
      return;
    }
    context.push(RoutePath.hrReconcile(planId: planId, returnTo: _returnTo));
  }

  // ── UI ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final permissions = ref.watch(currentPermissionsProvider);
    final canReadRecords =
        ref.watch(isSuperAdminProvider) ||
        (permissions.contains(Perm.employeeView) &&
            permissions.contains(Perm.employeeEdit));
    Widget body;
    if (_loading || _generating) {
      body = const UtenSkeletonList(itemCount: 6);
    } else if (_error != null) {
      body = UtenEmpty.error(
        message: _error,
        actionLabel: l10n.hrReconcileRetry,
        onAction: _retry,
      );
    } else if (_plan == null && _expired) {
      body = _expiredView(l10n);
    } else if (_plan == null) {
      body = UtenEmpty(
        icon: Icons.fact_check_outlined,
        message: l10n.hrReconcileEmptyEntry,
        actionLabel: canReadRecords ? l10n.hrReconcileRecords : null,
        onAction: canReadRecords ? _openRecords : null,
      );
    } else {
      body = _planView(context, l10n, _plan!);
    }
    if (context.breakpoint.isCompact) {
      body = UtenContentContainer(child: body);
    }
    return withFormDraft(
      PopScope(
        canPop: !_dirty && !_busy && !_appliedOnce,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && !_busy) _handleLeave();
        },
        child: Scaffold(
          appBar: UtenAppBar(
            title: l10n.hrReconcileTitle,
            leading: UtenBackButton(onPressed: _busy ? null : _handleLeave),
            actions: [
              if (canReadRecords)
                IconButton(
                  key: const Key('hr-reconcile-records'),
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
                          : _checkingReceipt
                          ? '正在核对原更正结果…'
                          : l10n.hrReconcileApplying,
                    ),
                  ),
              ],
            ),
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
    // 2026-10-09 全站表格滚动口径：摘要区进折叠头——上滑先收摘要（表头随之
    // 顶到视口顶），继续滚动才滚表格内容；竖向滚动条由联动门控（外滚阶段隐藏）。
    return RefreshIndicator(
      onRefresh: () => _loadPlan(plan.id),
      child: UtenCollapsingHeaderScrollView(
        collapsingHeader: _summaryHeader(context, l10n, plan),
        body: _table(context, l10n, plan),
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
          if (_knownInterruptedReceipt != null) ...[
            const Text('原更正已中断，已完成记录可在下表回看，原人工输入已保留。'),
            const SizedBox(height: UtenSpacing.s8),
            _originalReceiptActions(),
            const SizedBox(height: UtenSpacing.s8),
          ],
          if (!_canExecutePlan(plan))
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
                        plan.readOnlyReason ??
                            (plan.expired
                                ? l10n.hrReconcileExpiredTitle
                                : plan.status == HrReconcilePlanStatus.closed
                                ? l10n.hrReconcileStatusClosed
                                : l10n.hrReconcileReadOnlyNotice(
                                    plan.actorName,
                                  )),
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
                plan.status == HrReconcilePlanStatus.closed
                    ? '${l10n.hrReconcileRecords} · ${l10n.hrReconcileRecordCount(counts.rows)}'
                    : l10n.hrReconcileStatPeople(counts.rows - counts.applied),
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
    final editable = _canExecutePlan(plan);
    return MasterDataTableView<HrReconcileRow>(
      tableKey:
          'features.hr_task.pages.hr_reconcile_page.HrReconcilePageState._table.1',
      key: const Key('hr-reconcile-table'),
      // 折叠容器联动：拾取注入的 PrimaryScrollController，参与「收摘要 → 表格内滚」。
      primary: true,
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
      selectable: editable,
      // 他人认领/已执行/非 UPDATE 行不可勾选（已执行的不能再改）。
      idOf: (row) =>
          row.kind == HrReconcileRowKind.update &&
              !row.claimedByOther &&
              row.result == null &&
              editable
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
      ),
      // 员工合并列：姓名主行 + 工号·部门副行(2026-10-06 重做，三列并一)。
      MasterColumnDef(
        key: 'employee',
        label: l10n.hrReconcileColEmployee,
        width: 200,
        value: (row) => row.employee.name,
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
      ),
      MasterColumnDef(
        key: 'reason',
        label: l10n.hrReconcileColReason,
        width: 300,
        value: (row) => _reasonOf(row),
        // 照列表页原因列：红字折行不截断（选中行换统一前景色）。
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
      ),
      MasterColumnDef(
        key: 'notes',
        label: l10n.hrReconcileColNotes,
        width: 240,
        value: (row) =>
            row.items.isEmpty ? null : row.items.first.notes.join('；'),
        cellBuilder: (context, row) => HrReconcileNotesCell(row: row),
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
              final draft = _canExecutePlan(plan) ? _draftOf(row.rowNo) : null;
              final editable =
                  _canExecutePlan(plan) &&
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
    if (plan == null || !_canExecutePlan(plan)) return 0;
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
    if (plan == null || !_canExecutePlan(plan) || _busy) return;
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

final _hrReconcileRecordsPageProvider = FutureProvider.autoDispose
    .family<HrReconcilePlanSummaryPage, ({int page, String sessionKey})>(
      (ref, query) =>
          ref.watch(hrReconcileRepositoryProvider).listPlans(page: query.page),
    );

class _HrReconcileRecordsSheet extends ConsumerStatefulWidget {
  const _HrReconcileRecordsSheet();

  @override
  ConsumerState<_HrReconcileRecordsSheet> createState() =>
      _HrReconcileRecordsSheetState();
}

class _HrReconcileRecordsSheetState
    extends ConsumerState<_HrReconcileRecordsSheet> {
  int _page = 1;
  String? _sessionKey;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final permissions = ref.watch(currentPermissionsProvider);
    final canReadRecords =
        ref.watch(isSuperAdminProvider) ||
        (permissions.contains(Perm.employeeView) &&
            permissions.contains(Perm.employeeEdit));
    final sessionKey = ref.watch(masterDataSessionKeyProvider);
    if (_sessionKey != sessionKey) {
      _sessionKey = sessionKey;
      _page = 1;
    }
    final query = (page: _page, sessionKey: sessionKey);
    final records = canReadRecords
        ? ref.watch(_hrReconcileRecordsPageProvider(query))
        : null;
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.6,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
                child: Text(
                  l10n.hrReconcileRecordsTitle,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Expanded(
                child: records == null
                    ? const UtenEmpty(message: '当前账号没有查看核对记录的权限')
                    : records.when(
                        skipLoadingOnReload: false,
                        skipLoadingOnRefresh: false,
                        loading: () => const UtenSkeletonList(itemCount: 4),
                        error: (error, _) => UtenEmpty.error(
                          message: error is ApiException
                              ? error.message
                              : l10n.commonError,
                          actionLabel: l10n.hrReconcileRetry,
                          onAction: () => ref.invalidate(
                            _hrReconcileRecordsPageProvider(query),
                          ),
                        ),
                        data: (page) => Column(
                          children: [
                            Expanded(
                              child: page.items.isEmpty
                                  ? UtenEmpty(
                                      message: l10n.hrReconcileRecordsEmpty,
                                    )
                                  : ListView(
                                      key: ValueKey((sessionKey, page.page)),
                                      children: [
                                        for (final summary in page.items)
                                          ListTile(
                                            key: ValueKey(
                                              'hr-reconcile-record-${summary.id}',
                                            ),
                                            contentPadding: EdgeInsets.zero,
                                            title: Text(
                                              '${_recordTime(summary.createdAt)} · '
                                              '${l10n.hrReconcileRecordCount(summary.counts.rows)}',
                                            ),
                                            subtitle: Text(
                                              '${summary.actorName} · ${_recordStatusLabel(l10n, summary)}',
                                            ),
                                            onTap: () => Navigator.pop(
                                              context,
                                              summary.id,
                                            ),
                                          ),
                                      ],
                                    ),
                            ),
                            if (page.totalPages > 1)
                              UtenGridPager(
                                key: const Key('hr-reconcile-records-pager'),
                                currentPage: page.page,
                                totalPages: page.totalPages,
                                totalItems: page.total,
                                onPrev: page.page > 1
                                    ? () =>
                                          setState(() => _page = page.page - 1)
                                    : null,
                                onNext: page.page < page.totalPages
                                    ? () =>
                                          setState(() => _page = page.page + 1)
                                    : null,
                              ),
                          ],
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
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

String _recordTime(String? iso) {
  if (iso == null || iso.isEmpty) return '-';
  final parsed = DateTime.tryParse(iso);
  if (parsed == null) return iso;
  final local = parsed.isUtc ? parsed.toLocal() : parsed;
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}
