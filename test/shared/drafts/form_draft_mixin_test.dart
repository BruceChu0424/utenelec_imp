import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft_mixin.dart';
import 'package:uten_imp/shared/drafts/form_draft_navigation.dart';
import 'package:uten_imp/shared/drafts/form_draft_storage_api.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_models.dart';

final _testScope = StateProvider<AuthenticatedScope?>(
  (ref) => const AuthenticatedScope(userId: 'user-1'),
);
final _testServer = StateProvider<String>((ref) => 'https://test.example/api');

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

class _DraftGridRow extends EditableGridRow {}

class TestEditor extends ConsumerStatefulWidget {
  const TestEditor({super.key, this.withGrid = false});
  final bool withGrid;
  @override
  ConsumerState<TestEditor> createState() => TestEditorState();
}

class TestEditorState extends ConsumerState<TestEditor>
    with FormDraftMixin<TestEditor> {
  final text = TextEditingController();
  final grid = UtenEditableGridController<_DraftGridRow>();
  String choice = 'default';
  bool busy = false;
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
  ];
  @override
  Map<String, dynamic> captureFormDraft() => {
    'text': text.text,
    'choice': choice,
    if (widget.withGrid) 'rowCount': grid.rows.length,
  };
  @override
  Future<void> restoreFormDraft(Map<String, dynamic> data) async {
    text.text = data['text'] as String;
    choice = data['choice'] as String;
    if (widget.withGrid) {
      grid.replaceAll(
        List.generate(data['rowCount'] as int, (_) => _DraftGridRow()),
      );
    }
  }

  @override
  void initState() {
    super.initState();
    if (widget.withGrid) grid.addRow(_DraftGridRow());
    WidgetsBinding.instance.addPostFrameCallback((_) => initializeFormDraft());
  }

  @override
  void dispose() {
    text.dispose();
    grid.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => withFormDraft(
    Scaffold(
      body: Column(
        children: [
          TextField(key: const Key('input'), controller: text),
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
}) async {
  final container = ProviderContainer(
    overrides: [
      authenticatedScopeProvider.overrideWith((ref) => ref.watch(_testScope)),
      currentPermissionsProvider.overrideWithValue({'test:create'}),
      apiBaseUrlProvider.overrideWith((ref) => ref.watch(_testServer)),
      formDraftStorageProvider.overrideWithValue(storage),
    ],
  );
  final router = GoRouter(
    initialLocation: initial,
    routes: [
      DraftAwareGoRoute(
        path: '/new',
        builder: (_, state) =>
            TestEditor(key: state.pageKey, withGrid: withGrid),
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
    expect(find.textContaining('草稿尚未保存'), findsNothing);
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
      expect(draft.data, {'text': '1. 未完成', 'choice': 'chosen'});
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
    expect(find.byKey(const Key('input')), findsOneWidget);
    expect(find.textContaining('草稿尚未保存'), findsOneWidget);
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
