import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/shared/auth/native_read_view_scope_mixin.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

const _readerA = AuthenticatedScope(userId: 'reader-a');
final _reader = StateProvider<AuthenticatedScope?>((_) => _readerA);
final _server = StateProvider<String>((_) => 'https://a.invalid/api');

class _Snapshots extends SessionSnapshotNotifier {
  @override
  Future<SessionSnapshot?> build() async => SessionSnapshot(generation: 1);

  void emit(AsyncValue<SessionSnapshot?> value) => state = value;
}

class _Page extends ConsumerStatefulWidget {
  const _Page({super.key, required this.read, this.resource = 'document-a'});

  final Future<String> Function() read;
  final String resource;

  @override
  ConsumerState<_Page> createState() => _PageState();
}

class _PageState extends ConsumerState<_Page>
    with NativeReadViewScopeMixin<_Page> {
  String? value;
  String? error;
  bool loading = false;

  @override
  void initState() {
    super.initState();
    initializeNativeReadScope();
    WidgetsBinding.instance.addPostFrameCallback((_) => load());
  }

  @override
  void didUpdateWidget(covariant _Page oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.resource != widget.resource) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => load(background: true),
      );
    }
  }

  @override
  void nativeReadOwnerChanged() => setState(() {
    value = null;
    loading = false;
    error = 'Reader changed';
  });

  @override
  void nativeReadPermissionChanged() => setState(() {});

  @override
  Future<void> nativeReadReload() => load();

  Future<void> load({bool background = false}) async {
    final accepts = captureNativeRead(
      widget.resource,
      () => widget.resource,
      retainAccepted: background && value != null,
    );
    if (!accepts()) return;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final next = await widget.read();
      if (!accepts()) return;
      acceptNativeRead();
      setState(() {
        value = next;
        loading = false;
      });
    } catch (failure) {
      if (!accepts()) return;
      final message = failure is ApiException ? failure.message : 'Read failed';
      final retained = failNativeRead(failure, message: message);
      setState(() {
        error = retained ? null : message;
        if (nativeReadAccessDenied(failure) ||
            nativeReadResourceRetired(failure)) {
          value = null;
        }
        loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        TextButton(
          key: const Key('write'),
          onPressed: nativeReadCanWrite ? () {} : null,
          child: const Text('Write'),
        ),
        Expanded(
          child: Stack(
            children: [
              if (loading && !nativeReadAccessConfirmed)
                const Center(child: CircularProgressIndicator())
              else if (error != null)
                Center(child: Text(error!))
              else if (!nativeReadAccessConfirmed)
                nativeReadAccessNotice()
              else
                _SnapshotPane(value: value!),
              nativeReadRefreshFeedback(onRetry: () => load(background: true)),
            ],
          ),
        ),
      ],
    ),
  );
}

class _SnapshotPane extends StatefulWidget {
  const _SnapshotPane({required this.value});
  final String value;

  @override
  State<_SnapshotPane> createState() => _SnapshotPaneState();
}

class _SnapshotPaneState extends State<_SnapshotPane> {
  final scroll = ScrollController();

  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Text(widget.value),
      Expanded(
        child: ListView.builder(
          controller: scroll,
          itemCount: 50,
          itemExtent: 48,
          itemBuilder: (_, index) => Text('Row $index'),
        ),
      ),
    ],
  );
}

