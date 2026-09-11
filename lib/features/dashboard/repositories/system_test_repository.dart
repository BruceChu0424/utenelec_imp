import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';

/// 清空请求的接收超时：服务端同步执行「排水（≤45s）→ 业务附件自动清理（≤5 分钟预算）
/// → 清库」，网关对该路径同样放宽到 600s（deploy/nginx/*.conf 的
/// `location = /api/system-test/business-data/reset`），前端取 10 分钟与之对齐。
const businessDataResetReceiveTimeout = Duration(minutes: 10);

/// 工作台「系统测试 · 清空业务数据」结果摘要（与后端 Result 一一对应）。
class BusinessDataResetResult {
  const BusinessDataResetResult({
    required this.clearedTableCount,
    required this.clearedRows,
    required this.preservedTableCount,
    required this.authorizationEpochAfter,
    this.deletedAttachmentFiles = 0,
  });

  factory BusinessDataResetResult.fromJson(Map<String, dynamic> json) {
    return BusinessDataResetResult(
      clearedTableCount: (json['clearedTableCount'] as num).toInt(),
      clearedRows: (json['clearedRows'] as num).toInt(),
      preservedTableCount: (json['preservedTableCount'] as num).toInt(),
      authorizationEpochAfter: (json['authorizationEpochAfter'] as num).toInt(),
      deletedAttachmentFiles:
          (json['deletedAttachmentFiles'] as num?)?.toInt() ?? 0,
    );
  }

  /// 清空的业务表张数（后端白名单口径）。
  final int clearedTableCount;

  /// 清空前业务表合计行数。
  final int clearedRows;

  /// 校验行数不变而保留的主档/治理表张数。
  final int preservedTableCount;

  /// 清空完成后的全局 authorization epoch（所有旧会话已被其踢出）。
  final int authorizationEpochAfter;

  /// 清空前自动清理阶段物理删除的附件对象数（原件 + 临时文件）。
  final int deletedAttachmentFiles;
}

/// 上次清空结果（后端 audit_log 最近一条 business_data_reset 事件；
/// [available]=false 表示尚无记录）。清空请求在客户端/网关超时后服务端仍会完成并
/// 踢人，发起人重登后用它确认「已成功但断连」还是真的失败。
class BusinessDataResetLastResult {
  const BusinessDataResetLastResult({
    required this.available,
    this.finishedAt,
    this.operatorAccount,
    this.clearedTableCount = 0,
    this.clearedRows = 0,
    this.preservedTableCount = 0,
    this.authorizationEpochAfter = 0,
    this.deletedAttachmentFiles = 0,
  });

  factory BusinessDataResetLastResult.fromJson(Map<String, dynamic> json) {
    return BusinessDataResetLastResult(
      available: json['available'] == true,
      finishedAt: DateTime.tryParse(json['finishedAt']?.toString() ?? ''),
      operatorAccount: json['operatorAccount']?.toString(),
      clearedTableCount: (json['clearedTableCount'] as num?)?.toInt() ?? 0,
      clearedRows: (json['clearedRows'] as num?)?.toInt() ?? 0,
      preservedTableCount: (json['preservedTableCount'] as num?)?.toInt() ?? 0,
      authorizationEpochAfter:
          (json['authorizationEpochAfter'] as num?)?.toInt() ?? 0,
      deletedAttachmentFiles:
          (json['deletedAttachmentFiles'] as num?)?.toInt() ?? 0,
    );
  }

  static const none = BusinessDataResetLastResult(available: false);

  final bool available;
  final DateTime? finishedAt;
  final String? operatorAccount;
  final int clearedTableCount;
  final int clearedRows;
  final int preservedTableCount;
  final int authorizationEpochAfter;
  final int deletedAttachmentFiles;
}

abstract interface class SystemTestRepository {
  /// 执行清空业务数据。成功后服务端已让所有人（含当前账号）下线，
  /// 调用方应立即本地登出并跳登录页。
  Future<BusinessDataResetResult> resetBusinessData();
  Future<BusinessAttachmentResetPreview> previewBusinessAttachments();
  Future<BusinessAttachmentResetPreview> prepareBusinessAttachments(
    BusinessAttachmentResetPreview preview,
  );

  /// 上次清空结果（重登后系统测试区回显；运行开关未开启时后端 403）。
  Future<BusinessDataResetLastResult> lastBusinessDataResetResult();
}

class BusinessAttachmentResetPreview {
  const BusinessAttachmentResetPreview({
    required this.database,
    required this.fingerprint,
    required this.blockingCount,
    this.items = const [],
    this.hasMore = false,
  });
  final String database;
  final String fingerprint;
  final int blockingCount;
  final List<Map<String, dynamic>> items;
  final bool hasMore;
  factory BusinessAttachmentResetPreview.fromJson(Map<String, dynamic> json) =>
      BusinessAttachmentResetPreview(
        database: json['database'] as String,
        fingerprint: json['fingerprint'] as String,
        blockingCount: (json['blockingCount'] as num).toInt(),
        items: (json['items'] as List? ?? const [])
            .map((item) => Map<String, dynamic>.from(item as Map))
            .toList(),
        hasMore: json['hasMore'] == true,
      );
}

class ApiSystemTestRepository implements SystemTestRepository {
  const ApiSystemTestRepository(this._api);

  final ApiClient _api;

  @override
  Future<BusinessAttachmentResetPreview> previewBusinessAttachments() async =>
      BusinessAttachmentResetPreview.fromJson(
        await _api.get('/system-test/business-data/attachments/preview'),
      );

  @override
  Future<BusinessAttachmentResetPreview> prepareBusinessAttachments(
    BusinessAttachmentResetPreview preview,
  ) async => BusinessAttachmentResetPreview.fromJson(
    await _api.post(
      '/system-test/business-data/attachments/prepare',
      body: {
        'confirm': '清理测试业务附件',
        'database': preview.database,
        'fingerprint': preview.fingerprint,
      },
    ),
  );

  @override
  Future<BusinessDataResetResult> resetBusinessData() async {
    final json = await _api.postLongRunning(
      ApiEndpoints.systemTestBusinessDataReset,
      body: const {'confirm': '清空业务数据'},
      receiveTimeout: businessDataResetReceiveTimeout,
    );
    return BusinessDataResetResult.fromJson(json);
  }

  @override
  Future<BusinessDataResetLastResult> lastBusinessDataResetResult() async =>
      BusinessDataResetLastResult.fromJson(
        await _api.get(ApiEndpoints.systemTestBusinessDataLastResult),
      );
}

final systemTestRepositoryProvider = Provider<SystemTestRepository>((ref) {
  return ApiSystemTestRepository(ref.watch(apiClientProvider));
});

/// 上次清空结果（系统测试区展开时才读取；autoDispose：收起即释放，重登后重拉）。
final lastBusinessDataResetResultProvider =
    FutureProvider.autoDispose<BusinessDataResetLastResult>(
      (ref) =>
          ref.watch(systemTestRepositoryProvider).lastBusinessDataResetResult(),
    );
