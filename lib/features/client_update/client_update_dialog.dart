import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../components/buttons/uten_button.dart';
import '../../components/feedback/uten_dialog.dart';
import '../../core/l10n/gen/app_localizations.dart';
import '../../core/theme/uten_tokens.dart';
import '../../core/web_update/web_update_safety.dart';
import 'client_update_controller.dart';
import 'client_release.dart';
import '../../shared/platform_branding/platform_branding_provider.dart';

Future<bool?> showClientUpdateDialog(
  BuildContext context,
  ClientUpdateController controller, {
  Listenable? interruptSignal,
}) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  late final DialogRoute<bool> route;
  void interrupt() {
    if (route.isActive) navigator.removeRoute(route);
  }

  route = DialogRoute<bool>(
    settings: const RouteSettings(name: '/settings/software-update-offer'),
    context: context,
    barrierDismissible: false,
    builder: (_) => ClientUpdateDialog(controller: controller),
  );
  interruptSignal?.addListener(interrupt);
  controller.addOwnerDisposedListener(interrupt);
  try {
    return await navigator.push(route);
  } finally {
    interruptSignal?.removeListener(interrupt);
    controller.removeOwnerDisposedListener(interrupt);
  }
}

/// The idle threshold has passed with a verified package staged. The dialog
/// counts down visibly; reaching zero (or the primary button) installs, while
/// 稍后 keeps the current program until the next idle window.
Future<void> showClientUpdateCountdownDialog(
  BuildContext context, {
  required ClientRelease release,
  required String currentVersion,
  required Future<void> Function({required bool automatic}) onInstall,
}) {
  final navigator = Navigator.of(context, rootNavigator: true);
  return navigator.push(
    DialogRoute<void>(
      settings: const RouteSettings(
        name: '/settings/software-update-countdown',
      ),
      context: context,
      barrierDismissible: false,
      builder: (_) => ClientUpdateCountdownDialog(
        release: release,
        currentVersion: currentVersion,
        onInstall: onInstall,
      ),
    ),
  );
}

class ClientUpdateCountdownDialog extends ConsumerStatefulWidget {
  const ClientUpdateCountdownDialog({
    super.key,
    required this.release,
    required this.currentVersion,
    required this.onInstall,
    this.duration = const Duration(seconds: 10),
  });

  final ClientRelease release;
  final String currentVersion;
  final Future<void> Function({required bool automatic}) onInstall;
  final Duration duration;

  @override
  ConsumerState<ClientUpdateCountdownDialog> createState() =>
      _ClientUpdateCountdownDialogState();
}

