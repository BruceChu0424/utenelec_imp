import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/network/server_config.dart';
import '../../core/router/route_access_policy.dart';
import '../auth/permissions.dart';
import '../attachments/attachment.dart';
import '../attachments/attachment_upload_attempt.dart';
import '../providers/authenticated_scope_provider.dart';
import 'form_draft.dart';
import 'form_draft_history_projection.dart';
import 'form_draft_storage.dart';

final formDraftStorageProvider = Provider<FormDraftStorage>(
  (ref) => createFormDraftStorage(),
);

/// No login epoch in the durable key: logging back in must recover old work.
String formDraftStoragePrefix(String server, AuthenticatedScope scope) =>
    '${sha256.convert(utf8.encode(jsonEncode([server, scope.userId, scope.actorId])))}_';

final formDraftsProvider =
    NotifierProvider<FormDraftsNotifier, List<FormDraft>>(
      FormDraftsNotifier.new,
    );

class FormDraftConflict implements Exception {
  const FormDraftConflict();
  @override
  String toString() => '这份草稿已在其他页面修改或删除。当前输入仍在页面中，请保留页面并另存草稿。';
}

class FormDraftUnknownSubmission implements Exception {
  const FormDraftUnknownSubmission();
  @override
  String toString() => formDraftUnknownSubmissionMessage;
}

/// 单据保存失败的公共类型化解读：草稿保护抛出的 StateError / FormDraftConflict /
/// 存储格式异常自带「下一步怎么办」的大白话文案，必须原样带给用户；其余未知异常
/// 返回 null，调用方兜底提示并记日志——不许把可行动的错误吞成「保存失败，请稍后重试」。
String? describeFormSaveError(Object error) => switch (error) {
  FormDraftConflict() => error.toString(),
  StateError() => error.message.isEmpty ? null : error.message,
  final FormatException e => e.message.isEmpty ? null : e.message,
  final TimeoutException e => e.message?.isEmpty == false ? e.message : null,
  _ => null,
};

class FormDraftsNotifier extends Notifier<List<FormDraft>> {
  int _generation = 0;
  String? _prefix;
  AuthenticatedScope? _ownerScope;
  String? _ownerServer;
  Set<String> _permissions = {};
  FormDraftStorage? _storage;
  bool _readOnly = false;
  bool _closed = false;
  Future<void> _ready = Future.value();
  Future<void> _tail = Future.value();

  Future<void> get ready => _ready;

  /// Bound namespace for late editor callbacks, including after widget disposal.
  String? get ownerKey => _prefix;

  @override
  List<FormDraft> build() {
    _closed = false;
    final generation = ++_generation;
    ref.onDispose(() {
      _generation++;
      _closed = true;
      _prefix = null;
      _storage = null;
      _ownerScope = null;
      _ownerServer = null;
      _permissions = {};
      _readOnly = true;
    });
    final scope = ref.watch(authenticatedScopeProvider);
    _ownerScope = scope;
    _ownerServer = null;
    _permissions = ref.watch(currentPermissionsProvider);
    _prefix = null;
    _storage = null;
    _ready = Future.value();
    _readOnly = scope?.readOnly ?? true;
    if (scope == null) return const [];
    final server = ref.watch(apiBaseUrlProvider);
    _ownerServer = server;
    final prefix = formDraftStoragePrefix(server, scope);
    final storage = ref.watch(formDraftStorageProvider);
    _prefix = prefix;
    _storage = storage;
    _ready = Future<void>.microtask(() async {
      final records = await _safeDraftErrors(() => storage.readAll(prefix));
      if (generation != _generation) return;
      final drafts = <FormDraft>[];
      for (final record in records.entries) {
        try {
          final json = jsonDecode(record.value) as Map<String, dynamic>;
          if (!isActiveFormDraftRecord(json)) continue;
          final draft = FormDraft.fromJson(json);
          if (record.key != '$prefix${draft.id}') continue;
          if (_allowed(draft)) drafts.add(_visible(draft));
        } on FormatException {
          // Keep unreadable records on disk for recovery; never erase all drafts.
        } on TypeError {
          // A single invalid record cannot hide the rest of the user's drafts.
        } on ArgumentError {
          // Future module/version values are preserved, not silently deleted.
        }
      }
      drafts.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      state = drafts;
    });
    // The editor awaits ready and displays a storage failure. Listing stays safe.
    unawaited(_ready.catchError((Object _) {}));
    return const [];
  }

