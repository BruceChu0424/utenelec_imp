import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/authenticated_request_scope.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/attachments/attachment_file_rules.dart';
import '../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../models/company_file.dart';
import '../repositories/company_file_repository.dart';

String companyFileError(Object error, AppLocalizations l) =>
    error is ApiException ? error.message : l.companyFilesLoadFailed;

/// Navigator overlays outlive their launching page. Keep every editor and
/// picker tied to the original, sticky command identity.
class CompanyFileScopeBoundary extends ConsumerWidget {
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
  Widget build(BuildContext context, WidgetRef ref) =>
      ref.watch(sensitiveReadBoundaryProvider) == boundary &&
          (scope?.isCurrent ?? true) &&
          (isCurrent?.call() ?? true)
      ? child
      : UtenAlertDialog(
          title: Text(
            AppLocalizations.of(context).companyFilesPermissionDenied,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(AppLocalizations.of(context).companyFilesClose),
            ),
          ],
        );
}

class CompanyFileNameDialog extends StatefulWidget {
  const CompanyFileNameDialog({super.key, this.entry});
  final CompanyFile? entry;
  @override
  State<CompanyFileNameDialog> createState() => _CompanyFileNameDialogState();
}

class _CompanyFileNameDialogState extends State<CompanyFileNameDialog> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.entry?.name ?? '');
  late final _description = TextEditingController(
    text: widget.entry?.description ?? '',
  );
  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    void save() {
      if (_form.currentState!.validate()) {
        Navigator.pop(context, (
          name: _name.text.trim(),
          description: _description.text.trim(),
        ));
      }
    }

    return UtenAlertDialog(
      title: Text(
        widget.entry == null ? l.companyFilesNewFolder : l.companyFilesRename,
      ),
      content: SizedBox(
        width: 440,
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              UtenInput(
                label: l.companyFilesName,
                controller: _name,
                required: true,
                validator: (v) {
                  if (v == null || v.trim().isEmpty) {
                    return l.companyFilesRequiredName;
                  }
                  final entry = widget.entry;
                  if (entry != null &&
                      !entry.isFolder &&
                      attachmentExtension(v.trim()) !=
                          attachmentExtension(entry.name)) {
                    return l.companyFilesKeepExtension;
                  }
                  return null;
                },
                onFieldSubmitted: (_) => save(),
              ),
              const SizedBox(height: UtenSpacing.s16),
              if (widget.entry?.isFolder == false) ...[
                Text(l.companyFilesKeepExtension),
                const SizedBox(height: UtenSpacing.s16),
              ],
              UtenInput(
                label: l.companyFilesDescription,
                controller: _description,
                maxLines: 3,
              ),
              if (widget.entry == null) ...[
                const SizedBox(height: UtenSpacing.s16),
                Text(
                  l.companyFilesInherit,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: UtenSpacing.s4),
                Text(l.companyFilesAccessHint),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l.companyFilesCancel),
        ),
        UtenButton(onPressed: save, child: Text(l.companyFilesSave)),
      ],
    );
  }
}

class CompanyFilePasswordChoice {
  const CompanyFilePasswordChoice(this.password);
  final String? password;
}

class CompanyFilePasswordDialog extends StatefulWidget {
  const CompanyFilePasswordDialog({
    super.key,
    required this.entry,
    this.unlock = false,
  });
  final CompanyFile entry;
  final bool unlock;
  @override
  State<CompanyFilePasswordDialog> createState() =>
      _CompanyFilePasswordDialogState();
}

class _CompanyFilePasswordDialogState extends State<CompanyFilePasswordDialog> {
  final _form = GlobalKey<FormState>();
  final _password = TextEditingController();
  final _repeat = TextEditingController();
  bool _remove = false;
  @override
  void dispose() {
    _password.clear();
    _repeat.clear();
    _password.dispose();
    _repeat.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return UtenAlertDialog(
      title: Text(
        widget.unlock ? l.companyFilesUnlock : l.companyFilesPassword,
      ),
      content: SizedBox(
        width: 440,
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.entry.name,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: UtenSpacing.s12),
              Text(
                widget.unlock
                    ? l.companyFilesLockedHint
                    : l.companyFilesPasswordHint,
              ),
              const SizedBox(height: UtenSpacing.s16),
              if (!widget.unlock && widget.entry.passwordProtected)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(l.companyFilesRemovePassword),
                  value: _remove,
                  onChanged: (v) => setState(() => _remove = v ?? false),
                ),
              if (!_remove) ...[
                UtenInput(
                  label: widget.unlock
                      ? l.companyFilesPassword
                      : l.companyFilesNewPassword,
                  controller: _password,
                  isPassword: true,
                  aiSensitive: true,
                  validator: (v) =>
                      v == null || (widget.unlock ? v.isEmpty : v.length < 8)
                      ? l.companyFilesPasswordLength
                      : null,
                ),
                if (!widget.unlock) ...[
                  const SizedBox(height: UtenSpacing.s16),
                  UtenInput(
                    label: l.companyFilesRepeatPassword,
                    controller: _repeat,
                    isPassword: true,
                    aiSensitive: true,
                    validator: (v) => v != _password.text
                        ? l.companyFilesPasswordMismatch
                        : null,
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l.companyFilesCancel),
        ),
        UtenButton(
          onPressed: () {
            if (_remove || _form.currentState!.validate()) {
              Navigator.pop(
                context,
                CompanyFilePasswordChoice(_remove ? null : _password.text),
              );
            }
          },
          child: Text(
            widget.unlock ? l.companyFilesUnlock : l.companyFilesSave,
          ),
        ),
      ],
    );
  }
}

