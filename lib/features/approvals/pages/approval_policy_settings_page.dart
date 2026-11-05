import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/buttons/uten_close_button.dart';
import '../../../components/buttons/uten_refresh_button.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/inputs/uten_employee_picker.dart';
import '../../../components/inputs/uten_field_hint_icon.dart';
import '../../../components/layout/uten_adaptive_panel.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/auth/sensitive_write.dart';
import '../../../shared/badges/badge_registry.dart';
import '../../../shared/models/retained_async_page.dart';
import '../../../shared/providers/export_context_epoch_provider.dart';
import '../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../../../shared/providers/session_provider.dart';
import '../../../shared/widgets/sensitive_content_boundary.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../repositories/approval_policy_repository.dart';

const _policyHint =
    '普通申请按部门审核权限与实际管辖范围处理；部门负责人本人的申请交预先配置的替补审批人，不能本人审批。替补须在职、有有效账号及相应审批和原件权限。同一轮不同审批节点仍须分人办理。负责人不能自行改变本部门的回避审批人，须由另一配置管理员设置。修改负责人或此配置后，已提交的负责人本人申请须撤回重提。';

class ApprovalPolicySettingsPage extends ConsumerStatefulWidget {
  const ApprovalPolicySettingsPage({super.key});
  @override
  ConsumerState<ApprovalPolicySettingsPage> createState() =>
      _ApprovalPolicySettingsPageState();
}

class _ApprovalPolicySettingsPageState
    extends ConsumerState<ApprovalPolicySettingsPage> {
  final _retained = RetainedAsyncPage<List<ApprovalDepartmentPolicy>>();
  bool _refreshing = false;
  Future<void> _refresh() async {
    if (_refreshing) return;
    final epoch = ref.read(exportContextEpochProvider);
    setState(() => _refreshing = true);
    try {
      ref.invalidate(approvalDepartmentPoliciesProvider);
      await ref.read(approvalDepartmentPoliciesProvider.future);
    } catch (error) {
      if (mounted && ref.read(exportContextEpochProvider) == epoch) {
        setState(() => _refreshing = false);
        context.appApiError(error);
      }
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _edit(ApprovalDepartmentPolicy policy) async {
    final boundary = ref.read(sensitiveReadBoundaryProvider);
    final epoch = ref.read(exportContextEpochProvider);
    final updated = await showUtenAdaptivePanel<bool>(
      context: context,
      drawerWidth: 560,
      widthFraction: UtenPanelWidth.form,
      builder: (_) => SensitiveContentBoundary(
        boundary: boundary,
        isCurrent: () => ref.read(exportContextEpochProvider) == epoch,
        invalidatedBuilder: (dialogContext) => Scaffold(
          appBar: UtenAppBar(
            title: '审批设置',
            actions: [
              UtenCloseButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
              ),
            ],
          ),
          body: const UtenEmpty(message: '授权已变化，请关闭后重新打开'),
        ),
        child: _PolicyEditor(policy: policy),
      ),
    );
    if (mounted &&
        updated == true &&
        ref.read(exportContextEpochProvider) == epoch) {
      await _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final allowed = ref
        .watch(currentPermissionsProvider)
        .contains(Perm.approvalPolicyManage);
    final boundary = ref.watch(sensitiveReadBoundaryProvider);
    final canWrite =
        allowed && boundary.identity != null && !boundary.identity!.readOnly;
    final employeeId = ref.watch(
      sessionProvider.select((value) => value.user?.employeeId),
    );
    bool ownManager(ApprovalDepartmentPolicy row) =>
        row.managerId != null && row.managerId == employeeId;
    bool canConfigure(ApprovalDepartmentPolicy row) =>
        canWrite && !ownManager(row);

    final policies = allowed
        ? _retained.resolveFor(
            ref,
            'approval-policy',
            approvalDepartmentPoliciesProvider,
          )
        : null;
    return Scaffold(
      appBar: UtenAppBar(
        title: '审批设置',
        info: _policyHint,
        showBackButton: true,
        actions: [
          if (allowed)
            UtenRefreshButton(onRefresh: _refresh, busy: _refreshing),
        ],
      ),
      body: !allowed
          ? const UtenEmpty(message: '没有审批设置权限')
          : Stack(
              children: [
                UtenContentContainer.wide(
                  child: MasterDataTableView<ApprovalDepartmentPolicy>(
                    key: const Key('approval-policy-table'),
                    tableKey: 'approval-policy.departments',
                    columns: [
                      MasterColumnDef(
                        key: 'department',
                        label: '部门',
                        width: 200,
                        value: (row) => row.departmentName,
                      ),
                      MasterColumnDef(
                        key: 'manager',
                        label: '部门负责人',
                        width: 150,
                        value: (row) => row.managerName ?? '未设置',
                      ),
                      MasterColumnDef(
                        key: 'substitute',
                        label: '负责人本人申请审批人',
                        width: 220,
                        info: '只处理该部门负责人本人的部门审核环节。不会获得财务复核或总经办审批权。',
                        value: (row) => row.substituteEmployeeName ?? '未配置',
                      ),
                      if (canWrite)
                        MasterColumnDef(
                          key: 'configure',
                          label: '操作',
                          width: 160,
                          value: (_) => '配置',
                          cellBuilder: (_, row) => Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              UtenButton(
                                key: ValueKey(
                                  'approval-policy-edit-${row.departmentId}',
                                ),
                                type: UtenButtonType.tonal,
                                size: UtenButtonSize.small,
                                onPressed: canConfigure(row)
                                    ? () => _edit(row)
                                    : null,
                                child: const Text('配置'),
                              ),
                              if (ownManager(row))
                                const UtenFieldHintIcon(
                                  compact: true,
                                  info: '不能自行修改本人申请的回避审批人，请由另一配置管理员设置。',
                                ),
                            ],
                          ),
                        ),
                      MasterColumnDef(
                        key: 'policy',
                        label: '普通申请审核范围',
                        width: 260,
                        value: (_) => '部门审核权限与实际管辖范围',
                      ),
                    ],
                    items: policies?.value ?? const [],
                    facets: const {},
                    nullCounts: const {},
                    filters: const {},
                    onFilterChanged: (_, _) {},
                    onRowTap: canWrite
                        ? (row) => canConfigure(row)
                              ? _edit(row)
                              : Future<void>.value()
                        : null,
                    isLoading:
                        policies?.isLoading == true &&
                        policies?.hasValue != true,
                    isRefreshing:
                        policies?.isLoading == true &&
                        policies?.hasValue == true,
                    error: policies?.hasError == true ? '审批设置读取失败，请刷新重试' : null,
                    onRetry: _refresh,
                    emptyMessage: '暂无可配置部门',
                    paginationScope: ref.watch(exportContextEpochProvider),
                  ),
                ),
                if (_refreshing)
                  const UtenBusyOverlay(
                    title: '正在读取审批设置',
                    showDoNotLeaveHint: false,
                  ),
              ],
            ),
    );
  }
}