  bool _normalAllowed(FormDraft draft) =>
      !_readOnly &&
      formDraftRouteIsLocal(draft.route) &&
      draft.permission.isNotEmpty &&
      _permissions.contains(draft.permission) &&
      locationAllowedFor(_permissions, false, Uri.parse(draft.route).path);

  bool _recoveryAllowed(FormDraft draft) =>
      !_readOnly &&
      _permissions.contains(Perm.productionDailyReportView) &&
      isDailyReportCreateRecoveryDraft(draft);

  bool _allowed(FormDraft draft) =>
      _normalAllowed(draft) || _recoveryAllowed(draft);

  // Removal-only protocol stage. The history UI applies its current typed
  // price/PII projection to this copy; this stage cannot restore removed fields.
  // Ordinary editor data is retained until the private editor restore contract
  // is available. This does not claim general public active-draft redaction.
  FormDraft _visible(FormDraft draft) {
    final normal = _normalAllowed(draft);
    final data = normal
        ? Map<String, dynamic>.from(draft.data)
        : <String, dynamic>{
            dailyReportReadRecoveryOnlyKey: true,
            formDraftUnknownSubmissionKey: draft.hasUnknownSubmission,
            if (draft.data[dailyReportCreateStateKey] is String)
              dailyReportCreateStateKey: draft.data[dailyReportCreateStateKey],
            if (draft.data['createdReportId'] is String)
              'createdReportId': draft.data['createdReportId'],
            dailyReportCreateCommandKey:
                draft.data[dailyReportCreateCommandKey],
            dailyReportCreateReceiptKey:
                draft.data[dailyReportCreateReceiptKey],
          };
    return _removePrivateProtocol(
      FormDraft.fromJson({
        ...draft.toJson(),
        if (!normal) 'title': '生产日报原提交（只读核对）',
        'data': data,
      }),
    );
  }

  // This pure removal stage preserves nonprotocol fields and title. History
  // must use it directly; lack of CREATE never turns other schemas into a
  // daily-report recovery projection or removes their authorized quantities.
  FormDraft _removePrivateProtocol(FormDraft draft) {
    final data = Map<String, dynamic>.from(draft.data);
    // A JSON string bypasses recursive price/PII projection. Keep the original
    // body only in private durable storage, including for users with write access.
    data.remove(dailyReportCreateCommandKey);
    data.remove(dailyReportCreateReceiptKey);
    if (draft.data[dailyReportCreateCommandKey]
        case final Map<Object?, Object?> command) {
      data[dailyReportCreateCommandKey] = {
        for (final key in [
          'idempotencyKey',
          'bodyHash',
          'requestHash',
          'fullPayloadHash',
        ])
          if (command[key] is String) key: command[key],
      };
    }
    if (draft.data[dailyReportCreateReceiptKey]
        case final Map<Object?, Object?> receipt) {
      data[dailyReportCreateReceiptKey] = {
        for (final key in [
          'status',
          'idempotencyKey',
          'requestHash',
          'fullPayloadVersion',
          'fullPayloadHash',
          'reportId',
        ])
          if (key == 'fullPayloadVersion'
              ? receipt[key] is int
              : receipt[key] is String)
            key: receipt[key],
      };
    }
    return FormDraft.fromJson({...draft.toJson(), 'data': data});
  }

