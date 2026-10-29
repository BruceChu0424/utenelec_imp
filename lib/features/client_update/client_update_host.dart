import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui/opportunistic_dialog_coordinator.dart';
import '../../core/network/user_activity.dart';
import '../../core/web_update/web_update_safety.dart';
import '../../shared/providers/app_visibility_provider.dart';
import 'client_update_controller.dart';
import 'client_update_dialog.dart';
import 'client_update_page.dart';
import 'client_update_navigation.dart';
import 'client_staged_update.dart';
import 'client_auto_update_preferences.dart';

class ClientUpdateHost extends ConsumerStatefulWidget {
  const ClientUpdateHost({
    super.key,
    required this.enabled,
    required this.dialogContext,
    this.authenticated = true,
  });
  final bool enabled;
  final bool authenticated;
  final BuildContext? Function() dialogContext;
  @override
  ConsumerState<ClientUpdateHost> createState() => _ClientUpdateHostState();
}

class _ClientUpdateHostState extends ConsumerState<ClientUpdateHost> {
  Timer? _timer;
  Timer? _idleTimer;
  late DateTime _enabledAt = UserActivity.clock();
  bool _applying = false;
  bool _countdownOpen = false;
  String? _shownRelease;
  bool _dialogOpen = false;
  bool get _active =>
      mounted &&
      widget.enabled &&
      widget.authenticated &&
      !kIsWeb &&
      ref.read(appVisibilityProvider);

  @override
  void initState() {
    super.initState();
    if (!kIsWeb) {
      _idleTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        unawaited(_tryAutomaticUpdate());
      });
    }
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _schedule(const Duration(seconds: 1)),
    );
  }

  @override
  void didUpdateWidget(covariant ClientUpdateHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.enabled != oldWidget.enabled ||
        widget.authenticated != oldWidget.authenticated) {
      _enabledAt = UserActivity.clock();
      _schedule(const Duration(seconds: 1));
    }
  }

  bool _safeAndIdle() {
    if (!mounted ||
        !widget.enabled ||
        kIsWeb ||
        !ref.read(clientAutoUpdateEnabledProvider) ||
        !webUpdateSafety.safeToReload) {
      return false;
    }
    final lastInput = UserActivity.lastInputAt;
    final since = lastInput != null && lastInput.isAfter(_enabledAt)
        ? lastInput
        : _enabledAt;
    return UserActivity.clock().difference(since) >=
        (widget.authenticated
            ? const Duration(minutes: 5)
            : const Duration(seconds: 60));
  }

  Future<void> _tryAutomaticUpdate() async {
    if (!mounted ||
        _applying ||
        _countdownOpen ||
        !widget.enabled ||
        kIsWeb) {
      return;
    }
    final store = ref.read(clientStagedUpdateStoreProvider);
    final staged = store.update;
    if (staged == null || !store.mayApplyAutomatically(staged)) return;
    if (!_safeAndIdle()) return;
    // The visible countdown is the final grace period: input elsewhere cannot
    // happen through the modal barrier, and 稍后 restarts the idle window.
    _showCountdown(staged);
  }

  void _showCountdown(StagedClientUpdate staged) {
    final context = widget.dialogContext();
    if (context == null || !context.mounted) return;
    _countdownOpen = true;
    showClientUpdateCountdownDialog(
      context,
      release: staged.release,
      currentVersion: staged.context.currentVersion,
      onInstall: ({required bool automatic}) async {
        if (!mounted || _applying) return;
        _applying = true;
        try {
          if (widget.authenticated) {
            await ref
                .read(clientUpdateControllerProvider)
                .installPrepared(automatic: automatic);
          } else {
            // This path performs no authenticated or anonymous network request.
            await ref.read(clientStagedUpdateStoreProvider).apply(
              bridge: ref.read(clientUpdateBridgeProvider),
              isSafe: () => webUpdateSafety.safeToReload,
              automatic: automatic,
            );
          }
        } catch (_) {
          // The store retains the failure and latches this release for manual
          // review; an automatic retry must not loop on a broken package.
        } finally {
          _applying = false;
        }
      },
    ).whenComplete(() {
      if (mounted) _countdownOpen = false;
    });
  }

  void _schedule([Duration? delay]) {
    _timer?.cancel();
    if (_active) {
      _timer = Timer(
        delay ??
            Duration(
              seconds: ref
                  .read(clientUpdateControllerProvider)
                  .checkIntervalSeconds,
            ),
        _check,
      );
    }
  }

  Future<void> _check() async {
    if (!_active) return;
    final controller = ref.read(clientUpdateControllerProvider);
    await controller.check(automatic: true);
    if (!_active) return;
    final release = controller.release;
    if (release != null &&
        ref.read(clientAutoUpdateEnabledProvider) &&
        release.platform == 'windows' &&
        release.installMode == 'windows_archive' &&
        release.sizeBytes > 0 &&
        RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(release.sha256)) {
      await controller.prepareUpdate();
      if (!_active) return;
      if (controller.hasStagedUpdate) {
        // A blocking announcement would itself prevent an absent user's idle
        // installation. Availability remains visible on the update page.
        _schedule();
        return;
      }
    }
    if (release != null &&
        release.id != _shownRelease &&
        !_dialogOpen &&
        !controller.transferBusy) {
      final dialogs = ref.read(opportunisticDialogCoordinatorProvider);
      final context = widget.dialogContext();
      if (context == null || !context.mounted) {
        _schedule(const Duration(seconds: 5));
        return;
      }
      final navigator = Navigator.maybeOf(context);
      // Wait for authentication/business dialogs and routes to finish. Retrying
      // does not mark this login's update offer as seen before it is displayed.
      if (navigator == null ||
          !navigator.mounted ||
          ref.read(clientUpdateNavigationProvider).blocked ||
          dialogs.blocked) {
        _schedule(const Duration(seconds: 5));
        return;
      }
      final opportunity = dialogs.tryAcquire();
      if (opportunity == null) {
        _schedule(const Duration(seconds: 5));
        return;
      }
      _shownRelease = release.id;
      _dialogOpen = true;
      try {
        final details = await showClientUpdateDialog(
          context,
          controller,
          interruptSignal: opportunity,
        );
        if (opportunity.interrupted) _shownRelease = null;
        opportunity.dispose();
        if (details == true &&
            _active &&
            context.mounted &&
            !controller.isDisposed) {
          await openClientUpdatePage(context, controller);
        }
      } finally {
        opportunity.dispose();
        _dialogOpen = false;
      }
    }
    _schedule();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _idleTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<bool>(appVisibilityProvider, (_, visible) {
      if (visible) {
        _schedule(const Duration(seconds: 1));
      } else {
        _timer?.cancel();
      }
    });
    return const SizedBox.shrink();
  }
}
