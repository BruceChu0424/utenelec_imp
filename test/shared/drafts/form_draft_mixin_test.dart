import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:uten_imp/core/performance/responsive_data_codec.dart';
import 'package:uten_imp/core/performance/ui_work_budget.dart';
import 'package:uten_imp/shared/attachments/pending_attachment_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/interceptors/remote_mfa_interceptor.dart';
import 'package:uten_imp/core/network/remote_mfa_coordinator.dart';
import 'package:uten_imp/features/auth/widgets/remote_mfa_prompt.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft_mixin.dart';
import 'package:uten_imp/shared/drafts/form_draft_navigation.dart';
import 'package:uten_imp/shared/drafts/form_draft_storage_api.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/sensitive_read_boundary_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_models.dart';

final _testScope = StateProvider<AuthenticatedScope?>(
  (ref) => const AuthenticatedScope(userId: 'user-1'),
);
final _testServer = StateProvider<String>((ref) => 'https://test.example/api');
final _testPermissions = StateProvider<Set<String>>((ref) => {'test:create'});

class _DatasetSession extends SessionNotifier {
  _DatasetSession(this.initial);
  final SessionState initial;
  @override
  SessionState build() => initial;
  void replace(SessionState next) => state = next;
}

SessionState _datasetImpersonation({
  String? targetDataset = 'bd6a3b4a-474e-48d6-8c42-c8ed99030bcd',
  String? actorDataset = 'bd6a3b4a-474e-48d6-8c42-c8ed99030bcd',
  String actorName = '管理员',
}) => SessionState(
  status: AuthStatus.authenticated,
  user: AppUser(
    id: 'user-1',
    code: 'TARGET',
    name: '员工',
    businessDatasetId: targetDataset,
  ),
  actor: AppUser(
    id: 'admin',
    code: 'ADMIN',
    name: actorName,
    businessDatasetId: actorDataset,
  ),
);

class MemoryDraftStorage implements FormDraftStorage {
  final records = <String, String>{};
  bool failWrites = false;
  Future<void>? readGate;
  Future<void>? writeGate;
  @override
  Future<Map<String, String>> readAll(String prefix) async {
    await readGate;
    return {
      for (final entry in records.entries)
        if (entry.key.startsWith(prefix)) entry.key: entry.value,
    };
  }

  @override
  Future<String?> read(String key) async => records[key];
  @override
  Future<void> write(String key, String value) async {
    records[key] = value;
  }

  @override
  Future<void> remove(String key) async {
    records.remove(key);
  }

  @override
  Future<bool> compareAndSet(
    String key, {
    required String? expectedValue,
    required String? value,
  }) async {
    await writeGate;
    if (failWrites) throw StateError('storage full');
    if (records[key] != expectedValue) return false;
    if (value == null) {
      records.remove(key);
    } else {
      records[key] = value;
    }
    return true;
  }
}

class _RemoteMfaDraftAdapter implements HttpClientAdapter {
  int writeAttempts = 0, acceptedWrites = 0, verifications = 0;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.path == '/auth/mfa/verify') {
      verifications++;
      expect(options.data, {'otpCode': '123456'});
      return _json(200, {'verifiedUntil': '2026-10-17T23:00:00Z'});
    }
    expect(options.path, '/sales/new');
    writeAttempts++;
    if (writeAttempts == 1) {
      return _json(403, {'code': 'MFA_REQUIRED', 'message': '需要验证'});
    }
    acceptedWrites++;
    return _json(200, {'saved': true});
  }

  ResponseBody _json(int status, Map<String, dynamic> body) =>
      ResponseBody.fromString(
        jsonEncode(body),
        status,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
  @override
  void close({bool force = false}) {}
}

class _DraftGridRow extends EditableGridRow {}

class TestEditor extends ConsumerStatefulWidget {
  const TestEditor({
    super.key,
    this.withGrid = false,
    this.withAttachment = false,
    this.autoInitialize = true,
    this.trackPermissionChanges = true,
    this.failRestore = false,
    this.failReload = false,
    this.reloadGate,
    this.onSubmit,
  });
  final bool withGrid;
  final bool withAttachment;
  final bool autoInitialize;
  final bool trackPermissionChanges;
  final bool failRestore;
  final bool failReload;
  final Future<void>? reloadGate;
  final Future<void> Function(TestEditorState)? onSubmit;
  @override
  ConsumerState<TestEditor> createState() => TestEditorState();
}

class TestEditorState extends ConsumerState<TestEditor>
    with FormDraftMixin<TestEditor> {
  final text = TextEditingController();
  final grid = UtenEditableGridController<_DraftGridRow>();
  final attachments = PendingAttachmentController();
  String choice = 'default';
  bool busy = false;
  bool canReplay = false;
  int captures = 0;
  @override
  bool get formDraftTracksPermissionChanges => widget.trackPermissionChanges;
  @override
  bool get formDraftCanReplaySubmission => canReplay;
  @override
  bool get formDraftBusy => busy;
  @override
  FormDraftSpec get formDraftSpec => const FormDraftSpec(
    title: '测试单据',
    module: BadgeModule.sales,
    route: '/new',
    permission: 'test:create',
  );
  @override
  Iterable<Listenable> get formDraftListenables => [
    text,
    if (widget.withGrid) grid,
    if (widget.withAttachment) attachments,
  ];
  @override
  Map<String, dynamic> captureFormDraft() {
    captures++;
    return {
      'text': text.text,
      'choice': choice,
      if (widget.withGrid) 'rowCount': grid.rows.length,
      if (widget.withAttachment) 'attachments': attachments.exportDraft(),
    };
  }

  @override
  Future<void> restoreFormDraft(Map<String, dynamic> data) async {
    text.text = data['text'] as String;
    if (widget.failRestore) throw StateError('服务器来源已变化');
    choice = data['choice'] as String;
    if (widget.withGrid) {
      grid.replaceAll(
        List.generate(data['rowCount'] as int, (_) => _DraftGridRow()),
      );
    }
  }

  @override
  Future<void> Function()? get formDraftReloadSource => () async {
    text.text = '服务器最新单据';
    choice = 'default';
    await widget.reloadGate;
    if (widget.failReload) throw StateError('服务器不可用');
  };

  @override
  void initState() {
    super.initState();
    if (widget.withGrid) grid.addRow(_DraftGridRow());
    if (widget.autoInitialize) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => initializeFormDraft(),
      );
    }
  }

  @override
  void dispose() {
    text.dispose();
    grid.dispose();
    attachments.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => withFormDraft(
    Scaffold(
      body: Column(
        children: [
          TextField(key: const Key('input'), controller: text),
          if (widget.onSubmit != null)
            TextButton(
              key: const Key('send-draft'),
              onPressed: () => widget.onSubmit!(this),
              child: const Text('发送本次单据'),
            ),
          TextButton(
            onPressed: () => setState(() => choice = 'chosen'),
            child: Text(choice),
          ),
          TextButton(
            onPressed: () => context.go('/home'),
            child: const Text('离开'),
          ),
          TextButton(
            onPressed: () async {
              await completeFormDraft();
              if (context.mounted) context.go('/home');
            },
            child: const Text('提交成功'),
          ),
        ],
      ),
    ),
  );
}