  Future<FormDraft?> readDailyReportCreateRecovery(String id) =>
      _safeDraftErrors(() async {
        if (_closed) throw StateError('草稿会话已关闭');
        final generation = _generation, prefix = _prefix, storage = _storage;
        await _ready;
        if (generation != _generation ||
            _readOnly ||
            prefix == null ||
            storage == null ||
            !_permissions.contains(Perm.productionDailyReportView)) {
          throw StateError('当前身份或查看权限已变化');
        }
        _validateId(id);
        final raw = await storage.read('$prefix$id');
        if (generation != _generation) throw StateError('登录身份已变化');
        if (raw == null) return null;
        final json = jsonDecode(raw) as Map<String, dynamic>;
        if (!isActiveFormDraftRecord(json)) return null;
        final draft = FormDraft.fromJson(json);
        if (draft.id != id ||
            !_recoveryAllowed(draft) ||
            !_frozenOwnerMatches(draft.data[dailyReportCreateCommandKey])) {
          return null;
        }
        return draft;
      });

  bool _frozenOwnerMatches(Object? value) =>
      value is Map &&
      value['schema'] is int &&
      value['schema'] == 1 &&
      value['server'] is String &&
      value['server'] == _ownerServer &&
      value['userId'] is String &&
      value['userId'] == _ownerScope?.userId &&
      (value['actorId'] == null || value['actorId'] is String) &&
      value['actorId'] == _ownerScope?.actorId;

  bool _nonEmptyProofString(Object? value) =>
      value is String && value.trim().isNotEmpty;

  /// The sole local write available to a view-only report recovery. Preserve
  /// the stored request, raw inputs and attachment bytes; only attach the
  /// feature-verified receipt and created-document checkpoint under CAS.
  Future<FormDraft> confirmDailyReportCreateRecovery(
    String id, {
    required String expectedRevision,
    required Map<String, dynamic> receipt,
  }) {
    final generation = _generation, prefix = _prefix, storage = _storage;
    final ready = _ready;
    return _serial(() async {
      await ready;
      if (generation != _generation ||
          _readOnly ||
          prefix == null ||
          storage == null ||
          !_permissions.contains(Perm.productionDailyReportView)) {
        throw StateError('当前身份或查看权限已变化');
      }
      _validateId(id);
      final key = '$prefix$id';
      final existing = await storage.read(key);
      if (generation != _generation) throw StateError('登录身份已变化');
      if (existing == null) throw const FormDraftConflict();
      final currentJson = jsonDecode(existing) as Map<String, dynamic>;
      if (!isActiveFormDraftRecord(currentJson)) {
        throw const FormDraftConflict();
      }
      final current = FormDraft.fromJson(currentJson);
      if (current.id != id ||
          !_recoveryAllowed(current) ||
          current.revision != expectedRevision) {
        throw const FormDraftConflict();
      }
      final frozen = current.data[dailyReportCreateCommandKey];
      if (frozen is! Map ||
          !_frozenOwnerMatches(frozen) ||
          frozen['bodyJson'] is! String ||
          ![
            'idempotencyKey',
            'bodyHash',
            'requestHash',
            'fullPayloadHash',
          ].every((key) => _nonEmptyProofString(frozen[key])) ||
          ![
            'idempotencyKey',
            'requestHash',
            'fullPayloadHash',
            'reportId',
          ].every((key) => _nonEmptyProofString(receipt[key])) ||
          frozen['server'] != _ownerServer ||
          frozen['userId'] != _ownerScope?.userId ||
          frozen['actorId'] != _ownerScope?.actorId ||
          sha256
                  .convert(utf8.encode(frozen['bodyJson'] as String))
                  .toString() !=
              frozen['bodyHash'] ||
          receipt['status'] != 'COMMITTED' ||
          receipt['fullPayloadVersion'] is! int ||
          receipt['fullPayloadVersion'] != 1 ||
          receipt['idempotencyKey'] != frozen['idempotencyKey'] ||
          receipt['requestHash'] != frozen['requestHash'] ||
          receipt['fullPayloadHash'] != frozen['fullPayloadHash'] ||
          receipt['reportId'] is! String ||
          (receipt['reportId'] as String).isEmpty) {
        throw StateError('原请求证明与确认回执不一致');
      }
      try {
        final body = jsonDecode(frozen['bodyJson'] as String);
        if (body is! Map ||
            body['idempotencyKey'] != frozen['idempotencyKey']) {
          throw const FormatException('原请求标识不一致');
        }
      } on FormatException {
        throw StateError('原请求证明与确认回执不一致');
      }
      final savedJson = {
        ...currentJson,
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
        'revision': const Uuid().v4(),
        'data': {
          ...current.data,
          'createdReportId': receipt['reportId'],
          dailyReportCreateStateKey: 'CONFIRMED',
          dailyReportCreateReceiptKey: Map<String, dynamic>.from(receipt),
          formDraftUnknownSubmissionKey: false,
          '_formDraftSubmissionPending': false,
        },
      };
      final saved = FormDraft.fromJson(savedJson);
      if (!await storage.compareAndSet(
        key,
        expectedValue: existing,
        value: jsonEncode(savedJson),
      )) {
        throw const FormDraftConflict();
      }
      if (generation != _generation) throw StateError('登录身份或权限已变化');
      state = [_visible(saved), ...state.where((draft) => draft.id != id)];
      return saved;
    });
  }

