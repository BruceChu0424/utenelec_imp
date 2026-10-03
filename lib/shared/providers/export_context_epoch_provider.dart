import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/server_config.dart';
import '../auth/permissions.dart';
import 'authenticated_scope_provider.dart';

/// Persistent, monotonic fence; returning to a former identity cannot revive old work.
class ExportContextEpoch extends Notifier<int> {
  @override
  int build() {
    ref.listen(authenticatedScopeProvider, (previous, next) {
      if (previous != next) state++;
    });
    ref.listen(apiBaseUrlProvider, (previous, next) {
      if (previous != next) state++;
    });
    ref.listen(currentPermissionsProvider, (previous, next) {
      if (!setEquals(previous, next)) state++;
    });
    return 0;
  }
}

// dependencies: 本 notifier watch 了会被测试/子树覆盖的 provider（权限集合、
// 服务器地址），声明依赖才能在 ProviderScope 覆盖作用域内合法读取
// （Riverpod 作用域断言，见 master_header_column_filters_test）。
final exportContextEpochProvider = NotifierProvider<ExportContextEpoch, int>(
  ExportContextEpoch.new,
  dependencies: [
    authenticatedScopeProvider,
    apiBaseUrlProvider,
    currentPermissionsProvider,
  ],
);
