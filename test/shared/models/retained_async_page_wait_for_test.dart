import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/models/retained_async_page.dart';

class _Source {
  final requests = <Completer<int>>[];
  int disposals = 0;

  late final family = FutureProvider.autoDispose.family<int, int>((ref, page) {
    final request = Completer<int>();
    requests.add(request);
    ref.onDispose(() => disposals++);
    return request.future;
  });
}

class _Host extends ConsumerStatefulWidget {
  const _Host({super.key, required this.provider, this.observe = true});
  final FutureProvider<int> provider;
  final bool observe;

  @override
  ConsumerState<_Host> createState() => _HostState();
}

class _HostState extends ConsumerState<_Host> {
  final retained = RetainedAsyncPage<int>();
  late bool observe = widget.observe;

  Future<void> waitFor() => retained.waitFor(
    ref,
    widget.provider,
    () => ref.read(widget.provider.future),
  );

  void setObserved(bool value) => setState(() => observe = value);

  @override
  Widget build(BuildContext context) {
    final state = observe ? ref.watch(widget.provider) : null;
    return Text(
      state == null
          ? 'unobserved'
          : state.isLoading
          ? 'loading'
          : state.hasError
          ? 'failed'
          : '${state.requireValue}',
    );
  }
}

Future<(_HostState, ProviderContainer)> _mount(
  WidgetTester tester,
  FutureProvider<int> provider, {
  bool observe = true,
}) async {
  final container = ProviderContainer(retry: (count, error) => null);
  addTearDown(container.dispose);
  final key = GlobalKey<_HostState>();
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: _Host(key: key, provider: provider, observe: observe),
      ),
    ),
  );
  return (key.currentState!, container);
}

Future<void> _failFirst(
  WidgetTester tester,
  _Source source,
  ProviderContainer container,
  FutureProvider<int> provider,
) async {
  final failure = StateError('offline');
  final handled = expectLater(
    container.read(provider.future),
    throwsA(same(failure)),
  );
  source.requests.single.completeError(failure);
  await handled;
  await tester.pump();
  expect(container.read(provider).hasError, isTrue);
  expect(container.read(provider).isLoading, isFalse);
}

void main() {
  testWidgets(
    'waitFor adopts loading with a previous error without restarting retry',
    (tester) async {
      final source = _Source();
      final provider = source.family(2);
      final (host, container) = await _mount(tester, provider);
      await _failFirst(tester, source, container, provider);

      // Match onPageChange: its explicit invalidation has already started retry.
      container.invalidate(provider);
      final retry = container.read(provider);
      expect(retry.hasError, isTrue);
      expect(retry.isLoading, isTrue);
      expect(source.requests, hasLength(2));
      final waiting = host.waitFor();
      await tester.pump();
      expect(source.requests, hasLength(2));
      source.requests[1].complete(22);
      await waiting;
      await tester.pump();
      expect(find.text('22'), findsOneWidget);
      expect(container.read(provider).hasError, isFalse);
      expect(source.requests, hasLength(2));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('waitFor restarts a settled error exactly once', (tester) async {
    final source = _Source();
    final provider = source.family(2);
    final (host, container) = await _mount(tester, provider);
    await _failFirst(tester, source, container, provider);

    final waiting = host.waitFor();
    expect(source.requests, hasLength(2));
    source.requests[1].complete(23);
    await waiting;
    await tester.pump();
    expect(find.text('23'), findsOneWidget);
    expect(source.requests, hasLength(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'waitFor retains an auto-dispose family until the rebuilt page observes it',
    (tester) async {
      final source = _Source();
      final provider = source.family(2);
      final (host, _) = await _mount(tester, provider, observe: false);
      expect(source.requests, isEmpty);
      final waiting = host.waitFor();
      for (var frame = 0; frame < 3; frame++) {
        await tester.pump();
      }
      expect(source.requests, hasLength(1));
      expect(source.disposals, 0);
      source.requests.single.complete(24);
      await waiting;
      host.setObserved(true);
      await tester.pump();
      expect(find.text('24'), findsOneWidget);
      expect(source.requests, hasLength(1));
      expect(source.disposals, 0);
      host.setObserved(false);
      await tester.pump();
      await tester.pump();
      expect(source.disposals, 1);
      expect(tester.takeException(), isNull);
    },
  );
}