  /// Only the original CREATE future's explicit rejection can unlock editing.
  /// Ordinary save keeps the private command; receipt errors/unknown outcomes
  /// must never call this path. The shared CAS archives the exact preimage.
  Future<FormDraft> releaseRejectedDailyReportCreate(
    String id, {
    required String expectedRevision,
    required String expectedOperationKey,
    required String expectedBodyHash,
    required int httpStatus,
    required bool createAcknowledged,
  }) {
    final generation = _generation, prefix = _prefix, storage = _storage;
    final ready = _ready;
    return _serial(() async {
      await ready;
      if (_closed ||
          generation != _generation ||
          _readOnly ||
          prefix == null ||
          storage == null ||
          !_permissions.contains(Perm.productionDailyReportCreate) ||
          !_permissions.contains(Perm.productionDailyReportView) ||
          createAcknowledged ||
          (httpStatus != 400 && httpStatus != 422)) {
        throw StateError('这次原创建尚未明确拒绝，原提交继续保留');
      }
      _validateId(id);
      final key = '$prefix$id';
      final existing = await storage.read(key);
      if (_closed || generation != _generation) throw StateError('登录身份或权限已变化');
      if (existing == null) throw const FormDraftConflict();
      final json = jsonDecode(existing) as Map<String, dynamic>;
      if (!isActiveFormDraftRecord(json)) throw const FormDraftConflict();
      final current = FormDraft.fromJson(json);
      final frozen = current.data[dailyReportCreateCommandKey];
      if (current.id != id ||
          current.revision != expectedRevision ||
          !_recoveryAllowed(current) ||
          !_frozenOwnerMatches(frozen) ||
          frozen is! Map ||
          frozen['bodyJson'] is! String ||
          frozen['idempotencyKey'] != expectedOperationKey ||
          frozen['bodyHash'] != expectedBodyHash ||
          sha256
                  .convert(utf8.encode(frozen['bodyJson'] as String))
                  .toString() !=
              expectedBodyHash ||
          current.data['createdReportId'] != null ||
          current.data[dailyReportCreateReceiptKey] != null) {
        throw const FormDraftConflict();
      }
      final body = jsonDecode(frozen['bodyJson'] as String);
      if (body is! Map || body['idempotencyKey'] != expectedOperationKey) {
        throw const FormDraftConflict();
      }
      final releasedData = Map<String, dynamic>.from(current.data)
        ..remove(dailyReportCreateCommandKey)
        ..remove(dailyReportCreateReceiptKey)
        ..[dailyReportCreateStateKey] = 'REJECTED'
        ..[formDraftUnknownSubmissionKey] = false
        ..['_formDraftSubmissionPending'] = false;
      final savedJson = {
        ...json,
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
        'revision': const Uuid().v4(),
        'data': releasedData,
      };
      final saved = FormDraft.fromJson(savedJson);
      if (!await storage.compareAndSet(
        key,
        expectedValue: existing,
        value: jsonEncode(savedJson),
      )) {
        throw const FormDraftConflict();
      }
      if (_closed || generation != _generation) throw StateError('登录身份或权限已变化');
      state = [_visible(saved), ...state.where((draft) => draft.id != id)];
      return saved;
    });
  }

