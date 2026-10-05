import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';
import '../../components/layout/uten_editable_grid.dart';
import '../../components/layout/uten_draft_status_layout.dart';
import '../../core/network/api_exception.dart';
import '../../core/network/server_config.dart';
import '../../core/router/nav_helpers.dart';

import '../providers/authenticated_scope_provider.dart';
import 'form_draft.dart';
import 'form_draft_lifecycle.dart';
import 'form_draft_navigation.dart';
import 'form_draft_store.dart';

export 'form_draft.dart';
export 'form_draft_store.dart' show describeFormSaveError, describeSubmitError;

/// Pages provide only their typed snapshot codec and editable listenables.
/// Saving here never invokes a business create/submit/approve endpoint.
mixin FormDraftMixin<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  bool get formDraftEnabled => true;
  bool get formDraftBusy => false;
  bool get formDraftUsesRouterGuard => true;
  bool get formDraftUseCurrentRoute => true;
  String? get formDraftResumeId => null;
  ValueKey<String>? get formDraftRouterPageKey => null;

  /// True only with a persisted server idempotency key or a confirmed created ID.
  bool get formDraftCanReplaySubmission => false;

  /// A feature may provide a pure-read receipt action outside the blocked form.
  Widget? get formDraftSubmissionRecoveryAction => null;
  bool get formDraftHasConfirmedExternalRecovery => false;
  String? get formDraftRecoveryId => _draftRevision == null ? null : _draftId;
  String? get formDraftRecoveryRevision => _draftRevision;

  void holdFormDraftForReadRecovery() {
    if (!formDraftIdentityIsCurrent || !formDraftEnabled) return;
    _draftSubmissionPending = true;
    _draftSubmissionBlocked = true;
    _draftStatus.value = '原提交需要在当前查看范围下重新核对，输入继续保留';
    super.setState(() {});
  }

  /// Only for a feature that proves its send callback never crossed the API
  /// boundary. A timeout, rejected receipt or missing response is not unsent.
  Future<void> releaseFormDraftBeforeDispatch() async {
    if (!formDraftIdentityIsCurrent || !formDraftEnabled) return;
    _draftSubmissionPending = false;
    _draftSubmissionBlocked = false;
    await saveFormDraftNow();
    if (mounted) super.setState(() {});
  }

  /// Adopt only a locally persisted, already confirmed checkpoint after the
  /// feature validates its original command receipt. No business API is called.
  void adoptFormDraftRecoveryCheckpoint(FormDraft checkpoint) {
    if (!formDraftIdentityIsCurrent ||
        checkpoint.id != _draftId ||
        ref
                .read(formDraftsProvider)
                .where((draft) => draft.id == _draftId)
                .firstOrNull
                ?.revision !=
            checkpoint.revision ||
        checkpoint.hasUnknownSubmission ||
        _draftStore?.ownerKey != _draftOwnerKey ||
        !formDraftSpec.canRestore(checkpoint, currentRoute: _draftRoute)) {
      throw StateError('原草稿身份或创建结果尚未核对');
    }
    _draftRevision = checkpoint.revision;
    _draftSubmissionPending = false;
    _draftSubmissionBlocked = false;
    _draftRestoreBlocked = false;
    _draftError = null;
    _draftSavedJson = _captureDraftJson();
    _draftPendingJson = null;
    _draftStatus.value = '原创建已核对，未完成附件仍保留在本机';
    if (mounted) super.setState(() {});
  }

  /// A partially restored snapshot is not evidence for completion or replay.
  bool get formDraftRestorationBlocked => _draftRestoreBlocked;

  /// Returning to equal account/server values cannot revive this old page.
  bool get formDraftIdentityIsCurrent =>
      mounted && !_draftDisposed && !_draftIdentityChanged;

  /// Pages with an initial asynchronous GET start this before loading. Other
  /// editors start it when initializing the draft, before any storage await.
  void startFormDraftIdentityGuard() {
    if (_draftScopeSubscription != null || _draftServerSubscription != null) {
      return;
    }
    final originalScope = ref.read(authenticatedScopeProvider);
    final originalServer = ref.read(apiBaseUrlProvider);
    void invalidate() {
      if (!mounted || _draftDisposed || _draftIdentityChanged) return;
      super.setState(() => _draftIdentityChanged = true);
      _draftStatus.value = '登录身份或服务器已变化，请重新进入页面';
    }

    _draftScopeSubscription = ref.listenManual(authenticatedScopeProvider, (
      _,
      next,
    ) {
      if (next != originalScope) invalidate();
    });
    _draftServerSubscription = ref.listenManual(apiBaseUrlProvider, (_, next) {
      if (next != originalServer) invalidate();
    });
  }

  /// Unknown commands must retain their durable evidence when leaving. A
  /// replay-aware page may use its own per-command outcomes (including legacy
  /// drafts without the shared marker). This is separate from in-flight busy.
  bool get formDraftHasUnknownSubmission => hasUnknownFormDraftSubmission(
    captureFormDraft(),
    route: formDraftSpec.route,
    pendingFallback: _draftSubmissionPending,
    honorMarker: false,
  );
  FormDraftSpec get formDraftSpec;
  Map<String, dynamic> captureFormDraft();
  Future<void> restoreFormDraft(Map<String, dynamic> data);

  /// Opt in only when the page can discard partially restored in-memory fields
  /// and read its authoritative source again. Throw if that refresh fails.
  /// The original local draft is retained, and unresolved submissions cannot
  /// use this escape hatch.
  Future<void> Function()? get formDraftReloadSource => null;
  Iterable<Listenable> get formDraftListenables => const [];

  /// Static grids retain their legacy codec. Pages that rebuild derived rows
  /// must override both hooks and bind writable fields to stable business rows.
  Object? captureFormDraftPlatformFields() {
    final grids = _capturePlatformGridDrafts();
    return grids.isEmpty ? null : grids;
  }

  Future<void> restoreFormDraftPlatformFields(Object? snapshot) async {
    _restorePlatformGridDrafts(snapshot);
  }

  final _draftStatus = ValueNotifier<String>('');
  final _draftListeners = <Listenable>{};
  bool _draftReady = false;
  bool _draftRestoring = false;
  bool _draftFinished = false;
  bool _draftDisposed = false;
  bool _draftExitAllowed = false;
  bool _draftIdentityChanged = false;
  bool _draftStorageReady = false;
  bool _draftRestoreBlocked = false;
  bool _draftSubmissionPending = false;
  bool _draftSubmissionBlocked = false;
  bool _draftSkipResume = false;
  String _draftId = const Uuid().v4();
  String? _draftRevision;
  String _draftRoute = '';
  String _draftBaseline = '';
  String? _draftSavedJson;
  String? _draftPendingJson;
  Object? _draftError;
  Future<void>? _draftWriting;
  Future<bool>? _draftExitPrompt;
  FormDraftsNotifier? _draftStore;
  String? _draftOwnerKey;
  AuthenticatedScope? _draftScope;
  String? _draftServer;
  ProviderSubscription<AuthenticatedScope?>? _draftScopeSubscription;
  ProviderSubscription<String>? _draftServerSubscription;
  void Function()? _removeDraftLifecycle;
  late final _draftLifecycleObserver = _FormDraftLifecycleObserver(
    _flushDraftQuietly,
  );

  Future<void> initializeFormDraft() async {
    if (!formDraftEnabled ||
        _draftReady ||
        _draftRestoring ||
        !formDraftIdentityIsCurrent) {
      return;
    }
    final scope = ref.read(authenticatedScopeProvider);
    if (scope == null || scope.readOnly) return;
    startFormDraftIdentityGuard();
    _draftScope = scope;
    _draftServer = ref.read(apiBaseUrlProvider);
    super.setState(() => _draftRestoring = true);
    _draftBaseline = _captureDraftJson();
    _draftRoute = formDraftSpec.route;
    String? resumeId = _draftSkipResume ? null : formDraftResumeId;
    ValueKey<String>? pageKey = formDraftRouterPageKey;
    final routeState = goRouterPageStateOrNull(context);
    if (routeState != null) {
      final uri = routeState.uri;
      pageKey ??= routeState.pageKey;
      if (!_draftSkipResume &&
          (formDraftUseCurrentRoute ||
              (formDraftUsesRouterGuard &&
                  uri.path == Uri.parse(formDraftSpec.route).path))) {
        resumeId ??= uri.queryParameters['draftId'];
      }
      final parameters = Map<String, String>.of(uri.queryParameters)
        ..remove('draftId');
      if (formDraftUseCurrentRoute) {
        _draftRoute = uri.replace(queryParameters: parameters).toString();
      }
    }
    try {
      _draftStore = ref.read(formDraftsProvider.notifier);
      _draftOwnerKey = _draftStore!.ownerKey;
      await _draftStore!.ready;
      _draftStorageReady = true;
      if (!formDraftIdentityIsCurrent ||
          ref.read(authenticatedScopeProvider) != scope ||
          ref.read(apiBaseUrlProvider) != _draftServer) {
        if (mounted) {
          _draftIdentityChanged = true;
          _draftStatus.value = '登录身份或服务器已变化，请重新进入新建页面';
        }
        return;
      }
      if (resumeId != null) {
        final found = ref
            .read(formDraftsProvider)
            .where((draft) => draft.id == resumeId)
            .firstOrNull;
        if (found == null ||
            !formDraftSpec.canRestore(found, currentRoute: _draftRoute)) {
          throw StateError('草稿不存在或当前账号已无权继续填写');
        }
        _draftId = found.id;
        _draftRevision = found.revision;
        _draftSubmissionPending = found.hasUnknownSubmission;
        await restoreFormDraft(found.data);
        final frozenCommands = unknownFormDraftCommandIdentities(
          found.data,
          route: found.route,
        );
        if (!unknownFormDraftCommandIdentities(
          captureFormDraft(),
          route: formDraftSpec.route,
        ).containsAll(frozenCommands)) {
          throw const FormatException('原提交尚未完整恢复，请保留草稿并稍后核对');
        }
        await restoreFormDraftPlatformFields(found.data['_platformGridDrafts']);
        if (!formDraftIdentityIsCurrent ||
            ref.read(authenticatedScopeProvider) != scope ||
            ref.read(apiBaseUrlProvider) != _draftServer) {
          if (mounted) {
            _draftIdentityChanged = true;
            _draftStatus.value = '登录身份或服务器已变化，请重新进入新建页面';
          }
          return;
        }
        _draftSavedJson = _captureDraftJson();
        _draftSubmissionBlocked =
            _draftSubmissionPending && !formDraftCanReplaySubmission;
        _draftStatus.value = _draftSubmissionBlocked
            ? '上次提交结果待确认，请先核对任务中心的单据记录，避免重复创建。'
            : '已恢复本机草稿';
      }
    } catch (error) {
      _draftError = error;
      _draftRestoreBlocked = resumeId != null;
      _draftStatus.value = '草稿保护未就绪：$error';
    } finally {
      if (formDraftIdentityIsCurrent &&
          ref.read(authenticatedScopeProvider) == scope &&
          ref.read(apiBaseUrlProvider) == _draftServer) {
        // Even failed storage must keep dirty tracking and the leave dialog.
        _draftReady = true;
        FormDraftNavigation.register(
          this,
          _draftRoute,
          _confirmDraftExit,
          pageKey: pageKey,
        );
        WidgetsBinding.instance.addObserver(_draftLifecycleObserver);
        _removeDraftLifecycle = registerFormDraftLifecycle(_flushDraftQuietly);
        _syncDraftListeners();
      }
      _draftRestoring = false;
      if (mounted) super.setState(() {});
    }
  }

  /// A report page can remain open for another partial report after server refresh.
  /// Its next input belongs to a new draft identity and a new loaded baseline.
  Future<void> resetFormDraftAfterSubmission({
    bool preserveCurrentDraft = false,
    Future<void> Function()? prepare,
  }) async {
    if (preserveCurrentDraft) {
      await _draftWriting;
    } else {
      await completeFormDraft();
    }
    if (!formDraftIdentityIsCurrent) return;
    _removeDraftLifecycle?.call();
    _removeDraftLifecycle = null;
    WidgetsBinding.instance.removeObserver(_draftLifecycleObserver);
    FormDraftNavigation.unregister(this);
    // A new partial report is still owned by this same page identity. Keep
    // its sticky guard alive across reset and any asynchronous prepare step.
    for (final item in _draftListeners) {
      item.removeListener(markFormDraftChanged);
    }
    _draftListeners.clear();
    _draftReady = false;
    _draftRestoring = false;
    _draftFinished = false;
    _draftExitAllowed = false;
    _draftSubmissionPending = false;
    _draftSubmissionBlocked = false;
    _draftRestoreBlocked = false;
    _draftError = null;
    _draftId = const Uuid().v4();
    _draftRevision = null;
    _draftSavedJson = null;
    _draftPendingJson = null;
    _draftSkipResume = true;
    if (prepare != null) await prepare();
    await initializeFormDraft();
  }

  bool get _canReloadDraftSource =>
      _draftRestoreBlocked &&
      !_draftRestoring &&
      !_draftSubmissionPending &&
      !_draftSubmissionBlocked &&
      !formDraftHasUnknownSubmission &&
      !_draftIdentityChanged &&
      !formDraftBusy &&
      formDraftReloadSource != null;

  Future<void> _reloadDraftSource() async {
    if (!_canReloadDraftSource) return;
    final scope = _draftScope;
    final server = _draftServer;
    super.setState(() => _draftRestoring = true);
    _draftStatus.value = '正在读取最新单据，原本机草稿仍保留…';
    try {
      await formDraftReloadSource!();
      if (!mounted) return;
      if (_draftIdentityChanged ||
          ref.read(authenticatedScopeProvider) != scope ||
          ref.read(apiBaseUrlProvider) != server) {
        _draftIdentityChanged = true;
        return;
      }
      await resetFormDraftAfterSubmission(preserveCurrentDraft: true);
      if (mounted && !_draftIdentityChanged && _draftError == null) {
        _draftStatus.value = '原本机草稿已保留；已读取最新单据，请核对后继续。';
      }
    } catch (error) {
      _draftError = error;
      _draftRestoreBlocked = true;
      _draftStatus.value = '最新单据读取失败，原本机草稿仍保留：$error';
    } finally {
      _draftRestoring = false;
      if (mounted) super.setState(() {});
    }
  }

  void _syncDraftListeners() {
    if (!_draftReady || _draftDisposed) return;
    final current = formDraftListenables.toSet();
    for (final item in _draftListeners.difference(current)) {
      item.removeListener(markFormDraftChanged);
    }
    for (final item in current.difference(_draftListeners)) {
      item.addListener(markFormDraftChanged);
    }
    _draftListeners
      ..clear()
      ..addAll(current);
  }

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    if (_draftReady && !_draftRestoring && !_draftFinished) {
      markFormDraftChanged();
    }
  }

  void markFormDraftChanged() {
    if (!_draftReady ||
        _draftRestoring ||
        _draftFinished ||
        _draftDisposed ||
        _draftRestoreBlocked ||
        _draftSubmissionBlocked ||
        _draftIdentityChanged) {
      return;
    }
    _syncDraftListeners();
    try {
      final snapshot = _captureDraftJson();
      if (snapshot == _draftPendingJson ||
          (snapshot == _draftSavedJson && _draftError == null)) {
        return;
      }
      _draftExitAllowed = false;
      _draftPendingJson = snapshot;
      _draftStatus.value = '正在保存本机草稿…';
      _flushDraftQuietly();
    } catch (error) {
      _draftError = error;
      _draftStatus.value = '草稿保存失败：$error';
    }
  }

  void _flushDraftQuietly() {
    unawaited(
      saveFormDraftNow().catchError((Object error) {
        if (_draftDisposed) return;
        _draftError = error;
        _draftStatus.value = '草稿尚未保存，请勿关闭页面：$error';
      }),
    );
  }

  /// Explicit transaction checkpoint; callers must await before sending a create.
  Future<void> saveFormDraftNow() async {
    if (!formDraftEnabled || _draftFinished || _draftDisposed) return;
    if (_draftIdentityChanged) throw StateError('登录身份已变化');
    if (_draftRestoreBlocked) throw StateError('草稿未能恢复，请返回任务中心');
    if (!_draftReady) {
      if (_draftError != null) throw _draftError!;
      if (ref.read(authenticatedScopeProvider) != null) {
        throw StateError('草稿保护正在初始化，请稍后保存');
      }
      return;
    }
    if (!_draftStorageReady) {
      ref.invalidate(formDraftsProvider);
      _draftStore = ref.read(formDraftsProvider.notifier);
      await _draftStore!.ready;
      _draftOwnerKey = _draftStore!.ownerKey;
      if (_draftIdentityChanged) throw StateError('登录身份已变化');
      _draftStorageReady = true;
    }
    _draftPendingJson = _captureDraftJson();
    // Install the shared future BEFORE starting work. Waiters only join it;
    // they must not each start another writer after the same await completes.
    // That race used the same old revision twice, even within a single page.
    final existing = _draftWriting;
    if (existing != null) return existing;
    final completion = Completer<void>();
    _draftWriting = completion.future;
    unawaited(_drainDraftWrites(completion));
    return completion.future;
  }

  Future<void> _drainDraftWrites(Completer<void> completion) async {
    try {
      do {
        await _writeDraftLoop();
      } while (!_draftFinished &&
          !_draftIdentityChanged &&
          _draftPendingJson != _draftSavedJson);
      // No await between the last state check and releasing the writer slot.
      _draftWriting = null;
      completion.complete();
    } catch (error, stack) {
      _draftWriting = null;
      completion.completeError(error, stack);
    }
  }

  /// A confirmed server create must not become a false create/upload failure
  /// because a local checkpoint failed. IDs in memory still prevent recreation;
  /// the durable pre-submit marker protects an interrupted restart.
  Future<void> checkpointFormDraftAfterCreation() async {
    try {
      await saveFormDraftNow();
    } catch (error) {
      if (!_draftDisposed) {
        _draftError = error;
        _draftStatus.value = '单据已保存，继续处理本单；本机恢复记录暂存失败。';
      }
    }
  }

  Future<void> _writeDraftLoop() async {
    while (!_draftFinished && !_draftIdentityChanged) {
      final snapshot = _draftPendingJson;
      if (snapshot == null || snapshot == _draftSavedJson) return;
      if (snapshot == _draftBaseline) {
        // Back to the initial values: discard the clean draft without a
        // `deleted` tombstone, so this same identity keeps saving and the
        // next submission checkpoint is not refused (ADR-151 §1). Only the
        // user's explicit "不保存" writes a tombstone (see the exit prompt).
        final revision = _draftRevision;
        if (revision != null) {
          var current = revision;
          if (_savedDraftHasUnknownSubmission) {
            // The stored copy still says a command may be in flight. Reaching
            // here means this editor learned the command was definitely
            // rejected; persist that fact first, then discard.
            current = (await _draftStore!.save(
              _draftOf(snapshot),
              expectedRevision: revision,
            )).revision;
            _draftRevision = current;
          }
          await _draftStore!.discardClean(_draftId, expectedRevision: current);
        }
        _draftRevision = null;
        _draftSavedJson = snapshot;
        _draftError = null;
        if (!_draftDisposed) _draftStatus.value = '';
        continue;
      }
      final saved = await _draftStore!.save(
        _draftOf(snapshot),
        expectedRevision: _draftRevision,
      );
      _draftRevision = saved.revision;
      _draftSavedJson = snapshot;
      _draftError = null;
      if (!_draftDisposed) _draftStatus.value = '已自动保存本机草稿';
    }
  }

  FormDraft _draftOf(String snapshot) {
    final spec = formDraftSpec;
    return FormDraft(
      id: _draftId,
      title: spec.title,
      module: spec.module,
      route: _draftRoute,
      permission: spec.permission,
      draftKind: spec.draftKind,
      updatedAt: DateTime.now(),
      data: jsonDecode(snapshot) as Map<String, dynamic>,
    );
  }

  bool get _savedDraftHasUnknownSubmission {
    final saved = _draftSavedJson;
    if (saved == null) return false;
    try {
      return hasUnknownFormDraftSubmission(
        jsonDecode(saved) as Map<String, dynamic>,
        route: _draftRoute,
      );
    } on FormatException {
      return false;
    }
  }

  String _captureDraftJson() {
    final grids = captureFormDraftPlatformFields();
    return jsonEncode({
      ...captureFormDraft(),
      '_platformGridDrafts': ?grids,
      if (_draftSubmissionPending) '_formDraftSubmissionPending': true,
      formDraftUnknownSubmissionKey: formDraftHasUnknownSubmission,
    });
  }

  // These positions only bind metadata to the same local draft's row codecs;
  // server writes still use the independently verified UUID in each row draft.
  List<UtenEditableGridController> get _platformDraftGrids =>
      formDraftListenables
          .whereType<UtenEditableGridController>()
          .toSet()
          .toList();

  List<Object> _capturePlatformGridDrafts() => [
    for (final grid in _platformDraftGrids)
      [for (final row in grid.rows) row.platformFields.exportDraft()],
  ];

  void _restorePlatformGridDrafts(Object? snapshot) {
    if (snapshot is! List) return; // Earlier draft schemas had no extensions.
    final grids = _platformDraftGrids;
    if (snapshot.length != grids.length) {
      throw StateError('草稿扩展字段与当前表格数量不一致，请核对后恢复');
    }
    for (var index = 0; index < grids.length; index++) {
      final rows = snapshot[index];
      if (rows is! List || rows.length != grids[index].rows.length) {
        throw StateError('草稿扩展字段与明细行数不一致，请核对后恢复');
      }
      for (var row = 0; row < rows.length; row++) {
        grids[index].rows[row].platformFields.restoreDraft(rows[row]);
      }
    }
  }

  /// Fence a new business command before sending any bytes. An interrupted or
  /// unknown result stays recoverable but cannot create twice without proof.
  /// Replay-aware callers may supply their command-specific rejection evidence;
  /// omitted callbacks keep the original editable-validation contract.
  Future<R> runFormDraftSubmission<R>(
    Future<R> Function() send, {
    bool Function(ApiException error)? isDefiniteRejection,
  }) async {
    if (!formDraftEnabled || _draftScope == null) return send();
    if (_draftFinished) throw StateError('本次单据已经提交，请返回任务中心');
    if (_draftSubmissionPending && !formDraftCanReplaySubmission) {
      throw StateError('上次提交结果待确认，请先核对任务中心，不能重复创建');
    }
    final wasPending = _draftSubmissionPending;
    _draftSubmissionPending = true;
    try {
      await saveFormDraftNow();
      if (_draftDisposed ||
          !mounted ||
          _draftFinished ||
          _draftIdentityChanged ||
          _draftStore?.ownerKey != _draftOwnerKey ||
          ref.read(authenticatedScopeProvider) != _draftScope ||
          ref.read(apiBaseUrlProvider) != _draftServer) {
        throw StateError('页面或登录身份已变化，本次未提交新单据');
      }
    } catch (_) {
      _draftSubmissionPending = wasPending;
      rethrow;
    }
    try {
      return await send();
    } on ApiException catch (error) {
      // Structured validation/constraint conflicts are transaction rejections,
      // e.g. a duplicate master-data code. They must remain editable.
      final rejected =
          isDefiniteRejection?.call(error) ??
          (error.httpStatus == 400 ||
              error.httpStatus == 422 ||
              (error.httpStatus == 409 && error.code == 'CONFLICT'));
      if (rejected) {
        _draftSubmissionPending = false;
        // The server's definite rejection is what the user must see. A failing
        // local checkpoint here must not replace it with a generic local error
        // (2026-10-05: a 409 from 批量登记实际到货 surfaced only as
        // 「批量登记失败」). The durable pre-submit marker stays on disk until
        // the next successful autosave, which is the safe direction.
        try {
          await saveFormDraftNow();
        } catch (checkpointError) {
          if (!_draftDisposed) {
            _draftError = checkpointError;
            _draftStatus.value = '服务端未接受本次提交，内容仍在页面；本机草稿暂未保存成功，请勿关闭页面。';
          }
        }
      } else if (!formDraftCanReplaySubmission && mounted) {
        super.setState(() => _draftSubmissionBlocked = true);
      }
      rethrow;
    } catch (_) {
      if (!formDraftCanReplaySubmission && mounted) {
        super.setState(() => _draftSubmissionBlocked = true);
      }
      rethrow;
    }
  }

  Future<void> completeFormDraft() async {
    if (!formDraftEnabled || _draftFinished) return;
    _draftFinished = true;
    _draftExitAllowed = true;
    // Fence writes before deleting, so a late autosave cannot resurrect a draft.
    try {
      await _draftWriting;
    } catch (_) {}
    if (_draftIdentityChanged ||
        _draftStore?.ownerKey != _draftOwnerKey ||
        (mounted &&
            _draftScope != null &&
            (ref.read(authenticatedScopeProvider) != _draftScope ||
                ref.read(apiBaseUrlProvider) != _draftServer))) {
      return;
    }
    if (_draftRevision != null) {
      try {
        await _draftStore?.complete(_draftId, expectedRevision: _draftRevision);
      } catch (_) {
        // Business success must never enter the caller's create-failure/retry path.
        // The pre-write marker remains on disk and blocks unsafe replay.
        if (!_draftDisposed) {
          _draftStatus.value = '单据已保存，本机草稿清理失败；请以任务中心的单据记录为准。';
        }
        return;
      }
    }
    if (!_draftDisposed) _draftStatus.value = '';
  }

  Future<bool> _confirmDraftExit() {
    if (_draftIdentityChanged) return Future.value(true);
    if (formDraftHasConfirmedExternalRecovery) {
      // A verified checkpoint for this exact command is already durable.
      // Stop the old editor's autosaves without deleting that checkpoint.
      _draftFinished = true;
      _draftExitAllowed = true;
      return Future.value(true);
    }
    // The business operation already completed; its own navigation commonly
    // runs before the page's finally block clears _saving. Do not veto it.
    if (_draftFinished) return Future.value(true);
    if (formDraftBusy) return Future.value(false);
    if (_draftExitAllowed || !_draftReady || _draftRestoreBlocked) {
      return Future.value(true);
    }
    if (_captureDraftJson() == _draftBaseline && _draftRevision == null) {
      return Future.value(true);
    }
    return _draftExitPrompt ??= _showDraftExitPrompt().whenComplete(() {
      _draftExitPrompt = null;
    });
  }

  Future<bool> confirmFormDraftExit() => _confirmDraftExit();

  Future<bool> _showDraftExitPrompt() async {
    final unknown = formDraftHasUnknownSubmission;
    final decision = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: Text(unknown ? '提交结果待核对' : '是否保存为草稿？'),
        content: Text(
          unknown
              ? '原提交结果尚未确认，不能丢弃这份记录。保存原提交后可离开，之后仍按原标识核对结果。'
              : '你已填写内容。保存草稿后，可在对应任务中心继续填写。草稿保存在当前设备和浏览器。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, 'stay'),
            child: Text(unknown ? '继续核对' : '继续填写'),
          ),
          if (!unknown)
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, 'discard'),
              child: const Text('不保存'),
            ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, 'save'),
            child: Text(unknown ? '保存原提交后离开' : '保存草稿'),
          ),
        ],
      ),
    );
    if (!mounted || decision == null || decision == 'stay') return false;
    if (_draftFinished || _draftIdentityChanged) return true;
    if (formDraftBusy) return false;
    if (decision != 'save' && decision != 'discard') return false;
    try {
      if (decision == 'save') {
        await saveFormDraftNow();
        if (formDraftBusy) return false;
        _draftExitAllowed = true;
      } else {
        // Recheck after the dialog: an outcome may have become unknown while
        // it was open, or a stale/programmatic dialog result may say discard.
        if (formDraftHasUnknownSubmission) return false;
        // Discard is different from successful business completion.
        try {
          await _draftWriting;
        } catch (_) {}
        if (formDraftBusy || formDraftHasUnknownSubmission) return false;
        if (_draftIdentityChanged || _draftStore?.ownerKey != _draftOwnerKey) {
          return true;
        }
        _draftFinished = true;
        try {
          if (_draftRevision != null) {
            try {
              await _draftStore!.delete(
                _draftId,
                expectedRevision: _draftRevision,
              );
            } on FormDraftConflict {
              // Discard this editor's stale changes, never delete another tab's work.
            }
          }
          _draftExitAllowed = true;
        } catch (_) {
          _draftFinished = false;
          rethrow;
        }
      }
      return true;
    } catch (error) {
      _draftError = error;
      _draftStatus.value = '草稿尚未保存，请保留页面重试：$error';
      return false;
    }
  }

  Widget withFormDraft(Widget child) {
    if (!formDraftEnabled) return child;
    if (_draftIdentityChanged) {
      return const Material(
        child: Center(child: Text('登录身份或服务器已变化，请重新进入页面。原草稿保留在原账号下。')),
      );
    }
    // GoRouter onExit is the authoritative guard (covers go/replace and browser
    // back). The wrapper also protects editors hosted by a plain Navigator.
    var hasRouter = formDraftUsesRouterGuard;
    try {
      GoRouter.of(context);
    } catch (_) {
      hasRouter = false;
    }
    return PopScope(
      canPop: hasRouter || _draftExitAllowed || !_draftReady,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop || hasRouter) return;
        if (await _confirmDraftExit() && mounted) {
          _draftExitAllowed = true;
          super.setState(() {});
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) Navigator.of(context).pop(result);
          });
        }
      },
      child: ValueListenableBuilder<String>(
        valueListenable: _draftStatus,
        builder: (context, status, child) => UtenDraftStatusLayout(
          status: status,
          isError: _draftError != null,
          onRetry:
              _draftError == null ||
                  formDraftBusy ||
                  _draftRestoreBlocked ||
                  _draftSubmissionBlocked ||
                  _draftFinished
              ? null
              : () async {
                  try {
                    await saveFormDraftNow();
                  } catch (error) {
                    if (!_draftDisposed) {
                      _draftError = error;
                      _draftStatus.value = '草稿尚未保存，请保留页面重试：$error';
                    }
                  }
                },
          child: child!,
        ),
        child: Stack(
          children: [
            AbsorbPointer(
              absorbing:
                  _draftRestoring ||
                  _draftIdentityChanged ||
                  _draftRestoreBlocked ||
                  _draftSubmissionBlocked,
              child: child,
            ),
            if (_draftRestoring)
              const Positioned.fill(
                child: Material(
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(height: 12),
                        Text('正在准备草稿保护…'),
                      ],
                    ),
                  ),
                ),
              ),
            if (!_draftRestoring &&
                (_draftRestoreBlocked || _draftSubmissionBlocked))
              Center(
                child: Material(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _draftSubmissionBlocked
                              ? '上次提交的结果尚未确认。输入已保留，请先到任务中心核对是否已经生成单据。'
                              : '这份草稿暂时无法恢复，原草稿已保留。',
                        ),
                        const SizedBox(height: 12),
                        if (formDraftSubmissionRecoveryAction
                            case final recovery?) ...[
                          recovery,
                          const SizedBox(height: 12),
                        ],
                        if (_canReloadDraftSource) ...[
                          FilledButton(
                            onPressed: _reloadDraftSource,
                            child: const Text('保留本机草稿，加载最新单据'),
                          ),
                          const SizedBox(height: 12),
                        ],
                        FilledButton(
                          onPressed: () =>
                              GoRouter.of(context).go('/dashboard'),
                          child: const Text('返回工作台'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _draftDisposed = true;
    _removeDraftLifecycle?.call();
    WidgetsBinding.instance.removeObserver(_draftLifecycleObserver);
    FormDraftNavigation.unregister(this);
    _draftScopeSubscription?.close();
    for (final item in _draftListeners) {
      // Listener removal is safe even when the owning page disposed its controls.
      item.removeListener(markFormDraftChanged);
    }
    _draftServerSubscription?.close();
    _draftListeners.clear();
    _draftStatus.dispose();
    super.dispose();
  }
}

class _FormDraftLifecycleObserver extends WidgetsBindingObserver {
  _FormDraftLifecycleObserver(this.flush);
  final VoidCallback flush;
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) flush();
  }
}
