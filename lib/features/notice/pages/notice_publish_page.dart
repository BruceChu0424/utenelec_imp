import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/click_guard.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/inputs/required_field_decoration.dart';
import '../../../components/inputs/uten_employee_multi_picker.dart';
import '../../../components/inputs/uten_employee_picker.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_bottom_action_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_section_header.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../department/widgets/uten_department_picker.dart';
import '../models/notice.dart';
import '../models/notice_audience.dart';
import '../providers/notice_providers.dart';

class NoticePublishPage extends ConsumerStatefulWidget {
  const NoticePublishPage({super.key});

  @override
  ConsumerState<NoticePublishPage> createState() => _NoticePublishPageState();
}

class _NoticePublishPageState extends ConsumerState<NoticePublishPage> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _contentController = TextEditingController();
  final _actionRouteController = TextEditingController();

  NoticeType _type = NoticeType.announcement;
  NoticeKind _kind = NoticeKind.normal;
  bool _topPriority = false;
  NoticeAudienceScope _audienceScope = NoticeAudienceScope.all;
  List<DeptSelection> _departments = const [];
  List<UtenEmployeePickerItem> _employees = const [];
  DateTime? _dueAt;

  static const _publishableTypes = <NoticeType>[
    NoticeType.announcement,
    NoticeType.policy,
    NoticeType.benefit,
    NoticeType.system,
    NoticeType.urgent,
  ];

  @override
  void dispose() {
    _titleController.dispose();
    _contentController.dispose();
    _actionRouteController.dispose();
    super.dispose();
  }

  Future<List<UtenEmployeePickerItem>> _loadEmployees(String? keyword) async {
    final items = await ref
        .read(noticeRepositoryProvider)
        .searchAudienceEmployees(search: keyword);
    return [
      for (final item in items)
        UtenEmployeePickerItem(
          id: item.id,
          name: item.name,
          departmentName: item.departmentName,
        ),
    ];
  }

  String _typeLabel(AppLocalizations l10n, NoticeType type) => switch (type) {
    NoticeType.announcement => l10n.noticeTypeAnnouncement,
    NoticeType.policy => l10n.noticeTypePolicy,
    NoticeType.benefit => l10n.noticeTypeBenefit,
    NoticeType.system => l10n.noticeTypeSystem,
    NoticeType.urgent => l10n.noticeTypeUrgent,
    _ => type.label,
  };

  bool get _hasSelectedAudience =>
      _departments.isNotEmpty || _employees.isNotEmpty;

  Future<void> _onPublish() async {
    final l10n = AppLocalizations.of(context);
    if (_formKey.currentState?.validate() != true) return;
    if (_audienceScope == NoticeAudienceScope.selected &&
        !_hasSelectedAudience) {
      context.appError(l10n.noticePublishValidateAudience);
      return;
    }

    try {
      NoticeAudiencePreview? preview;
      if (_audienceScope == NoticeAudienceScope.selected) {
        preview = await ref
            .read(noticeRepositoryProvider)
            .previewAudience(
              departmentIds: _departments.map((item) => item.id).toList(),
              employeeIds: _employees.map((item) => item.id).toList(),
            );
      }
      if (!mounted) return;
      final confirmed = await _confirmPublish(l10n, preview);
      if (confirmed != true || !mounted) return;

      final type = _kind == NoticeKind.todo ? NoticeType.task : _type;
      final priority = type == NoticeType.urgent
          ? NoticePriority.urgent
          : (_topPriority ? NoticePriority.important : NoticePriority.normal);
      final published = await ref
          .read(noticeRepositoryProvider)
          .publish(
            title: _titleController.text.trim(),
            content: _contentController.text.trim(),
            type: type,
            topPriority: _topPriority,
            priority: priority,
            audienceScope: _audienceScope,
            departmentIds: _departments.map((item) => item.id).toList(),
            employeeIds: _employees.map((item) => item.id).toList(),
            kind: _kind,
            actionRoute: _actionRouteController.text.trim().isEmpty
                ? null
                : _actionRouteController.text.trim(),
            dueAt: _dueAt,
          );
      ref.invalidate(noticeListProvider);
      ref.read(unreadNoticeCountProvider.notifier).refresh();
      if (!mounted) return;
      final recipientCount = published.audienceCount;
      if (recipientCount == null) {
        context.appSuccess(l10n.noticePublishPublished);
      } else {
        context.appSuccess(l10n.noticePublishPublishedTo(recipientCount));
      }
      context.go('/notice');
    } catch (error) {
      if (mounted) context.appApiError(error);
    }
  }

  Future<bool?> _confirmPublish(
    AppLocalizations l10n,
    NoticeAudiencePreview? preview,
  ) {
    final summary = preview == null
        ? l10n.noticePublishConfirmBodyAll
        : l10n.noticePublishConfirmAudience(
            preview.summary,
            preview.recipientCount,
          );
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: Icon(
          _type == NoticeType.urgent
              ? Icons.notification_important_outlined
              : Icons.send_outlined,
          color: _type == NoticeType.urgent
              ? Theme.of(dialogContext).colorScheme.error
              : Theme.of(dialogContext).colorScheme.primary,
        ),
        title: Text(l10n.noticePublishConfirmTitle),
        content: Text(summary),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(dialogContext, true),
            icon: const Icon(Icons.send_rounded),
            label: Text(l10n.noticePublishPublishButton),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: UtenAppBar(title: l10n.noticePublishTitle, showBackButton: true),
      bottomNavigationBar: UtenBottomActionBar(
        child: Row(
          children: [
            UtenActionButton(
              type: UtenActionButtonType.ghost,
              label: Text(l10n.commonCancel),
              onAction: () async {
                if (context.canPop()) {
                  context.pop();
                } else {
                  context.go('/notice');
                }
              },
            ),
            const SizedBox(width: UtenSpacing.s12),
            Expanded(
              child: UtenActionButton(
                icon: Icons.send_rounded,
                label: Text(l10n.noticePublishPublishButton),
                loadingLabel: Text(l10n.noticePublishPublishing),
                onAction: _onPublish,
              ),
            ),
          ],
        ),
      ),
      body: UtenContentContainer(
        maxWidth: 1040,
        child: Form(
          key: _formKey,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 820;
              final content = _buildContentCard(context, l10n);
              final audience = _buildAudienceColumn(context, l10n);
              return SingleChildScrollView(
                padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s24),
                child: wide
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(flex: 5, child: content),
                          const SizedBox(width: UtenSpacing.s24),
                          Expanded(flex: 4, child: audience),
                        ],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          content,
                          const SizedBox(height: UtenSpacing.s24),
                          audience,
                        ],
                      ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildContentCard(BuildContext context, AppLocalizations l10n) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        UtenSectionHeader(
          title: l10n.noticePublishContentSection,
          icon: Icons.edit_note_rounded,
        ),
        const SizedBox(height: UtenSpacing.s8),
        UtenCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SegmentedButton<NoticeKind>(
                segments: const [
                  ButtonSegment(
                    value: NoticeKind.normal,
                    icon: Icon(Icons.notifications_none_rounded),
                    label: Text('普通通知'),
                  ),
                  ButtonSegment(
                    value: NoticeKind.todo,
                    icon: Icon(Icons.task_alt_rounded),
                    label: Text('待办通知'),
                  ),
                ],
                selected: {_kind},
                onSelectionChanged: (selection) {
                  setState(() {
                    _kind = selection.first;
                    if (_kind == NoticeKind.todo) _type = NoticeType.task;
                  });
                },
              ),
              const SizedBox(height: UtenSpacing.s12),
              Text(
                _kind == NoticeKind.todo
                    ? '发布后会进入接收人的工作台待办；接收人仍需具备目标页面权限。'
                    : '普通通知只进入消息中心，不会产生待办任务。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: UtenSpacing.s16),
              if (_kind == NoticeKind.normal)
                DropdownButtonFormField<NoticeType>(
                  initialValue: _type,
                  decoration: InputDecoration(
                    labelText: l10n.noticePublishTypeLabel,
                    prefixIcon: Icon(_type.icon, color: _type.color),
                    border: const OutlineInputBorder(),
                  ),
                  items: [
                    for (final type in _publishableTypes)
                      DropdownMenuItem(
                        value: type,
                        child: Text(_typeLabel(l10n, type)),
                      ),
                  ],
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() => _type = value);
                  },
                )
              else ...[
                TextFormField(
                  controller: _actionRouteController,
                  maxLength: 500,
                  decoration: const InputDecoration(
                    labelText: '办理页面（可选）',
                    hintText: '例如 /production/schedule',
                    prefixIcon: Icon(Icons.link_rounded),
                    border: OutlineInputBorder(),
                    helperText: '仅支持应用内以 / 开头的路径',
                  ),
                  validator: (value) {
                    final route = value?.trim() ?? '';
                    if (route.isNotEmpty &&
                        (!route.startsWith('/') || route.startsWith('//'))) {
                      return '请输入有效的站内路径';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: UtenSpacing.s8),
                OutlinedButton.icon(
                  onPressed: _pickDueDate,
                  icon: const Icon(Icons.event_outlined),
                  label: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _dueAt == null
                          ? '设置截止日期（可选）'
                          : '截止日期：${_dueAt!.year}-'
                                '${_dueAt!.month.toString().padLeft(2, '0')}-'
                                '${_dueAt!.day.toString().padLeft(2, '0')}',
                    ),
                  ),
                ),
              ],
              if (_kind == NoticeKind.normal && _type == NoticeType.urgent) ...[
                const SizedBox(height: UtenSpacing.s8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.warning_amber_rounded,
                      size: 18,
                      color: theme.colorScheme.error,
                    ),
                    const SizedBox(width: UtenSpacing.s8),
                    Expanded(
                      child: Text(
                        l10n.noticePublishUrgentHint,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: UtenSpacing.s16),
              ListenableBuilder(
                listenable: _titleController,
                builder: (context, _) {
                  final empty = _titleController.text.trim().isEmpty;
                  return TextFormField(
                    controller: _titleController,
                    maxLength: 200,
                    textInputAction: TextInputAction.next,
                    decoration: applyRequiredEmpty(
                      InputDecoration(
                        label: requiredLabel(
                          l10n.noticePublishTitleLabel,
                          theme,
                          required: true,
                          base: theme.inputDecorationTheme.labelStyle,
                        ),
                        hintText: l10n.noticePublishTitleHint,
                        border: const OutlineInputBorder(),
                      ),
                      theme,
                      requiredEmpty: empty,
                    ),
                    validator: (value) => value?.trim().isEmpty ?? true
                        ? l10n.noticePublishValidateTitle
                        : null,
                  );
                },
              ),
              const SizedBox(height: UtenSpacing.s12),
              ListenableBuilder(
                listenable: _contentController,
                builder: (context, _) {
                  final empty = _contentController.text.trim().isEmpty;
                  return TextFormField(
                    controller: _contentController,
                    minLines: 10,
                    maxLines: 16,
                    maxLength: 20000,
                    decoration: applyRequiredEmpty(
                      InputDecoration(
                        label: requiredLabel(
                          l10n.noticePublishContentLabel,
                          theme,
                          required: true,
                          base: theme.inputDecorationTheme.labelStyle,
                        ),
                        hintText: l10n.noticePublishContentHint,
                        alignLabelWithHint: true,
                        border: const OutlineInputBorder(),
                      ),
                      theme,
                      requiredEmpty: empty,
                    ),
                    validator: (value) => value?.trim().isEmpty ?? true
                        ? l10n.noticePublishValidateContent
                        : null,
                  );
                },
              ),
              SwitchListTile.adaptive(
                value: _topPriority,
                contentPadding: EdgeInsets.zero,
                title: Text(l10n.noticePublishTopPriority),
                subtitle: Text(l10n.noticePublishTopPriorityHint),
                secondary: const Icon(Icons.push_pin_outlined),
                onChanged: (value) => setState(() => _topPriority = value),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _pickDueDate() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: _dueAt ?? now,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: DateTime(now.year + 3),
      helpText: '选择待办截止日期',
    );
    if (date == null || !mounted) return;
    setState(() {
      _dueAt = DateTime(date.year, date.month, date.day, 23, 59);
    });
  }

  Widget _buildAudienceColumn(BuildContext context, AppLocalizations l10n) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        UtenSectionHeader(
          title: l10n.noticePublishScopeTitle,
          icon: Icons.groups_2_outlined,
        ),
        const SizedBox(height: UtenSpacing.s8),
        UtenCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SegmentedButton<NoticeAudienceScope>(
                segments: [
                  ButtonSegment(
                    value: NoticeAudienceScope.all,
                    icon: const Icon(Icons.public_rounded),
                    label: Text(l10n.noticePublishScopeAll),
                  ),
                  ButtonSegment(
                    value: NoticeAudienceScope.selected,
                    icon: const Icon(Icons.tune_rounded),
                    label: Text(l10n.noticePublishScopeSelected),
                  ),
                ],
                selected: {_audienceScope},
                onSelectionChanged: (selection) {
                  setState(() => _audienceScope = selection.first);
                },
              ),
              const SizedBox(height: UtenSpacing.s12),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: _audienceScope == NoticeAudienceScope.all
                    ? _AudienceHint(
                        key: const ValueKey('all-audience'),
                        icon: Icons.domain_rounded,
                        title: l10n.noticePublishScopeAll,
                        message: l10n.noticePublishScopeAllHint,
                      )
                    : Column(
                        key: const ValueKey('selected-audience'),
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            l10n.noticePublishScopeSelectedHint,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: UtenSpacing.s16),
                          UtenDepartmentPicker(
                            mode: UtenDepartmentPickerMode.multi,
                            initialSelection: _departments,
                            label: l10n.noticePublishDepartmentsLabel,
                            hint: l10n.noticePublishDepartmentsHint,
                            onChanged: (selection) {
                              setState(() => _departments = selection);
                            },
                          ),
                          const SizedBox(height: UtenSpacing.s16),
                          UtenEmployeeMultiPicker(
                            loader: _loadEmployees,
                            initialSelection: _employees,
                            label: l10n.noticePublishEmployeesLabel,
                            hint: l10n.noticePublishEmployeesHint,
                            sheetTitle: l10n.noticePublishEmployeePickerTitle,
                            searchHint: l10n.noticePublishEmployeeSearchHint,
                            emptyMessage: l10n.noticePublishEmployeeEmpty,
                            selectedCountLabel:
                                l10n.noticePublishEmployeeSelectedCount,
                            clearLabel: l10n.noticePublishEmployeeClear,
                            confirmLabel: l10n.noticePublishEmployeeConfirm,
                            onChanged: (selection) {
                              setState(() => _employees = selection);
                            },
                          ),
                          const SizedBox(height: UtenSpacing.s16),
                          _AudienceHint(
                            icon: Icons.filter_alt_outlined,
                            title: l10n.noticePublishAudienceSummary(
                              _departments.length,
                              _employees.length,
                            ),
                            message: l10n.noticePublishAudienceRecalculateHint,
                          ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _AudienceHint extends StatelessWidget {
  const _AudienceHint({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: UtenRadius.mdAll,
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: theme.colorScheme.primary),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: UtenSpacing.s4),
                Text(
                  message,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