  /// Pure receipt adoption into this active draft. No upload or business write.
  /// All original bytes and attempt identities stay in the same history CAS.
  Future<FormDraft> confirmDailyReportAttachmentRecovery(
    String id, {
    required String expectedRevision,
    required List<Map<String, dynamic>> receipts,
  }) {
    final generation = _generation, prefix = _prefix, storage = _storage;
    final ready = _ready;
    return _serial(() async {
      await ready;
      if (_closed ||
          generation != _generation ||
          _readOnly ||
          prefix == null ||
          storage == null ||
          !_permissions.contains(Perm.productionDailyReportView) ||
          !_permissions.contains(Perm.attachmentView)) {
        throw StateError('当前身份或附件查看权限已变化');
      }
      _validateId(id);
      final key = '$prefix$id';
      final existing = await storage.read(key);
      if (generation != _generation || _closed) {
        throw StateError('登录身份已变化');
      }
      if (existing == null) {
        throw const FormDraftConflict();
      }
      final json = jsonDecode(existing) as Map<String, dynamic>;
      if (!isActiveFormDraftRecord(json)) {
        throw const FormDraftConflict();
      }
      final current = FormDraft.fromJson(json);
      final frozen = current.data[dailyReportCreateCommandKey];
      final parent = current.data[dailyReportCreateReceiptKey];
      final reportId = current.data['createdReportId'];
      if (current.id != id ||
          current.revision != expectedRevision ||
          !_recoveryAllowed(current) ||
          !_frozenOwnerMatches(frozen) ||
          frozen is! Map ||
          parent is! Map ||
          reportId is! String ||
          reportId.isEmpty ||
          parent['reportId'] != reportId ||
          parent['status'] != 'COMMITTED' ||
          parent['fullPayloadVersion'] is! int ||
          parent['fullPayloadVersion'] != 1 ||
          parent['idempotencyKey'] != frozen['idempotencyKey'] ||
          parent['requestHash'] != frozen['requestHash'] ||
          parent['fullPayloadHash'] != frozen['fullPayloadHash'] ||
          frozen['bodyJson'] is! String ||
          sha256
                  .convert(utf8.encode(frozen['bodyJson'] as String))
                  .toString() !=
              frozen['bodyHash']) {
        throw const FormDraftConflict();
      }
      final originalBody = jsonDecode(frozen['bodyJson'] as String);
      if (originalBody is! Map ||
          originalBody['idempotencyKey'] != frozen['idempotencyKey']) {
        throw const FormDraftConflict();
      }
      final identity = AttachmentUploadIdentity(
        server: _ownerServer!,
        userId: _ownerScope!.userId,
        actorId: _ownerScope!.actorId,
        parentProofHash: frozen['fullPayloadHash'] as String,
      );
      final attachments = Map<String, dynamic>.from(
        current.data['attachments'] as Map,
      );
      final items = (attachments['items'] as List)
          .map((v) => Map<String, dynamic>.from(v as Map))
          .toList();
      final seen = <String>{};
      for (final receipt in receipts) {
        final localId = receipt['localUploadId'];
        if (localId is! String || !seen.add(localId)) {
          throw const FormDraftConflict();
        }
        final matches = items
            .where((item) => item['localUploadId'] == localId)
            .toList();
        if (matches.length != 1) {
          throw const FormDraftConflict();
        }
        final item = matches.single;
        final attempts = item['uploadAttempts'] as Map;
        final attempt = AttachmentUploadAttempt.restore(
          Map<String, dynamic>.from(attempts[reportId] as Map),
        );
        final row = Attachment.fromJson(receipt);
        if (attempt.data['ownerType'] != 'PRODUCTION_DAILY_REPORT' ||
            attempt.ownerId != reportId ||
            !attempt.belongsTo(identity) ||
            !attempt.matchesNativeReceipt(row) ||
            !attempt.matchesFile(
              name: item['name'] as String,
              contentType: item['contentType'] as String,
              bytes: base64Decode(item['bytes'] as String),
            )) {
          throw StateError('原附件身份、父单或文件指纹与回执不一致');
        }
        item['uploadedTo'] = {
          ...(item['uploadedTo'] as List? ?? const []).cast<String>(),
          reportId,
        }.toList();
        item['confirmedAttachmentIds'] = {
          ...(item['confirmedAttachmentIds'] as Map? ?? const {}),
          reportId: row.id,
        };
        if (row.deleted) {
          item['confirmedDeletedOwners'] = {
            ...(item['confirmedDeletedOwners'] as List? ?? const [])
                .cast<String>(),
            reportId,
          }.toList();
        }
      }
      if (receipts.isEmpty) {
        return current;
      }
      final savedJson = {
        ...json,
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
        'revision': const Uuid().v4(),
        'data': {
          ...current.data,
          'attachments': {...attachments, 'items': items},
        },
      };
      final saved = FormDraft.fromJson(savedJson);
      if (!await storage.compareAndSet(
        key,
        expectedValue: existing,
        value: jsonEncode(savedJson),
      )) {
        throw const FormDraftConflict();
      }
      if (_closed || generation != _generation) {
        throw StateError('登录身份或权限已变化');
      }
      state = [_visible(saved), ...state.where((draft) => draft.id != id)];
      return saved;
    });
  }

