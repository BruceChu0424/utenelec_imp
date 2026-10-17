import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/permissions.dart';
import '../../core/network/server_config.dart';
import '../providers/authenticated_scope_provider.dart';

/// Permission refreshes wait for the current command/recovery to finish. They
/// refresh authority only and never replay a command or replace draft inputs.
mixin ReviewAuthorityRefreshMixin<T extends ConsumerStatefulWidget>
    on ConsumerState<T> {
  bool _authorityRefreshPending = false;
  bool Function() _sameAuthorityOwner = () => true;

  Set<String> get reviewAuthorityPermissionCodes;
  bool get reviewAuthorityRefreshBlocked;
  Future<void> refreshReviewAuthority();

  void initializeReviewAuthorityRefresh() {
    final owner = ref.read(authenticatedScopeProvider);
    final server = ref.read(apiBaseUrlProvider);
    _sameAuthorityOwner = () =>
        ref.read(authenticatedScopeProvider) == owner &&
        ref.read(apiBaseUrlProvider) == server;
    ref.listenManual(currentPermissionsProvider, (previous, next) {
      if (!_sameAuthorityOwner()) {
        _authorityRefreshPending = false;
        return;
      }
      if (!reviewAuthorityPermissionCodes.any(
        (code) => (previous?.contains(code) ?? false) != next.contains(code),
      )) {
        return;
      }
      _authorityRefreshPending = true;
      if (mounted) setState(() {});
    });
    ref.listenManual(isSuperAdminProvider, (previous, next) {
      if (!_sameAuthorityOwner()) {
        _authorityRefreshPending = false;
        return;
      }
      if (previous == next) return;
      _authorityRefreshPending = true;
      if (mounted) setState(() {});
    });
  }

  void scheduleReviewAuthorityRefresh() {
    if (!_authorityRefreshPending || reviewAuthorityRefreshBlocked) return;
    _authorityRefreshPending = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_sameAuthorityOwner()) return;
      if (reviewAuthorityRefreshBlocked) {
        _authorityRefreshPending = true;
        return;
      }
      unawaited(refreshReviewAuthority());
    });
  }
}
