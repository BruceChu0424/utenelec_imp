// 公共运行时设置仓库（仅需登录，非超管）。
//
// 拉前端需要的、非敏感的全局运行时配置：会话空闲超时、审计总留存、
// 附件单文件上限、徽章轮询间隔。取值一律以服务端登记为准 (ADR-110)，前端只保留
// 拉取失败时的兜底默认值，不再各自写死规则。
// 管理类设置走 SystemSettingRepository（authorization:manage + superAdmin）；本仓库对全体登录用户只读。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_endpoints.dart';
import '../attachments/attachment_file_rules.dart';

class PublicSettings {
  const PublicSettings({
    this.idleTimeoutMinutes = 30,
    this.auditReceiptRetentionMonths = 36,
    this.attachmentMaxBytes = kAttachmentMaxFileBytes,
    this.badgePollSeconds = 60,
  });

  final int idleTimeoutMinutes;
  final int auditReceiptRetentionMonths;

  /// 附件单文件上限字节数 (服务端部署配置)。
  final int attachmentMaxBytes;

  /// 红点/徽章后台轮询间隔秒数。
  final int badgePollSeconds;

  factory PublicSettings.fromJson(Map<String, dynamic> j) => PublicSettings(
    idleTimeoutMinutes: (j['idleTimeoutMinutes'] as num?)?.toInt() ?? 30,
    auditReceiptRetentionMonths:
        (j['auditReceiptRetentionMonths'] as num?)?.toInt() ?? 36,
    attachmentMaxBytes:
        (j['attachmentMaxBytes'] as num?)?.toInt() ?? kAttachmentMaxFileBytes,
    badgePollSeconds: (j['badgePollSeconds'] as num?)?.toInt() ?? 60,
  );
}

abstract interface class PublicSettingsRepository {
  Future<PublicSettings> fetch();
}

class DioPublicSettingsRepository implements PublicSettingsRepository {
  DioPublicSettingsRepository(this.api);
  final ApiClient api;

  @override
  Future<PublicSettings> fetch() async {
    final json = await api.get(ApiEndpoints.publicSettings);
    final settings = PublicSettings.fromJson(json);
    // 附件上限要在没有 ref 的地方 (新建单据的暂存控制器) 生效：每次拉到就同步一次。
    AttachmentLimits.apply(settings.attachmentMaxBytes);
    return settings;
  }
}

final publicSettingsRepositoryProvider = Provider<PublicSettingsRepository>(
  (ref) => DioPublicSettingsRepository(ref.watch(apiClientProvider)),
);

/// 页面级读取；拉取失败时回退到兜底默认值，不阻塞页面。
final publicSettingsProvider = FutureProvider.autoDispose<PublicSettings>((
  ref,
) async {
  try {
    return await ref.watch(publicSettingsRepositoryProvider).fetch();
  } catch (_) {
    return const PublicSettings();
  }
});