class _PolicyEditor extends ConsumerStatefulWidget {
  const _PolicyEditor({required this.policy});
  final ApprovalDepartmentPolicy policy;
  @override
  ConsumerState<_PolicyEditor> createState() => _PolicyEditorState();
}

class _PolicyEditorState extends ConsumerState<_PolicyEditor> {
  late ApprovalDepartmentPolicy _policy = widget.policy;
  late UtenEmployeePickerItem? _selected = _policy.substituteEmployeeId == null
      ? null
      : UtenEmployeePickerItem(
          id: _policy.substituteEmployeeId!,
          name: _policy.substituteEmployeeName ?? '原审批人',
        );
  bool _busy = false, _uncertain = false, _candidateLoading = false;
  int _candidateGeneration = 0;
  bool get _changed => _selected?.id != _policy.substituteEmployeeId;

  Future<void> _reconcile() async {
    if (_busy) return;
    final epoch = ref.read(exportContextEpochProvider);
    setState(() => _busy = true);
    try {
      final rows = await ref
          .read(approvalPolicyRepositoryProvider)
          .departments();
      if (!mounted || ref.read(exportContextEpochProvider) != epoch) return;
      final latest = rows
          .where((row) => row.departmentId == _policy.departmentId)
          .firstOrNull;
      if (latest == null) throw const FormatException('该部门已不存在，请关闭后重新读取');
      setState(() {
        _policy = latest;
        _uncertain = false;
      });
    } catch (error) {
      if (mounted && ref.read(exportContextEpochProvider) == epoch) {
        setState(() => _busy = false);
        context.appApiError(error);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    if (_busy || _uncertain || !_changed) return;
    if (_selected != null && _selected!.id == _policy.managerId) {
      context.appWarning('部门负责人不能审批本人的申请');
      return;
    }
    final epoch = ref.read(exportContextEpochProvider);
    final boundary = ref.read(sensitiveReadBoundaryProvider);
    bool current() =>
        mounted &&
        ref.read(exportContextEpochProvider) == epoch &&
        ref.read(sensitiveReadBoundaryProvider) == boundary &&
        boundary.permissions.contains(Perm.approvalPolicyManage);
    var sent = false;
    setState(() => _busy = true);
    try {
      await runSensitiveWrite(
        ref,
        isCurrent: current,
        write: () {
          sent = true;
          return ref
              .read(approvalPolicyRepositoryProvider)
              .save(_policy, _selected?.id);
        },
      );
      if (!mounted || !current()) return;
      setState(() => _busy = false);
      ref.invalidate(approvalDepartmentPoliciesProvider);
      refreshBadges(ref);
      Navigator.of(context).pop(true);
      context.appSuccess('审批设置已保存');
    } catch (error) {
      if (mounted && current()) {
        setState(() {
          _busy = false;
          _uncertain =
              sent &&
              !(error is ApiException &&
                  error.hasResponseCode &&
                  const {400, 403, 404, 409, 422}.contains(error.httpStatus));
        });
        context.appApiError(error, fallback: '设置结果待核对，当前选择已保留');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final boundary = ref.watch(sensitiveReadBoundaryProvider);
    final employeeId = ref.watch(
      sessionProvider.select((value) => value.user?.employeeId),
    );
    final allowed =
        boundary.permissions.contains(Perm.approvalPolicyManage) &&
        boundary.identity != null &&
        !boundary.identity!.readOnly &&
        !(_policy.managerId != null && _policy.managerId == employeeId);
    final epoch = ref.watch(exportContextEpochProvider);
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: UtenAppBar(
          title: '部门审批回避',
          info: _policyHint,
          actions: [
            UtenCloseButton(
              onPressed: _busy ? null : () => Navigator.of(context).pop(),
            ),
          ],
          showPagePermissionAction: false,
        ),
        body: Stack(
          children: [
            UtenContentContainer(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  0,
                  UtenSpacing.s16,
                  0,
                  UtenFloatingActionGroup.scrollClearance,
                ),
                children: [
                  Text(
                    _policy.departmentName,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: UtenSpacing.s16),
                  Text('部门负责人  ${_policy.managerName ?? '未设置'}'),
                  const SizedBox(height: UtenSpacing.s20),
                  UtenEmployeePicker(
                    key: const Key('approval-policy-substitute'),
                    initial: _selected,
                    label: '负责人本人申请时的审批人',
                    sheetTitle: '选择回避审批人',
                    allowClear: true,
                    enabled: allowed && !_busy && !_uncertain,
                    presentation:
                        UtenEmployeePickerPresentation.businessReference,
                    showDepartmentFilter: false,
                    candidateScopeKey: (_policy.departmentId, epoch),
                    pagedLoader: (query) async {
                      final generation = ++_candidateGeneration;
                      await Future<void>.value();
                      if (!mounted ||
                          ref.read(exportContextEpochProvider) != epoch) {
                        return UtenEmployeePickerPage.empty(page: query.page);
                      }
                      setState(() => _candidateLoading = true);
                      try {
                        final result = await ref
                            .read(approvalPolicyRepositoryProvider)
                            .candidatesPage(
                              _policy.departmentId,
                              query.keyword,
                              page: query.page,
                            );
                        return mounted &&
                                generation == _candidateGeneration &&
                                ref.read(exportContextEpochProvider) == epoch
                            ? result
                            : UtenEmployeePickerPage.empty(page: query.page);
                      } finally {
                        if (mounted && generation == _candidateGeneration) {
                          setState(() => _candidateLoading = false);
                        }
                      }
                    },
                    onChanged: (value) => setState(() => _selected = value),
                  ),
                  const SizedBox(height: UtenSpacing.s12),
                  Row(
                    children: [
                      Text(
                        _uncertain
                            ? '设置结果待核对'
                            : _selected == null
                            ? '未配置回避审批人'
                            : '已选择回避审批人',
                      ),
                      const UtenFieldHintIcon(
                        info:
                            '未配置时，负责人本人的申请不能自动跳过部门审核。配置只改变负责人本人申请的首审责任，不授予被选员工新权限。',
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (_busy || _candidateLoading)
              const UtenBusyOverlay(
                title: '正在处理审批设置',
                showDoNotLeaveHint: false,
              ),
          ],
        ),
        floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
        floatingActionButtonAnimator: FloatingActionButtonAnimator.noAnimation,
        floatingActionButton: allowed
            ? UtenFloatingActionGroup(
                children: [
                  if (_uncertain)
                    UtenButton(
                      onPressed: _busy ? null : _reconcile,
                      child: const Text('核对设置'),
                    )
                  else
                    UtenButton(
                      key: const Key('approval-policy-save'),
                      onPressed: _busy || !_changed ? null : _save,
                      icon: Icons.save_outlined,
                      child: const Text('保存设置'),
                    ),
                ],
              )
            : null,
      ),
    );
  }
}
