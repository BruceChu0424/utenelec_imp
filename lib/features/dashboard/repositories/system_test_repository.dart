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

/// 清空请求的接收超时：服务端受理后 5 分钟内完成文件阶段——检查(≤60s)→排水(≤45s)
/// →加锁删除测试文件，共用一个截止点；之后清库。网关对该路径放宽到 600s
/// (deploy/nginx/*.conf 的 `location = /api/system-test/business-data/reset`)，
/// 前端接收超时取 10 分钟与之对齐。
const businessDataResetReceiveTimeout = Duration(minutes: 10);

/// 工作台「系统测试 · 清空业务数据」结果摘要(与后端 Result 一一对应)。
class BusinessDataResetResult {
  const BusinessDataResetResult({
    required this.clearedTableCount,
    required this.clearedRows,
    required this.preservedTableCount,
    required this.authorizationEpochAfter,
    this.deletedAttachmentFiles = 0,
    this.deadBackgroundEventsCleared = 0,
  });

  factory BusinessDataResetResult.fromJson(Map<String, dynamic> json) {
    return BusinessDataResetResult(
      clearedTableCount: (json['clearedTableCount'] as num).toInt(),
      clearedRows: (json['clearedRows'] as num).toInt(),
      preservedTableCount: (json['preservedTableCount'] as num).toInt(),
      authorizationEpochAfter: (json['authorizationEpochAfter'] as num).toInt(),
      deletedAttachmentFiles:
          (json['deletedAttachmentFiles'] as num?)?.toInt() ?? 0,
      deadBackgroundEventsCleared:
          (json['deadBackgroundEventsCleared'] as num?)?.toInt() ?? 0,
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

  /// 本次清空物理删除的测试文件数(按存储位置去重，正式文件 + 暂存副本)。
  final int deletedAttachmentFiles;

  /// 随清空一并清除的、处理失败且已停止重试的后台事件条数。
  final int deadBackgroundEventsCleared;
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
    this.deadBackgroundEventsCleared = 0,
    this.operatorId,
    this.attemptId,
    this.receiptsSupported = false,
    this.attemptReceived = false,
    this.attemptReceivedByCurrentServer = false,
    this.attemptFailed = false,
    this.attemptFailureMessage,
    this.attemptDeletedAttachmentFiles = 0,
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
      deadBackgroundEventsCleared:
          (json['deadBackgroundEventsCleared'] as num?)?.toInt() ?? 0,
      operatorId: json['operatorId'] as String?,
      attemptId: json['attemptId'] as String?,
      // 旧服务端没有受理回执字段：不能把「字段缺失」当「从未受理」去撤销本地记录。
      receiptsSupported: json.containsKey('attemptReceived'),
      attemptReceived: json['attemptReceived'] == true,
      attemptReceivedByCurrentServer:
          json['attemptReceivedByCurrentServer'] == true,
      attemptFailed: json['attemptFailed'] == true,
      attemptFailureMessage: json['attemptFailureMessage']?.toString(),
      attemptDeletedAttachmentFiles:
          (json['attemptDeletedAttachmentFiles'] as num?)?.toInt() ?? 0,
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

  /// 该次清空一并清除的失败后台事件条数(旧记录为 0)。
  final int deadBackgroundEventsCleared;
  final String? operatorId;
  final String? attemptId;

  /// 服务端受理回执（ADR-067 §9，只对本地待确认的 attemptId 查询时有意义）：
  /// 服务器是否收到过该请求、受理它的进程是否还是当前进程、受理后是否明确失败。
  /// [receiptsSupported] 为假表示服务端还是旧版本、没有回执字段，上述三项不可采信。
  final bool receiptsSupported;
  final bool attemptReceived;
  final bool attemptReceivedByCurrentServer;
  final bool attemptFailed;

  /// 失败回执的摘要(不含文件名；含文件名的完整原因只在清空弹窗「重新检查」里)。
  final String? attemptFailureMessage;

  /// 失败前已经物理删除的测试文件数：删掉部分文件之后才失败时大于 0，此时数据没有清空。
  final int attemptDeletedAttachmentFiles;

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
    deadBackgroundEventsCleared: deadBackgroundEventsCleared,
    operatorId: operatorId,
    attemptId: attemptId,
    receiptsSupported: receiptsSupported,
    attemptReceived: attemptReceived,
    attemptReceivedByCurrentServer: attemptReceivedByCurrentServer,
    attemptFailed: attemptFailed,
    attemptFailureMessage: attemptFailureMessage,
    attemptDeletedAttachmentFiles: attemptDeletedAttachmentFiles,
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

/// 清空请求失败后，只有下面这些情况说明不了服务端有没有执行完，按「结果待确认」处理、
/// 绝不自动重发：
///   · 连接中断或超时；
///   · 没有统一错误码的 5xx(网关 502/503/504 的错误页、框架默认错误页等)；
///   · 本端登录状态切换(SESSION_*)，旧请求的结果已被丢弃；
///   · 本地已有待确认记录(RESET_PENDING_CONFIRMATION)；
///   · 服务端明说结果未确认(RESET_OUTCOME_UNCERTAIN：提交事务或写完成回执时出错)。
/// 其余带统一错误码的响应都是服务端确定的失败(包括 500，例如数据库执行失败、服务器配置
/// 有误)，原文照登，不当成待确认：开头的「本次已经物理删除了 d 个测试文件」等说明必须让人看到。
bool isBusinessDataResetOutcomeUncertain(ApiException error) {
  if (error is NetworkException || error is NetworkTimeoutException) {
    return true;
  }
  final code = error.code;
  if (code.startsWith('SESSION_') ||
      code == 'RESET_PENDING_CONFIRMATION' ||
      code == 'RESET_OUTCOME_UNCERTAIN') {
    return true;
  }
  // 本端在发请求之前就拒绝的(没有 HTTP 状态，例如待确认记录写不进去)不算：请求根本没发出。
  final status = error.httpStatus;
  return !error.hasResponseCode && status != null && status >= 500;
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
  /// 调用方应立即本地登出并跳登录页。
  Future<BusinessDataResetResult> resetBusinessData();

  /// 清空前检查(只读，不删任何文件)：与服务端清空时排水前、删除前的检查是同一个，
  /// 返回将删除的测试文件计数和现在不能清空的原因(服务端原文)。
  Future<BusinessDataResetPreview> previewBusinessDataReset();

  /// 上次清空结果（重登后系统测试区回显；运行开关未开启时后端 403）。
  Future<BusinessDataResetLastResult> lastBusinessDataResetResult();
  Future<BusinessDataResetAttempt?> pendingBusinessDataReset();
}

int _count(Object? value) => (value as num?)?.toInt() ?? 0;

List<T> _list<T>(Object? value, T Function(Map<String, dynamic>) parse) =>
    (value as List? ?? const [])
        .map((item) => parse(Map<String, dynamic>.from(item as Map)))
        .toList(growable: false);

/// 清空前检查结果(与后端 BusinessTestResetFilesPort.Check 一一对应)。
///
/// 测试文件清单只来自服务端的唯一规则；客户端只展示，不自行判断哪些文件会被删。
class BusinessDataResetPreview {
  const BusinessDataResetPreview({
    this.locations = 0,
    this.presentFiles = 0,
    this.absentFiles = 0,
    this.inspectedObjects = 0,
    this.inspectionComplete = true,
    this.inspectionSkipped = false,
    this.allListedMissing = false,
    this.kinds = const [],
    this.deadBackgroundEvents = const [],
    this.refusals = const [],
  });

  factory BusinessDataResetPreview.fromJson(Map<String, dynamic> json) =>
      BusinessDataResetPreview(
        locations: _count(json['locations']),
        presentFiles: _count(json['presentFiles']),
        absentFiles: _count(json['absentFiles']),
        inspectedObjects: _count(json['inspectedObjects']),
        inspectionComplete: json['inspectionComplete'] == true,
        // 旧服务端没有这个字段：缺省按「做了核对」处理。
        inspectionSkipped: json['inspectionSkipped'] == true,
        allListedMissing: json['allListedMissing'] == true,
        kinds: _list(json['kinds'], BusinessDataResetFileKind.fromJson),
        deadBackgroundEvents: _list(
          json['deadBackgroundEvents'],
          BusinessDataResetDeadEvents.fromJson,
        ),
        refusals: _list(json['refusals'], BusinessDataResetRefusal.fromJson),
      );

  /// 登记的测试文件存储位置数(同一个物理文件只算一次)。
  final int locations;

  /// 实地核对仍在存储里、清空时将被删除的文件数。
  final int presentFiles;

  /// 已经不在存储里的文件数(含已登记删除的)。
  final int absentFiles;

  /// 本次预先核对了多少个位置；[inspectionComplete] 为假时小于 [locations]。
  final int inspectedObjects;
  final bool inspectionComplete;

  /// 服务端这次根本没有核对存储(例如清空分类本身有问题，已列在拒绝原因里)：
  /// 此时 [presentFiles]/[absentFiles]/[inspectedObjects] 都是 0，不代表文件不在，
  /// 也不是「文件太多没核对完」。
  final bool inspectionSkipped;

  /// 登记了文件但存储里一个都没找到(可能是附件存储盘没挂载)：醒目提醒，不禁用。
  final bool allListedMissing;

  /// 按来源类别(业务附件/上传会话/AI识别原件/报价模板候选/删除任务)的份数。
  final List<BusinessDataResetFileKind> kinds;

  /// 处理失败、已停止重试、会随清空一并清除的后台事件(按类别)。
  final List<BusinessDataResetDeadEvents> deadBackgroundEvents;

  /// 现在不能清空的原因，每条是服务端给人看的完整原文(可能含文件名)。
  final List<BusinessDataResetRefusal> refusals;

  bool get refused => refusals.isNotEmpty;

  int get deadBackgroundEventCount =>
      deadBackgroundEvents.fold(0, (sum, item) => sum + item.events);
}

class BusinessDataResetFileKind {
  const BusinessDataResetFileKind({required this.label, required this.files});

  factory BusinessDataResetFileKind.fromJson(Map<String, dynamic> json) =>
      BusinessDataResetFileKind(
        label: json['label']?.toString() ?? '',
        files: _count(json['files']),
      );

  final String label;
  final int files;
}

class BusinessDataResetDeadEvents {
  const BusinessDataResetDeadEvents({
    required this.label,
    required this.events,
  });

  factory BusinessDataResetDeadEvents.fromJson(Map<String, dynamic> json) =>
      BusinessDataResetDeadEvents(
        label: json['label']?.toString() ?? '',
        events: _count(json['events']),
      );

  final String label;
  final int events;
}

class BusinessDataResetRefusal {
  const BusinessDataResetRefusal({
    required this.code,
    required this.message,
    this.count = 0,
  });

  factory BusinessDataResetRefusal.fromJson(Map<String, dynamic> json) =>
      BusinessDataResetRefusal(
        code: json['code']?.toString() ?? '',
        count: _count(json['count']),
        message: json['message']?.toString() ?? '',
      );

  /// 原因码(只用于测试与排障，不展示)。
  final String code;
  final int count;

  /// 给人看的完整原文：哪个文件、哪类来源、什么规则、下一步怎么做。
  final String message;
}

/// 失败回执的上次结果文案：回执摘要不含文件名；删掉部分文件之后才失败时注明已删数。
String businessDataResetFailureNotice(BusinessDataResetLastResult result) {
  final summary = result.attemptFailureMessage?.trim();
  final deleted = result.attemptDeletedAttachmentFiles;
  final buffer = StringBuffer('上次清空没有完成：')
    ..write(summary?.isNotEmpty == true ? summary : '服务器已拒绝本次请求');
  if (deleted > 0 && !(summary ?? '').contains('已物理删除 $deleted 个')) {
    buffer.write('(已物理删除 $deleted 个测试文件，数据没有清空)');
  }
  return buffer.toString();
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
  Future<BusinessDataResetPreview> previewBusinessDataReset() async =>
      BusinessDataResetPreview.fromJson(
        await _api.get(ApiEndpoints.systemTestBusinessDataPreview),
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
        businessDataResetFailureNotice(result),
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
