// 运行时只在两个构建期可信端点之间切换：API_BASE_URL（本地）和
// CLOUD_API_BASE_URL（云端）。Release 绝不从本地存储读取任意 host。
//
// 原生端的 auto 模式探测本地服务，本地可达优先本地，否则才使用固定云端地址；
// Debug 可显式设置开发覆盖。Web Release 始终走当前页面同源 /api，并通过公司
// 内外网的 split-horizon DNS / 不同访问入口落到对应站点；Web 不运行局域网探针。
//
// 日常云入口按 ADR-183 转发到公司同一业务服务，不持有 JWT 或业务数据库密钥。
// 本机连接选择不改变公司的写主；灾备接管由独立受控作业完成，并撤销旧会话后重新登录，
// 不通过共享 JWT 密钥或客户端自动回放请求来实现切换。
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/providers/shared_providers.dart';
import 'api_base_url.dart';
import 'server_selection.dart';

/// 当前生效的后端 base URL：据选择模式 + 云端地址 + 本地可达性决定。
/// - local → 编译期本地地址；
/// - cloud → 云端地址（未配则回落本地）；
/// - auto  → 本地可达用本地，否则用云端（未配云端则回落本地）。
final apiBaseUrlProvider = Provider<String>((ref) {
  // prefs 未注入时 shared_providers 已给出全内存空实现（读全默认），
  // 这里保持对可空读取的容忍以适配测试注入 null 的场景。
  final prefs = ref.watch(sharedPreferencesProvider);
  return effectiveServerUrl(
    mode: readServerMode(prefs),
    local: apiBaseUrl,
    cloud: readCloudUrl(prefs),
    localReachable: ref.watch(localServerReachableProvider),
    web: kIsWeb,
  );
});
