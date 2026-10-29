import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../../core/performance/responsive_data_codec.dart';
import '../../core/router/route_names.dart';
import '../../shared/auth/permissions.dart';
import '../../shared/drafts/form_draft.dart';
import '../../shared/drafts/form_draft_storage.dart';
import '../../shared/drafts/form_draft_store.dart';
import '../../shared/providers/authenticated_scope_provider.dart';
import 'client_release_publish_queue.dart';
import 'client_package_integrity.dart';

const clientReleasePublishRoute = RouteName.clientReleasePublish;
const clientReleasePublishDraftKind = 'client-release-publish-v1';

/// A local preservation capability, captured before picker/network awaits.
/// It owns one original namespace/key and can never acquire another identity
/// or authorize an API request. Existing shared durable CAS/history/reset
/// fences remain the only storage implementation.
class ClientReleasePublishDraftLease {
  ClientReleasePublishDraftLease({
    required this.storage,
    required String server,
    required AuthenticatedScope owner,
    String? draftId,
  }) : id = draftId ?? const Uuid().v4(),
       _resume = draftId != null,
       _prefix = formDraftStoragePrefix(server, owner) {
    if (owner.actorId != null || owner.readOnly) {
      throw StateError('当前身份不能创建发布草稿');
    }
    if (!RegExp(r'^[a-fA-F0-9-]{36}$').hasMatch(id)) {
      throw const FormatException('发布草稿编号无效');
    }
  }
  final FormDraftStorage storage;
  final String id, _prefix;
  final bool _resume;
  String? _raw;
  bool _loaded = false;
  bool _discarded = false;
  bool _discarding = false;
  Future<void> _tail = Future.value();
  Map<String, dynamic>? lastSnapshot;
  String get key => '$_prefix$id';
  Future<FormDraft?> load() async {
    await _tail;
    return _load();
  }

