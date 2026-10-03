import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../../core/network/server_config.dart';
import '../../../shared/drafts/form_draft_storage_api.dart';
import '../../../shared/drafts/form_draft_store.dart';
import '../../../shared/providers/authenticated_scope_provider.dart';
import '../models/daily_report_approval_intent.dart';

class StoredDailyReportApproval {
  const StoredDailyReportApproval(
    this.intent,
    this.raw,
    this.storageKey, {
    required this.hasBeenDispatched,
  });
  final DailyReportApprovalIntent intent;
  final String raw;
  final String storageKey;
  final bool hasBeenDispatched;
}

/// Uses the existing atomic per-record storage, under a separate feature namespace.
/// Unknown commands have no automatic expiry and cannot be replaced by a new GET.
class DailyReportApprovalIntentStore {
  DailyReportApprovalIntentStore(this.storage, this.prefix, this.isCurrent);
  final FormDraftStorage storage;
  final String? prefix;
  final bool Function() isCurrent;

  String _key(String id) {
    if (prefix == null || !isCurrent()) throw StateError('登录身份或服务器已变化，请重新进入日报');
    if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(id)) {
      throw const FormatException('日报标识无效');
    }
    return '$prefix$id';
  }

  Future<StoredDailyReportApproval?> read(String reportId) async {
    final key = _key(reportId);
    final raw = await storage.read(key);
    if (!isCurrent()) throw StateError('登录身份或服务器已变化');
    if (raw == null) return null;
    final data = Map<String, dynamic>.from(jsonDecode(raw) as Map);
    final phase = data['phase'];
    if (phase != null && phase != 'PREPARED' && phase != 'DISPATCHED') {
      throw const FormatException('原审核阶段无法识别，请保留记录核对');
    }
    final intent = DailyReportApprovalIntent.fromJson(data);
    if (intent.reportId != reportId) {
      throw const FormatException('本机原审核记录不属于这张日报');
    }
    return StoredDailyReportApproval(
      intent,
      raw,
      key,
      hasBeenDispatched: phase != 'PREPARED',
    );
  }

  Future<StoredDailyReportApproval> begin(
    DailyReportApprovalIntent intent,
  ) async {
    final key = _key(intent.reportId);
    final raw = jsonEncode({...intent.toJson(), 'phase': 'PREPARED'});
    final written = await storage.compareAndSet(
      key,
      expectedValue: null,
      value: raw,
    );
    if (!isCurrent()) throw StateError('登录身份或服务器已变化，本次没有发送审核');
    if (!written) throw StateError('另一个页面已保留原审核，请先核对原提交');
    return StoredDailyReportApproval(
      intent,
      raw,
      key,
      hasBeenDispatched: false,
    );
  }

  String _recordKey(StoredDailyReportApproval record) {
    final key = _key(record.intent.reportId);
    if (record.storageKey != key) throw StateError('不能处理其他登录身份的原审核记录');
    return key;
  }

  /// Every sender changes the CAS value, including an explicit V2 replay.
  /// An older page can therefore never delete a newer page's claimed attempt.
  Future<StoredDailyReportApproval> claim(
    StoredDailyReportApproval record,
  ) async {
    final key = _recordKey(record);
    final raw = jsonEncode({
      ...record.intent.toJson(),
      'phase': 'DISPATCHED',
      'attemptId': const Uuid().v4(),
    });
    if (!await storage.compareAndSet(
      key,
      expectedValue: record.raw,
      value: raw,
    )) {
      throw StateError('原审核已由另一页面领取，请重新核对记录');
    }
    if (!isCurrent()) throw StateError('登录身份或服务器已变化，本次未发送审核');
    return StoredDailyReportApproval(
      record.intent,
      raw,
      key,
      hasBeenDispatched: true,
    );
  }

  Future<bool> cancelPrepared(StoredDailyReportApproval record) async {
    if (record.hasBeenDispatched) throw StateError('已发送的原审核只能核对结果');
    return storage.compareAndSet(
      _recordKey(record),
      expectedValue: record.raw,
      value: null,
    );
  }

  /// Called only after a sender knows it never invoked the network closure.
  /// A prior DISPATCHED/legacy unknown record is never eligible for this release.
  Future<bool> cancelUnsentClaim(
    StoredDailyReportApproval claimed,
    StoredDailyReportApproval beforeClaim,
  ) async {
    if (beforeClaim.hasBeenDispatched ||
        beforeClaim.storageKey != claimed.storageKey ||
        beforeClaim.intent.idempotencyKey != claimed.intent.idempotencyKey) {
      throw StateError('不能撤销此前结果未知的审核');
    }
    return storage.compareAndSet(
      _recordKey(claimed),
      expectedValue: claimed.raw,
      value: null,
    );
  }

  Future<void> complete(StoredDailyReportApproval record) async {
    final key = _recordKey(record);
    final removed = await storage.compareAndSet(
      key,
      expectedValue: record.raw,
      value: null,
    );
    if (!removed && await storage.read(key) != null) {
      throw StateError('本机记录已变化，未删除其他页面的新记录');
    }
  }
}

final dailyReportApprovalIntentStoreProvider =
    Provider<DailyReportApprovalIntentStore>((ref) {
      final scope = ref.watch(authenticatedScopeProvider);
      final server = ref.watch(apiBaseUrlProvider);
      final storage = ref.watch(formDraftStorageProvider);
      var alive = true;
      ref.onDispose(() => alive = false);
      return DailyReportApprovalIntentStore(
        storage,
        scope == null || scope.readOnly
            ? null
            : 'daily_report_approval_${formDraftStoragePrefix(server, scope)}',
        () =>
            alive &&
            ref.read(authenticatedScopeProvider) == scope &&
            ref.read(apiBaseUrlProvider) == server,
      );
    });
