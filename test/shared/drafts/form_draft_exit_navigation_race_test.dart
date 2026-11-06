import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_close_button.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft_mixin.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

import 'form_draft_mixin_test.dart' show MemoryDraftStorage;

class _Pops extends NavigatorObserver {
  final names = <String>[];
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route.settings.name != null) names.add(route.settings.name!);
  }
}

class _Editor extends ConsumerStatefulWidget {
  const _Editor();
  @override
  ConsumerState<_Editor> createState() => _EditorState();
}

class _EditorState extends ConsumerState<_Editor> with FormDraftMixin<_Editor> {
  final text = TextEditingController();
  int permits = 0;
  bool busy = false;
  @override
  bool get formDraftBusy => busy;
  @override
  bool get formDraftCanReplaySubmission => true;
  @override
  FormDraftSpec get formDraftSpec => const FormDraftSpec(
    title: '退出竞争原单据',
    module: BadgeModule.sales,
    route: '/new',
    permission: 'test:create',
  );
  @override
  Iterable<Listenable> get formDraftListenables => [text];
  @override
  Map<String, dynamic> captureFormDraft() => {'text': text.text};
  @override
  Future<void> restoreFormDraft(Map<String, dynamic> data) async {
    text.text = data['text'] as String;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => initializeFormDraft());
  }

  Future<void> requestExit() async {
    if (await confirmFormDraftExit() && mounted) {
      permits++;
      Navigator.of(context).pop();
    }
  }

  Future<void> persistExit() async {
    if (await saveFormDraftBeforeExit() && mounted) {
      permits++;
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) => withFormDraft(
    Scaffold(
      appBar: AppBar(
        title: const Text('原单据'),
        actions: [UtenCloseButton(onPressed: requestExit)],
      ),
      body: TextField(key: const Key('race-input'), controller: text),
    ),
  );
  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }
}

Future<
  ({
    ProviderContainer container,
    GlobalKey<NavigatorState> navigator,
    _Pops observer,
  })
>
_mount(WidgetTester t) async {
  final container = ProviderContainer(
    overrides: [
      authenticatedScopeProvider.overrideWithValue(
        const AuthenticatedScope(userId: 'exit-owner'),
      ),
      currentPermissionsProvider.overrideWithValue({'test:create'}),
      apiBaseUrlProvider.overrideWithValue('https://test.example/api'),
      formDraftStorageProvider.overrideWithValue(MemoryDraftStorage()),
    ],
  );
  final navigator = GlobalKey<NavigatorState>(), observer = _Pops();
  await t.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        navigatorKey: navigator,
        navigatorObservers: [observer],
        routes: {
          '/': (_) => const Scaffold(body: Text('工作区')),
          '/behind': (_) => const Scaffold(body: Text('后层单据')),
          '/new': (_) => const _Editor(),
        },
      ),
    ),
  );
  unawaited(navigator.currentState!.pushNamed('/behind'));
  await t.pumpAndSettle();
  unawaited(navigator.currentState!.pushNamed('/new'));
  await t.pumpAndSettle();
  await t.enterText(find.byKey(const Key('race-input')), '原输入 0005.');
  await t.pumpAndSettle();
  return (container: container, navigator: navigator, observer: observer);
}

void main() {
  for (final decision in ['save', 'discard', 'stay', 'unknown-save']) {
    testWidgets(
      'two explicit exits before $decision decision pop only their original route',
      (t) async {
        final env = await _mount(t);
        final editor = t.state<_EditorState>(find.byType(_Editor));
        if (decision == 'unknown-save') {
          await expectLater(
            editor.runFormDraftSubmission(() async {
              throw NetworkTimeoutException();
            }),
            throwsA(isA<NetworkTimeoutException>()),
          );
        }
        final first = editor.requestExit();
        await t.pumpAndSettle();
        // A separate host/native exit can arrive while the first confirmation is open.
        final second = editor.requestExit();
        await t.pump();
        expect(find.byType(AlertDialog), findsOneWidget);
        if (decision == 'unknown-save') expect(find.text('不保存'), findsNothing);
        await t.tap(
          find.text(switch (decision) {
            'save' => '保存草稿',
            'discard' => '不保存',
            'stay' => '继续填写',
            _ => '保存原提交后离开',
          }),
        );
        await t.pumpAndSettle();
        await Future.wait([first, second]);
        expect(env.observer.names, decision == 'stay' ? isEmpty : ['/new']);
        expect(editor.permits, decision == 'stay' ? 0 : 1);
        expect(
          find.text('后层单据'),
          decision == 'stay' ? findsNothing : findsOneWidget,
        );
        if (decision == 'unknown-save') {
          expect(
            env.container.read(formDraftsProvider).single.hasUnknownSubmission,
            isTrue,
          );
        }
        await t.pumpWidget(const SizedBox());
        env.container.dispose();
      },
    );
  }
  testWidgets(
    'retired route cannot use another exit permit while its closing animation is mounted',
    (t) async {
      final env = await _mount(t);
      final editor = t.state<_EditorState>(find.byType(_Editor));
      final first = editor.requestExit();
      await t.pumpAndSettle();
      await t.tap(find.text('保存草稿'));
      await t.pump();
      await first;
      expect(
        editor.mounted,
        isTrue,
        reason: 'The original route is still alive during its exit transition.',
      );
      final second = editor.requestExit();
      await t.pumpAndSettle();
      await second;
      expect(env.observer.names, ['/new']);
      expect(editor.permits, 1);
      expect(find.text('后层单据'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      env.container.dispose();
    },
  );
  testWidgets(
    'retired route cannot reuse direct persistence during its exit transition',
    (t) async {
      final env = await _mount(t);
      final editor = t.state<_EditorState>(find.byType(_Editor));
      final first = editor.persistExit();
      await t.pump();
      await first;
      expect(editor.mounted, isTrue);
      final second = editor.persistExit();
      await t.pumpAndSettle();
      await second;
      expect(env.observer.names, ['/new']);
      expect(editor.permits, 1);
      expect(find.text('后层单据'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      env.container.dispose();
    },
  );

  testWidgets(
    'confirmed business completion still exits before its busy finally finishes',
    (t) async {
      final env = await _mount(t);
      final editor = t.state<_EditorState>(find.byType(_Editor));
      editor.busy = true;
      await editor.completeFormDraft();
      await editor.requestExit();
      await t.pumpAndSettle();
      expect(env.observer.names, ['/new']);
      expect(find.text('后层单据'), findsOneWidget);
      expect(env.container.read(formDraftsProvider), isEmpty);
      await t.pumpWidget(const SizedBox());
      env.container.dispose();
    },
  );
}
