import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/remote_mfa_coordinator.dart';
import '../../../core/network/server_config.dart';
import '../../../core/router/app_router.dart';
import '../../../core/ui/opportunistic_dialog_coordinator.dart';
import '../../../shared/providers/authenticated_scope_provider.dart';
import '../remote_access_text.dart';
import '../repositories/remote_mfa_repository.dart';

Future<bool?> showRemoteMfaCodeDialog(
  BuildContext context, {
  required Future<void> Function(String code) verify,
  required bool Function() isCurrent,
  String? title,
  String? message,
}) {
  DialogPriorityReservation? priority;
  try {
    priority = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(opportunisticDialogCoordinatorProvider).prioritize();
  } on StateError {
    /* Standalone dialog. */
  }
  return UtenBusyOverlay.yieldWhile(
    () => showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => RemoteMfaCodeDialog(
        verify: verify,
        isCurrent: isCurrent,
        title: title,
        message: message,
      ),
    ),
  ).whenComplete(() => priority?.release());
}

class RemoteMfaCodeDialog extends StatefulWidget {
  const RemoteMfaCodeDialog({
    super.key,
    required this.verify,
    required this.isCurrent,
    this.title,
    this.message,
  });
  final Future<void> Function(String code) verify;
  final bool Function() isCurrent;
  final String? title, message;
  @override
  State<RemoteMfaCodeDialog> createState() => _RemoteMfaCodeDialogState();
}

class _RemoteMfaCodeDialogState extends State<RemoteMfaCodeDialog> {
  final _code = TextEditingController();
  bool _busy = false;
  String? _error;
  String t(String key) => remoteAccessText(context, key);
  @override
  void dispose() {
    _code.clear();
    _code.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    if (_busy) return;
    if (!widget.isCurrent()) {
      Navigator.of(context).pop(false);
      return;
    }
    if (!RegExp(r'^\d{6}$').hasMatch(_code.text)) {
      setState(() => _error = t('otpInvalid'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.verify(_code.text);
      if (mounted) Navigator.of(context).pop(widget.isCurrent());
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = remoteAccessError(context, error));
    } catch (_) {
      if (mounted) setState(() => _error = t('failed'));
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _code.clear();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => UtenAlertDialog(
    key: const Key('remote-mfa-dialog'),
    title: Text(widget.title ?? t('verifyTitle')),
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(widget.message ?? t('verifyHint')),
          const SizedBox(height: 16),
          UtenInput(
            key: const Key('remote-mfa-code'),
            label: t('otp'),
            hint: t('otpHint'),
            controller: _code,
            keyboardType: TextInputType.number,
            aiSensitive: true,
            enabled: !_busy,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(6),
            ],
            autofillHints: const [AutofillHints.oneTimeCode],
            onFieldSubmitted: (_) => _confirm(),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
    ),
    actions: [
      UtenButton(
        type: UtenButtonType.ghost,
        onPressed: _busy ? null : () => Navigator.of(context).pop(false),
        child: Text(t('cancel')),
      ),
      UtenButton(
        key: const Key('remote-mfa-confirm'),
        onPressed: _busy ? null : _confirm,
        isLoading: _busy,
        child: Text(t('verify')),
      ),
    ],
  );
}

class RemoteMfaPromptHost extends ConsumerStatefulWidget {
  const RemoteMfaPromptHost({super.key});
  @override
  ConsumerState<RemoteMfaPromptHost> createState() =>
      _RemoteMfaPromptHostState();
}

class _RemoteMfaPromptHostState extends ConsumerState<RemoteMfaPromptHost> {
  void Function()? _unregister;
  @override
  void initState() {
    super.initState();
    _unregister = RemoteMfaCoordinator.instance.register(
      _prompt,
      context: () =>
          (ref.read(authenticatedScopeProvider), ref.read(apiBaseUrlProvider)),
    );
  }

  @override
  void dispose() {
    _unregister?.call();
    super.dispose();
  }

  Future<String?> _prompt() async {
    final host = appNavigatorKey.currentContext;
    final scope = ref.read(authenticatedScopeProvider);
    final endpoint = ref.read(apiBaseUrlProvider);
    if (host == null ||
        !host.mounted ||
        scope == null ||
        scope.actorId != null) {
      return null;
    }
    final repository = ref.read(remoteMfaRepositoryProvider);
    bool current() =>
        mounted &&
        scope == ref.read(authenticatedScopeProvider) &&
        endpoint == ref.read(apiBaseUrlProvider);
    final accepted = await showRemoteMfaCodeDialog(
      host,
      verify: (code) async {
        await repository.verify(code);
      },
      isCurrent: current,
    );
    if (accepted != true || !current() || !host.mounted) return null;
    return remoteAccessText(host, 'verifiedRetry');
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