Future<({GoRouter router, ProviderContainer container})> pumpEditor(
  WidgetTester tester,
  MemoryDraftStorage storage, {
  String initial = '/new',
  bool settle = true,
  bool withGrid = false,
  bool withAttachment = false,
  bool autoInitialize = true,
  bool trackPermissionChanges = true,
  bool failRestore = false,
  bool failReload = false,
  Future<void>? reloadGate,
  Future<void> Function(TestEditorState)? onSubmit,
  AuthenticatedScope? initialScope,
  SessionState? initialSession,
}) async {
  final container = ProviderContainer(
    overrides: [
      if (initialScope != null) _testScope.overrideWith((ref) => initialScope),
      if (initialSession != null)
        sessionProvider.overrideWith(() => _DatasetSession(initialSession))
      else
        authenticatedScopeProvider.overrideWith((ref) => ref.watch(_testScope)),
      currentPermissionsProvider.overrideWith(
        (ref) => ref.watch(_testPermissions),
      ),
      apiBaseUrlProvider.overrideWith((ref) => ref.watch(_testServer)),
      formDraftStorageProvider.overrideWithValue(storage),
    ],
  );
  final router = GoRouter(
    initialLocation: initial,
    routes: [
      DraftAwareGoRoute(
        path: '/new',
        builder: (_, state) => TestEditor(
          key: state.pageKey,
          withGrid: withGrid,
          withAttachment: withAttachment,
          autoInitialize: autoInitialize,
          trackPermissionChanges: trackPermissionChanges,
          failRestore: failRestore,
          failReload: failReload,
          reloadGate: reloadGate,
          onSubmit: onSubmit,
        ),
      ),
      DraftAwareGoRoute(
        path: '/home',
        builder: (_, _) => const Scaffold(body: Text('任务中心')),
      ),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
  return (router: router, container: container);
}

void main() {
  testWidgets('grid presentation changes never capture the business draft', (
    tester,
  ) async {
    final storage = MemoryDraftStorage();
    final env = await pumpEditor(tester, storage, withGrid: true);
    final editor = tester.state<TestEditorState>(find.byType(TestEditor));
    final baseline = editor.captures;
    final row = editor.grid.rows.single;
    editor.grid.toggleSelect(row);
    editor.grid.copySelected((_) => _DraftGridRow());
    editor.grid.clearSelection();
    editor.grid.selectAll();
    editor.grid.clearSelection();
    await tester.pumpAndSettle();
    expect(editor.captures, baseline);
    expect(env.container.read(formDraftsProvider), isEmpty);

    editor.grid.addRow(_DraftGridRow());
    expect(editor.captures, greaterThan(baseline));
    await editor.saveFormDraftNow();
    expect(env.container.read(formDraftsProvider).single.data['rowCount'], 2);
    final beforeMetadata = editor.captures;
    row.platformFields.setValue(
      const PlatformColumnDefinition(id: 'field', scope: 'test', name: 'Code'),
      '000017',
    );
    expect(editor.captures, greaterThan(beforeMetadata));
    await editor.saveFormDraftNow();
    expect(
      env.container.read(formDraftsProvider).single.data['_platformGridDrafts'],
      isNotEmpty,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    env.router.dispose();
    env.container.dispose();
  });

  testWidgets(
    'live capability editor retains owner input through permission ABA and repeated initialization guards',
    (tester) async {
      final storage = MemoryDraftStorage();
      final env = await pumpEditor(
        tester,
        storage,
        autoInitialize: false,
        trackPermissionChanges: false,
      );
      final editor = tester.state<TestEditorState>(find.byType(TestEditor));
      editor.startFormDraftIdentityGuard();
      env.container.read(_testPermissions.notifier).state = {};
      env.container.read(sensitiveReadBoundaryProvider);
      env.container.read(_testPermissions.notifier).state = {'test:create'};
      env.container.read(sensitiveReadBoundaryProvider);
      // Automatic source capture and initialization may start the guard again.
      editor.startFormDraftIdentityGuard();
      await editor.initializeFormDraft();
      await tester.pumpAndSettle();
      editor.text.text = 'original owner input';
      await editor.saveFormDraftNow();
      final saved = Map<String, String>.of(storage.records);
      env.container.read(_testPermissions.notifier).state = {};
      env.container.read(sensitiveReadBoundaryProvider);
      editor.startFormDraftIdentityGuard();
      await tester.pumpAndSettle();
      expect(editor.formDraftIdentityIsCurrent, isTrue);
      expect(editor.text.text, 'original owner input');
      final savedEnvelope =
          jsonDecode(saved.values.single) as Map<String, Object?>;
      final savedData = savedEnvelope['data']! as Map<String, Object?>;
      expect(savedData['text'], 'original owner input');
      expect(storage.records, saved);
      // Revoking visibility may hide the task-center entry; owner evidence stays.
      expect(env.container.read(formDraftsProvider), isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      env.router.dispose();
      env.container.dispose();
    },
  );
  for (final change in ['account', 'server', 'session epoch', 'dataset']) {
    testWidgets(
      'live capability editor keeps sticky $change ABA identity fence',
      (tester) async {
        final storage = MemoryDraftStorage();
        final env = await pumpEditor(
          tester,
          storage,
          trackPermissionChanges: false,
        );
        final editor = tester.state<TestEditorState>(find.byType(TestEditor));
        editor.text.text = 'retained only for the original owner';
        await editor.saveFormDraftNow();
        final before = Map<String, String>.of(storage.records);
        final owner = env.container.read(_testScope);
        final server = env.container.read(_testServer);
        if (change == 'account') {
          env.container.read(_testScope.notifier).state =
              const AuthenticatedScope(userId: 'other');
        } else if (change == 'session epoch' || change == 'dataset') {
          env.container.read(_testScope.notifier).state = AuthenticatedScope(
            userId: owner!.userId,
            epoch: owner.epoch + (change == 'session epoch' ? 1 : 0),
            businessDatasetId: change == 'dataset'
                ? 'bd6a3b4a-474e-48d6-8c42-c8ed99030bcd'
                : owner.businessDatasetId,
          );
        } else {
          env.container.read(_testServer.notifier).state =
              'https://other.example/api';
        }
        await tester.pump();
        if (change != 'server') {
          env.container.read(_testScope.notifier).state = owner;
        } else {
          env.container.read(_testServer.notifier).state = server;
        }
        await tester.pumpAndSettle();
        editor.startFormDraftIdentityGuard();
        expect(editor.formDraftIdentityIsCurrent, isFalse);
        await expectLater(editor.saveFormDraftNow(), throwsStateError);
        var sends = 0;
        await expectLater(
          editor.runFormDraftSubmission(() async => sends++),
          throwsStateError,
        );
        expect(sends, 0);
        expect(storage.records, before);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        env.router.dispose();
        env.container.dispose();
      },
    );
  }
  testWidgets('a replacement dataset blocks the old editor before any create', (
    tester,
  ) async {
    final storage = MemoryDraftStorage();
    final env = await pumpEditor(
      tester,
      storage,
      initialScope: const AuthenticatedScope(
        userId: 'user-1',
        businessDatasetId: 'bd6a3b4a-474e-48d6-8c42-c8ed99030bcd',
      ),
    );
    final editor = tester.state<TestEditorState>(find.byType(TestEditor));
    editor.text.text = '旧数据集的未完成输入';
    await editor.saveFormDraftNow();
    final before = Map<String, String>.of(storage.records);
    env.container.read(_testScope.notifier).state = const AuthenticatedScope(
      userId: 'user-1',
      businessDatasetId: 'ae4221bb-e660-4b30-a745-44bc62c4f14c',
    );
    await tester.pumpAndSettle();
    expect(editor.formDraftIdentityIsCurrent, isFalse);
    var sends = 0;
    await expectLater(
      editor.runFormDraftSubmission(() async => sends++),
      throwsStateError,
    );
    expect(sends, 0);
    expect(storage.records, before);
    expect(env.container.read(formDraftsProvider), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    env.router.dispose();
    env.container.dispose();
  });
  for (final mismatch in [
    'actor replacement',
    'actor missing',
    'target missing',
  ]) {
    testWidgets(
      'impersonation $mismatch fences the old editor and its ABA return',
      (tester) async {
        final storage = MemoryDraftStorage();
        final initial = _datasetImpersonation();
        final env = await pumpEditor(tester, storage, initialSession: initial);
        final editor = tester.state<TestEditorState>(find.byType(TestEditor));
        editor.text.text = '原数据集的未完成代操作输入';
        await editor.saveFormDraftNow();
        final before = Map<String, String>.of(storage.records);
        final owner =
            env.container.read(sessionProvider.notifier) as _DatasetSession;
        final changed = _datasetImpersonation(
          targetDataset: mismatch == 'target missing'
              ? null
              : initial.user!.businessDatasetId,
          actorDataset: mismatch == 'actor replacement'
              ? 'ae4221bb-e660-4b30-a745-44bc62c4f14c'
              : mismatch == 'actor missing'
              ? null
              : initial.actor!.businessDatasetId,
        );
        owner.replace(changed);
        await tester.pumpAndSettle();
        expect(env.container.read(authenticatedScopeProvider), isNull);
        expect(changed.isSameIdentity(initial), isFalse);
        expect(editor.formDraftIdentityIsCurrent, isFalse);
        var sends = 0;
        await expectLater(
          editor.runFormDraftSubmission(() async => sends++),
          throwsStateError,
        );
        owner.replace(initial);
        await tester.pumpAndSettle();
        expect(env.container.read(authenticatedScopeProvider), isNotNull);
        expect(editor.formDraftIdentityIsCurrent, isFalse);
        await expectLater(
          editor.runFormDraftSubmission(() async => sends++),
          throwsStateError,
        );
        expect(sends, 0);
        expect(storage.records, before);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        env.router.dispose();
        env.container.dispose();
      },
    );
  }
  testWidgets(
    'same-dataset actor refresh leaves the editor able to checkpoint and submit once',
    (tester) async {
      final storage = MemoryDraftStorage();
      final initial = _datasetImpersonation();
      final env = await pumpEditor(tester, storage, initialSession: initial);
      final editor = tester.state<TestEditorState>(find.byType(TestEditor));
      editor.text.text = '同数据集可继续提交';
      await editor.saveFormDraftNow();
      final beforeScope = env.container.read(authenticatedScopeProvider);
      var scopeNotifications = 0;
      env.container.listen(
        authenticatedScopeProvider,
        (_, _) => scopeNotifications++,
      );
      (env.container.read(sessionProvider.notifier) as _DatasetSession).replace(
        _datasetImpersonation(actorName: '管理员最新姓名'),
      );
      await tester.pumpAndSettle();
      expect(
        identical(env.container.read(authenticatedScopeProvider), beforeScope),
        isTrue,
      );
      expect(scopeNotifications, 0);
      expect(editor.formDraftIdentityIsCurrent, isTrue);
      var sends = 0;
      await editor.runFormDraftSubmission(() async {
        sends++;
        expect(
          env.container.read(formDraftsProvider).single.hasUnknownSubmission,
          isTrue,
        );
      });
      expect(sends, 1);
      await editor.completeFormDraft();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      env.router.dispose();
      env.container.dispose();
    },
  );
  testWidgets(
    'default early source guard preserves permission ABA before draft initialization',
    (tester) async {
      final env = await pumpEditor(
        tester,
        MemoryDraftStorage(),
        autoInitialize: false,
      );
      final editor = tester.state<TestEditorState>(find.byType(TestEditor));
      final source = Completer<void>();
      final loading = () async {
        editor.startFormDraftIdentityGuard();
        await source.future;
        await editor.initializeFormDraft();
      }();
      env.container.read(_testPermissions.notifier).state = {};
      env.container.read(sensitiveReadBoundaryProvider);
      env.container.read(_testPermissions.notifier).state = {'test:create'};
      env.container.read(sensitiveReadBoundaryProvider);
      source.complete();
      await loading;
      expect(editor.formDraftIdentityIsCurrent, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      env.router.dispose();
      env.container.dispose();
    },
  );

  testWidgets(
    'permission ABA during attachment restoration cannot revive the old editor',
    (tester) async {
      final env = await pumpEditor(
        tester,
        MemoryDraftStorage(),
        withAttachment: true,
      );
      final editor = tester.state<TestEditorState>(find.byType(TestEditor));
      editor.attachments.add(
        PlatformFile(
          name: 'current.pdf',
          size: 1,
          bytes: Uint8List.fromList([9]),
        ),
      );
      await tester.pumpAndSettle();
      Object? failure;
      var finished = false;
      final restore = editor.attachments
          .restoreDraftResponsive({
            'items': [
              {
                'name': 'old.pdf',
                'contentType': 'application/pdf',
                'bytes': base64Encode(Uint8List(200000)),
              },
            ],
          }, isCurrent: () => editor.formDraftIdentityIsCurrent)
          .then<void>(
            (_) => finished = true,
            onError: (Object error) {
              failure = error;
              finished = true;
            },
          );
      env.container.read(_testPermissions.notifier).state = {};
      env.container.read(sensitiveReadBoundaryProvider);
      env.container.read(_testPermissions.notifier).state = {'test:create'};
      env.container.read(sensitiveReadBoundaryProvider);
      expect(editor.formDraftIdentityIsCurrent, isFalse);
      for (var frame = 0; frame < 100 && !finished; frame++) {
        await tester.pump(const Duration(milliseconds: 10));
        if (!finished) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)),
          );
        }
      }
      expect(finished, isTrue);
      await restore;
      expect(failure, isA<UiWorkCancelled>());
      expect(editor.attachments.items.single.name, 'current.pdf');
      expect(editor.attachments.items.single.bytes, [9]);
      await tester.pumpWidget(const SizedBox.shrink());
      env.router.dispose();
      env.container.dispose();
    },
  );

  testWidgets(
    'draft capture owns incomplete fields and deferred attachment bytes before async persistence',
    (tester) async {
      final storage = MemoryDraftStorage();
      final env = await pumpEditor(tester, storage, withAttachment: true);
      final editor = tester.state<TestEditorState>(find.byType(TestEditor));
      final source = Uint8List.fromList(List.generate(200000, (i) => i % 251));
      editor.text.text = '0.';
      editor.attachments.add(
        PlatformFile(name: 'original.pdf', size: source.length, bytes: source),
      );
      final snapshot = editor.captureFormDraftSnapshot();
      expect(
        (((snapshot['attachments'] as Map)['items'] as List).single
            as Map)['bytes'],
        isA<DraftByteValue>(),
      );
      source[0] = 255;
      var finished = false;
      final writing = editor.saveFormDraftNow().whenComplete(
        () => finished = true,
      );
      // Advance both Flutter's fake timers and native compute messages. Awaiting
      // the fake-zone serial writer from runAsync alone cannot drain its timers.
      for (var frame = 0; frame < 100 && !finished; frame++) {
        await tester.pump(const Duration(milliseconds: 10));
        if (!finished) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)),
          );
        }
      }
      expect(finished, isTrue);
      await writing;
      await tester.pumpAndSettle();
      final data = env.container.read(formDraftsProvider).single.data;
      expect(data['text'], '0.');
      final bytes = base64Decode(
        ((((data['attachments'] as Map)['items'] as List).single
                as Map)['bytes'])
            as String,
      );
      expect(bytes.length, 200000);
      expect(bytes.first, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      env.router.dispose();
      env.container.dispose();
    },
  );

  testWidgets(
    'blocked restoration excludes an already focused keyboard editor',
    (tester) async {
      final env = await pumpEditor(tester, MemoryDraftStorage());
      final editor = tester.state<TestEditorState>(find.byType(TestEditor));
      await tester.enterText(find.byKey(const Key('input')), '原始未完成输入-');
      await tester.pumpAndSettle();
      editor.holdFormDraftForSourceReload(StateError('source changed'));
      await tester.pumpAndSettle();
      final input = tester.widget<EditableText>(find.byType(EditableText));
      expect(input.focusNode.hasFocus, isFalse);
      expect(input.focusNode.canRequestFocus, isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      expect(editor.text.text, '原始未完成输入-');
      await tester.pumpWidget(const SizedBox.shrink());
      env.router.dispose();
      env.container.dispose();
    },
  );

  testWidgets(
    'MFA admission preserves an editable form and only a second user click sends again',
    (tester) async {
      final adapter = _RemoteMfaDraftAdapter();
      final coordinator = RemoteMfaCoordinator();
      final dio = Dio(BaseOptions(baseUrl: 'https://test.example/api'))
        ..httpClientAdapter = adapter;
      dio.interceptors.add(RemoteMfaInterceptor(coordinator: coordinator));
      final api = ApiClient(dio);
      ApiException? refusal;
      final env = await pumpEditor(
        tester,
        MemoryDraftStorage(),
        onSubmit: (editor) async {
          try {
            await editor.runFormDraftSubmission(
              () => api.post('/sales/new', body: {'text': editor.text.text}),
              isDefiniteRejection: (_) => false,
            );
            await editor.completeFormDraft();
          } on ApiException catch (error) {
            refusal = error;
          }
        },
      );
      final unregister = coordinator.register(() async {
        final accepted = await showRemoteMfaCodeDialog(
          tester.element(find.byType(TestEditor)),
          verify: (code) async {
            await api.post('/auth/mfa/verify', body: {'otpCode': code});
          },
          isCurrent: () => true,
        );
        return accepted == true ? '验证完成，请人工继续' : null;
      });
      addTearDown(unregister);
      await tester.enterText(find.byKey(const Key('input')), '保留的原始编辑');
      await tester.tap(find.byKey(const Key('send-draft')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('remote-mfa-dialog')), findsOneWidget);
      expect(adapter.writeAttempts, 1);
      expect(adapter.acceptedWrites, 0);
      await tester.enterText(
        find.descendant(
          of: find.byKey(const Key('remote-mfa-code')),
          matching: find.byType(TextField),
        ),
        '123456',
      );
      await tester.tap(find.byKey(const Key('remote-mfa-confirm')));
      await tester.pumpAndSettle();
      expect(adapter.verifications, 1);
      expect(
        adapter.writeAttempts,
        1,
        reason: 'verification must never replay the business request',
      );
      expect(refusal?.code, 'MFA_RETRY_REQUIRED');
      final editor = tester.state<TestEditorState>(find.byType(TestEditor));
      expect(editor.formDraftHasUnknownSubmission, isFalse);
      expect(editor.text.text, '保留的原始编辑');
      expect(
        env.container
            .read(formDraftsProvider)
            .single
            .data['_formDraftSubmissionPending'],
        isNull,
      );
      await tester.enterText(find.byKey(const Key('input')), '用户核查后继续');
      await tester.tap(find.byKey(const Key('send-draft')));
      await tester.pumpAndSettle();
      expect(adapter.writeAttempts, 2);
      expect(adapter.acceptedWrites, 1);
      expect(env.container.read(formDraftsProvider), isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      env.router.dispose();
      env.container.dispose();
    },
  );
  for (final code in [
    'MFA_REQUIRED',
    'MFA_RETRY_REQUIRED',
    'REMOTE_ACCESS_DENIED',
  ]) {
    testWidgets(
      'fresh structured $code admission overrides a conservative business callback',
      (tester) async {
        final env = await pumpEditor(tester, MemoryDraftStorage());
        final editor = tester.state<TestEditorState>(find.byType(TestEditor));
        editor.text.text = '保留编辑';
        await expectLater(
          editor.runFormDraftSubmission(
            () async => throw ApiException(
              code,
              '准入拒绝',
              httpStatus: 403,
              hasResponseCode: true,
            ),
            isDefiniteRejection: (_) => false,
          ),
          throwsA(isA<ApiException>()),
        );
        expect(
          env.container
              .read(formDraftsProvider)
              .single
              .data['_formDraftSubmissionPending'],
          isNull,
        );
        var sends = 0;
        await editor.runFormDraftSubmission(() async => sends++);
        expect(sends, 1);
        await tester.pumpWidget(const SizedBox.shrink());
        env.router.dispose();
        env.container.dispose();
      },
    );
    testWidgets(
      '$code cannot erase an earlier unknown command on an explicit replay',
      (tester) async {
        final env = await pumpEditor(tester, MemoryDraftStorage());
        final editor = tester.state<TestEditorState>(find.byType(TestEditor))
          ..canReplay = true;
        editor.text.text = '前次结果未知';
        await expectLater(
          editor.runFormDraftSubmission(
            () async => throw NetworkTimeoutException(),
          ),
          throwsA(isA<NetworkTimeoutException>()),
        );
        await expectLater(
          editor.runFormDraftSubmission(
            () async => throw ApiException(
              code,
              '本次未开始',
              httpStatus: 403,
              hasResponseCode: true,
            ),
            isDefiniteRejection: (_) => true,
          ),
          throwsA(isA<ApiException>()),
        );
        expect(
          env.container
              .read(formDraftsProvider)
              .single
              .data['_formDraftSubmissionPending'],
          isTrue,
        );
        expect(editor.formDraftHasUnknownSubmission, isTrue);
        await tester.pumpWidget(const SizedBox.shrink());
        env.router.dispose();
        env.container.dispose();
      },
    );
  }
  testWidgets(
    'an unstructured MFA-looking 403 is not proof that the write was refused',
    (tester) async {
      final env = await pumpEditor(tester, MemoryDraftStorage());
      final editor = tester.state<TestEditorState>(find.byType(TestEditor));
      editor.text.text = '不得丢弃';
      await expectLater(
        editor.runFormDraftSubmission(
          () async => throw ApiException(
            'MFA_REQUIRED',
            'unknown origin',
            httpStatus: 403,
          ),
        ),
        throwsA(isA<ApiException>()),
      );
      var sends = 0;
      await expectLater(
        editor.runFormDraftSubmission(() async => sends++),
        throwsStateError,
      );
      expect(sends, 0);
      expect(
        env.container
            .read(formDraftsProvider)
            .single
            .data['_formDraftSubmissionPending'],
        isTrue,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      env.router.dispose();
      env.container.dispose();
    },
  );
  for (final change in ['account', 'server', 'dataset']) {
    testWidgets(
      'ABA $change during initial draft storage read cannot bind old state again',
      (tester) async {
        final gate = Completer<void>();
        final storage = MemoryDraftStorage()..readGate = gate.future;
        final env = await pumpEditor(tester, storage, settle: false);
        await tester.pump();
        final owner = env.container.read(_testScope);
        final server = env.container.read(_testServer);
        if (change == 'account') {
          env.container.read(_testScope.notifier).state =
              const AuthenticatedScope(userId: 'other');
        } else if (change == 'dataset') {
          env.container.read(_testScope.notifier).state = AuthenticatedScope(
            userId: owner!.userId,
            businessDatasetId: 'bd6a3b4a-474e-48d6-8c42-c8ed99030bcd',
          );
        } else {
          env.container.read(_testServer.notifier).state =
              'https://other.example/api';
        }
        await tester.pump();
        if (change != 'server') {
          env.container.read(_testScope.notifier).state = owner;
        } else {
          env.container.read(_testServer.notifier).state = server;
        }
        await tester.pump();
        gate.complete();
        await tester.pumpAndSettle();
        expect(find.textContaining('登录身份或服务器已变化'), findsOneWidget);
        expect(storage.records, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
    testWidgets(
      'ABA $change during partial draft reset cannot rearm the previous page',
      (tester) async {
        final env = await pumpEditor(tester, MemoryDraftStorage());
        final editor = tester.state<TestEditorState>(find.byType(TestEditor));
        editor.text.text = '已完成前段';
        await editor.saveFormDraftNow();
        final gate = Completer<void>();
        final resetting = editor.resetFormDraftAfterSubmission(
          prepare: () => gate.future,
        );
        await tester.pump();
        final owner = env.container.read(_testScope);
        final server = env.container.read(_testServer);
        if (change == 'account') {
          env.container.read(_testScope.notifier).state =
              const AuthenticatedScope(userId: 'other');
        } else if (change == 'dataset') {
          env.container.read(_testScope.notifier).state = AuthenticatedScope(
            userId: owner!.userId,
            businessDatasetId: 'bd6a3b4a-474e-48d6-8c42-c8ed99030bcd',
          );
        } else {
          env.container.read(_testServer.notifier).state =
              'https://other.example/api';
        }
        await tester.pump();
        if (change != 'server') {
          env.container.read(_testScope.notifier).state = owner;
        } else {
          env.container.read(_testServer.notifier).state = server;
        }
        await tester.pump();
        gate.complete();
        await resetting;
        await tester.pumpAndSettle();
        expect(find.textContaining('登录身份或服务器已变化'), findsOneWidget);
        var sends = 0;
        await expectLater(
          editor.runFormDraftSubmission(() async {
            sends++;
          }),
          throwsStateError,
        );
        expect(sends, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'unknown exit keeps evidence and offers only save original or continue',
    (tester) async {
      final storage = MemoryDraftStorage();
      final env = await pumpEditor(tester, storage);
      final editor = tester.state<TestEditorState>(find.byType(TestEditor))
        ..canReplay = true;
      editor.text.text = '原提交';
      await expectLater(
        editor.runFormDraftSubmission(() async {
          throw NetworkTimeoutException();
        }),
        throwsA(isA<NetworkTimeoutException>()),
      );
      env.router.go('/home');
      await tester.pumpAndSettle();
      expect(find.text('不保存'), findsNothing);
      expect(find.text('继续核对'), findsOneWidget);
      await tester.tap(find.text('保存原提交后离开'));
      await tester.pumpAndSettle();
      expect(find.text('任务中心'), findsOneWidget);
      expect(
        env.container
            .read(formDraftsProvider)
            .single
            .data['_formDraftSubmissionPending'],
        isTrue,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      env.router.dispose();
      env.container.dispose();
    },
  );
  for (final late in [false, true]) {
    testWidgets(
      'unknown exit rejects forced discard including late outcome=$late',
      (tester) async {
        final storage = MemoryDraftStorage();
        final env = await pumpEditor(tester, storage);
        final editor = tester.state<TestEditorState>(find.byType(TestEditor))
          ..canReplay = true;
        editor.text.text = '不可丢弃的原提交';
        await editor.saveFormDraftNow();
        Future<void> unknown() async => expectLater(
          editor.runFormDraftSubmission(() async {
            throw NetworkTimeoutException();
          }),
          throwsA(isA<NetworkTimeoutException>()),
        );
        if (!late) await unknown();
        env.router.go('/home');
        await tester.pumpAndSettle();
        if (late) await unknown();
        final dialog = tester.element(find.byType(AlertDialog));
        Navigator.of(dialog).pop('discard');
        await tester.pumpAndSettle();
        expect(find.byType(TestEditor), findsOneWidget);
        expect(
          env.container
              .read(formDraftsProvider)
              .single
              .data['_formDraftSubmissionPending'],
          isTrue,
        );
        expect(storage.records, hasLength(1));
        await tester.pumpWidget(const SizedBox.shrink());
        env.router.dispose();
        env.container.dispose();
      },
    );
  }
  for (final replay in [false, true]) {
    testWidgets(
      'definite server rejection survives a failing local checkpoint replay=$replay',
      (tester) async {
        // 2026-10-05：批量登记实际到货的服务端 409 被本机草稿写入失败顶替成通用失败文案。
        final storage = MemoryDraftStorage();
        final env = await pumpEditor(tester, storage);
        final editor = tester.state<TestEditorState>(find.byType(TestEditor))
          ..canReplay = replay;
        editor.text.text = '原始输入';
        await expectLater(
          editor.runFormDraftSubmission(() async {
            storage.failWrites = true;
            throw ApiException('CONFLICT', '服务端原因', httpStatus: 409);
          }),
          throwsA(
            isA<ApiException>().having((e) => e.message, 'message', '服务端原因'),
          ),
        );
        await tester.pump();
        // 本地检查点失败不再顶替服务端错误（页面自己展示 409 文案）；
        // 预提交标记留在盘上是安全方向，底部状态条已退役。
        storage.failWrites = false;
        var calls = 0;
        await editor.runFormDraftSubmission(() async {
          calls++;
        });
        expect(calls, 1, reason: '明确拒绝后仍可改了再提交');
        await tester.pumpWidget(const SizedBox.shrink());
        env.router.dispose();
        env.container.dispose();
      },
    );
  }
  for (final status in [400, 422]) {
    testWidgets(
      'default $status rejection keeps original editable draft behavior',
      (tester) async {
        final env = await pumpEditor(tester, MemoryDraftStorage());
        final editor = tester.state<TestEditorState>(find.byType(TestEditor));
        editor.text.text = '原始输入';
        await expectLater(
          editor.runFormDraftSubmission(() async {
            throw ApiException('VALIDATION_FAILED', '校验失败', httpStatus: status);
          }),
          throwsA(isA<ApiException>()),
        );
        expect(
          env.container
              .read(formDraftsProvider)
              .single
              .data['_formDraftSubmissionPending'],
          isNull,
        );
        var calls = 0;
        await editor.runFormDraftSubmission(() async {
          calls++;
        });
        expect(calls, 1);
        await tester.pumpWidget(const SizedBox.shrink());
        env.router.dispose();
        env.container.dispose();
      },
    );
    testWidgets('replay caller may retain unknown marker after later $status', (
      tester,
    ) async {
      final env = await pumpEditor(tester, MemoryDraftStorage());
      final editor = tester.state<TestEditorState>(find.byType(TestEditor))
        ..canReplay = true;
      editor.text.text = '冻结的原命令';
      await expectLater(
        editor.runFormDraftSubmission(() async {
          throw NetworkTimeoutException();
        }),
        throwsA(isA<NetworkTimeoutException>()),
      );
      await expectLater(
        editor.runFormDraftSubmission(() async {
          throw ApiException('VALIDATION_FAILED', '校验失败', httpStatus: status);
        }, isDefiniteRejection: (_) => false),
        throwsA(isA<ApiException>()),
      );
      expect(
        env.container
            .read(formDraftsProvider)
            .single
            .data['_formDraftSubmissionPending'],
        isTrue,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      env.router.dispose();
      env.container.dispose();
    });
  }
  testWidgets(
    'source reload preserves failed local draft and starts a new identity',
    (tester) async {
      final storage = MemoryDraftStorage();
      var env = await pumpEditor(tester, storage);
      await tester.enterText(find.byKey(const Key('input')), '原本机填写');
      await tester.pumpAndSettle();
      final oldDraft = env.container.read(formDraftsProvider).single;
      final oldRecords = Map<String, String>.from(storage.records);
      await tester.pumpWidget(const SizedBox());
      env.router.dispose();
      env.container.dispose();
      env = await pumpEditor(
        tester,
        storage,
        initial: oldDraft.resumeLocation,
        failRestore: true,
      );
      expect(find.text('这份草稿暂时无法恢复，原草稿已保留。'), findsOneWidget);
      expect(storage.records, oldRecords);
      await tester.tap(find.text('保留本机草稿，加载最新单据'));
      await tester.pumpAndSettle();
      expect(find.text('这份草稿暂时无法恢复，原草稿已保留。'), findsNothing);
      expect(find.text('服务器最新单据'), findsOneWidget);
      expect(storage.records, oldRecords);
      await tester.enterText(find.byKey(const Key('input')), '基于最新单据继续审核');
      await tester.pumpAndSettle();
      final drafts = env.container.read(formDraftsProvider);
      expect(drafts, hasLength(2));
      expect(
        drafts.singleWhere((draft) => draft.id == oldDraft.id).toJson(),
        oldDraft.toJson(),
      );
      expect(
        drafts.singleWhere((draft) => draft.id != oldDraft.id).data['text'],
        '基于最新单据继续审核',
      );
      await tester.pumpWidget(const SizedBox());
      env.router.dispose();
      env.container.dispose();
    },
  );

  testWidgets(
    'failed reload remains blocked and never checkpoints partial state',
    (tester) async {
      final storage = MemoryDraftStorage();
      var env = await pumpEditor(tester, storage);
      await tester.enterText(find.byKey(const Key('input')), '原本机填写');
      await tester.pumpAndSettle();
      final draft = env.container.read(formDraftsProvider).single;
      final oldRecords = Map<String, String>.from(storage.records);
      await tester.pumpWidget(const SizedBox());
      env.router.dispose();
      env.container.dispose();
      env = await pumpEditor(
        tester,
        storage,
        initial: draft.resumeLocation,
        failRestore: true,
        failReload: true,
      );
      await tester.tap(find.text('保留本机草稿，加载最新单据'));
      await tester.pumpAndSettle();
      expect(find.text('这份草稿暂时无法恢复，原草稿已保留。'), findsOneWidget);
      final editor = tester.state<TestEditorState>(find.byType(TestEditor));
      await expectLater(editor.saveFormDraftNow(), throwsStateError);
      expect(storage.records, oldRecords);
      await tester.pumpWidget(const SizedBox());
      env.router.dispose();
      env.container.dispose();
    },
  );

  testWidgets(
    'identity change during source reload cannot unlock a different account',
    (tester) async {
      final storage = MemoryDraftStorage();
      var env = await pumpEditor(tester, storage);
      await tester.enterText(find.byKey(const Key('input')), '原账号填写');
      await tester.pumpAndSettle();
      final draft = env.container.read(formDraftsProvider).single;
      final oldRecords = Map<String, String>.from(storage.records);
      await tester.pumpWidget(const SizedBox());
      env.router.dispose();
      env.container.dispose();
      final gate = Completer<void>();
      env = await pumpEditor(
        tester,
        storage,
        initial: draft.resumeLocation,
        failRestore: true,
        reloadGate: gate.future,
      );
      await tester.tap(find.text('保留本机草稿，加载最新单据'));
      await tester.pump();
      env.container.read(_testScope.notifier).state = const AuthenticatedScope(
        userId: 'user-2',
      );
      await tester.pump();
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.textContaining('原草稿保留在原账号下'), findsOneWidget);
      expect(env.container.read(formDraftsProvider), isEmpty);
      expect(storage.records, oldRecords);
      await tester.pumpWidget(const SizedBox());
      env.router.dispose();
      env.container.dispose();
    },
  );

  testWidgets(
    'unresolved submission cannot use source reload after restore failure',
    (tester) async {
      final storage = MemoryDraftStorage();
      var env = await pumpEditor(tester, storage);
      await tester.enterText(find.byKey(const Key('input')), '已发出提交');
      await tester.pumpAndSettle();
      final editor = tester.state<TestEditorState>(find.byType(TestEditor));
      await expectLater(
        editor.runFormDraftSubmission(() async => throw StateError('丢失响应')),
        throwsStateError,
      );
      final draft = env.container.read(formDraftsProvider).single;
      expect(draft.data['_formDraftSubmissionPending'], isTrue);
      await tester.pumpWidget(const SizedBox());
      env.router.dispose();
      env.container.dispose();
      env = await pumpEditor(
        tester,
        storage,
        initial: draft.resumeLocation,
        failRestore: true,
      );
      expect(find.text('保留本机草稿，加载最新单据'), findsNothing);
      expect(find.text('这份草稿暂时无法恢复，原草稿已保留。'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      env.router.dispose();
      env.container.dispose();
    },
  );
  testWidgets(
    'metadata-only grid edits survive local draft recovery with their source version',
    (tester) async {
      final storage = MemoryDraftStorage();
      var env = await pumpEditor(tester, storage, withGrid: true);
      final editor = tester.state<TestEditorState>(find.byType(TestEditor));
      final fields = editor.grid.rows.single.platformFields;
      fields.sourceRecordId = 'original-record';
      fields.version = 7;
      fields.setValue(
        const PlatformColumnDefinition(
          id: 'field',
          scope: 'test',
          name: '外部编号',
        ),
        '000017',
      );
      await editor.saveFormDraftNow();
      final draft = env.container.read(formDraftsProvider).single;
      expect(draft.data['_platformGridDrafts'], isNotEmpty);
      await tester.pumpWidget(const SizedBox());
      env.router.dispose();
      env.container.dispose();
      env = await pumpEditor(
        tester,
        storage,
        initial: draft.resumeLocation,
        withGrid: true,
      );
      final restored = tester
          .state<TestEditorState>(find.byType(TestEditor))
          .grid
          .rows
          .single
          .platformFields;
      expect(restored.sourceRecordId, 'original-record');
      expect(restored.version, 7);
      expect(restored.cells.single.value, '000017');
      expect(restored.dirty, isTrue);
      await tester.pumpWidget(const SizedBox());
      env.router.dispose();
      env.container.dispose();
    },
  );
  testWidgets(
    'identity change during pre-submit checkpoint never dispatches under the new user',
    (tester) async {
      final storage = MemoryDraftStorage();
      final env = await pumpEditor(tester, storage);
      await tester.enterText(find.byKey(const Key('input')), '旧账号填写');
      await tester.pumpAndSettle();
      final editor = tester.state<TestEditorState>(find.byType(TestEditor));
      final gate = Completer<void>();
      storage.writeGate = gate.future;
      var creates = 0;
      final submission = editor.runFormDraftSubmission(() async {
        creates++;
      });
      final check = expectLater(submission, throwsStateError);
      await tester.pump();
      env.container.read(_testScope.notifier).state = const AuthenticatedScope(
        userId: 'user-2',
      );
      await tester.pump();
      gate.complete();
      await check;
      await tester.pumpAndSettle();
      expect(creates, 0);
      expect(env.container.read(formDraftsProvider), isEmpty);
      await tester.pumpWidget(const SizedBox());
      env.router.dispose();
      env.container.dispose();
    },
  );
  testWidgets(
    'confirmed save navigation bypasses busy but ordinary busy exit is blocked',
    (tester) async {
      final storage = MemoryDraftStorage();
      final env = await pumpEditor(tester, storage);
      await tester.enterText(find.byKey(const Key('input')), '已保存单据');
      await tester.pumpAndSettle();
      final editor = tester.state<TestEditorState>(find.byType(TestEditor));
      editor.busy = true;
      env.router.go('/home');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('input')), findsOneWidget);
      await tester.tap(find.text('提交成功'));
      await tester.pumpAndSettle();
      expect(find.text('任务中心'), findsOneWidget);
      expect(env.container.read(formDraftsProvider), isEmpty);
      await tester.pumpWidget(const SizedBox());
      env.router.dispose();
      env.container.dispose();
    },
  );
  testWidgets('overlapping autosave and explicit checkpoints use one writer', (
    tester,
  ) async {
    final storage = MemoryDraftStorage();
    final env = await pumpEditor(tester, storage);
    await tester.enterText(find.byKey(const Key('input')), '原草稿');
    await tester.pumpAndSettle();
    final editor = tester.state<TestEditorState>(find.byType(TestEditor));
    final unchangedCheckpoint = editor.saveFormDraftNow();
    editor.text.text = '恢复后补填，已取得单据编号';
    final explicitCheckpoint = editor.saveFormDraftNow();
    await Future.wait([unchangedCheckpoint, explicitCheckpoint]);
    await tester.pumpAndSettle();
    expect(env.container.read(formDraftsProvider), hasLength(1));
    expect(
      env.container.read(formDraftsProvider).single.data['text'],
      '恢复后补填，已取得单据编号',
    );
    await tester.pumpWidget(const SizedBox());
    env.router.dispose();
    env.container.dispose();
  });
  testWidgets(
    'explicit duplicate-code conflict permits correction and a new submit',
    (tester) async {
      final storage = MemoryDraftStorage();
      final env = await pumpEditor(tester, storage);
      await tester.enterText(find.byKey(const Key('input')), 'duplicate-code');
      await tester.pumpAndSettle();
      final editor = tester.state<TestEditorState>(find.byType(TestEditor));
      await expectLater(
        editor.runFormDraftSubmission(() async {
          throw ApiException('CONFLICT', '编号已存在', httpStatus: 409);
        }),
        throwsA(isA<ApiException>()),
      );
      expect(
        env.container
            .read(formDraftsProvider)
            .single
            .data['_formDraftSubmissionPending'],
        isNull,
      );
      await tester.enterText(find.byKey(const Key('input')), 'new-code');
      await tester.pumpAndSettle();
      var submitted = false;
      await editor.runFormDraftSubmission(() async {
        submitted = true;
      });
      expect(submitted, isTrue);
      await tester.pumpWidget(const SizedBox());
      env.router.dispose();
      env.container.dispose();
    },
  );
  testWidgets(
    'identity switch while storage opens keeps the old form blocked',
    (tester) async {
      final gate = Completer<void>();
      final storage = MemoryDraftStorage()..readGate = gate.future;
      final env = await pumpEditor(tester, storage, settle: false);
      expect(find.text('正在准备草稿保护…'), findsOneWidget);
      env.container.read(_testScope.notifier).state = const AuthenticatedScope(
        userId: 'user-2',
      );
      await tester.pump();
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('input')), findsNothing);
      expect(find.textContaining('登录身份或服务器已变化'), findsOneWidget);
      expect(storage.records, isEmpty);
      await tester.pumpWidget(const SizedBox());
      env.router.dispose();
      env.container.dispose();
    },
  );
  for (final changeServer in [false, true]) {
    testWidgets(
      'identity fence hides previous form and prevents cross-scope completion server=$changeServer',
      (tester) async {
        final storage = MemoryDraftStorage();
        final env = await pumpEditor(tester, storage);
        await tester.enterText(find.byKey(const Key('input')), '仅原账号可见');
        await tester.pumpAndSettle();
        final editor = tester.state<TestEditorState>(find.byType(TestEditor));
        final original = Map<String, String>.of(storage.records);
        if (changeServer) {
          env.container.read(_testServer.notifier).state =
              'https://other.example/api';
        } else {
          env.container.read(_testScope.notifier).state =
              const AuthenticatedScope(userId: 'user-2');
        }
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('input')), findsNothing);
        expect(env.container.read(formDraftsProvider), isEmpty);
        await editor.completeFormDraft();
        expect(
          storage.records,
          original,
          reason:
              'A late completion must not write under the replacement identity',
        );
        await tester.pumpWidget(const SizedBox());
        env.router.dispose();
        env.container.dispose();
      },
    );
  }

  testWidgets('two pushed editors of same route prompt only the top instance', (
    tester,
  ) async {
    final storage = MemoryDraftStorage();
    final env = await pumpEditor(tester, storage);
    await tester.enterText(find.byKey(const Key('input')), '第一张');
    await tester.pumpAndSettle();
    env.router.push('/new');
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('input')), '第二张');
    await tester.pumpAndSettle();
    env.router.pop();
    await tester.pumpAndSettle();
    expect(find.text('是否保存为草稿？'), findsOneWidget);
    await tester.tap(find.text('保存草稿'));
    await tester.pumpAndSettle();
    expect(find.text('是否保存为草稿？'), findsNothing);
    expect(
      tester.widget<TextField>(find.byKey(const Key('input'))).controller!.text,
      '第一张',
    );
    expect(env.container.read(formDraftsProvider), hasLength(2));
    await tester.pumpWidget(const SizedBox());
    env.router.dispose();
    env.container.dispose();
  });

  // ADR-151 §1 (2026-10-04 批量登记实际入库「取消勾选再勾回」后提交必失败):
  // 自动保存回到初始值只丢弃干净草稿, 不写 deleted 墓碑; 同一页面之后的保存与提交照常。
  testWidgets(
    'returning to initial values discards cleanly and the same identity saves again',
    (tester) async {
      final storage = MemoryDraftStorage();
      final env = await pumpEditor(tester, storage);
      await tester.enterText(find.byKey(const Key('input')), '改一下');
      await tester.pumpAndSettle();
      final first = env.container.read(formDraftsProvider).single;
      await tester.enterText(find.byKey(const Key('input')), '');
      await tester.pumpAndSettle();
      expect(env.container.read(formDraftsProvider), isEmpty);
      final discarded =
          jsonDecode(storage.records.values.single) as Map<String, dynamic>;
      expect(discarded['id'], first.id);
      expect(discarded['completed'], isNot(true));
      expect(discarded.containsKey('historyAction'), isFalse);
      expect(discarded['lifecycle'], formDraftCleanDiscardedLifecycle);
      expect(discarded.containsKey('data'), isFalse, reason: '不再保留输入事实');
      await tester.enterText(find.byKey(const Key('input')), '再改');
      await tester.pumpAndSettle();
      final again = env.container.read(formDraftsProvider).single;
      expect(again.id, first.id);
      expect(again.data['text'], '再改');
      await tester.pumpWidget(const SizedBox());
      env.router.dispose();
      env.container.dispose();
    },
  );

  testWidgets(
    'submission after returning to initial values checkpoints and sends once',
    (tester) async {
      final storage = MemoryDraftStorage();
      final env = await pumpEditor(tester, storage);
      final editor = tester.state<TestEditorState>(find.byType(TestEditor));
      await tester.tap(find.text('default'));
      await tester.pumpAndSettle();
      editor.choice = 'default';
      editor.markFormDraftChanged();
      await tester.pumpAndSettle();
      expect(env.container.read(formDraftsProvider), isEmpty);
      var sends = 0;
      await editor.runFormDraftSubmission(() async {
        sends++;
        final checkpoint = env.container.read(formDraftsProvider).single;
        expect(checkpoint.data['_formDraftSubmissionPending'], isTrue);
      });
      expect(sends, 1);
      await editor.completeFormDraft();
      expect(
        (jsonDecode(storage.records.values.single)
            as Map<String, dynamic>)['historyAction'],
        'completed',
      );
      await tester.pumpWidget(const SizedBox());
      env.router.dispose();
      env.container.dispose();
    },
  );

  testWidgets(
    'definite rejection back at initial values clears the pending marker before discarding',
    (tester) async {
      final storage = MemoryDraftStorage();
      final env = await pumpEditor(tester, storage);
      final editor = tester.state<TestEditorState>(find.byType(TestEditor));
      await expectLater(
        editor.runFormDraftSubmission(() async {
          throw ApiException(
            'VALIDATION_FAILED',
            '盘点说明最多500字',
            httpStatus: 422,
          );
        }),
        throwsA(
          isA<ApiException>().having((e) => e.message, 'message', '盘点说明最多500字'),
        ),
      );
      await tester.pumpAndSettle();
      expect(env.container.read(formDraftsProvider), isEmpty);
      final record =
          jsonDecode(storage.records.values.single) as Map<String, dynamic>;
      expect(record['lifecycle'], formDraftCleanDiscardedLifecycle);
      var sends = 0;
      await editor.runFormDraftSubmission(() async => sends++);
      expect(sends, 1, reason: '被明确拒绝后改正可再次提交');
      await tester.pumpWidget(const SizedBox());
      env.router.dispose();
      env.container.dispose();
    },
  );

  testWidgets('empty defaults do not create draft or prompt', (tester) async {
    final storage = MemoryDraftStorage();
    final env = await pumpEditor(tester, storage);
    await tester.tap(find.text('离开'));
    await tester.pumpAndSettle();
    expect(find.text('任务中心'), findsOneWidget);
    expect(storage.records, isEmpty);
    await tester.pumpWidget(const SizedBox());
    env.router.dispose();
    env.container.dispose();
  });

  testWidgets(
    'autosave survives hard disposal and restores raw input and selection',
    (tester) async {
      final storage = MemoryDraftStorage();
      var env = await pumpEditor(tester, storage);
      await tester.enterText(find.byKey(const Key('input')), '1. 未完成');
      await tester.tap(find.text('default'));
      await tester.pumpAndSettle();
      final draft = env.container.read(formDraftsProvider).single;
      expect(draft.data, {
        'text': '1. 未完成',
        'choice': 'chosen',
        '_formDraftHasUnknownSubmission': false,
      });
      await tester.pumpWidget(const SizedBox());
      env.router.dispose();
      env.container.dispose();
      env = await pumpEditor(tester, storage, initial: draft.resumeLocation);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('input')))
            .controller!
            .text,
        '1. 未完成',
      );
      expect(find.text('chosen'), findsOneWidget);
      expect(env.container.read(formDraftsProvider), hasLength(1));
      await tester.pumpWidget(const SizedBox());
      env.router.dispose();
      env.container.dispose();
    },
  );

  testWidgets(
    'go navigation stays on cancel, persists on save and removes on discard',
    (tester) async {
      final storage = MemoryDraftStorage();
      final env = await pumpEditor(tester, storage);
      await tester.enterText(find.byKey(const Key('input')), '客户还没选择');
      await tester.pumpAndSettle();
      await tester.tap(find.text('离开'));
      await tester.pumpAndSettle();
      expect(find.text('是否保存为草稿？'), findsOneWidget);
      await tester.tap(find.text('继续填写'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('input')), findsOneWidget);
      await tester.tap(find.text('离开'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存草稿'));
      await tester.pumpAndSettle();
      expect(find.text('任务中心'), findsOneWidget);
      final draft = env.container.read(formDraftsProvider).single;
      env.router.go(draft.resumeLocation);
      await tester.pumpAndSettle();
      await tester.tap(find.text('离开'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('不保存'));
      await tester.pumpAndSettle();
      expect(find.text('任务中心'), findsOneWidget);
      expect(env.container.read(formDraftsProvider), isEmpty);
      await tester.pumpWidget(const SizedBox());
      env.router.dispose();
      env.container.dispose();
    },
  );

  testWidgets('failed durable write cannot close after choosing save', (
    tester,
  ) async {
    final storage = MemoryDraftStorage()..failWrites = true;
    final env = await pumpEditor(tester, storage);
    await tester.enterText(find.byKey(const Key('input')), '重要内容');
    await tester.pumpAndSettle();
    await tester.tap(find.text('离开'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存草稿'));
    await tester.pumpAndSettle();
    // 退出保存失败：页面必须留在原地（错误经瞬时通知提示，底部状态条已退役）。
    expect(find.byKey(const Key('input')), findsOneWidget);
    storage.failWrites = false;
    await tester.tap(find.text('离开'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存草稿'));
    await tester.pumpAndSettle();
    expect(find.text('任务中心'), findsOneWidget);
    expect(env.container.read(formDraftsProvider).single.data['text'], '重要内容');
    await tester.pumpWidget(const SizedBox());
    env.router.dispose();
    env.container.dispose();
  });

  testWidgets('business completion leaves tombstone and no leave prompt', (
    tester,
  ) async {
    final storage = MemoryDraftStorage();
    final env = await pumpEditor(tester, storage);
    await tester.enterText(find.byKey(const Key('input')), '已提交');
    await tester.pumpAndSettle();
    await tester.tap(find.text('提交成功'));
    await tester.pumpAndSettle();
    expect(find.text('任务中心'), findsOneWidget);
    expect(env.container.read(formDraftsProvider), isEmpty);
    expect(
      (jsonDecode(storage.records.values.single)
          as Map<String, dynamic>)['completed'],
      isTrue,
    );
    await tester.pumpWidget(const SizedBox());
    env.router.dispose();
    env.container.dispose();
  });

  testWidgets(
    'unknown non-idempotent submit survives restart and cannot submit twice',
    (tester) async {
      final storage = MemoryDraftStorage();
      var env = await pumpEditor(tester, storage);
      await tester.enterText(find.byKey(const Key('input')), '原始单据');
      await tester.pumpAndSettle();
      final editor = tester.state<TestEditorState>(find.byType(TestEditor));
      var calls = 0;
      await expectLater(
        editor.runFormDraftSubmission(() async {
          calls++;
          throw StateError('response lost');
        }),
        throwsStateError,
      );
      await expectLater(
        editor.runFormDraftSubmission(() async {
          calls++;
        }),
        throwsStateError,
      );
      expect(calls, 1);
      final saved = env.container.read(formDraftsProvider).single;
      expect(saved.data['_formDraftSubmissionPending'], isTrue);
      await tester.pumpWidget(const SizedBox());
      env.router.dispose();
      env.container.dispose();
      env = await pumpEditor(tester, storage, initial: saved.resumeLocation);
      expect(find.textContaining('上次提交的结果尚未确认'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('input')))
            .controller!
            .text,
        '原始单据',
      );
      await tester.pumpWidget(const SizedBox());
      env.router.dispose();
      env.container.dispose();
    },
  );
}
