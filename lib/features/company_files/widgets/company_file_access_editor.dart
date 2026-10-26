import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../components/inputs/uten_search_bar.dart';
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
        title: Text(l.companyFilesPermissionDenied),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l.companyFilesClose),
          ),
        ],
      ),
    );
  }
}

Future<CompanyFilePrincipal?> showCompanyFilePrincipalPicker(
  BuildContext context, {
  required CompanyFileRepository repository,
  required AuthenticatedRequestScope scope,
  required SensitiveReadBoundary boundary,
}) => showDialog<CompanyFilePrincipal>(
  context: context,
  builder: (_) => CompanyFileScopeBoundary(
    boundary: boundary,
    scope: scope,
    child: _CompanyFilePrincipalDialog(repository: repository, scope: scope),
  ),
);

/// Only entry-local reading rules are offered during creation. Existing advanced
/// operation ACLs are edited separately and never reconstructed from this widget.
class CompanyFileInitialAccessEditor extends StatefulWidget {
  const CompanyFileInitialAccessEditor({
    super.key,
    required this.repository,
    required this.scope,
    required this.boundary,
    required this.onChanged,
    this.initialValue = const CompanyFileInitialAccessDraft.inherited(),
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

class _CompanyFileInitialAccessEditorState
    extends State<CompanyFileInitialAccessEditor> {
  late bool _inherit = widget.initialValue.inheritPermissions;
  late bool _passwordEnabled = widget.initialValue.password != null;
  late final _password = TextEditingController(
    text: widget.initialValue.password,
  );
  late final _repeat = TextEditingController(
    text: widget.initialValue.password,
  );
  late final List<CompanyFileAccessRule> _rules = widget.initialValue.rules
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
      inheritPermissions: _inherit,
      rules: _rules,
      password: _passwordEnabled ? _password.text : null,
    ),
  );

  Future<void> _add(String effect) async {
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
        Align(
          alignment: Alignment.centerLeft,
          child: UtenButton(
            key: ValueKey('initial-access-add-${effect.toLowerCase()}'),
            type: UtenButtonType.ghost,
            icon: Icons.person_add_alt_outlined,
            onPressed: _enabled ? () => _add(effect) : null,
            child: Text(l.companyFilesAddReader),
          ),
        ),
      ],
    );
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
        RadioGroup<bool>(
          groupValue: _inherit,
          onChanged: (value) {
            if (!_enabled || value == null) return;
            setState(() => _inherit = value);
            _publish();
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              RadioListTile<bool>(
                key: const Key('initial-access-inherit'),
                contentPadding: EdgeInsets.zero,
                value: true,
                enabled: _enabled,
                title: Text(l.companyFilesInheritEntryAccess),
              ),
              RadioListTile<bool>(
                key: const Key('initial-access-specific'),
                contentPadding: EdgeInsets.zero,
                value: false,
                enabled: _enabled,
                title: Text(l.companyFilesSpecificReaders),
              ),
            ],
          ),
        ),
        Text(
          _inherit
              ? l.companyFilesAccessHint
              : l.companyFilesSpecificReadersHint,
          style: theme.textTheme.bodySmall,
        ),
        if (!_inherit || _rules.isNotEmpty) ...[
          const SizedBox(height: UtenSpacing.s16),
          if (_rules.isEmpty) ...[
            Text(
              l.companyFilesNoReadersSelected,
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: UtenSpacing.s12),
          ],
          _readers('ALLOW', l.companyFilesAllowedReaders),
          const SizedBox(height: UtenSpacing.s12),
          _readers('DENY', l.companyFilesDeniedReaders),
        ],
        const SizedBox(height: UtenSpacing.s16),
        const Divider(),
        SwitchListTile(
          key: const Key('initial-access-password-switch'),
          contentPadding: EdgeInsets.zero,
          title: Text(l.companyFilesSetInitialPassword),
          value: _passwordEnabled,
          onChanged: !_enabled
              ? null
              : (value) {
                  setState(() {
                    _passwordEnabled = value;
                    if (!value) {
                      _password.clear();
                      _repeat.clear();
                    }
                  });
                  _publish();
                },
        ),
        Text(l.companyFilesEntryPasswordHint, style: theme.textTheme.bodySmall),
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

class _CompanyFilePrincipalDialog extends StatefulWidget {
  const _CompanyFilePrincipalDialog({
    required this.repository,
    required this.scope,
  });
  final CompanyFileRepository repository;
  final AuthenticatedRequestScope scope;
  @override
  State<_CompanyFilePrincipalDialog> createState() =>
      _CompanyFilePrincipalDialogState();
}

class _CompanyFilePrincipalDialogState
    extends State<_CompanyFilePrincipalDialog> {
  String _type = 'USER', _search = '';
  int _request = 0;
  List<CompanyFilePrincipal>? _items;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    ++_request;
    super.dispose();
  }

  Future<void> _load() async {
    final request = ++_request;
    setState(() {
      _items = null;
      _error = null;
    });
    try {
      final rows = await widget.scope.run(
        () => widget.repository.principals(type: _type, search: _search),
      );
      if (mounted && widget.scope.isCurrent && request == _request) {
        setState(() => _items = rows);
      }
    } catch (error) {
      if (mounted && widget.scope.isCurrent && request == _request) {
        setState(() => _error = error);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return UtenAlertDialog(
      title: Text(l.companyFilesAddReader),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: UtenSpacing.s8,
            runSpacing: UtenSpacing.s8,
            children: [
              for (final type in const ['USER', 'DEPARTMENT'])
                ChoiceChip(
                  label: Text(
                    type == 'USER'
                        ? l.companyFilesUser
                        : l.companyFilesDepartment,
                  ),
                  selected: _type == type,
                  onSelected: (_) {
                    if (_type == type || !widget.scope.isCurrent) return;
                    _type = type;
                    _load();
                  },
                ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s12),
          UtenSearchBar(
            hint: l.companyFilesPrincipalSearch,
            onInputChanged: (_) {
              ++_request;
              setState(() {
                _items = null;
                _error = null;
              });
            },
            onChanged: (value) {
              _search = value;
              _load();
            },
          ),
          const SizedBox(height: UtenSpacing.s12),
          if (!widget.scope.isCurrent)
            Text(l.companyFilesPermissionDenied)
          else if (_error != null)
            UtenEmpty.error(
              message: _error is ApiException
                  ? (_error as ApiException).message
                  : l.companyFilesLoadFailed,
              actionLabel: l.companyFilesRetry,
              onAction: _load,
            )
          else if (_items == null)
            const Center(child: CircularProgressIndicator())
          else if (_items!.isEmpty)
            UtenEmpty(message: l.companyFilesNoResults)
          else
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * .38,
              ),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _items!.length,
                itemBuilder: (_, index) {
                  final person = _items![index];
                  return ListTile(
                    leading: Icon(
                      person.type == 'USER'
                          ? Icons.person_outline
                          : Icons.groups_outlined,
                    ),
                    title: Text(person.name),
                    subtitle: person.detail.isEmpty
                        ? null
                        : Text(person.detail),
                    onTap: !widget.scope.isCurrent
                        ? null
                        : () => Navigator.pop(context, person),
                  );
                },
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l.companyFilesCancel),
        ),
      ],
    );
  }
}
