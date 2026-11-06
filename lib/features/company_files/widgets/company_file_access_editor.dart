import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_dialog_modules.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../components/inputs/uten_employee_picker.dart';
import '../../../shared/widgets/uten_department_picker.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/authenticated_request_scope.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../../../shared/widgets/sensitive_content_boundary.dart';
import '../models/company_file.dart';
import '../models/company_file_access_draft.dart';
import '../repositories/company_file_repository.dart';

/// An overlay must never re-adopt old private content after A -> B -> A.
class CompanyFileScopeBoundary extends StatelessWidget {
  const CompanyFileScopeBoundary({
    super.key,
    required this.boundary,
    required this.child,
    this.scope,
    this.isCurrent,
  });

  final SensitiveReadBoundary boundary;
  final AuthenticatedRequestScope? scope;
  final Widget child;
  final bool Function()? isCurrent;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return SensitiveContentBoundary(
      boundary: boundary,
      scope: scope,
      isCurrent: isCurrent,
      child: child,
      invalidatedBuilder: (context) => UtenAlertDialog(
        showCloseButton: true,
        onClose: () => Navigator.pop(context),
        title: Text(l.companyFilesPermissionDenied),
      ),
    );
  }
}

/// The library supplies authorized account IDs; shared selectors own presentation.
Future<CompanyFilePrincipal?> showCompanyFilePrincipalPicker(
  BuildContext context, {
  required CompanyFileRepository repository,
  required AuthenticatedRequestScope scope,
  required SensitiveReadBoundary boundary,
  String type = 'USER',
}) async {
  final l = AppLocalizations.of(context);
  Widget protect(BuildContext _, Widget child) =>
      CompanyFileScopeBoundary(boundary: boundary, scope: scope, child: child);
  if (type == 'DEPARTMENT') {
    final tree = await scope.run(repository.principalDepartments);
    if (!context.mounted || !scope.isCurrent) return null;
    final selected = await showUtenDepartmentPickerPanel(
      context,
      tree: tree,
      selectablePredicate: (_) => true,
      scopeBuilder: protect,
    );
    if (!scope.isCurrent || selected == null || selected.isEmpty) return null;
    final department = selected.single;
    return CompanyFilePrincipal(
      id: department.id,
      name: department.name,
      detail: department.fullPath,
      type: type,
    );
  }
  final candidates = <String, CompanyFilePrincipal>{};
  final selected = await showUtenEmployeeSelectionPanel(
    context,
    title: l.companyFilesAddReader,
    searchHint: l.companyFilesPrincipalSearch,
    emptyMessage: l.companyFilesNoResults,
    candidateScopeKey: (boundary, scope),
    scopeBuilder: protect,
    cancelDepartmentTreeReadOnClose: true,
    departmentTreeLoader: () => scope.run(repository.principalDepartments),
    pagedLoader: (query) async {
      final page = await scope.run(
        () => repository.principalsPage(
          type: 'USER',
          search: query.keyword ?? '',
          page: query.page,
          departmentId: query.departmentId,
          includeSubtree: query.includeDepartmentSubtree,
        ),
      );
      if (page.page != query.page ||
          page.items.any((row) => row.type != 'USER' || row.id.isEmpty)) {
        throw const FormatException('资料库授权主体分页响应无效');
      }
      for (final row in page.items) {
        candidates[row.id] = row;
      }
      return UtenEmployeePickerPage(
        page: page.page,
        totalPages: page.totalPages,
      total: page.total,
        items: [
          for (final row in page.items)
            UtenEmployeePickerItem(
              id: row.id,
              name: row.name,
              departmentId: row.departmentId,
              departmentName: row.detail,
            ),
        ],
      );
    },
  );
  if (!scope.isCurrent || selected == null || selected.isEmpty) return null;
  return candidates[selected.single.id];
}

/// Only entry-local reading rules are offered during creation. Existing advanced
/// operation ACLs are edited separately and never reconstructed from this widget.
class CompanyFileInitialAccessEditor extends StatefulWidget {
  const CompanyFileInitialAccessEditor({
    super.key,
    required this.repository,
    required this.scope,
    required this.boundary,
    required this.onChanged,
    this.initialValue = const CompanyFileInitialAccessDraft.everyoneVisible(),
    this.enabled = true,
  });

  final CompanyFileRepository repository;
  final AuthenticatedRequestScope scope;
  final SensitiveReadBoundary boundary;
  final ValueChanged<CompanyFileInitialAccessDraft> onChanged;
  final CompanyFileInitialAccessDraft initialValue;
  final bool enabled;

