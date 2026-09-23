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
    this.receiptsSupported = false,
    this.attemptReceived = false,
    this.attemptReceivedByCurrentServer = false,
    this.attemptFailed = false,
    this.attemptFailureMessage,
    this.confirmedPendingAttempt = false,
    this.retiredPendingReason,
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
      // 旧服务端没有受理回执字段：不能把「字段缺失」当「从未受理」去撤销本地记录。
      receiptsSupported: json.containsKey('attemptReceived'),
      attemptReceived: json['attemptReceived'] == true,
      attemptReceivedByCurrentServer:
          json['attemptReceivedByCurrentServer'] == true,
      attemptFailed: json['attemptFailed'] == true,
      attemptFailureMessage: json['attemptFailureMessage']?.toString(),
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

  /// 服务端受理回执（ADR-067 §9，只对本地待确认的 attemptId 查询时有意义）：
  /// 服务器是否收到过该请求、受理它的进程是否还是当前进程、受理后是否明确失败。
  /// [receiptsSupported] 为假表示服务端还是旧版本、没有回执字段，上述三项不可采信。
  final bool receiptsSupported;
  final bool attemptReceived;
  final bool attemptReceivedByCurrentServer;
  final bool attemptFailed;
  final String? attemptFailureMessage;

  /// Local correlation result, never accepted from a server JSON flag.
  final bool confirmedPendingAttempt;

  /// 本地待确认记录已按服务端回执**确定地**撤销的原因（未收到 / 已失败 / 进程重启回滚）；
  /// 非空表示可以重新提交。只由本地推导，不接受服务端 JSON 直接给出。
  final String? retiredPendingReason;

  BusinessDataResetLastResult _copy({
    bool? confirmedPendingAttempt,
    String? retiredPendingReason,
  }) => BusinessDataResetLastResult(
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
    receiptsSupported: receiptsSupported,
    attemptReceived: attemptReceived,
    attemptReceivedByCurrentServer: attemptReceivedByCurrentServer,
    attemptFailed: attemptFailed,
    attemptFailureMessage: attemptFailureMessage,
    confirmedPendingAttempt:
        confirmedPendingAttempt ?? this.confirmedPendingAttempt,
    retiredPendingReason: retiredPendingReason ?? this.retiredPendingReason,
  );

  BusinessDataResetLastResult confirmedForPendingAttempt() =>
      _copy(confirmedPendingAttempt: true);

  BusinessDataResetLastResult retiredPendingAttempt(String reason) =>
      _copy(retiredPendingReason: reason);
}

/// 「服务器未收到」只在请求发出这么久之后才采信：受理回执是请求进入服务的第一步、
/// 独立提交，正常几毫秒；留出网关排队的余量，避免把仍在路上的请求当成没送到。
const businessDataResetNeverReceivedGrace = Duration(seconds: 30);

bool isBusinessDataResetOutcomeUncertain(ApiException error) {
  final status = error.httpStatus;
  // A commit can succeed before the server loses its connection or response.
  // Neither a 5xx nor an INTERNAL error proves that this command rolled back.
  return error is NetworkException ||
      error is NetworkTimeoutException ||
      (status != null && status >= 500 && status < 600) ||
      error.code == 'INTERNAL' ||
      error.code == 'SESSION_CHANGED' ||
      error.code == 'SESSION_STATE_UNAVAILABLE' ||
      error.code == 'RESET_PENDING_CONFIRMATION';
}

class BusinessDataResetPendingException extends ApiException {
  BusinessDataResetPendingException()
    : super(
        'RESET_PENDING_CONFIRMATION',
        '清空结果待确认，服务器可能仍在执行或已完成。请勿再次提交；重新登录后核对本次完成记录。',
      );
}

abstract interface class SystemTestRepository {
  /// 执行清空业务数据。成功后服务端已让所有人（含当前账号）下线，
  /// 调用方应立即本地登出并跳登录页。[password] 是操作者本次重新输入的登录密码
  /// (与改系统设置同一门槛)，只随请求体发送，不落本地。
  Future<BusinessDataResetResult> resetBusinessData({required String password});
  Future<BusinessAttachmentResetPreview> previewBusinessAttachments();

  /// 提前分批删除测试业务附件。与清空业务数据同一门槛：[password] 是操作者本次重新输入的
  /// 登录密码，只随请求体发送，不落本地。
  Future<BusinessAttachmentResetPreview> prepareBusinessAttachments(
    BusinessAttachmentResetPreview preview, {
    required String password,
  });

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
    BusinessAttachmentResetPreview preview, {
    required String password,
  }) async => BusinessAttachmentResetPreview.fromJson(
    await _api.post(
      '/system-test/business-data/attachments/prepare',
      body: {
        'confirm': '清理测试业务附件',
        'database': preview.database,
        'fingerprint': preview.fingerprint,
        'password': password,
      },
    ),
  );

  @override
  Future<BusinessDataResetResult> resetBusinessData({
    required String password,
  }) async {
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
          body: {
            'confirm': '清空业务数据',
            'password': password,
            'attemptId': attempt.id,
          },
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
    if (attempt == null) return result;
    if (result.available &&
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
    // 服务端回执（ADR-067 §9）把待确认记录**确定地**收尾，不靠「查不到完成回执」猜：
    // 受理后明确失败 → 撤销并给出原因；受理它的进程已重启而没有完成回执 → 清库事务已随
    // 进程消亡回滚，撤销；从未受理且请求发出已超过余量 → 服务器根本没收到，撤销。
    // 受理了、还是当前进程、也没失败 → 仍在执行（或提交确认丢失），继续等待。
    // 旧服务端没有回执字段：沿用 §8 只认精确完成回执，不撤销。
    if (!result.receiptsSupported) return result;
    if (result.attemptFailed) {
      await journal.removeIfSame(attempt);
      return result.retiredPendingAttempt(
        '本次清空未执行：${result.attemptFailureMessage?.trim().isNotEmpty == true ? result.attemptFailureMessage!.trim() : '服务器已拒绝本次请求'}',
      );
    }
    if (result.attemptReceived && !result.attemptReceivedByCurrentServer) {
      await journal.removeIfSame(attempt);
      return result.retiredPendingAttempt('服务器在执行本次清空期间重启，清空未完成并已整体回滚');
    }
    if (!result.attemptReceived &&
        _now().toUtc().difference(attempt.startedAt) >=
            businessDataResetNeverReceivedGrace) {
      await journal.removeIfSame(attempt);
      return result.retiredPendingAttempt('服务器没有收到本次清空请求（提交时连接中断），没有执行清空');
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
      // 精确完成回执或按服务端受理回执确定撤销，都已改写本地记录：待确认状态随之刷新，
      // 清空按钮据此重新放开。
      if (active &&
          (result.confirmedPendingAttempt ||
              result.retiredPendingReason != null)) {
        ref.invalidate(pendingBusinessDataResetProvider);
      }
      return result;
    });
