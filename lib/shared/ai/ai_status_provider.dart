import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_endpoints.dart';

/// `GET /ai/status`: 当前账号能否使用 AI(ADR-133)。不含服务商/模型等配置细节。
class AiStatus {
  const AiStatus({
    required this.available,
    required this.aiAllowedForMe,
    required this.supportsVision,
  });

  factory AiStatus.fromJson(Map<String, dynamic> json) => AiStatus(
    available: json['available'] == true,
    aiAllowedForMe: json['aiAllowedForMe'] == true,
    supportsVision: json['supportsVision'] == true,
  );

  static const unavailable = AiStatus(
    available: false,
    aiAllowedForMe: false,
    supportsVision: false,
  );

  /// 管理员已配置并启用可用的 AI 服务。
  final bool available;

  /// 当前账号有 `ai:use` 权限。
  final bool aiAllowedForMe;

  /// 当前 AI 服务能识别图片/扫描件。
  final bool supportsVision;

  /// 本账号本次能否真正用上 AI。
  bool get usable => available && aiAllowedForMe;
}

/// 读取失败(断网、访客账号、服务端未升级)一律当作「AI 未开启」, 不打扰用户:
/// 各功能照常走不依赖 AI 的路径, 真正提交时服务端仍会独立判断。
final aiStatusProvider = FutureProvider.autoDispose<AiStatus>((ref) async {
  final api = ref.watch(apiClientProvider);
  try {
    return AiStatus.fromJson(await api.get(ApiEndpoints.aiStatus));
  } catch (_) {
    return AiStatus.unavailable;
  }
});