  Future<FormDraftHistoryPage> historyPage({
    String? before,
    int limit = 30,
  }) async {
    if (_closed) return const FormDraftHistoryPage(entries: []);
    final generation = _generation;
    final prefix = _prefix;
    final storage = _storage;
    await ready;
    if (generation != _generation) throw StateError('登录身份或权限已变化');
    if (prefix == null ||
        storage == null ||
        storage is! FormDraftHistoryStorage) {
      return const FormDraftHistoryPage(entries: []);
    }
    final page = await _safeDraftErrors(
      () => (storage as FormDraftHistoryStorage).readHistoryPage(
        prefix,
        before: before,
        limit: limit,
      ),
    );
    if (generation != _generation) throw StateError('登录身份或权限已变化');
    return FormDraftHistoryPage(
      entries: page.entries
          .where(
            (entry) => canReadFormDraftHistory(
              FormDraft(
                id: entry.draftId,
                title: '',
                module: entry.module,
                route: entry.route,
                permission: entry.permission,
                draftKind: entry.draftKind,
                revision: entry.revision,
                updatedAt: entry.recordedAt,
                data: const {},
              ),
              _permissions,
            ),
          )
          .toList(),
      // A page with no currently-authorized entries still advances its seek.
      nextCursor: page.nextCursor,
    );
  }

  Future<FormDraftHistoryRecord?> readHistory(String id) async {
    if (_closed) return null;
    final generation = _generation;
    final prefix = _prefix;
    final storage = _storage;
    await ready;
    if (generation != _generation) throw StateError('登录身份或权限已变化');
    if (prefix == null ||
        storage == null ||
        storage is! FormDraftHistoryStorage) {
      return null;
    }
    final record = await _safeDraftErrors(
      () => (storage as FormDraftHistoryStorage).readHistoryRecord(prefix, id),
    );
    if (generation != _generation) throw StateError('登录身份或权限已变化');
    if (record == null) return null;
    final projected = projectFormDraftHistorySnapshot(
      record.draft,
      _permissions,
    );
    return projected == null
        ? null
        : FormDraftHistoryRecord(
            entry: record.entry,
            draft: _removePrivateProtocol(projected),
          );
  }

