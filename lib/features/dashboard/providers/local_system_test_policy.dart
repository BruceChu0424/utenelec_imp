import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/server_config.dart';

/// 测试工具只保留在 Debug 客户端，并且必须连接本机后端。
/// 以实际 API 目标为准，公司内网地址也属于服务器。
bool permitsLocalSystemTests(String target, {required bool debugBuild}) {
  if (!debugBuild) return false;
  final uri = Uri.tryParse(target);
  if (uri == null ||
      !uri.hasAuthority ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      (uri.scheme != 'http' && uri.scheme != 'https')) {
    return false;
  }
  return const {'localhost', '127.0.0.1', '::1', '[::1]'}.contains(uri.host);
}

final localSystemTestEnabledProvider = Provider<bool>((ref) {
  final target = Uri.base.resolve(ref.watch(apiBaseUrlProvider)).toString();
  return permitsLocalSystemTests(target, debugBuild: kDebugMode);
});