class _ClientUpdateCountdownDialogState
    extends ConsumerState<ClientUpdateCountdownDialog> {
  late int _remaining = widget.duration.inSeconds;
  bool _finished = false;
  bool _waitingForSafety = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    // In-flight background work must not install under the countdown; it
    // pauses at zero and fires as soon as the page is safe again.
    webUpdateSafety.addListener(_safetyChanged);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  void _tick() {
    if (_finished || !mounted) return;
    if (_remaining > 1) {
      setState(() => _remaining -= 1);
      return;
    }
    if (webUpdateSafety.safeToReload) {
      _install(automatic: true);
    } else if (!_waitingForSafety) {
      setState(() => _waitingForSafety = true);
    }
  }

  void _safetyChanged() {
    if (_finished || !_waitingForSafety || !webUpdateSafety.safeToReload) {
      return;
    }
    _install(automatic: true);
  }

  Future<void> _install({required bool automatic}) async {
    if (_finished || !mounted) return;
    _finished = true;
    _timer?.cancel();
    final install = widget.onInstall;
    Navigator.of(context, rootNavigator: true).pop();
    await install(automatic: automatic);
  }

  void _cancel() {
    if (_finished || !mounted) return;
    _finished = true;
    _timer?.cancel();
    Navigator.of(context, rootNavigator: true).pop();
  }

  @override
  void dispose() {
    _timer?.cancel();
    webUpdateSafety.removeListener(_safetyChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final branding = ref.watch(platformBrandingSnapshotProvider);
    final language = Localizations.localeOf(context).languageCode;
    final version = widget.release.version;
    final safe = webUpdateSafety.safeToReload;
    final title = switch (language) {
      'zh' => '有新的版本（$version）',
      'ko' => '새 버전이 있습니다 ($version)',
      _ => 'A new version is available ($version)',
    };
    return UtenAlertDialog(
      maxWidth: 460,
      title: Text(
        title,
        textAlign: TextAlign.center,
        style: theme.textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w700,
        ),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(branding.companyName, textAlign: TextAlign.center),
          Text(branding.platformName, textAlign: TextAlign.center),
          const SizedBox(height: UtenSpacing.s12),
          Text(switch (language) {
            'zh' => '建议立即更新。',
            'ko' => '지금 업데이트하는 것을 권장합니다.',
            _ => 'We recommend updating now.',
          }),
          const SizedBox(height: UtenSpacing.s12),
          Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                '$_remaining',
                style: theme.textTheme.displaySmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: scheme.primary,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  height: 1.1,
                ),
              ),
              const SizedBox(width: UtenSpacing.s8),
              Text(
                _waitingForSafety
                    ? (language == 'zh' ? '当前操作完成后自动更新' : '将等待当前操作完成后自动更新')
                    : switch (language) {
                        'zh' => '秒后自动更新',
                        'ko' => '초 후 자동 업데이트',
                        _ => 's until auto-update',
                      },
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s12),
          Text(
            _waitingForSafety
                ? (language == 'zh' ? '有操作尚未完成，系统会等待。' : '正在等待未完成的操作。')
                : '${l10n.clientUpdateCurrent} ${widget.currentVersion}',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      actions: [
        UtenButton(
          type: UtenButtonType.ghost,
          onPressed: _cancel,
          child: Text(l10n.clientUpdateLater),
        ),
        UtenButton(
          onPressed: safe ? () => _install(automatic: false) : null,
          child: Text(
            language == 'zh'
                ? '${l10n.clientUpdateNow}（$_remaining）'
                : language == 'ko'
                ? '지금 업데이트($_remaining)'
                : '${l10n.clientUpdateNow} ($_remaining)',
          ),
        ),
      ],
    );
  }
}

/// The login offer announces availability. Release notes and installation live
/// on the dedicated software update page opened by the primary action.
class ClientUpdateDialog extends ConsumerWidget {
  const ClientUpdateDialog({super.key, required this.controller});
  final ClientUpdateController controller;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final branding = ref.watch(platformBrandingSnapshotProvider);
    final version = controller.release?.version ?? '';
    final title = switch (Localizations.localeOf(context).languageCode) {
      'zh' => '有新的版本（$version）',
      'ko' => '새 버전이 있습니다 ($version)',
      _ => 'A new version is available ($version)',
    };
    return UtenAlertDialog(
      maxWidth: 460,
      title: Text(
        title,
        textAlign: TextAlign.center,
        style: theme.textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w700,
        ),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(branding.companyName, textAlign: TextAlign.center),
          Text(branding.platformName, textAlign: TextAlign.center),
          const SizedBox(height: UtenSpacing.s12),
          Text(switch (Localizations.localeOf(context).languageCode) {
            'zh' => '建议立即更新。',
            'ko' => '지금 업데이트하는 것을 권장합니다.',
            _ => 'We recommend updating now.',
          }),
          const SizedBox(height: UtenSpacing.s12),
          Text(
            '${l10n.clientUpdateCurrent} ${controller.installed?.currentVersion ?? ''}',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      actions: [
        UtenButton(
          type: UtenButtonType.ghost,
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.clientUpdateLater),
        ),
        UtenButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(l10n.clientUpdateDetails),
        ),
      ],
    );
  }
}
