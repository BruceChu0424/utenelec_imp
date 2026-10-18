import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/server_config.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/display_datetime.dart';
import '../../../shared/providers/authenticated_scope_provider.dart';
import '../../../shared/providers/session_provider.dart';
import '../../../components/settings/settings_section.dart';
import '../../../core/l10n/remote_access_text.dart';
import '../repositories/remote_mfa_repository.dart';
import '../widgets/remote_mfa_prompt.dart';

class RemoteMfaPage extends ConsumerWidget {
  const RemoteMfaPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) => _MfaSession(
    key: ValueKey((
      ref.watch(authenticatedScopeProvider),
      ref.watch(apiBaseUrlProvider),
    )),
  );
}

class _MfaSession extends ConsumerStatefulWidget {
  const _MfaSession({super.key});
  @override
  ConsumerState<_MfaSession> createState() => _MfaSessionState();
}

class _MfaSessionState extends ConsumerState<_MfaSession> {
  late final Object _owner;
  RemoteMfaStatus? _status;
  RemoteMfaEnrollment? _enrollment;
  Timer? _expiry;
  final _otp = TextEditingController();
  bool _busy = false;
  String? _error;
  bool get _current =>
      mounted &&
      _owner ==
          (ref.read(authenticatedScopeProvider), ref.read(apiBaseUrlProvider));
  String t(String key) => remoteAccessText(context, key);
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
    _expiry?.cancel();
    _enrollment = null;
    _otp.clear();
    _otp.dispose();
    super.dispose();
  }

  bool get _self => ref.read(authenticatedScopeProvider)?.actorId == null;
  Future<void> _load() async {
    if (!_current || !_self) return;
    await _run(() async {
      final status = await ref.read(remoteMfaRepositoryProvider).status();
      if (_current) {
        setState(() {
          _status = status;
          if (status.enabled || !status.pending) _clearEnrollment();
        });
      }
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
          if (error.code == 'MFA_ENROLLMENT_EXPIRED') _clearEnrollment();
        });
      }
    } catch (_) {
      if (_current) setState(() => _error = t('failed'));
    } finally {
      if (_current) setState(() => _busy = false);
    }
  }

  void _clearEnrollment() {
    _enrollment = null;
    _expiry?.cancel();
    _otp.clear();
  }

  Future<void> _enroll() => _run(() async {
    final enrollment = await ref.read(remoteMfaRepositoryProvider).enroll();
    if (!_current) return;
    _expiry?.cancel();
    final remaining = enrollment.expiresAt.difference(DateTime.now());
    if (remaining <= Duration.zero) {
      throw const FormatException('Expired setup');
    }
    setState(() => _enrollment = enrollment);
    _expiry = Timer(remaining, () {
      if (_current) {
        setState(() {
          _clearEnrollment();
          _error = t('setupExpired');
        });
      }
    });
  });
  Future<void> _confirm() async {
    if (!RegExp(r'^\d{6}$').hasMatch(_otp.text)) {
      setState(() => _error = t('otpInvalid'));
      return;
    }
    await _run(() async {
      final result = await ref
          .read(remoteMfaRepositoryProvider)
          .confirm(_otp.text);
      if (!mounted || !_current) return;
      if (!result.enabled) throw const FormatException('Setup not confirmed');
      setState(() {
        _clearEnrollment();
        _status = result;
      });
      context.appSuccess(t('bound'));
    });
  }

  Future<void> _verify() async {
    final repository = ref.read(remoteMfaRepositoryProvider);
    final verified = await showRemoteMfaCodeDialog(
      context,
      verify: (code) async {
        await repository.verify(code);
      },
      isCurrent: () => _current,
    );
    if (mounted && _current && verified == true) {
      context.appSuccess(t('verifiedRetry'));
      await _load();
    }
  }

  Future<void> _disable() async {
    final repository = ref.read(remoteMfaRepositoryProvider);
    final removed = await showRemoteMfaCodeDialog(
      context,
      title: t('disable'),
      message: t('disableWarning'),
      verify: repository.disable,
      isCurrent: () => _current,
    );
    if (removed != true || !_current) return;
    await ref.read(sessionProvider.notifier).logout();
    if (mounted) context.go(RouteName.login);
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    final enrollment = _enrollment;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: UtenAppBar(title: t('personal'), leading: const UtenBackButton()),
      body: UtenContentContainer.narrow(
        child: ListView(
          padding: const EdgeInsets.all(UtenSpacing.s16),
          children: [
            Text(t('mfaIntro'), style: theme.textTheme.bodyMedium),
            const SizedBox(height: UtenSpacing.s16),
            if (!_self)
              Text(t('selfOnly'))
            else ...[
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    _error!,
                    key: const Key('mfa-error'),
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ),
              if (status == null)
                Center(
                  child: _busy
                      ? const CircularProgressIndicator()
                      : UtenButton(onPressed: _load, child: Text(t('retry'))),
                ),
              if (status != null)
                SettingsSection(
                  title: t('personal'),
                  children: [
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        status.enabled
                            ? Icons.verified_user_outlined
                            : Icons.security_outlined,
                      ),
                      title: Text(
                        t(status.enabled ? 'mfaBound' : 'mfaMissing'),
                      ),
                      subtitle: Text(
                        t(status.sessionVerified ? 'verified' : 'notVerified'),
                      ),
                    ),
                    if (!status.enrollmentAllowed)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Text(t('officeOnly')),
                      ),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Wrap(
                        spacing: 12,
                        runSpacing: 8,
                        children: [
                          if (!status.enabled &&
                              status.enrollmentAllowed &&
                              enrollment == null)
                            UtenButton(
                              key: const Key('mfa-enroll'),
                              isLoading: _busy,
                              onPressed: _busy ? null : _enroll,
                              child: Text(t('enroll')),
                            ),
                          if (status.enabled)
                            UtenButton(
                              key: const Key('mfa-verify'),
                              isLoading: _busy,
                              onPressed: _busy ? null : _verify,
                              child: Text(t('verify')),
                            ),
                          if (status.enabled && status.enrollmentAllowed)
                            UtenButton(
                              key: const Key('mfa-disable'),
                              type: UtenButtonType.ghost,
                              isLoading: _busy,
                              onPressed: _busy ? null : _disable,
                              child: Text(t('disable')),
                            ),
                          UtenButton(
                            type: UtenButtonType.ghost,
                            isLoading: _busy,
                            onPressed: _busy ? null : _load,
                            child: Text(t('refresh')),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              if (enrollment != null) ...[
                const SizedBox(height: 20),
                SettingsSection(
                  title: t('enroll'),
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(t('scan')),
                          const SizedBox(height: 12),
                          Center(
                            child: Container(
                              color: Colors.white,
                              padding: const EdgeInsets.all(8),
                              child: QrImageView(
                                data: enrollment.otpauthUri,
                                size: 200,
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            t('setupKey'),
                            style: theme.textTheme.labelLarge,
                          ),
                          SelectableText(
                            enrollment.secret,
                            key: const Key('mfa-secret'),
                          ),
                          TextButton.icon(
                            onPressed: () async {
                              await Clipboard.setData(
                                ClipboardData(text: enrollment.secret),
                              );
                              if (context.mounted && _current) {
                                context.appSuccess(t('copied'));
                              }
                            },
                            icon: const Icon(Icons.copy_outlined),
                            label: Text(t('copy')),
                          ),
                          Text(
                            t('secretHint'),
                            style: theme.textTheme.bodySmall,
                          ),
                          Text(
                            '${t('expires')}: ${DisplayDateTime.beijing(enrollment.expiresAt.toIso8601String())}',
                          ),
                          const SizedBox(height: 16),
                          UtenInput(
                            key: const Key('mfa-setup-otp'),
                            controller: _otp,
                            label: t('otp'),
                            hint: t('otpHint'),
                            aiSensitive: true,
                            keyboardType: TextInputType.number,
                            enabled: !_busy,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                              LengthLimitingTextInputFormatter(6),
                            ],
                            autofillHints: const [AutofillHints.oneTimeCode],
                            onFieldSubmitted: (_) => _busy ? null : _confirm(),
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 12,
                            runSpacing: 8,
                            children: [
                              UtenButton(
                                key: const Key('mfa-confirm'),
                                onPressed: _busy ? null : _confirm,
                                child: Text(t('confirmSetup')),
                              ),
                              UtenButton(
                                type: UtenButtonType.ghost,
                                onPressed: _busy
                                    ? null
                                    : () => setState(_clearEnrollment),
                                child: Text(t('cancel')),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}