  Future<FormDraft?> _load() async {
    final raw = await storage.read(key);
    if (raw == null) {
      _loaded = true;
      _raw = null;
      return null;
    }
    if (!_resume) throw const FormDraftConflict();
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic> || !isActiveFormDraftRecord(decoded)) {
      throw const FormDraftConflict();
    }
    final draft = FormDraft.fromJson(decoded);
    if (draft.id != id ||
        draft.route != clientReleasePublishRoute ||
        draft.draftKind != clientReleasePublishDraftKind ||
        draft.permission != Perm.clientReleasePublish ||
        draft.module != BadgeModule.system) {
      throw const FormatException('发布草稿与当前页面不一致');
    }
    validateSnapshot(draft.data);
    _loaded = true;
    _raw = raw;
    lastSnapshot = draft.data;
    return draft;
  }

  Future<void> save(Map<String, dynamic> snapshot) {
    if (_discarded || _discarding) {
      return Future.error(StateError('原发布草稿正在或已经明确丢弃'));
    }
    validateSnapshot(snapshot);
    // Deep metadata-only ownership before the first await; no picker source,
    // Uint8List, local filesystem path or authentication material is accepted.
    final owned = jsonDecode(jsonEncode(snapshot)) as Map<String, dynamic>;
    lastSnapshot = owned;
    final next = _tail.catchError((Object _) {}).then((_) async {
      if (!_loaded) {
        await _load();
      }
      final draft = FormDraft(
        id: id,
        title: '客户端发布队列',
        module: BadgeModule.system,
        route: clientReleasePublishRoute,
        permission: Perm.clientReleasePublish,
        draftKind: clientReleasePublishDraftKind,
        updatedAt: DateTime.now(),
        revision: const Uuid().v4(),
        data: owned,
      );
      final encoded = await encodeJsonResponsive(draft.toJson());
      if (!await storage.compareAndSet(
        key,
        expectedValue: _raw,
        value: encoded,
      )) {
        throw const FormDraftConflict();
      }
      _raw = encoded;
    });
    _tail = next;
    return next;
  }

  Future<void> flush() => _tail;
  Future<void> discard({required bool Function() isCurrent}) async {
    if (_discarding || _discarded) throw StateError('原草稿已在处理');
    _discarding = true;
    try {
      await _tail;
      if (!isCurrent()) throw StateError('发布身份已变化，原草稿继续保留');
      if (lastSnapshot?[formDraftUnknownSubmissionKey] == true) {
        throw const FormDraftUnknownSubmission();
      }
      final previous = await storage.read(key);
      if (!isCurrent()) throw StateError('发布身份已变化，原草稿继续保留');
      if (previous != _raw) throw const FormDraftConflict();
      if (previous != null) {
        final json = jsonDecode(previous) as Map<String, dynamic>;
        if (isActiveFormDraftRecord(json) &&
            FormDraft.fromJson(json).hasUnknownSubmission) {
          throw const FormDraftUnknownSubmission();
        }
        if (!await storage.compareAndSet(
          key,
          expectedValue: previous,
          value: null,
        )) {
          throw const FormDraftConflict();
        }
      }
      _discarded = true;
    } finally {
      _discarding = false;
    }
  }

  static void validateSnapshot(Map<String, dynamic> snapshot) {
    if (snapshot['schemaVersion'] != 1 ||
        snapshot['rows'] is! List ||
        (snapshot['rows'] as List).length >
            ClientReleasePublishQueue.maximumFiles ||
        snapshot.keys.any(
          (key) => !const {
            'schemaVersion',
            'rows',
            'context',
            'withdrawals',
            formDraftUnknownSubmissionKey,
          }.contains(key),
        )) {
      throw const FormatException('发布队列草稿格式无效');
    }
    if (snapshot['context'] != null) _validateMetadata(snapshot['context']);
    final ids = <String>{};
    var unknown = false;
    for (final raw in snapshot['rows'] as List) {
      final row = Map<String, dynamic>.from(raw as Map);
      if (row.keys.any(
        (key) => !const {
          'localId',
          'metadata',
          'fileName',
          'sizeBytes',
          'requestId',
          'sha256',
          'releaseId',
          'stage',
          'pendingOperation',
          'retentionPending',
          'publishAcknowledged',
        }.contains(key),
      )) {
        throw const FormatException('发布草稿不能包含文件内容、路径或认证材料');
      }
      final item = ClientReleaseQueueItem.restore(row);
      ClientReleasePublishQueue.requireId(item.localId);
      unknown =
          unknown ||
          row['pendingOperation'] != null ||
          const {'unknown', 'uploading', 'publishing'}.contains(row['stage']);
      if (!ids.add(item.localId) ||
          item.sizeBytes < 0 ||
          item.sizeBytes > maxClientPackageBytes) {
        throw const FormatException('发布草稿项目无效');
      }
      _validateMetadata(row['metadata']);
    }
    final withdrawals = snapshot['withdrawals'] as List? ?? const [];
    if (withdrawals.length > ClientReleasePublishQueue.maximumFiles) {
      throw const FormatException('撤回草稿项目过多');
    }
    final withdrawalIds = <String>{};
    for (final raw in withdrawals) {
      final row = Map<String, dynamic>.from(raw as Map);
      if (row.length != 2 ||
          !row.containsKey('id') ||
          !row.containsKey('state')) {
        throw const FormatException('撤回草稿格式无效');
      }
      final id = row['id'] as String;
      ClientReleasePublishQueue.requireId(id);
      final state = ClientReleaseWithdrawState.values.byName(
        row['state'] as String,
      );
      unknown =
          unknown ||
          state == ClientReleaseWithdrawState.sending ||
          state == ClientReleaseWithdrawState.unknown;
      if (!withdrawalIds.add(id)) throw const FormatException('撤回草稿编号重复');
    }
    if (unknown && snapshot[formDraftUnknownSubmissionKey] != true) {
      throw const FormatException('未决发布草稿不能移除提交保护');
    }
  }

  static void _validateMetadata(Object? raw) {
    final metadata = Map<String, dynamic>.from(raw as Map);
    if (metadata.keys.any(
          (key) => !const {
            'platform',
            'runtimeFamily',
            'architecture',
            'packageKind',
            'version',
            'buildNumber',
            'releaseNotes',
            'storeUrl',
          }.contains(key),
        ) ||
        metadata.values.any(
          (value) => value is! String || value.length > 10000,
        )) {
      throw const FormatException('发布草稿包含未支持的元数据');
    }
    ClientReleasePublishMetadata.fromJson(metadata);
  }
}
