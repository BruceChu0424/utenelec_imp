import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/inputs/uten_employee_picker.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_bottom_action_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/auth/permissions.dart';
import '../models/finance_procurement_workflow.dart';
import '../repositories/finance_procurement_workflow_repository.dart';

class FinanceWorkflowResponsibilitiesPage extends ConsumerStatefulWidget {
  const FinanceWorkflowResponsibilitiesPage({super.key});

  @override
  ConsumerState<FinanceWorkflowResponsibilitiesPage> createState() =>
      _FinanceWorkflowResponsibilitiesPageState();
}

class _FinanceWorkflowResponsibilitiesPageState
    extends ConsumerState<FinanceWorkflowResponsibilitiesPage> {
  final _formKey = GlobalKey<FormState>();
  final Map<String, FinanceWorkflowResponsibility> _responsibilities = {};
  final Map<String, UtenEmployeePickerItem?> _selections = {};
  List<UtenEmployeePickerItem> _reviewers = const [];
  final Set<String> _dirty = {};
  bool _loading = false;
  bool _saving = false;
  String? _error;
  int _requestVersion = 0;

  bool get _allowed {
    return ref.read(isSuperAdminProvider) ||
        ref
            .read(currentPermissionsProvider)
            .contains(Perm.workflowAssignmentManage);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    if (!_allowed) return;
    final requestVersion = ++_requestVersion;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final repository = ref.read(financeProcurementWorkflowRepositoryProvider);
      final responsibilitiesFuture = repository.responsibilities();
      final reviewersFuture = repository.reviewers();
      final responsibilities = await responsibilitiesFuture;
      final reviewers = await reviewersFuture;
      if (!mounted || requestVersion != _requestVersion) return;

      final reviewerItems = reviewers
          .map(
            (reviewer) => UtenEmployeePickerItem(
              id: reviewer.userId,
              name: reviewer.employeeName,
              departmentName: reviewer.departmentName,
            ),
          )
          .toList(growable: false);
      final reviewersById = <String, UtenEmployeePickerItem>{
        for (final reviewer in reviewerItems) reviewer.id: reviewer,
      };
      final responsibilitiesByCode = <String, FinanceWorkflowResponsibility>{
        for (final responsibility in responsibilities)
          responsibility.behaviorCode: responsibility,
      };

      _responsibilities.clear();
      _selections.clear();
      for (final behavior in FinanceWorkflowBehavior.values) {
        final responsibility =
            responsibilitiesByCode[behavior.code] ??
            FinanceWorkflowResponsibility.empty(behavior.code);
        _responsibilities[behavior.code] = responsibility;
        final assigneeId = responsibility.assigneeUserId;
        _selections[behavior.code] = assigneeId == null
            ? null
            : reviewersById[assigneeId] ??
                  UtenEmployeePickerItem(
                    id: assigneeId,
                    name: responsibility.assigneeName ?? '原负责人（当前不可选）',
                    departmentName: responsibility.assigneeDepartmentName,
                  );
      }
      setState(() {
        _reviewers = reviewerItems;
        _dirty.clear();
        _loading = false;
      });
    } on ApiException catch (error) {
      if (!mounted || requestVersion != _requestVersion) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || requestVersion != _requestVersion) return;
      setState(() {
        _error = '负责人设置加载失败，请检查网络后重试';
        _loading = false;
      });
    }
  }

  Future<List<UtenEmployeePickerItem>> _loadReviewers(String? keyword) async {
    final normalized = keyword?.trim().toLowerCase() ?? '';
    if (normalized.isEmpty) return _reviewers;
    return _reviewers
        .where((reviewer) {
          return reviewer.name.toLowerCase().contains(normalized) ||
              (reviewer.departmentName ?? '').toLowerCase().contains(
                normalized,
              );
        })
        .toList(growable: false);
  }

  void _select(String behaviorCode, UtenEmployeePickerItem? reviewer) {
    final original = _responsibilities[behaviorCode]?.assigneeUserId;
    setState(() {
      _selections[behaviorCode] = reviewer;
      if (reviewer?.id == original) {
        _dirty.remove(behaviorCode);
      } else {
        _dirty.add(behaviorCode);
      }
    });
  }

  Future<void> _save() async {
    if (_saving || _dirty.isEmpty) return;
    if (_formKey.currentState?.validate() != true) {
      context.appError('请先为两类订货审批选择负责人');
      return;
    }
    final password = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _ResponsibilityPasswordDialog(),
    );
    if (!mounted || password == null || password.isEmpty) return;

    setState(() => _saving = true);
    final repository = ref.read(financeProcurementWorkflowRepositoryProvider);
    final pendingCodes = _dirty.toList(growable: false);
    var savedCount = 0;
    try {
      for (final behaviorCode in pendingCodes) {
        final selected = _selections[behaviorCode]!;
        final current =
            _responsibilities[behaviorCode] ??
            FinanceWorkflowResponsibility.empty(behaviorCode);
        final updated = await repository.updateResponsibility(
          behaviorCode: behaviorCode,
          assigneeUserId: selected.id,
          expectedVersion: current.version,
          password: password,
        );
        if (!mounted) return;
        _responsibilities[behaviorCode] = FinanceWorkflowResponsibility(
          behaviorCode: behaviorCode,
          assigneeUserId: selected.id,
          assigneeName: updated.assigneeName ?? selected.name,
          assigneeDepartmentName:
              updated.assigneeDepartmentName ?? selected.departmentName,
          version: updated.version,
          updatedAt: updated.updatedAt,
          updatedByName: updated.updatedByName,
        );
        setState(() => _dirty.remove(behaviorCode));
        savedCount++;
      }
      if (!mounted) return;
      context.appSuccess('审批负责人设置已保存');
      await _load();
    } on ApiException catch (error) {
      if (!mounted) return;
      context.appError(
        savedCount == 0
            ? error.message
            : '已保存 $savedCount 项，其余保存失败：${error.message}',
      );
    } catch (_) {
      if (!mounted) return;
      context.appError(
        savedCount == 0 ? '保存失败，请稍后重试' : '已保存 $savedCount 项，其余保存失败，请重试',
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final permissions = ref.watch(currentPermissionsProvider);
    final allowed =
        ref.watch(isSuperAdminProvider) ||
        permissions.contains(Perm.workflowAssignmentManage);
    final hasData = _responsibilities.isNotEmpty;
    return Scaffold(
      appBar: UtenAppBar(
        title: '审批负责人设置',
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: '/finance'),
        ),
      ),
      body: SafeArea(
        child: !allowed
            ? UtenEmpty.error(
                message: '无权管理审批负责人',
                description: '请联系管理员授予流程负责人管理权限。',
              )
            : _loading && !hasData
            ? const UtenSkeletonList(itemCount: 4)
            : _error != null && !hasData
            ? UtenEmpty.error(
                message: _error,
                actionLabel: '重新加载',
                onAction: _load,
              )
            : _buildForm(),
      ),
      bottomNavigationBar: allowed && hasData
          ? UtenBottomActionBar(
              child: UtenButton(
                key: const Key('workflow-responsibility-save'),
                size: UtenButtonSize.large,
                isExpanded: true,
                isLoading: _saving,
                icon: Icons.save_outlined,
                onPressed: _dirty.isNotEmpty && !_saving ? _save : null,
                onDisabledTap: _saving
                    ? null
                    : () => context.appWarning('请先选择需要修改的负责人'),
                child: Text(
                  _dirty.isEmpty ? '负责人设置没有改动' : '保存负责人设置（${_dirty.length} 项）',
                ),
              ),
            )
          : null,
    );
  }

  Widget _buildForm() {
    return UtenContentContainer.narrow(
      child: Form(
        key: _formKey,
        child: RefreshIndicator(
          onRefresh: _load,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s16),
            children: [
              const _ResponsibilityNotice(),
              if (_loading) ...[
                const SizedBox(height: UtenSpacing.s8),
                const LinearProgressIndicator(minHeight: 2),
              ],
              if (_error != null) ...[
                const SizedBox(height: UtenSpacing.s12),
                _SettingsInlineError(message: _error!, onRetry: _load),
              ],
              const SizedBox(height: UtenSpacing.s16),
              for (
                var i = 0;
                i < FinanceWorkflowBehavior.values.length;
                i++
              ) ...[
                _ResponsibilityCard(
                  behavior: FinanceWorkflowBehavior.values[i],
                  responsibility:
                      _responsibilities[FinanceWorkflowBehavior
                          .values[i]
                          .code] ??
                      FinanceWorkflowResponsibility.empty(
                        FinanceWorkflowBehavior.values[i].code,
                      ),
                  selected: _selections[FinanceWorkflowBehavior.values[i].code],
                  dirty: _dirty.contains(
                    FinanceWorkflowBehavior.values[i].code,
                  ),
                  saving: _saving,
                  loader: _loadReviewers,
                  onChanged: (reviewer) =>
                      _select(FinanceWorkflowBehavior.values[i].code, reviewer),
                ),
                if (i != FinanceWorkflowBehavior.values.length - 1)
                  const SizedBox(height: UtenSpacing.s12),
              ],
              const SizedBox(height: UtenSpacing.s24),
            ],
          ),
        ),
      ),
    );
  }
}

