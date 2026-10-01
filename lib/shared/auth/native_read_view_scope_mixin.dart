import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../components/feedback/uten_reviewer_responsibility_notice.dart';
import '../../components/feedback/uten_empty.dart';
import '../../core/network/server_config.dart';
import '../providers/authenticated_scope_provider.dart';
import 'session_snapshot_provider.dart';

/// Owns already rendered native details as well as their pending callbacks.
/// Every identity transition advances the owner epoch, including A-B-A.
mixin NativeReadViewScopeMixin<T extends ConsumerStatefulWidget>
    on ConsumerState<T> {
  int _ownerEpoch = 0;
  int _accessEpoch = 0;
  int _readEpoch = 0;
  bool _accepted = false;
  bool _pendingRead = false;
  bool _permissionReady = false;
  int? _snapshotGeneration;
  bool _hasConfirmedSnapshot = false;
  final Set<ModalRoute<dynamic>> _privateRoutes = {};
  final Map<ModalRoute<dynamic>, int> _dialogAccess = {};
  final ValueNotifier<int> _accessChanges = ValueNotifier(0);

  bool get nativeReadAccessConfirmed =>
      mounted &&
      _accepted &&
      _permissionReady &&
      ref.read(authenticatedScopeProvider) != null;

  bool get nativeReadCanWrite =>
      nativeReadAccessConfirmed &&
      ref.read(authenticatedScopeProvider)?.readOnly != true;

  void nativeReadOwnerChanged();
  void nativeReadPermissionChanged();
  Future<void> nativeReadReload();

  void initializeNativeReadScope() {
    final initial = confirmedSessionSnapshot(ref.read(sessionSnapshotProvider));
    _permissionReady =
        ref.read(authenticatedScopeProvider) != null && initial != null;
    _snapshotGeneration = initial?.generation;
    _hasConfirmedSnapshot = initial != null;
    void ownerChanged() {
      _ownerEpoch++;
      _accessEpoch++;
      _readEpoch++;
      _accepted = false;
      _pendingRead = false;
      _permissionReady = false;
      if (!mounted) return;
      nativeReadOwnerChanged();
      // Modal inputs and confirmations belong to the old reader too.
      for (final route in _privateRoutes.toList()) {
        if (route.isActive) route.navigator?.removeRoute(route);
      }
      _privateRoutes.clear();
      _dialogAccess.clear();
      _accessChanges.value++;
    }

    ref.listenManual(authenticatedScopeProvider, (previous, next) {
      if (previous != next) ownerChanged();
    });
    ref.listenManual(apiBaseUrlProvider, (previous, next) {
      if (previous != next) ownerChanged();
    });
    ref.listenManual(sessionSnapshotProvider, (previous, next) {
      if (ref.read(authenticatedScopeProvider) == null) return;
      final snapshot = confirmedSessionSnapshot(next);
      final generation = snapshot?.generation;
      final ready = snapshot != null;
      final wasReady = _permissionReady;
      _permissionReady = ready;
      final revalidate =
          _hasConfirmedSnapshot &&
          (!ready || generation != _snapshotGeneration);
      if (revalidate) {
        _accessEpoch++;
        _readEpoch++;
        _pendingRead = false;
        _accepted = false;
        _accessChanges.value++;
      }
      if (ready) {
        _hasConfirmedSnapshot = true;
        _snapshotGeneration = generation;
      }
      if (mounted && (ready != wasReady || revalidate)) {
        nativeReadPermissionChanged();
      }
      // Retain controllers owned by this reader, but validate the native DTO
      // again before displaying details or restoring command capabilities.
      if (ready &&
          (revalidate || !wasReady) &&
          !_accepted &&
          !_pendingRead &&
          mounted) {
        final owner = _ownerEpoch;
        final read = _readEpoch;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && owner == _ownerEpoch && read == _readEpoch) {
            nativeReadReload();
          }
        });
      }
    });
  }

  bool Function() captureNativeRead(
    String resource,
    String Function() currentResource,
  ) {
    final scope = ref.read(authenticatedScopeProvider);
    final snapshot = confirmedSessionSnapshot(
      ref.read(sessionSnapshotProvider),
    );
    if (scope == null || snapshot == null || !_permissionReady) {
      // The first native read waits for Me too. Do not let an unconfirmed
      // response become accepted data or suppress the first ready reload.
      return () => false;
    }
    final snapshotGeneration = snapshot.generation;
    final owner = _ownerEpoch;
    final access = _accessEpoch;
    final read = ++_readEpoch;
    _accepted = false;
    _pendingRead = true;
    return () =>
        mounted &&
        _permissionReady &&
        ref.read(authenticatedScopeProvider) == scope &&
        confirmedSessionSnapshot(
              ref.read(sessionSnapshotProvider),
            )?.generation ==
            snapshotGeneration &&
        owner == _ownerEpoch &&
        access == _accessEpoch &&
        read == _readEpoch &&
        resource == currentResource();
  }

  /// Capture before an async confirmation or command, without starting a read.
  bool Function() captureNativeOwnership() {
    final owner = _ownerEpoch;
    final access = _accessEpoch;
    return () => mounted && owner == _ownerEpoch && access == _accessEpoch;
  }

  void acceptNativeRead() {
    _accepted = true;
    _pendingRead = false;
  }

  Widget nativeReadAccessNotice() {
    if (ref.read(authenticatedScopeProvider) == null) {
      return const UtenEmpty(message: '当前登录身份无效，原页面信息已隐藏');
    }
    final snapshot = ref.watch(sessionSnapshotProvider);
    return UtenEmpty(
      isError: snapshot.hasError,
      message: snapshot.hasError ? '无法核对查看范围，当前信息暂不显示' : '正在核对查看范围，当前信息暂不显示',
      actionLabel: '重新核对',
      onAction: () => ref.read(sessionSnapshotProvider.notifier).refresh(),
    );
  }

  Widget trackNativeReadDialog(BuildContext context, Widget child) {
    _privateRoutes.removeWhere((route) => !route.isActive);
    _dialogAccess.removeWhere((route, _) => !route.isActive);
    final route = ModalRoute.of(context);
    if (route is! PopupRoute<dynamic>) return child;
    _privateRoutes.add(route);
    final access = _dialogAccess.putIfAbsent(route, () => _accessEpoch);
    return ValueListenableBuilder<int>(
      valueListenable: _accessChanges,
      builder: (context, _, _) {
        final current = mounted && access == _accessEpoch && nativeReadCanWrite;
        return Stack(
          children: [
            Offstage(offstage: !current, child: child),
            if (!current)
              AlertDialog(
                title: const Text('操作权限已更新'),
                content: const Text('此窗口中的输入不会提交。请关闭窗口，核对当前信息后再操作。'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('关闭'),
                  ),
                ],
              ),
          ],
        );
      },
    );
  }

  @override
  void dispose() {
    _privateRoutes.clear();
    _dialogAccess.clear();
    _accessChanges.dispose();
    super.dispose();
  }

  Future<bool> showNativeReadReviewerConfirm(
    BuildContext context, {
    required String message,
    String title = '确认审核',
    String confirmLabel = '确认审核',
    String actionLabel = '审核',
    String? responsibilityDescription,
  }) async =>
      await showDialog<bool>(
        context: context,
        builder: (dialogContext) => trackNativeReadDialog(
          dialogContext,
          AlertDialog(
            title: Text(title),
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  UtenReviewerResponsibilityNotice(
                    actionLabel: actionLabel,
                    description: responsibilityDescription,
                  ),
                  const SizedBox(height: 12),
                  Text(message),
                ],
              ),
            ),
            actionsAlignment: MainAxisAlignment.center,
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: Text(confirmLabel),
              ),
            ],
          ),
        ),
      ) ==
      true;
}
