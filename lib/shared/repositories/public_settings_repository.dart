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
import '../providers/authenticated_scope_provider.dart';

/// Reported by the installed database capability, never inferred from month settings.
enum AuditArchivePurgeMode { preserveUnclassified, legacyPurge, unknown }

AuditArchivePurgeMode _auditArchivePurgeMode(Object? value) => switch (value) {
  'PRESERVE_UNCLASSIFIED' => AuditArchivePurgeMode.preserveUnclassified,
  'LEGACY_PURGE' => AuditArchivePurgeMode.legacyPurge,
  _ => AuditArchivePurgeMode.unknown,
};

class PublicSettings {
  const PublicSettings({
    this.idleTimeoutMinutes = 30,
    this.auditReceiptRetentionMonths = 36,
    this.attachmentMaxBytes = kAttachmentMaxFileBytes,
    this.badgePollSeconds = 60,
    this.auditArchivePurgeMode = AuditArchivePurgeMode.unknown,
  });

  final int idleTimeoutMinutes;
  final int auditReceiptRetentionMonths;

  /// Last reported central archive behavior. Missing/failed reads are unverified.
  final AuditArchivePurgeMode auditArchivePurgeMode;

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
    auditArchivePurgeMode: _auditArchivePurgeMode(j['auditArchivePurgeMode']),
  );

  PublicSettings withoutVerifiedAuditMode() => PublicSettings(
    idleTimeoutMinutes: idleTimeoutMinutes,
    auditReceiptRetentionMonths: auditReceiptRetentionMonths,
    attachmentMaxBytes: attachmentMaxBytes,
    badgePollSeconds: badgePollSeconds,
  );
}

abstract interface class PublicSettingsRepository {
  Future<PublicSettings> fetch();
}

class DioPublicSettingsRepository implements PublicSettingsRepository {
  DioPublicSettingsRepository(this.api, {this.onFetched, this.onFetchFailed});
  final ApiClient api;
  final void Function(PublicSettings)? onFetched;
  final void Function()? onFetchFailed;
  Future<PublicSettings>? _running;

  @override
  Future<PublicSettings> fetch() {
    final running = _running;
    if (running != null) return running;
    late final Future<PublicSettings> next;
    next = _fetch().whenComplete(() {
      if (identical(_running, next)) _running = null;
    });
    _running = next;
    return next;
  }

  Future<PublicSettings> _fetch() async {
    try {
      final json = await api.get(ApiEndpoints.publicSettings);
      final settings = PublicSettings.fromJson(json);
      final publish = onFetched;
      if (publish != null) {
        publish(settings);
      } else {
        // Standalone callers keep the existing attachment-limit contract.
        AttachmentLimits.apply(settings.attachmentMaxBytes);
      }
      return settings;
    } catch (_) {
      onFetchFailed?.call();
      rethrow;
    }
  }
}

/// The existing idle-settings refresh also updates other runtime consumers.
/// Identity/server changes clear the snapshot; no second polling timer is added.
final publicSettingsSnapshotProvider = StateProvider<PublicSettings?>((ref) {
  ref.watch(authenticatedScopeProvider);
  ref.watch(apiClientProvider);
  return null;
});

/// The settings view must remain explicit and usable when its source snapshot
/// cannot be read (for example while an identity/server is being restored).
final auditArchivePurgeModeProvider = Provider<AuditArchivePurgeMode>((ref) {
  try {
    return ref.watch(publicSettingsSnapshotProvider)?.auditArchivePurgeMode ??
        AuditArchivePurgeMode.unknown;
  } catch (_) {
    return AuditArchivePurgeMode.unknown;
  }
});

final publicSettingsRepositoryProvider = Provider<PublicSettingsRepository>((
  ref,
) {
  final scope = ref.watch(authenticatedScopeProvider);
  final api = ref.watch(apiClientProvider);
  var alive = true;
  ref.onDispose(() => alive = false);
  return DioPublicSettingsRepository(
    api,
    onFetched: (settings) {
      if (!alive ||
          ref.read(authenticatedScopeProvider) != scope ||
          !identical(ref.read(apiClientProvider), api)) {
        return;
      }
      AttachmentLimits.apply(settings.attachmentMaxBytes);
      ref.read(publicSettingsSnapshotProvider.notifier).state = settings;
    },
    onFetchFailed: () {
      if (!alive ||
          ref.read(authenticatedScopeProvider) != scope ||
          !identical(ref.read(apiClientProvider), api)) {
        return;
      }
      final previous = ref.read(publicSettingsSnapshotProvider);
      if (previous != null) {
        // Keep known runtime limits, but a failed fresh read cannot continue
        // presenting central archive preservation as a verified capability.
        ref.read(publicSettingsSnapshotProvider.notifier).state = previous
            .withoutVerifiedAuditMode();
      }
    },
  );
});

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
