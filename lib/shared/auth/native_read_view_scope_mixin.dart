import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../components/feedback/uten_reviewer_responsibility_notice.dart';
import '../../components/feedback/uten_empty.dart';
import '../../components/feedback/uten_inline_notice.dart';
import '../../core/network/api_exception.dart';
import '../../core/network/server_config.dart';
import '../../core/network/read_scope_revision.dart';
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
  Object? _acceptedResource;
  Object? _pendingResource;
  String? _refreshError;
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
      !_pendingRead &&
      _refreshError == null &&
      ref.read(authenticatedScopeProvider)?.readOnly != true;

  bool get nativeReadRefreshing => _pendingRead && nativeReadAccessConfirmed;
  String? get nativeReadRefreshError => _refreshError;

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
      _acceptedResource = null;
      _pendingResource = null;
      _refreshError = null;
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
    ref.listenManual(readScopeRevisionProvider, (previous, next) {
      if (previous == next ||
          !mounted ||
          ref.read(authenticatedScopeProvider) == null) {
        return;
      }
      // An actual read-scope change can keep the same account, roles and Me
      // generation. Retire derived DTOs/dialog authority, retaining this
      // reader's local controllers, draft text and uncertain command intent.
      invalidateNativeReadAccess();
      nativeReadPermissionChanged();
      _scheduleNativeReadReload();
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
        invalidateNativeReadAccess();
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
        _scheduleNativeReadReload();
      }
    });
  }

  void _scheduleNativeReadReload() {
    if (!mounted || !_permissionReady || _accepted || _pendingRead) return;
    final owner = _ownerEpoch;
    final read = _readEpoch;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          _permissionReady &&
          !_accepted &&
          !_pendingRead &&
          owner == _ownerEpoch &&
          read == _readEpoch) {
        nativeReadReload();
      }
    });
  }

  /// Resource identity can be a stable string or an immutable compound query.
  bool Function() captureNativeRead(
    Object resource,
    Object Function() currentResource, {
    bool retainAccepted = false,
  }) {
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
    // Retention is display-only and opt-in for a revalidation of this exact
    // resource. Owner/access/snapshot transitions clear acceptance separately;
    // no equality check can revive an earlier A-B-A reader or resource.
    _accepted =
        retainAccepted &&
        nativeReadAccessConfirmed &&
        _acceptedResource == resource;
    _pendingResource = resource;
    _refreshError = null;
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
    _acceptedResource = _pendingResource;
    _pendingRead = false;
    _refreshError = null;
  }

  /// Finishes only an already-fenced read. A failed background check may keep
  /// its previously authorized display, but commands remain unavailable until
  /// a successful reread. Confirmed access denial retires the old display too.
  bool failNativeRead(Object error, {required String message}) {
    _pendingRead = false;
    if (nativeReadAccessDenied(error) || nativeReadResourceRetired(error)) {
      invalidateNativeReadAccess();
      return false;
    }
    if (nativeReadAccessConfirmed && _acceptedResource == _pendingResource) {
      _refreshError = message;
      return true;
    }
    return false;
  }

  /// Hide accepted data and invalidate pending reads/dialogs immediately when a
  /// caller's required permission disappears, even before the Me refresh finishes.
  void invalidateNativeReadAccess() {
    _accessEpoch++;
    _readEpoch++;
    _accepted = false;
    _pendingRead = false;
    _acceptedResource = null;
    _pendingResource = null;
    _refreshError = null;
    _accessChanges.value++;
  }

  Widget nativeReadRefreshFeedback({required VoidCallback onRetry}) =>
      NativeReadRefreshFeedback(
        refreshing: nativeReadRefreshing,
        error: nativeReadRefreshError,
        onRetry: onRetry,
      );

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

  Widget trackNativeReadDialog(
    BuildContext context,
    Widget child, {
    bool readOnly = false,
    // A confirmation body already belongs to a dialog shell. Its revoked
    // notice must stay intrinsic-safe instead of nesting another dialog.
    bool inlineNotice = false,
  }) {
    _privateRoutes.removeWhere((route) => !route.isActive);
    _dialogAccess.removeWhere((route, _) => !route.isActive);
    final route = ModalRoute.of(context);
    if (route is! PopupRoute<dynamic>) return child;
    _privateRoutes.add(route);
    final access = _dialogAccess.putIfAbsent(route, () => _accessEpoch);
    return ValueListenableBuilder<int>(
      valueListenable: _accessChanges,
      builder: (context, _, _) {
        final current =
            mounted &&
            access == _accessEpoch &&
            (readOnly ? nativeReadAccessConfirmed : nativeReadCanWrite);
        return Stack(
          children: [
            Offstage(offstage: !current, child: child),
            if (!current && inlineNotice)
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '操作权限已更新',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 12),
                  const Text('此窗口中的输入不会提交。请关闭窗口，核对当前信息后再操作。'),
                  const SizedBox(height: 12),
                  Align(
                    child: TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('关闭'),
                    ),
                  ),
                ],
              ),
            if (!current && !inlineNotice)
              // The retained offstage dialog still owns its scroll position.
              // This notice must not attach to that route's primary controller.
              PrimaryScrollController.none(
                child: UtenAlertDialog(
                  title: const Text('操作权限已更新'),
                  content: const Text('此窗口中的输入不会提交。请关闭窗口，核对当前信息后再操作。'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('关闭'),
                    ),
                  ],
                ),
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
          UtenAlertDialog(
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

/// The same confirmed access failures used by the network exception factory.
bool nativeReadAccessDenied(Object error) =>
    error is ApiException &&
    (error.httpStatus == 401 ||
        error.httpStatus == 403 ||
        error.code == 'UNAUTHORIZED' ||
        error.code == 'FORBIDDEN');

/// A detail endpoint confirms that the record no longer exists or is no longer
/// addressable. This is distinct from a transient network/read failure.
bool nativeReadResourceRetired(Object error) =>
    error is ApiException &&
    (error.httpStatus == 404 || error.code == 'NOT_FOUND');

/// A Stack overlay keeps the detail subtree and its scroll controllers mounted.
/// The previous display is explicitly labelled when a background check fails.
class NativeReadRefreshFeedback extends StatelessWidget {
  const NativeReadRefreshFeedback({
    super.key,
    required this.refreshing,
    required this.error,
    required this.onRetry,
  });

  final bool refreshing;
  final String? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    if (!refreshing && error == null) return const SizedBox.shrink();
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Material(
        color: Theme.of(context).colorScheme.surface,
        child: refreshing
            ? Semantics(
                label: '正在核对最新数据',
                child: const LinearProgressIndicator(minHeight: 2),
              )
            : ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 160),
                child: SingleChildScrollView(
                  primary: false,
                  child: UtenInlineNotice(
                    level: UtenInlineNoticeLevel.warning,
                    title: '更新失败，当前显示上次内容',
                    message: error,
                    trailing: TextButton.icon(
                      onPressed: onRetry,
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('重新更新'),
                    ),
                  ),
                ),
              ),
      ),
    );
  }
}
