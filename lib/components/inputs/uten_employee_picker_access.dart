import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/server_config.dart';
import '../../shared/auth/permissions.dart';
import '../../shared/providers/authenticated_scope_provider.dart';

/// Binds a candidate request to one authenticated identity, server and effective
/// authorization. A monotonic revision also rejects A -> B -> A responses.
/// Standalone component previews without ProviderScope remain supported.
class EmployeePickerAccess {
  EmployeePickerAccess(this.container, {this.onInvalidated}) {
    final source = container;
    if (source == null) return;
    _snapshot = _read();
    _subscriptions.addAll([
      source.listen(authenticatedScopeProvider, (_, _) => _refresh()),
      source.listen(apiBaseUrlProvider, (_, _) => _refresh()),
      source.listen(currentPermissionsProvider, (_, _) => _refresh()),
      source.listen(isSuperAdminProvider, (_, _) => _refresh()),
    ]);
  }

  final ProviderContainer? container;
  final VoidCallback? onInvalidated;
  final _subscriptions = <ProviderSubscription<Object?>>[];
  _AccessSnapshot? _snapshot;
  var _revision = 0;
  var _disposed = false;

  static ProviderContainer? containerOf(
    BuildContext context, {
    bool listen = false,
  }) {
    try {
      return ProviderScope.containerOf(context, listen: listen);
    } on StateError {
      return null;
    }
  }

  _AccessSnapshot _read() => _AccessSnapshot(
    container!.read(authenticatedScopeProvider),
    container!.read(apiBaseUrlProvider),
    Set.of(container!.read(currentPermissionsProvider)),
    container!.read(isSuperAdminProvider),
  );

  void _refresh() {
    if (_disposed || container == null) return;
    final next = _read();
    if (next.sameAs(_snapshot!)) return;
    _snapshot = next;
    _revision++;
    onInvalidated?.call();
  }

  EmployeePickerAccessTicket capture() {
    _refresh();
    return EmployeePickerAccessTicket._(this, _revision);
  }

  void dispose() {
    _disposed = true;
    for (final subscription in _subscriptions) {
      subscription.close();
    }
    _subscriptions.clear();
  }
}

class EmployeePickerAccessTicket {
  EmployeePickerAccessTicket._(this._owner, this._revision);
  final EmployeePickerAccess _owner;
  final int _revision;

  bool get isCurrent {
    _owner._refresh();
    return !_owner._disposed && _revision == _owner._revision;
  }
}

class _AccessSnapshot {
  _AccessSnapshot(
    this.identity,
    this.server,
    this.permissions,
    this.superAdmin,
  );
  final AuthenticatedScope? identity;
  final String server;
  final Set<String> permissions;
  final bool superAdmin;

  bool sameAs(_AccessSnapshot other) =>
      identity == other.identity &&
      server == other.server &&
      superAdmin == other.superAdmin &&
      setEquals(permissions, other.permissions);
}

mixin EmployeePickerAccessState<T extends StatefulWidget> on State<T> {
  EmployeePickerAccess? _pickerAccess;
  EmployeePickerAccess get pickerAccess => _pickerAccess!;

  @protected
  void onPickerAccessInvalidated() {}

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final container = EmployeePickerAccess.containerOf(context, listen: true);
    if (_pickerAccess != null &&
        identical(container, _pickerAccess!.container)) {
      return;
    }
    final replaced = _pickerAccess != null;
    _pickerAccess?.dispose();
    _pickerAccess = EmployeePickerAccess(
      container,
      onInvalidated: onPickerAccessInvalidated,
    );
    if (replaced) onPickerAccessInvalidated();
  }

  @override
  void dispose() {
    _pickerAccess?.dispose();
    super.dispose();
  }
}