class CompanyFileAccessDialog extends ConsumerStatefulWidget {
  const CompanyFileAccessDialog({
    super.key,
    required this.entry,
    required this.repository,
    required this.scope,
    required this.boundary,
  });
  final CompanyFile entry;
  final CompanyFileRepository repository;
  final AuthenticatedRequestScope scope;
  final SensitiveReadBoundary boundary;
  @override
  ConsumerState<CompanyFileAccessDialog> createState() =>
      _CompanyFileAccessDialogState();
}

class _CompanyFileAccessDialogState
    extends ConsumerState<CompanyFileAccessDialog> {
  CompanyFileAccess? _access;
  List<CompanyFileAccessRule> _rules = [];
  bool _inherit = true;
  bool _busy = false;
  Object? _error;
  bool get _current =>
      mounted &&
      widget.scope.isCurrent &&
      ref.read(sensitiveReadBoundaryProvider) == widget.boundary;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final value = await widget.scope.run(
        () => widget.repository.access(widget.entry.id),
      );
      if (!_current) return;
      setState(() {
        _access = value;
        _inherit = value.inheritPermissions;
        _rules = value.rules.toList();
      });
    } catch (e) {
      if (_current) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    if (_busy || !_current || _access == null) return;
    if (_rules.any((r) => r.actions.isEmpty)) {
      setState(
        () => _error = ApiException(
          'INVALID',
          AppLocalizations.of(context).companyFilesRuleActionsRequired,
        ),
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.scope.run(
        () => widget.repository.saveAccess(
          widget.entry.id,
          version: _access!.version,
          inheritPermissions: _inherit,
          rules: _rules,
        ),
      );
      if (mounted && _current) Navigator.pop(context, true);
    } catch (e) {
      if (_current) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _add() async {
    final principal = await showDialog<CompanyFilePrincipal>(
      context: context,
      builder: (_) => CompanyFileScopeBoundary(
        boundary: widget.boundary,
        scope: widget.scope,
        child: _CompanyFilePrincipalDialog(
          repository: widget.repository,
          scope: widget.scope,
        ),
      ),
    );
    if (!_current || principal == null) return;
    final existing = _rules
        .where(
          (r) => r.subjectType == principal.type && r.subjectId == principal.id,
        )
        .toList();
    if (existing.length >= 2) {
      setState(
        () => _error = ApiException(
          'DUPLICATE',
          AppLocalizations.of(context).companyFilesDuplicateRule,
        ),
      );
      return;
    }
    setState(() {
      _error = null;
      _rules.add(
        CompanyFileAccessRule(
          subjectType: principal.type,
          subjectId: principal.id,
          subjectName: principal.name,
          effect: existing.any((r) => r.effect == 'ALLOW') ? 'DENY' : 'ALLOW',
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final boundary = ref.watch(sensitiveReadBoundaryProvider);
    final current = boundary == widget.boundary && widget.scope.isCurrent;
    final actions = <String, String>{
      'view': l.companyFilesRead,
      'download': l.companyFilesDownload,
      'create': l.companyFilesCreate,
      'upload': l.companyFilesUpload,
      'edit': l.companyFilesEdit,
      'move': l.companyFilesMove,
      'delete': l.companyFilesDelete,
      'restore': l.companyFilesRestore,
      'manage_permissions': l.companyFilesManage,
    };
    return PopScope(
      canPop: !_busy,
      child: UtenAlertDialog(
        title: Text(l.companyFilesAccess),
        content: SizedBox(
          width: 650,
          child: !current
              ? Text(l.companyFilesPermissionDenied)
              : _access == null
              ? _busy
                    ? const Center(child: CircularProgressIndicator())
                    : UtenEmpty.error(
                        message: companyFileError(_error!, l),
                        actionLabel: l.companyFilesRetry,
                        onAction: _load,
                      )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      widget.entry.name,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: UtenSpacing.s12),
                    Text(l.companyFilesAccessHint),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(l.companyFilesInherit),
                      value: _inherit,
                      onChanged: _busy
                          ? null
                          : (v) => setState(() => _inherit = v),
                    ),
                    ..._rules.asMap().entries.map((row) {
                      final i = row.key, rule = row.value;
                      bool duplicate(String effect) =>
                          _rules.asMap().entries.any(
                            (other) =>
                                other.key != i &&
                                other.value.subjectType == rule.subjectType &&
                                other.value.subjectId == rule.subjectId &&
                                other.value.effect == effect,
                          );
                      return Padding(
                        padding: const EdgeInsets.only(bottom: UtenSpacing.s12),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: Theme.of(
                                context,
                              ).colorScheme.outlineVariant,
                            ),
                            borderRadius: UtenRadius.controlAll,
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(UtenSpacing.s12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Row(
                                  children: [
                                    Icon(
                                      rule.subjectType == 'USER'
                                          ? Icons.person_outline
                                          : Icons.groups_outlined,
                                    ),
                                    const SizedBox(width: UtenSpacing.s8),
                                    Expanded(
                                      child: Text(
                                        rule.subjectName,
                                        style: Theme.of(
                                          context,
                                        ).textTheme.titleSmall,
                                      ),
                                    ),
                                    IconButton(
                                      tooltip: l.companyFilesRemoveRule,
                                      onPressed: _busy
                                          ? null
                                          : () => setState(
                                              () => _rules.removeAt(i),
                                            ),
                                      icon: const Icon(Icons.close),
                                    ),
                                  ],
                                ),
                                Wrap(
                                  spacing: UtenSpacing.s8,
                                  runSpacing: UtenSpacing.s4,
                                  children: [
                                    ChoiceChip(
                                      label: Text(l.companyFilesAllow),
                                      selected: rule.effect == 'ALLOW',
                                      onSelected: _busy || duplicate('ALLOW')
                                          ? null
                                          : (_) => setState(
                                              () => _rules[i] = rule.copyWith(
                                                effect: 'ALLOW',
                                              ),
                                            ),
                                    ),
                                    ChoiceChip(
                                      label: Text(l.companyFilesDeny),
                                      selected: rule.effect == 'DENY',
                                      selectedColor: Theme.of(
                                        context,
                                      ).colorScheme.errorContainer,
                                      onSelected: _busy || duplicate('DENY')
                                          ? null
                                          : (_) => setState(
                                              () => _rules[i] = rule.copyWith(
                                                effect: 'DENY',
                                              ),
                                            ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: UtenSpacing.s8),
                                Wrap(
                                  spacing: UtenSpacing.s6,
                                  runSpacing: UtenSpacing.s4,
                                  children: actions.entries
                                      .map(
                                        (a) => FilterChip(
                                          label: Text(a.value),
                                          selected: rule.actions.contains(
                                            a.key,
                                          ),
                                          onSelected: _busy
                                              ? null
                                              : (selected) => setState(() {
                                                  final next = {
                                                    ...rule.actions,
                                                  };
                                                  if (selected) {
                                                    next.add(a.key);
                                                  } else {
                                                    next.remove(a.key);
                                                  }
                                                  _rules[i] = rule.copyWith(
                                                    actions: next,
                                                  );
                                                }),
                                        ),
                                      )
                                      .toList(),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    }),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: UtenButton(
                        type: UtenButtonType.secondary,
                        icon: Icons.add,
                        onPressed: _busy ? null : _add,
                        child: Text(l.companyFilesAddRule),
                      ),
                    ),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: UtenSpacing.s12),
                        child: Text(
                          companyFileError(_error!, l),
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                  ],
                ),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: Text(l.companyFilesCancel),
          ),
          if (current && _access != null)
            UtenButton(
              isLoading: _busy,
              onPressed: _save,
              child: Text(l.companyFilesSave),
            ),
        ],
      ),
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
    } catch (e) {
      if (mounted && request == _request) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return UtenAlertDialog(
      title: Text(l.companyFilesAddRule),
      content: SizedBox(
        width: 480,
        height: (MediaQuery.sizeOf(context).height * .5).clamp(200, 500),
        child: Column(
          children: [
            Wrap(
              spacing: UtenSpacing.s8,
              children: [
                ChoiceChip(
                  label: Text(l.companyFilesUser),
                  selected: _type == 'USER',
                  onSelected: (_) {
                    _type = 'USER';
                    _load();
                  },
                ),
                ChoiceChip(
                  label: Text(l.companyFilesDepartment),
                  selected: _type == 'DEPARTMENT',
                  onSelected: (_) {
                    _type = 'DEPARTMENT';
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
              },
              onChanged: (v) {
                _search = v;
                _load();
              },
            ),
            const SizedBox(height: UtenSpacing.s12),
            Expanded(
              child: !widget.scope.isCurrent
                  ? Text(l.companyFilesPermissionDenied)
                  : _error != null
                  ? UtenEmpty.error(
                      message: companyFileError(_error!, l),
                      actionLabel: l.companyFilesRetry,
                      onAction: _load,
                    )
                  : _items == null
                  ? const Center(child: CircularProgressIndicator())
                  : _items!.isEmpty
                  ? UtenEmpty(message: l.companyFilesNoResults)
                  : ListView.builder(
                      itemCount: _items!.length,
                      itemBuilder: (_, i) {
                        final p = _items![i];
                        return ListTile(
                          leading: Icon(
                            p.type == 'USER'
                                ? Icons.person_outline
                                : Icons.groups_outlined,
                          ),
                          title: Text(p.name),
                          subtitle: p.detail.isEmpty ? null : Text(p.detail),
                          onTap: () => Navigator.pop(context, p),
                        );
                      },
                    ),
            ),
          ],
        ),
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

class CompanyFileDestination {
  const CompanyFileDestination(this.id);
  final String? id;
}

class CompanyFileMoveDialog extends StatefulWidget {
  const CompanyFileMoveDialog({
    super.key,
    required this.source,
    required this.repository,
    required this.scope,
  });
  final CompanyFile source;
  final CompanyFileRepository repository;
  final AuthenticatedRequestScope scope;
  @override
  State<CompanyFileMoveDialog> createState() => _CompanyFileMoveDialogState();
}

class _CompanyFileMoveDialogState extends State<CompanyFileMoveDialog> {
  String? _parent;
  CompanyFileListing? _listing;
  Object? _error;
  int _request = 0, _page = 0;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final request = ++_request;
    setState(() {
      _listing = null;
      _error = null;
    });
    try {
      final value = await widget.scope.run(
        () => widget.repository.list(parentId: _parent, page: _page),
      );
      if (mounted && widget.scope.isCurrent && request == _request) {
        setState(() => _listing = value);
      }
    } catch (e) {
      if (mounted && request == _request) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final listing = _listing;
    final folders =
        listing?.entries
            .where((e) => e.isFolder && e.id != widget.source.id && !e.locked)
            .toList() ??
        [];
    return UtenAlertDialog(
      title: Text(l.companyFilesSelectFolder),
      content: SizedBox(
        width: 520,
        height: (MediaQuery.sizeOf(context).height * .5).clamp(200, 520),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                TextButton(
                  onPressed: () {
                    _parent = null;
                    _page = 0;
                    _load();
                  },
                  child: Text(l.companyFilesTitle),
                ),
                ...?listing?.breadcrumbs.map(
                  (b) => TextButton(
                    onPressed: () {
                      _parent = b.id;
                      _page = 0;
                      _load();
                    },
                    child: Text('/ ${b.name}'),
                  ),
                ),
              ],
            ),
            const Divider(),
            Expanded(
              child: !widget.scope.isCurrent
                  ? Text(l.companyFilesPermissionDenied)
                  : _error != null
                  ? UtenEmpty.error(
                      message: companyFileError(_error!, l),
                      actionLabel: l.companyFilesRetry,
                      onAction: _load,
                    )
                  : listing == null
                  ? const Center(child: CircularProgressIndicator())
                  : folders.isEmpty
                  ? UtenEmpty(
                      icon: Icons.folder_outlined,
                      message: l.companyFilesEmpty,
                    )
                  : ListView.builder(
                      itemCount: folders.length,
                      itemBuilder: (_, i) => ListTile(
                        leading: Icon(
                          Icons.folder_rounded,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        title: Text(folders[i].name),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () {
                          _parent = folders[i].id;
                          _page = 0;
                          _load();
                        },
                      ),
                    ),
            ),
            if (listing != null && listing.total > listing.size)
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  IconButton(
                    tooltip: l.companyFilesPrevious,
                    onPressed: _page == 0
                        ? null
                        : () {
                            _page--;
                            _load();
                          },
                    icon: const Icon(Icons.chevron_left),
                  ),
                  Text(
                    '${_page + 1} / ${(listing.total / listing.size).ceil()}',
                  ),
                  IconButton(
                    tooltip: l.companyFilesNext,
                    onPressed: (_page + 1) * listing.size >= listing.total
                        ? null
                        : () {
                            _page++;
                            _load();
                          },
                    icon: const Icon(Icons.chevron_right),
                  ),
                ],
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l.companyFilesCancel),
        ),
        UtenButton(
          onPressed:
              listing != null &&
                  widget.scope.isCurrent &&
                  listing.allows('move') &&
                  listing.allows(
                    widget.source.isFolder ? 'create' : 'upload',
                  ) &&
                  _parent != widget.source.parentId
              ? () => Navigator.pop(context, CompanyFileDestination(_parent))
              : null,
          child: Text(l.companyFilesMoveHere),
        ),
      ],
    );
  }
}
