import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/server_config.dart';
import '../../../core/router/route_access_policy.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/ui/uten_notify.dart';
import '../../../core/utils/display_datetime.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/authenticated_scope_provider.dart';
import '../../../shared/providers/session_provider.dart';
import '../../../core/l10n/remote_access_text.dart';
import '../../../components/settings/settings_section.dart';
import '../repositories/remote_access_repository.dart';

class AdminRemoteAccessPage extends ConsumerWidget {
  const AdminRemoteAccessPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final allowed = platformSettingsAllowedFor(
      ref.watch(currentPermissionsProvider),
      ref.watch(isSuperAdminProvider),
    );
    if (!allowed) {
      return Scaffold(
        body: Center(child: Text(remoteAccessText(context, 'denied'))),
      );
    }
    return _RemoteAccessSession(
      key: ValueKey((
        ref.watch(authenticatedScopeProvider),
        ref.watch(apiBaseUrlProvider),
      )),
    );
  }
}

class _RemoteAccessSession extends ConsumerStatefulWidget {
  const _RemoteAccessSession({super.key});
  @override
  ConsumerState<_RemoteAccessSession> createState() =>
      _RemoteAccessSessionState();
}

class _RemoteAccessSessionState extends ConsumerState<_RemoteAccessSession> {
  late final Object _owner;
  RemoteAccessStatus? _status;
  final _limit = TextEditingController();
  bool _enabled = false, _busy = false;
  String? _error;
  String t(String key) => remoteAccessText(context, key);
  bool get _current =>
      mounted &&
      _owner ==
          (
            ref.read(authenticatedScopeProvider),
            ref.read(apiBaseUrlProvider),
          ) &&
      platformSettingsAllowedFor(
        ref.read(currentPermissionsProvider),
        ref.read(isSuperAdminProvider),
      );
  @override
  void initState() {
    super.initState();
    _owner = (
      ref.read(authenticatedScopeProvider),
      ref.read(apiBaseUrlProvider),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _limit.dispose();
    super.dispose();
  }

  Future<void> _readback() async {
    final result = await ref.read(remoteAccessRepositoryProvider).status();
    if (!_current) return;
    setState(() {
      _status = result;
      _enabled = result.policy.enabled;
      _limit.text = result.policy.maxUsers.toString();
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    if (!_current || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on ApiException catch (error) {
      if (_current) {
        setState(() {
          _error = remoteAccessError(context, error);
          _status = null;
        });
      }
    } catch (_) {
      if (_current) {
        setState(() {
          _error = t('failed');
          _status = null;
        });
      }
    } finally {
      if (_current) setState(() => _busy = false);
    }
  }

  Future<void> _load() => _run(_readback);
  Future<void> _save() async {
    final status = _status;
    final limit = int.tryParse(_limit.text);
    if (status?.currentAccessChannel != 'local') return;
    if (status == null ||
        limit == null ||
        limit < 1 ||
        limit > 10000 ||
        limit < status.authorizedCount) {
      setState(() => _error = t('invalidLimit'));
      return;
    }
    final enabled = _enabled;
    await _run(() async {
      await ref
          .read(remoteAccessRepositoryProvider)
          .save(
            enabled: enabled,
            maxUsers: limit,
            expectedVersion: status.policy.version,
          );
      if (!_current) return;
      await _readback();
      if (!mounted || !_current) return;
      if (_status?.policy.enabled != enabled ||
          _status?.policy.maxUsers != limit) {
        throw const FormatException('Policy readback differs');
      }
      context.appSuccess(t('saved'));
    });
  }

  Future<void> _revoke(RemoteAccessUser user) async {
    if (!_current || _busy) return;
    final confirmed = await UtenNotify.alert(
      context,
      title: '${t('revoke')} · ${user.displayName}',
      message: t('revokeConfirm'),
      confirmLabel: t('confirm'),
      cancelLabel: t('cancel'),
    );
    if (confirmed != true || !_current) return;
    await _run(() async {
      await ref.read(remoteAccessRepositoryProvider).revoke(user.id);
      if (_current) await _readback();
    });
  }

  Future<void> _reset(RemoteAccessUser user) async {
    if (!_current || _busy) return;
    final reason = await showDialog<String>(
      context: context,
      builder: (_) => const _ResetReasonDialog(),
    );
    if (reason == null || !_current) return;
    await _run(() async {
      await ref.read(remoteAccessRepositoryProvider).resetMfa(user.id, reason);
      if (!_current) return;
      if (user.id == ref.read(authenticatedScopeProvider)?.userId) {
        await ref.read(sessionProvider.notifier).logout();
        if (mounted) context.go(RouteName.login);
      } else {
        await _readback();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: UtenAppBar(
        title: t('title'),
        leading: const UtenBackButton(),
        actions: [
          IconButton(
            tooltip: t('refresh'),
            onPressed: _busy ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: UtenContentContainer.narrow(
        child: ListView(
          padding: const EdgeInsets.all(UtenSpacing.s16),
          children: [
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text(
                  _error!,
                  key: const Key('remote-access-error'),
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            if (status == null)
              Center(
                child: _busy
                    ? const CircularProgressIndicator()
                    : UtenButton(onPressed: _load, child: Text(t('retry'))),
              ),
            if (status != null) ...[
              SettingsSection(
                title: t('connection'),
                children: [
                  _StatusRow(t('currentPath'), t(status.currentAccessChannel)),
                  _StatusRow(
                    t('remote'),
                    t(
                      status.remoteChannelConfigured
                          ? 'configured'
                          : 'notConfigured',
                    ),
                  ),
                  _StatusRow(
                    t('observed'),
                    DisplayDateTime.beijing(
                      status.observedAt.toIso8601String(),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      t('channelHint'),
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              SettingsSection(
                title: t('access'),
                children: [
                  if (status.currentAccessChannel != 'local')
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(t('policyOfficeOnly')),
                    ),
                  SwitchListTile.adaptive(
                    key: const Key('remote-access-enabled'),
                    contentPadding: EdgeInsets.zero,
                    title: Text(t('enabled')),
                    subtitle: Text(t('enabledHint')),
                    value: _enabled,
                    onChanged: _busy || status.currentAccessChannel != 'local'
                        ? null
                        : (value) => setState(() => _enabled = value),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: UtenInput(
                      key: const Key('remote-access-limit'),
                      label: t('maxUsers'),
                      info: t('maxHint'),
                      controller: _limit,
                      keyboardType: TextInputType.number,
                      enabled: !_busy && status.currentAccessChannel == 'local',
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(6),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: UtenButton(
                        key: const Key('remote-access-save'),
                        onPressed:
                            _busy || status.currentAccessChannel != 'local'
                            ? null
                            : _save,
                        isLoading: _busy,
                        child: Text(t('save')),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              SettingsSection(
                title:
                    '${t('people')} ${status.authorizedCount}/${status.policy.maxUsers}',
                children: [
                  if (status.authorizedUsers.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Text(t('noPeople')),
                    ),
                  for (final user in status.authorizedUsers)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final identity = Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                user.displayName.isEmpty
                                    ? user.username
                                    : user.displayName,
                                style: theme.textTheme.titleSmall,
                              ),
                              Text(
                                '${user.username} · ${t(user.mfaEnabled ? 'mfaBound' : 'mfaMissing')}',
                                style: theme.textTheme.bodySmall,
                              ),
                            ],
                          );
                          final actions = Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              if (user.mfaEnabled &&
                                  status.currentAccessChannel == 'local')
                                UtenButton(
                                  type: UtenButtonType.ghost,
                                  isLoading: _busy,
                                  onPressed: _busy ? null : () => _reset(user),
                                  child: Text(t('reset')),
                                ),
                              UtenButton(
                                key: ValueKey('remote-revoke-${user.id}'),
                                type: UtenButtonType.ghost,
                                isLoading: _busy,
                                onPressed: _busy ? null : () => _revoke(user),
                                child: Text(t('revoke')),
                              ),
                            ],
                          );
                          return constraints.maxWidth < 620
                              ? Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    identity,
                                    const SizedBox(height: 8),
                                    actions,
                                  ],
                                )
                              : Row(
                                  children: [
                                    Expanded(child: identity),
                                    const SizedBox(width: 16),
                                    actions,
                                  ],
                                );
                        },
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: UtenButton(
                        type: UtenButtonType.ghost,
                        onPressed: _busy
                            ? null
                            : () async {
                                await context.push(RouteName.adminPermissions);
                                if (_current) await _load();
                              },
                        child: Text(t('managePeople')),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow(this.label, this.value);
  final String label, value;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: LayoutBuilder(
      builder: (context, constraints) => constraints.maxWidth < 500
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [Text(label), const SizedBox(height: 4), Text(value)],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 180, child: Text(label)),
                Expanded(child: Text(value)),
              ],
            ),
    ),
  );
}

class _ResetReasonDialog extends StatefulWidget {
  const _ResetReasonDialog();
  @override
  State<_ResetReasonDialog> createState() => _ResetReasonDialogState();
}

class _ResetReasonDialogState extends State<_ResetReasonDialog> {
  final _reason = TextEditingController();
  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    String t(String key) => remoteAccessText(context, key);
    return UtenAlertDialog(
      title: Text(t('reset')),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(t('resetWarning')),
            const SizedBox(height: 16),
            UtenInput(
              label: t('resetReason'),
              controller: _reason,
              maxLines: 3,
              inputFormatters: [LengthLimitingTextInputFormatter(256)],
              onChanged: (_) => setState(() {}),
            ),
          ],
        ),
      ),
      actions: [
        UtenButton(
          type: UtenButtonType.ghost,
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t('cancel')),
        ),
        UtenButton(
          onPressed: _reason.text.trim().isEmpty
              ? null
              : () => Navigator.of(context).pop(_reason.text.trim()),
          child: Text(t('confirm')),
        ),
      ],
    );
  }
}