class _ResponsibilityNotice extends StatelessWidget {
  const _ResponsibilityNotice();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(UtenSpacing.s16),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.32),
        borderRadius: UtenRadius.lgAll,
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.28),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.verified_user_outlined, color: theme.colorScheme.primary),
          const SizedBox(width: UtenSpacing.s12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '一个行为只指定一名负责人',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: UtenSpacing.s4),
                Text(
                  '订货单提交后，只有指定人员会收到任务并可以处理。修改需输入当前账号密码，操作会记录审计日志。',
                  style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ResponsibilityCard extends StatelessWidget {
  const _ResponsibilityCard({
    required this.behavior,
    required this.responsibility,
    required this.selected,
    required this.dirty,
    required this.saving,
    required this.loader,
    required this.onChanged,
  });

  final FinanceWorkflowBehavior behavior;
  final FinanceWorkflowResponsibility responsibility;
  final UtenEmployeePickerItem? selected;
  final bool dirty;
  final bool saving;
  final UtenEmployeePickerLoader loader;
  final ValueChanged<UtenEmployeePickerItem?> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final updatedAt = ChinaDateTime.formatIsoInstant(
      responsibility.updatedAt,
      fallback: responsibility.updatedAt ?? '',
    );
    final metadata = <String>[
      if (responsibility.updatedByName?.isNotEmpty == true)
        '修改人：${responsibility.updatedByName}',
      if (updatedAt.isNotEmpty) '修改时间：$updatedAt',
    ];
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: UtenRadius.lgAll,
        side: BorderSide(
          color: dirty
              ? theme.colorScheme.primary
              : theme.colorScheme.outlineVariant,
          width: dirty ? 1.5 : 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.1),
                    borderRadius: UtenRadius.mdAll,
                  ),
                  child: Icon(
                    behavior.iconKey == 'purchase'
                        ? Icons.shopping_cart_checkout_outlined
                        : Icons.precision_manufacturing_outlined,
                    color: theme.colorScheme.primary,
                  ),
                ),
                const SizedBox(width: UtenSpacing.s12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        behavior.label,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: UtenSpacing.s4),
                      Text(
                        behavior.description,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: UtenSpacing.s8),
                UtenStatusBadge(
                  label: dirty
                      ? '待保存'
                      : responsibility.configured
                      ? '已设置'
                      : '未设置',
                  type: dirty
                      ? UtenStatusBadgeType.warning
                      : responsibility.configured
                      ? UtenStatusBadgeType.success
                      : UtenStatusBadgeType.danger,
                ),
              ],
            ),
            const SizedBox(height: UtenSpacing.s16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(UtenSpacing.s12),
              decoration: BoxDecoration(
                color: theme.colorScheme.tertiaryContainer.withValues(
                  alpha: 0.3,
                ),
                borderRadius: UtenRadius.mdAll,
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.lock_person_outlined,
                    size: 20,
                    color: theme.colorScheme.tertiary,
                  ),
                  const SizedBox(width: UtenSpacing.s8),
                  const Expanded(
                    child: Text(
                      '只有此人会收到并可处理',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: UtenSpacing.s12),
            UtenEmployeePicker(
              key: ValueKey('workflow-reviewer-${behavior.code}'),
              label: '财务审核负责人',
              hint: '点击选择负责人',
              sheetTitle: '选择${behavior.label}负责人',
              initial: selected,
              enabled: !saving,
              loader: loader,
              onChanged: onChanged,
              validator: (value) => value == null ? '请选择财务审核负责人' : null,
              emptyMessage: '没有可选的财务审核人员',
              emptyDescription: '候选人由服务器按在职状态和财务审核权限筛选。',
            ),
            if (metadata.isNotEmpty) ...[
              const SizedBox(height: UtenSpacing.s8),
              Text(
                metadata.join(' · '),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ResponsibilityPasswordDialog extends StatefulWidget {
  const _ResponsibilityPasswordDialog();

  @override
  State<_ResponsibilityPasswordDialog> createState() =>
      _ResponsibilityPasswordDialogState();
}

class _ResponsibilityPasswordDialogState
    extends State<_ResponsibilityPasswordDialog> {
  final _formKey = GlobalKey<FormState>();
  final _password = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  void _submit() {
    if (_formKey.currentState?.validate() != true) return;
    Navigator.of(context).pop(_password.text);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      icon: const Icon(Icons.lock_outline_rounded),
      title: const Text('确认修改审批负责人'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('修改后只会向新负责人发送后续任务。请输入当前账号密码确认，本次操作会记录审计日志。'),
            const SizedBox(height: UtenSpacing.s16),
            TextFormField(
              key: const Key('workflow-responsibility-password'),
              controller: _password,
              autofocus: true,
              obscureText: _obscure,
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(
                labelText: '当前账号密码',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  tooltip: _obscure ? '显示密码' : '隐藏密码',
                  onPressed: () => setState(() => _obscure = !_obscure),
                  icon: Icon(
                    _obscure
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                ),
              ),
              validator: (value) =>
                  value == null || value.isEmpty ? '请输入当前账号密码' : null,
              onFieldSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        UtenButton(
          size: UtenButtonSize.large,
          type: UtenButtonType.ghost,
          icon: Icons.close_rounded,
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        UtenButton(
          key: const Key('workflow-responsibility-password-confirm'),
          size: UtenButtonSize.large,
          icon: Icons.verified_user_outlined,
          onPressed: _submit,
          child: const Text('确认并保存'),
        ),
      ],
    );
  }
}

class _SettingsInlineError extends StatelessWidget {
  const _SettingsInlineError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer.withValues(alpha: 0.45),
        borderRadius: UtenRadius.mdAll,
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline_rounded, color: theme.colorScheme.error),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(child: Text(message)),
          const SizedBox(width: UtenSpacing.s8),
          UtenButton(
            size: UtenButtonSize.large,
            type: UtenButtonType.tonal,
            icon: Icons.refresh_rounded,
            onPressed: onRetry,
            child: const Text('重试'),
          ),
        ],
      ),
    );
  }
}