  @override
  State<CompanyFileInitialAccessEditor> createState() =>
      _CompanyFileInitialAccessEditorState();
}

/// 「谁可以查看」的三种口径：全员可见 / 跟随所在文件夹 / 指定人员或部门。
enum _InitialAccessMode { everyone, inherit, specific }

class _CompanyFileInitialAccessEditorState
    extends State<CompanyFileInitialAccessEditor> {
  late _InitialAccessMode _mode = widget.initialValue.marksEveryone
      ? _InitialAccessMode.everyone
      : widget.initialValue.inheritPermissions
      ? _InitialAccessMode.inherit
      : _InitialAccessMode.specific;
  late bool _passwordEnabled = widget.initialValue.password != null;
  late final _password = TextEditingController(
    text: widget.initialValue.password,
  );
  late final _repeat = TextEditingController(
    text: widget.initialValue.password,
  );
  late final List<CompanyFileAccessRule> _rules = widget.initialValue.rules
      .where((rule) => !rule.isEveryoneRule)
      .toList();
  bool _picking = false;
  String? _error;

  bool get _enabled => widget.enabled && !_picking && widget.scope.isCurrent;

  @override
  void dispose() {
    _password.clear();
    _repeat.clear();
    _password.dispose();
    _repeat.dispose();
    super.dispose();
  }

  void _publish() => widget.onChanged(
    CompanyFileInitialAccessDraft(
      inheritPermissions: _mode != _InitialAccessMode.specific,
      rules: _mode == _InitialAccessMode.everyone
          ? [kCompanyFileEveryoneRule, ..._rules]
          : _rules,
      password: _passwordEnabled ? _password.text : null,
    ),
  );

  Future<void> _add(String effect, [String type = 'USER']) async {
    if (!_enabled) return;
    final l = AppLocalizations.of(context);
    if (_rules.length >= 100) {
      setState(() => _error = l.companyFilesAccessRuleLimit);
      return;
    }
    setState(() => _picking = true);
    try {
      final principal = await showCompanyFilePrincipalPicker(
        context,
        repository: widget.repository,
        scope: widget.scope,
        boundary: widget.boundary,
        type: type,
      );
      if (!mounted || !widget.scope.isCurrent || principal == null) return;
      if (_rules.any(
        (rule) =>
            rule.subjectType == principal.type &&
            rule.subjectId == principal.id &&
            rule.effect == effect,
      )) {
        setState(() => _error = l.companyFilesDuplicateRule);
        return;
      }
      setState(() {
        _error = null;
        _rules.add(
          CompanyFileAccessRule(
            subjectType: principal.type,
            subjectId: principal.id,
            subjectName: principal.name,
            effect: effect,
          ),
        );
      });
      _publish();
    } catch (error) {
      if (mounted && widget.scope.isCurrent) {
        setState(
          () => _error = error is ApiException
              ? error.message
              : l.companyFilesLoadFailed,
        );
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Widget _readers(String effect, String title) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final readers = _rules.asMap().entries.where(
      (row) => row.value.effect == effect,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(title, style: theme.textTheme.titleSmall),
        const SizedBox(height: UtenSpacing.s8),
        for (final row in readers)
          ListTile(
            key: ValueKey(
              'initial-access-rule-${row.value.subjectType}-${row.value.subjectId}-$effect',
            ),
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              row.value.subjectType == 'USER'
                  ? Icons.person_outline
                  : Icons.groups_outlined,
            ),
            title: Text(row.value.subjectName),
            trailing: IconButton(
              tooltip: l.companyFilesRemoveRule,
              onPressed: !_enabled
                  ? null
                  : () {
                      setState(() => _rules.removeAt(row.key));
                      _publish();
                    },
              icon: const Icon(Icons.close),
            ),
          ),
        Wrap(
          spacing: UtenSpacing.s8,
          runSpacing: UtenSpacing.s8,
          children: [
            for (final type in const ['USER', 'DEPARTMENT'])
              UtenButton(
                key: ValueKey(
                  type == 'USER'
                      ? 'initial-access-add-${effect.toLowerCase()}'
                      : 'initial-access-add-${effect.toLowerCase()}-department',
                ),
                type: UtenButtonType.ghost,
                icon: type == 'USER'
                    ? Icons.person_add_alt_outlined
                    : Icons.group_add_outlined,
                onPressed: _enabled ? () => _add(effect, type) : null,
                child: Text(
                  type == 'USER'
                      ? l.companyFilesUser
                      : l.companyFilesDepartment,
                ),
              ),
          ],
        ),
      ],
    );
  }

  void _selectInitialMode(_InitialAccessMode? value) {
    if (!_enabled || value == null) return;
    setState(() => _mode = value);
    _publish();
  }

  void _setPasswordEnabled(bool value) {
    setState(() {
      _passwordEnabled = value;
      if (!value) {
        _password.clear();
        _repeat.clear();
      }
    });
    _publish();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(l.companyFilesWhoCanRead, style: theme.textTheme.titleMedium),
        const SizedBox(height: UtenSpacing.s8),
        RadioGroup<_InitialAccessMode>(
          groupValue: _mode,
          onChanged: _selectInitialMode,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final option in [
                (
                  _InitialAccessMode.everyone,
                  'initial-access-everyone',
                  Icons.public_outlined,
                  l.companyFilesEveryoneCanRead,
                ),
                (
                  _InitialAccessMode.inherit,
                  'initial-access-inherit',
                  Icons.account_tree_outlined,
                  l.companyFilesInheritEntryAccess,
                ),
                (
                  _InitialAccessMode.specific,
                  'initial-access-specific',
                  Icons.people_outline_rounded,
                  l.companyFilesSpecificReaders,
                ),
              ]) ...[
                if (option.$1 != _InitialAccessMode.everyone)
                  const SizedBox(height: UtenSpacing.s12),
                UtenDialogSettingTile(
                  canRequestFocus: false,
                  key: Key(option.$2),
                  icon: option.$3,
                  title: Text(option.$4),
                  selected: _mode == option.$1,
                  onTap: !_enabled ? null : () => _selectInitialMode(option.$1),
                  trailing: Radio<_InitialAccessMode>(
                    value: option.$1,
                    enabled: _enabled,
                  ),
                ),
              ],
            ],
          ),
        ),
        Text(switch (_mode) {
          _InitialAccessMode.everyone => l.companyFilesEveryoneReadHint,
          _InitialAccessMode.inherit => l.companyFilesAccessHint,
          _InitialAccessMode.specific => l.companyFilesSpecificReadersHint,
        }, style: theme.textTheme.bodySmall),
        if (_mode != _InitialAccessMode.inherit || _rules.isNotEmpty) ...[
          const SizedBox(height: UtenSpacing.s16),
          if (_mode == _InitialAccessMode.specific) ...[
            if (_rules.isEmpty) ...[
              Text(
                l.companyFilesNoReadersSelected,
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: UtenSpacing.s12),
            ],
            _readers('ALLOW', l.companyFilesAllowedReaders),
            const SizedBox(height: UtenSpacing.s12),
          ],
          _readers('DENY', l.companyFilesDeniedReaders),
        ],
        const SizedBox(height: UtenSpacing.s16),
        const Divider(),
        UtenDialogSettingTile(
          canRequestFocus: false,
          icon: Icons.shield_outlined,
          title: Text(l.companyFilesSetInitialPassword),
          subtitle: Text(l.companyFilesEntryPasswordHint),
          onTap: !_enabled
              ? null
              : () => _setPasswordEnabled(!_passwordEnabled),
          trailing: Switch(
            key: const Key('initial-access-password-switch'),
            value: _passwordEnabled,
            onChanged: !_enabled ? null : _setPasswordEnabled,
          ),
        ),
        if (_passwordEnabled) ...[
          const SizedBox(height: UtenSpacing.s12),
          UtenInput(
            key: const Key('initial-access-password'),
            label: l.companyFilesNewPassword,
            controller: _password,
            isPassword: true,
            aiSensitive: true,
            enabled: _enabled,
            required: true,
            autofillHints: const [],
            info: l.companyFilesPasswordByteLimit,
            validator: (value) =>
                !_passwordEnabled ||
                    (value != null &&
                        value.trim().isNotEmpty &&
                        value.runes.length >= 8 &&
                        utf8.encode(value).length <= 72)
                ? null
                : l.companyFilesPasswordByteLimit,
            onChanged: (_) => _publish(),
          ),
          const SizedBox(height: UtenSpacing.s12),
          UtenInput(
            key: const Key('initial-access-password-repeat'),
            label: l.companyFilesRepeatPassword,
            controller: _repeat,
            isPassword: true,
            aiSensitive: true,
            enabled: _enabled,
            required: true,
            autofillHints: const [],
            validator: (value) => !_passwordEnabled || value == _password.text
                ? null
                : l.companyFilesPasswordMismatch,
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: UtenSpacing.s12),
          Text(
            _error!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ],
      ],
    );
  }
}
