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
    for (final provider in [
      authenticatedScopeProvider,
      apiBaseUrlProvider,
      currentPermissionsProvider,
      isSuperAdminProvider,
    ]) {
      try {
        _subscriptions.add(source.listen(provider, (_, _) => _refresh()));
      } on UnimplementedError {
        // 基础设施 provider（如 SharedPreferences）只由 main.dart 注入；
        // 组件预览与 widget 测试没有它们——跳过订阅，快照按缺省值工作。
      }
    }
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

  /// 基础设施 provider 未注入（测试/预览）时取缺省值，不阻断构建。
  T _readOr<T>(ProviderListenable<T> provider, T fallback) {
    try {
      return container!.read(provider);
    } on UnimplementedError {
      return fallback;
    } on StateError {
      return fallback;
    }
  }

  _AccessSnapshot _read() => _AccessSnapshot(
    _readOr<AuthenticatedScope?>(authenticatedScopeProvider, null),
    _readOr(apiBaseUrlProvider, ''),
    Set.of(_readOr(currentPermissionsProvider, const <String>{})),
    _readOr(isSuperAdminProvider, false),
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