  Future<T> _serial<T>(Future<T> Function() operation) {
    if (_closed) return Future<T>.error(StateError('草稿会话已关闭'));
    final next = _tail.then((_) => _safeDraftErrors(operation));
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  /// Decoder errors can embed the original JSON in their source/value. Editors
  /// display error.toString(), so preserve the bytes on disk but expose only a
  /// controlled conflict message at every public storage/recovery boundary.
  Future<T> _safeDraftErrors<T>(Future<T> Function() operation) async {
    try {
      return await operation();
    } on FormatException {
      throw const FormDraftConflict();
    } on TypeError {
      throw const FormDraftConflict();
    } on ArgumentError {
      throw const FormDraftConflict();
    }
  }

  Map<String, dynamic> _preserveFrozenDailyReportCommand(
    FormDraft incoming,
    Map<String, dynamic>? stored,
  ) {
    if (stored == null) return incoming.data;
    final original = FormDraft.fromJson(stored);
    final frozen = original.data[dailyReportCreateCommandKey];
    if (!isDailyReportCreateRecoveryDraft(original) ||
        frozen is! Map ||
        frozen['bodyJson'] is! String) {
      return incoming.data;
    }
    if (incoming.module != original.module ||
        incoming.route != original.route ||
        incoming.permission != original.permission ||
        incoming.draftKind != original.draftKind) {
      throw const FormDraftConflict();
    }
    final proposed = incoming.data[dailyReportCreateCommandKey];
    if (proposed != null) {
      if (proposed is! Map) throw const FormDraftConflict();
      for (final entry in proposed.entries) {
        if (!frozen.containsKey(entry.key) ||
            jsonEncode(entry.value) != jsonEncode(frozen[entry.key])) {
          throw const FormDraftConflict();
        }
      }
    }
    // Public lists intentionally omit bodyJson. Autosave of that projection
    // must not erase or replace the frozen command kept by the original owner.
    return {
      ...incoming.data,
      dailyReportCreateCommandKey: Map<String, dynamic>.from(frozen),
    };
  }

  Future<FormDraft> save(FormDraft draft, {String? expectedRevision}) {
    final generation = _generation;
    final prefix = _prefix;
    final storage = _storage;
    final ready = _ready;
    return _serial(() async {
      await ready;
      if (draft.data.containsKey(formDraftHistoryReadOnlyProjectionKey)) {
        throw StateError('草稿历史仅供查看，不能覆盖或另存为编辑草稿');
      }
      if (generation != _generation ||
          _readOnly ||
          prefix == null ||
          storage == null ||
          !_normalAllowed(draft)) {
        throw StateError('登录身份或权限已变化，草稿未写入其他账号');
      }
      _validateId(draft.id);
      final key = '$prefix${draft.id}';
      final existing = await storage.read(key);
      if (generation != _generation) throw StateError('登录身份已变化');
      final current = existing == null
          ? null
          : jsonDecode(existing) as Map<String, dynamic>;
      if (current != null && current['id'] != draft.id) {
        throw const FormDraftConflict();
      }
      if ((current != null && !isActiveFormDraftRecord(current)) ||
          current?['revision'] != expectedRevision) {
        throw const FormDraftConflict();
      }
      final saved = FormDraft(
        id: draft.id,
        title: draft.title,
        module: draft.module,
        route: draft.route,
        permission: draft.permission,
        draftKind: draft.draftKind,
        updatedAt: DateTime.now(),
        data: _preserveFrozenDailyReportCommand(draft, current),
        revision: const Uuid().v4(),
      );
      final written = await storage.compareAndSet(
        key,
        expectedValue: existing,
        value: jsonEncode(saved.toJson()),
      );
      if (!written) throw const FormDraftConflict();
      if (generation == _generation) {
        state = [
          _visible(saved),
          ...state.where((item) => item.id != draft.id),
        ];
      }
      return saved;
    });
  }

  Future<void> delete(String id, {String? expectedRevision}) {
    final generation = _generation;
    final prefix = _prefix;
    final storage = _storage;
    final ready = _ready;
    final revision =
        expectedRevision ??
        state.where((draft) => draft.id == id).firstOrNull?.revision;
    return _serial(() async {
      await ready;
      if (generation != _generation ||
          _readOnly ||
          prefix == null ||
          storage == null) {
        throw StateError('登录身份已变化');
      }
      _validateId(id);
      final key = '$prefix$id';
      final existing = await storage.read(key);
      if (generation != _generation) throw StateError('登录身份已变化');
      if (existing != null) {
        final current = jsonDecode(existing) as Map<String, dynamic>;
        if (current['id'] != id) throw const FormDraftConflict();
        if (current['completed'] != true &&
            !_normalAllowed(FormDraft.fromJson(current))) {
          throw StateError('草稿操作权限已变化');
        }
        if (current['completed'] != true &&
            FormDraft.fromJson(current).hasUnknownSubmission) {
          throw const FormDraftUnknownSubmission();
        }
        if (!isActiveFormDraftRecord(current) ||
            current['revision'] != revision) {
          throw const FormDraftConflict();
        }
        final deleted = await storage.compareAndSet(
          key,
          expectedValue: existing,
          value: jsonEncode({
            // Non-history test/custom storage must also retain original bytes.
            if (storage is! FormDraftHistoryStorage) ...current,
            'version': 1, 'id': id, 'completed': true,
            'historyAction': 'deleted', 'revision': const Uuid().v4(),
            'completedAt': DateTime.now().toUtc().toIso8601String(),
          }),
        );
        if (!deleted) throw const FormDraftConflict();
      }
      if (generation == _generation) {
        state = state.where((item) => item.id != id).toList();
      }
    });
  }

  /// Confirmed creation leaves a terminal marker and an immutable payload in
  /// history. Stale tabs cannot restore or recreate the submitted editor.
  Future<void> complete(String id, {String? expectedRevision}) {
    final generation = _generation;
    final prefix = _prefix;
    final storage = _storage;
    final ready = _ready;
    final revision =
        expectedRevision ??
        state.where((draft) => draft.id == id).firstOrNull?.revision;
    return _serial(() async {
      await ready;
      if (generation != _generation ||
          _readOnly ||
          prefix == null ||
          storage == null) {
        throw StateError('登录身份已变化');
      }
      _validateId(id);
      final key = '$prefix$id';
      final existing = await storage.read(key);
      if (generation != _generation) throw StateError('登录身份已变化');
      final current = existing == null
          ? null
          : jsonDecode(existing) as Map<String, dynamic>;
      if (current != null && current['id'] != id) {
        throw const FormDraftConflict();
      }
      if (current != null &&
          current['completed'] != true &&
          !isActiveFormDraftRecord(current)) {
        throw const FormDraftConflict();
      }
      if (current?['completed'] != true) {
        if (current != null && !_normalAllowed(FormDraft.fromJson(current))) {
          throw StateError('草稿操作权限已变化');
        }
        if (current != null && current['revision'] != revision) {
          throw const FormDraftConflict();
        }
        final completed = await storage.compareAndSet(
          key,
          expectedValue: existing,
          value: jsonEncode({
            if (storage is! FormDraftHistoryStorage && current != null)
              ...current,
            'version': 1,
            'id': id,
            'completed': true,
            'historyAction': 'completed',
            'revision': const Uuid().v4(),
            'completedAt': DateTime.now().toUtc().toIso8601String(),
          }),
        );
        if (!completed) throw const FormDraftConflict();
      }
      if (generation == _generation) {
        state = state.where((item) => item.id != id).toList();
      }
    });
  }

  void _validateId(String id) {
    if (!RegExp(r'^[a-zA-Z0-9-]+$').hasMatch(id)) {
      throw const FormatException('草稿标识无效');
    }
  }
}
