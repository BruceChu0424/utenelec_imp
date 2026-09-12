import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/server_config.dart';
import '../../../shared/auth/session_epoch_provider.dart';
import '../../../shared/providers/session_provider.dart';
import '../models/business_data_reset_attempt.dart';
import '../providers/business_data_reset_journal.dart';

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
    this.operatorId,
    this.attemptId,
    this.confirmedPendingAttempt = false,
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
      operatorId: json['operatorId'] as String?,
      attemptId: json['attemptId'] as String?,
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
  final String? operatorId;
  final String? attemptId;

  /// Local correlation result, never accepted from a server JSON flag.
  final bool confirmedPendingAttempt;

  BusinessDataResetLastResult confirmedForPendingAttempt() =>
      BusinessDataResetLastResult(
        available: available,
        finishedAt: finishedAt,
        operatorAccount: operatorAccount,
        clearedTableCount: clearedTableCount,
        clearedRows: clearedRows,
        preservedTableCount: preservedTableCount,
        authorizationEpochAfter: authorizationEpochAfter,
        deletedAttachmentFiles: deletedAttachmentFiles,
        operatorId: operatorId,
        attemptId: attemptId,
        confirmedPendingAttempt: true,
      );
}

bool isBusinessDataResetOutcomeUncertain(ApiException error) =>
    error is NetworkException ||
    error is NetworkTimeoutException ||
    error.httpStatus == 502 ||
    error.httpStatus == 504 ||
    error.code == 'SESSION_CHANGED' ||
    error.code == 'SESSION_STATE_UNAVAILABLE' ||
    error.code == 'RESET_PENDING_CONFIRMATION';

class BusinessDataResetPendingException extends ApiException {
  BusinessDataResetPendingException()
    : super(
        'RESET_PENDING_CONFIRMATION',
        '清空结果待确认，服务器可能仍在执行或已完成。请勿再次提交；重新登录后核对本次完成记录。',
      );
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
  Future<BusinessDataResetAttempt?> pendingBusinessDataReset();
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
  ApiSystemTestRepository(
    this._api, {
    required String server,
    required this.operatorId,
    required this.journal,
    DateTime Function()? now,
  }) : server = Uri.base.resolve(server).toString(),
       _now = now ?? DateTime.now;

  final ApiClient _api;
  final String server;
  final String? operatorId;
  final BusinessDataResetJournal journal;
  final DateTime Function() _now;
  bool _inFlight = false;

  @override
  Future<BusinessDataResetAttempt?> pendingBusinessDataReset() async {
    final operator = operatorId;
    if (operator == null || operator.isEmpty) return null;
    try {
      return await journal.read(server, operator);
    } catch (_) {
      throw ApiException(
        'RESET_CONFIRMATION_UNAVAILABLE',
        '无法读取本标签页的清空待确认记录，请勿重新提交；请稍后重试读取。',
      );
    }
  }

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
    if (_inFlight) throw BusinessDataResetPendingException();
    final operator = operatorId;
    if (operator == null || operator.isEmpty) {
      throw ApiException('UNAUTHORIZED', '请重新登录后操作');
    }
    _inFlight = true;
    try {
      if (await pendingBusinessDataReset() != null) {
        throw BusinessDataResetPendingException();
      }
      final attempt = BusinessDataResetAttempt(
        id: const Uuid().v4(),
        server: server,
        operatorId: operator,
        startedAt: _now().toUtc(),
      );
      try {
        await journal.save(attempt);
      } catch (_) {
        throw ApiException(
          'RESET_CONFIRMATION_UNAVAILABLE',
          '无法保存清空请求的待确认记录，尚未发送清空请求。',
        );
      }
      try {
        final json = await _api.postLongRunning(
          ApiEndpoints.systemTestBusinessDataReset,
          body: {'confirm': '清空业务数据', 'attemptId': attempt.id},
          receiveTimeout: businessDataResetReceiveTimeout,
        );
        final result = BusinessDataResetResult.fromJson(json);
        // A direct authenticated 200 is authoritative. If local cleanup fails,
        // preserve its receipt for the next sign-in instead of hiding success.
        try {
          await journal.removeIfSame(attempt);
        } catch (_) {}
        return result;
      } on ApiException catch (error) {
        if (isBusinessDataResetOutcomeUncertain(error)) {
          throw BusinessDataResetPendingException();
        }
        await journal.removeIfSame(attempt);
        rethrow;
      } catch (_) {
        // Malformed/lost success responses can follow a committed reset too.
        // Never replay a destructive command to discover what happened.
        throw BusinessDataResetPendingException();
      }
    } finally {
      _inFlight = false;
    }
  }

  @override
  Future<BusinessDataResetLastResult> lastBusinessDataResetResult() async {
    final attempt = await pendingBusinessDataReset();
    final result = BusinessDataResetLastResult.fromJson(
      await _api.get(
        ApiEndpoints.systemTestBusinessDataLastResult,
        query: attempt == null ? null : {'attemptId': attempt.id},
      ),
    );
    if (attempt != null &&
        result.available &&
        attempt.matchesCompletion(
          currentServer: server,
          currentOperatorId: operatorId ?? '',
          completedBy: result.operatorId,
          completedAttemptId: result.attemptId,
          finishedAt: result.finishedAt,
        )) {
      await journal.removeIfSame(attempt);
      return result.confirmedForPendingAttempt();
    }
    return result;
  }
}

final systemTestRepositoryProvider = Provider<SystemTestRepository>((ref) {
  return ApiSystemTestRepository(
    ref.watch(apiClientProvider),
    server: ref.watch(apiBaseUrlProvider),
    operatorId: ref.watch(sessionProvider.select((state) => state.user?.id)),
    journal: ref.watch(businessDataResetJournalProvider),
  );
});

final pendingBusinessDataResetProvider =
    FutureProvider.autoDispose<BusinessDataResetAttempt?>((ref) {
      ref.watch(sessionEpochProvider);
      return ref.watch(systemTestRepositoryProvider).pendingBusinessDataReset();
    });

/// Every new login queries again. An exact completion releases only the original
/// local receipt; a missing/older/other operator's record cannot unblock it.
final lastBusinessDataResetResultProvider =
    FutureProvider.autoDispose<BusinessDataResetLastResult>((ref) async {
      var active = true;
      ref.onDispose(() => active = false);
      ref.watch(sessionEpochProvider);
      final result = await ref
          .watch(systemTestRepositoryProvider)
          .lastBusinessDataResetResult();
      if (active && result.confirmedPendingAttempt) {
        ref.invalidate(pendingBusinessDataResetProvider);
      }
      return result;
    });
