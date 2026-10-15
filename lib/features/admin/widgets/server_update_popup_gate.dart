import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/route_names.dart';
import '../../../core/ui/opportunistic_dialog_coordinator.dart';
import '../../../core/ui/uten_notify.dart';
import '../../../core/utils/display_datetime.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/badges/badge_registry.dart';
import '../../../shared/providers/app_visibility_provider.dart';
import '../../../shared/providers/shared_providers.dart';
import '../providers/server_operations_access.dart';
import '../providers/server_storage_request_store.dart';
import '../repositories/server_operations_repository.dart';

final serverUpdateReminderEligibleProvider = Provider<bool>(
  (ref) =>
      ref.watch(serverOperationsWritableProvider) &&
      (ref.watch(isSuperAdminProvider) ||
          ref.watch(currentPermissionsProvider).contains(Perm.serverUpdate)),
);

/// Dashboard-only optional reminder. Every refresh is host-local STATUS, no OSS.
class ServerUpdatePopupGate extends ConsumerWidget {
  const ServerUpdatePopupGate({
    super.key,
    required this.visible,
    required this.child,
  });
  final bool visible;
  final Widget child;
  @override
  Widget build(BuildContext context, WidgetRef ref) => Stack(
    children: [
      child,
      _ReminderSession(
        key: ValueKey((
          ref.watch(serverOperationsOwnerProvider),
          ref.watch(serverUpdateReminderEligibleProvider),
        )),
        visible: visible,
      ),
    ],
  );
}

class _ReminderSession extends ConsumerStatefulWidget {
  const _ReminderSession({super.key, required this.visible});
  final bool visible;
  @override
  ConsumerState<_ReminderSession> createState() => _ReminderState();
}

class _ReminderState extends ConsumerState<_ReminderSession> {
  late final Object? _owner;
  late final OpportunisticDialogCoordinator _dialogs;
  DialogOpportunity? _opportunity;
  Timer? _timer;
  bool _busy = false;
  final _acknowledged = <String>{};
  final _snoozed = <String, DateTime>{};
  bool get _current =>
      mounted &&
      _owner != null &&
      _owner == ref.read(serverOperationsOwnerProvider) &&
      ref.read(serverUpdateReminderEligibleProvider);
  bool get _active =>
      _current && widget.visible && ref.read(appVisibilityProvider);

  @override
  void initState() {
    super.initState();
    _owner = ref.read(serverOperationsOwnerProvider);
    _dialogs = ref.read(opportunisticDialogCoordinatorProvider);
    _dialogs.addListener(_priorityChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _queue());
  }

  @override
  void didUpdateWidget(covariant _ReminderSession oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible == oldWidget.visible) return;
    if (!widget.visible) {
      _timer?.cancel();
      _opportunity?.interrupt();
    } else {
      _queue();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _dialogs.removeListener(_priorityChanged);
    _opportunity?.interrupt();
    super.dispose();
  }

  void _priorityChanged() => _queue(const Duration(seconds: 3));
  void _queue([Duration delay = const Duration(milliseconds: 800)]) {
    _timer?.cancel();
    if (!_active || _busy) return;
    _timer = Timer(delay, _check);
  }

  Future<void> _check() async {
    if (!_active || _busy) return;
    if (_dialogs.blocked || ModalRoute.of(context)?.isCurrent != true) {
      _queue(const Duration(seconds: 5));
      return;
    }
    _busy = true;
    DialogOpportunity? opportunity;
    try {
      final status = await ref
          .read(serverOperationsRepositoryProvider)
          .status();
      if (!mounted ||
          !_active ||
          !status.available ||
          !status.canUpdate ||
          !status.updateAvailable ||
          status.latestVersion == null ||
          status.sourceRevision == null ||
          _dialogs.blocked ||
          ModalRoute.of(context)?.isCurrent != true) {
        return;
      }
      final identity = ref.read(serverStorageRequestOwnerProvider);
      if (identity == null) return;
      final key =
          'serverUpdate.reminder.v1.${sha256.convert(utf8.encode(jsonEncode([identity, status.sourceRevision, status.latestVersion])))}';
      final preferences = ref.read(sharedPreferencesProvider);
      final saved = preferences.getString(key);
      if (saved == 'ack' || _acknowledged.contains(key)) return;
      final until = _snoozed[key] ?? DateTime.tryParse(saved ?? '');
      if (until != null && until.isAfter(clock.now().toUtc())) return;
      opportunity = _dialogs.tryAcquire();
      if (opportunity == null) return;
      _opportunity = opportunity;
      if (!mounted) return;
      final open = await UtenNotify.alert(
        context,
        title: '服务器有新版本 ${status.latestVersion}',
        message:
            '当前版本：${status.currentVersion ?? '尚未确认'}\n'
            '上次检查时间：${DisplayDateTime.beijing(status.lastCheckedAt?.toIso8601String(), fallback: '尚未确认')}\n\n'
            '可到服务器更新页面选择立即更新或预约凌晨执行。平时不会自动连接发布源。',
        confirmLabel: '去更新',
        cancelLabel: '稍后（15 分钟）',
        icon: Icons.system_update_alt_rounded,
        interruptSignal: opportunity,
        barrierDismissible: true,
      );
      if (!_active || opportunity.interrupted) return;
      if (open == true) {
        _acknowledged.add(key);
        await preferences.setString(key, 'ack');
        if (!mounted || !_active) return;
        unawaited(GoRouter.of(context).push(RouteName.adminServerOperations));
      } else {
        final next = clock.now().toUtc().add(const Duration(minutes: 15));
        _snoozed[key] = next;
        await preferences.setString(key, next.toIso8601String());
      }
    } catch (_) {
      // Optional reminders cannot block normal work or infer a new version.
    } finally {
      opportunity?.dispose();
      if (identical(_opportunity, opportunity)) _opportunity = null;
      _busy = false;
      // Host-local status only; unchanged badge counts may conceal a newer
      // checked version, so do not depend exclusively on a count transition.
      _queue(const Duration(seconds: 60));
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(appVisibilityProvider, (_, visible) {
      if (!visible) {
        _timer?.cancel();
        _opportunity?.interrupt();
      } else {
        _queue();
      }
    });
    ref.listen(badgeSummaryProvider, (_, _) => _queue());
    return const SizedBox.shrink();
  }
}
