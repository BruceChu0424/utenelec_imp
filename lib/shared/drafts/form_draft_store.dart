import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/network/server_config.dart';
import '../../core/router/route_access_policy.dart';
import '../auth/permissions.dart';
import '../providers/authenticated_scope_provider.dart';
import 'form_draft.dart';
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

class FormDraftsNotifier extends Notifier<List<FormDraft>> {
  int _generation = 0;
  String? _prefix;
  Set<String> _permissions = {};
  FormDraftStorage? _storage;
  Future<void> _ready = Future.value();
  Future<void> _tail = Future.value();

  Future<void> get ready => _ready;

  /// Bound namespace for late editor callbacks, including after widget disposal.
  String? get ownerKey => _prefix;

  @override
  List<FormDraft> build() {
    final generation = ++_generation;
    final scope = ref.watch(authenticatedScopeProvider);
    _permissions = ref.watch(currentPermissionsProvider);
    _prefix = null;
    _storage = null;
    _ready = Future.value();
    if (scope == null || scope.readOnly) return const [];
    final server = ref.watch(apiBaseUrlProvider);
    final prefix = formDraftStoragePrefix(server, scope);
    final storage = ref.watch(formDraftStorageProvider);
    _prefix = prefix;
    _storage = storage;
    _ready = Future<void>.microtask(() async {
      final records = await storage.readAll(prefix);
      if (generation != _generation) return;
      final drafts = <FormDraft>[];
      for (final record in records.values) {
        try {
          final json = jsonDecode(record) as Map<String, dynamic>;
          if (json['completed'] == true) continue;
          final draft = FormDraft.fromJson(json);
          if (_allowed(draft)) drafts.add(draft);
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
    ref.onDispose(() => _generation++);
    return const [];
  }

  bool _allowed(FormDraft draft) =>
      formDraftRouteIsLocal(draft.route) &&
      (draft.permission.isEmpty || _permissions.contains(draft.permission)) &&
      locationAllowedFor(_permissions, false, Uri.parse(draft.route).path);

  Future<T> _serial<T>(Future<T> Function() operation) {
    final next = _tail.then((_) => operation());
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<FormDraft> save(FormDraft draft, {String? expectedRevision}) {
    final generation = _generation;
    final prefix = _prefix;
    final storage = _storage;
    final ready = _ready;
    return _serial(() async {
      await ready;
      if (generation != _generation ||
          prefix == null ||
          storage == null ||
          !_allowed(draft)) {
        throw StateError('登录身份或权限已变化，草稿未写入其他账号');
      }
      _validateId(draft.id);
      final key = '$prefix${draft.id}';
      final existing = await storage.read(key);
      if (generation != _generation) throw StateError('登录身份已变化');
      final current = existing == null
          ? null
          : jsonDecode(existing) as Map<String, dynamic>;
      if (current?['completed'] == true ||
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
        data: draft.data,
        revision: const Uuid().v4(),
      );
      final written = await storage.compareAndSet(
        key,
        expectedValue: existing,
        value: jsonEncode(saved.toJson()),
      );
      if (!written) throw const FormDraftConflict();
      if (generation == _generation) {
        state = [saved, ...state.where((item) => item.id != draft.id)];
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
      if (generation != _generation || prefix == null || storage == null) {
        throw StateError('登录身份已变化');
      }
      _validateId(id);
      final key = '$prefix$id';
      final existing = await storage.read(key);
      if (generation != _generation) throw StateError('登录身份已变化');
      if (existing != null) {
        final current = jsonDecode(existing) as Map<String, dynamic>;
        if (current['completed'] != true &&
            FormDraft.fromJson(current).hasUnknownSubmission) {
          throw const FormDraftUnknownSubmission();
        }
        if (current['completed'] == true || current['revision'] != revision) {
          throw const FormDraftConflict();
        }
        final deleted = await storage.compareAndSet(
          key,
          expectedValue: existing,
          value: null,
        );
        if (!deleted) throw const FormDraftConflict();
      }
      if (generation == _generation) {
        state = state.where((item) => item.id != id).toList();
      }
    });
  }

  /// Called only after confirmed business creation. Atomically replace the
  /// payload with a tiny completion marker: stale tabs can neither restore the
  /// submitted form nor recreate it after cleanup. The payload itself is gone.
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
      if (generation != _generation || prefix == null || storage == null) {
        throw StateError('登录身份已变化');
      }
      _validateId(id);
      final key = '$prefix$id';
      final existing = await storage.read(key);
      if (generation != _generation) throw StateError('登录身份已变化');
      final current = existing == null
          ? null
          : jsonDecode(existing) as Map<String, dynamic>;
      if (current?['completed'] != true) {
        if (current != null && current['revision'] != revision) {
          throw const FormDraftConflict();
        }
        final completed = await storage.compareAndSet(
          key,
          expectedValue: existing,
          value: jsonEncode({
            'version': 1,
            'id': id,
            'completed': true,
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