Future<({ProviderContainer container, GlobalKey<_PageState> key})> _mount(
  WidgetTester tester,
  Queue<Future<String>> reads,
) async {
  final key = GlobalKey<_PageState>();
  final container = ProviderContainer(
    overrides: [
      authenticatedScopeProvider.overrideWith((ref) => ref.watch(_reader)),
      apiBaseUrlProvider.overrideWith((ref) => ref.watch(_server)),
      sessionSnapshotProvider.overrideWith(_Snapshots.new),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: _Page(key: key, read: reads.removeFirst),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (container: container, key: key);
}

bool _canWrite(WidgetTester tester) =>
    tester.widget<TextButton>(find.byKey(const Key('write'))).onPressed != null;

void main() {
  testWidgets(
    'compound filter identities fence stale reads and cannot revive after another read',
    (tester) async {
      final fixture = await _mount(
        tester,
        Queue.of([Future.value('Accepted')]),
      );
      var query = ('goods-a', 'name=开关', true);
      final first = fixture.key.currentState!.captureNativeRead(
        query,
        () => query,
      );
      expect(first(), isTrue);
      query = ('goods-a', 'name=端子', true);
      expect(first(), isFalse);
      final second = fixture.key.currentState!.captureNativeRead(
        query,
        () => query,
      );
      expect(second(), isTrue);
      query = ('goods-a', 'name=开关', true);
      expect(first(), isFalse);
      expect(second(), isFalse);
      final third = fixture.key.currentState!.captureNativeRead(
        query,
        () => query,
      );
      expect(third(), isTrue);
    },
  );
  testWidgets(
    'background read retains the subtree and scroll until new data arrives',
    (tester) async {
      final gate = Completer<String>();
      final fixture = await _mount(
        tester,
        Queue.of([Future.value('Accepted A'), gate.future]),
      );
      final pane = tester.state<_SnapshotPaneState>(find.byType(_SnapshotPane));
      pane.scroll.jumpTo(240);
      await tester.pump();
      final pending = fixture.key.currentState!.load(background: true);
      await tester.pump();
      expect(find.text('Accepted A'), findsOneWidget);
      expect(tester.state(find.byType(_SnapshotPane)), same(pane));
      expect(pane.scroll.offset, 240);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(_canWrite(tester), isFalse);

      gate.complete('Accepted B');
      await pending;
      await tester.pumpAndSettle();
      expect(find.text('Accepted B'), findsOneWidget);
      expect(tester.state(find.byType(_SnapshotPane)), same(pane));
      expect(pane.scroll.offset, 240);
      expect(_canWrite(tester), isTrue);
    },
  );

  testWidgets(
    'failed background check labels old data and blocks writes until retry succeeds',
    (tester) async {
      final gate = Completer<String>();
      final retry = Completer<String>();
      final fixture = await _mount(
        tester,
        Queue.of([Future.value('Accepted A'), gate.future, retry.future]),
      );
      final pending = fixture.key.currentState!.load(background: true);
      gate.completeError(NetworkException('Connection lost'));
      await pending;
      await tester.pumpAndSettle();
      expect(find.text('Accepted A'), findsOneWidget);
      expect(find.text('更新失败，当前显示上次内容'), findsOneWidget);
      expect(find.text('Connection lost'), findsOneWidget);
      expect(_canWrite(tester), isFalse);

      await tester.tap(find.text('重新更新'));
      await tester.pump();
      expect(find.text('更新失败，当前显示上次内容'), findsNothing);
      expect(find.text('Accepted A'), findsOneWidget);
      retry.complete('Accepted B');
      await tester.pumpAndSettle();
      expect(find.text('Accepted B'), findsOneWidget);
      expect(_canWrite(tester), isTrue);
    },
  );

  testWidgets(
    'foreground reread keeps the existing hide-until-confirmed contract',
    (tester) async {
      final gate = Completer<String>();
      final fixture = await _mount(
        tester,
        Queue.of([Future.value('Accepted A'), gate.future]),
      );
      final pending = fixture.key.currentState!.load();
      await tester.pump();
      expect(find.text('Accepted A'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      gate.complete('Accepted B');
      await pending;
      await tester.pumpAndSettle();
      expect(find.text('Accepted B'), findsOneWidget);
    },
  );

  for (final failure in [
    ApiException('FORBIDDEN', 'Read access revoked'),
    ApiException('CUSTOM_RULE', 'Read access revoked', httpStatus: 403),
    ApiException('UNAUTHORIZED', 'Session expired'),
    ApiException('NOT_FOUND', 'Record no longer exists'),
    ApiException(
      'CUSTOM_NOT_FOUND',
      'Record no longer exists',
      httpStatus: 404,
    ),
  ]) {
    testWidgets(
      'background ${failure.code}/${failure.httpStatus} retires old private data',
      (tester) async {
        final gate = Completer<String>();
        final fixture = await _mount(
          tester,
          Queue.of([Future.value('Accepted A'), gate.future]),
        );
        final pending = fixture.key.currentState!.load(background: true);
        gate.completeError(failure);
        await pending;
        await tester.pumpAndSettle();
        expect(find.text('Accepted A'), findsNothing);
        expect(find.text(failure.message), findsOneWidget);
        expect(find.text('更新失败，当前显示上次内容'), findsNothing);
        expect(_canWrite(tester), isFalse);
      },
    );
  }

  for (final transition in ['account', 'server']) {
    testWidgets('retained background read cannot survive $transition A-B-A', (
      tester,
    ) async {
      final gate = Completer<String>();
      final fixture = await _mount(
        tester,
        Queue.of([Future.value('Accepted A'), gate.future]),
      );
      final pending = fixture.key.currentState!.load(background: true);
      await tester.pump();
      if (transition == 'account') {
        fixture.container.read(_reader.notifier).state =
            const AuthenticatedScope(userId: 'reader-b');
      } else {
        fixture.container.read(_server.notifier).state =
            'https://b.invalid/api';
      }
      await tester.pump();
      expect(find.text('Accepted A'), findsNothing);
      if (transition == 'account') {
        fixture.container.read(_reader.notifier).state = _readerA;
      } else {
        fixture.container.read(_server.notifier).state =
            'https://a.invalid/api';
      }
      await tester.pump();
      gate.complete('Late private A');
      await pending;
      await tester.pumpAndSettle();
      expect(find.text('Late private A'), findsNothing);
      expect(find.text('Accepted A'), findsNothing);
      expect(_canWrite(tester), isFalse);
    });
  }

  testWidgets(
    'permission snapshot ABA hides retained data and rejects its late response',
    (tester) async {
      final oldGate = Completer<String>();
      final newGate = Completer<String>();
      final fixture = await _mount(
        tester,
        Queue.of([Future.value('Accepted A'), oldGate.future, newGate.future]),
      );
      final initial = fixture.container.read(sessionSnapshotProvider);
      final oldRead = fixture.key.currentState!.load(background: true);
      final snapshots =
          fixture.container.read(sessionSnapshotProvider.notifier)
              as _Snapshots;
      snapshots.emit(const AsyncLoading<SessionSnapshot?>());
      await tester.pump();
      expect(find.text('Accepted A'), findsNothing);
      snapshots.emit(initial);
      await tester.pump();
      await tester.pump();
      oldGate.complete('Late private A');
      await oldRead;
      await tester.pump();
      expect(find.text('Late private A'), findsNothing);
      newGate.complete('Newly confirmed');
      await tester.pumpAndSettle();
      expect(find.text('Newly confirmed'), findsOneWidget);
    },
  );

  testWidgets('retention never crosses a document identity', (tester) async {
    final fixture = await _mount(
      tester,
      Queue.of([Future.value('Accepted A')]),
    );
    final gate = Completer<String>();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: fixture.container,
        child: MaterialApp(
          home: _Page(
            key: fixture.key,
            resource: 'document-b',
            read: () => gate.future,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Accepted A'), findsNothing);
    gate.complete('Accepted document B');
    await tester.pumpAndSettle();
    expect(find.text('Accepted document B'), findsOneWidget);
  });
}
