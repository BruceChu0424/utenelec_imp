import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui/opportunistic_dialog_coordinator.dart';
import '../../shared/providers/app_visibility_provider.dart';
import 'client_update_controller.dart';
import 'client_update_dialog.dart';
import 'client_update_page.dart';
import 'client_update_navigation.dart';

class ClientUpdateHost extends ConsumerStatefulWidget {
  const ClientUpdateHost({
    super.key,
    required this.enabled,
    required this.dialogContext,
  });
  final bool enabled;
  final BuildContext? Function() dialogContext;
  @override
  ConsumerState<ClientUpdateHost> createState() => _ClientUpdateHostState();
}

class _ClientUpdateHostState extends ConsumerState<ClientUpdateHost> {
  Timer? _timer;
  String? _shownRelease;
  bool _dialogOpen = false;
  bool get _active =>
      mounted && widget.enabled && !kIsWeb && ref.read(appVisibilityProvider);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _schedule(const Duration(seconds: 1)),
    );
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
