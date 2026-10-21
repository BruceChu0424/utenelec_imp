import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_refresh_scope.dart';

class _Host extends StatefulWidget {
  const _Host({
    super.key,
    required this.controller,
    required this.request,
    this.replaceRequests = false,
  });

  final UtenRefreshController controller;
  final Future<void> request;
  final bool replaceRequests;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  int tick = 0;
  bool visible = true;
  Future<void>? replacementRequest;

  void refresh() => setState(() => tick++);
  void hideSegment() => setState(() => visible = false);
  void showSegment() => setState(() => visible = true);
  void replaceRequest(Future<void> request) => setState(() {
    replacementRequest = request;
    tick++;
  });

  @override
  void dispose() {
    widget.controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => UtenRefreshScope(
    controller: widget.controller,
    child: visible
        ? _Segment(
            tick: tick,
            request: replacementRequest ?? widget.request,
            replaceKey: widget.replaceRequests ? 'query' : null,
          )
        : const SizedBox.shrink(),
  );
}

class _Segment extends StatefulWidget {
  const _Segment({required this.tick, required this.request, this.replaceKey});

  final int tick;
  final Future<void> request;
  final Object? replaceKey;

  @override
  State<_Segment> createState() => _SegmentState();
}

class _SegmentState extends State<_Segment>
    with UtenRefreshParticipant<_Segment> {
  @override
  void initState() {
    super.initState();
    if (widget.tick > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          trackRefresh(widget.request, replaceKey: widget.replaceKey);
        }
      });
    }
  }

  @override
  void didUpdateWidget(_Segment oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tick != widget.tick) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          trackRefresh(widget.request, replaceKey: widget.replaceKey);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

Future<GlobalKey<_HostState>> _mount(
  WidgetTester tester,
  UtenRefreshController controller,
  Future<void> request, {
  bool replaceRequests = false,
}) async {
  final key = GlobalKey<_HostState>();
  await tester.pumpWidget(
    MaterialApp(
      home: _Host(
        key: key,
        controller: controller,
        request: request,
        replaceRequests: replaceRequests,
      ),
    ),
  );
  return key;
}

void main() {
  for (final replaceRequests in [false, true]) {
    testWidgets(
      'a newer query replaces only its keyed wait with replaceRequests=$replaceRequests',
      (tester) async {
        final controller = UtenRefreshController();
        final oldRequest = Completer<void>();
        final newRequest = Completer<void>();
        final metadata = Completer<void>();
        final host = await _mount(
          tester,
          controller,
          oldRequest.future,
          replaceRequests: replaceRequests,
        );
        var finished = false;
        final refresh = controller.run(() {
          host.currentState!.refresh();
          controller.track(metadata.future);
        })..then((_) => finished = true);
        await tester.pump();
        await tester.pump();
        expect(finished, isFalse);

        host.currentState!.replaceRequest(newRequest.future);
        await tester.pump();
        await tester.pump();
        expect(finished, isFalse, reason: 'the latest query is still pending');
        newRequest.complete();
        await tester.pump();
        await tester.pump();
        expect(finished, isFalse, reason: 'metadata is an independent request');
        metadata.complete();
        await tester.pumpAndSettle();
        expect(finished, replaceRequests);
        expect(oldRequest.isCompleted, isFalse);
        oldRequest.complete();
        await tester.pumpAndSettle();
        await refresh;
        expect(finished, isTrue);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('waits for the visible segment request started after its frame', (
    tester,
  ) async {
    final controller = UtenRefreshController();
    final request = Completer<void>();
    final host = await _mount(tester, controller, request.future);
    var finished = false;
    final refresh = controller.run(host.currentState!.refresh)
      ..then((_) => finished = true);
    await tester.pump();
    await tester.pump();
    expect(finished, isFalse);
    request.complete();
    await tester.pumpAndSettle();
    await refresh;
    expect(finished, isTrue);
  });

  testWidgets('an empty segment completes without a pending child request', (
    tester,
  ) async {
    final controller = UtenRefreshController();
    final request = Completer<void>();
    final host = await _mount(tester, controller, request.future);
    host.currentState!.visible = false;
    final refresh = controller.run(host.currentState!.refresh);
    await tester.pumpAndSettle();
    await refresh;
    expect(request.isCompleted, isFalse);
    request.complete();
  });

  testWidgets('waits for a late child mounted after scope metadata completes', (
    tester,
  ) async {
    final controller = UtenRefreshController();
    final metadata = Completer<void>();
    final request = Completer<void>();
    final host = await _mount(tester, controller, request.future);
    host.currentState!.hideSegment();
    await tester.pump();
    var finished = false;
    final refresh = controller.run(() {
      host.currentState!.refresh();
      controller.track(metadata.future);
      metadata.future.then((_) => host.currentState!.showSegment());
    })..then((_) => finished = true);
    await tester.pump();
    expect(finished, isFalse);
    metadata.complete();
    await tester.pump();
    await tester.pump();
    expect(find.byType(_Segment), findsOneWidget);
    expect(finished, isFalse);
    request.complete();
    await tester.pump();
    await tester.pumpAndSettle();
    await refresh;
    expect(finished, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failed request releases the wait and allows another refresh', (
    tester,
  ) async {
    final controller = UtenRefreshController();
    final request = Completer<void>();
    final host = await _mount(tester, controller, request.future);
    final refresh = controller.run(host.currentState!.refresh);
    final failure = expectLater(refresh, throwsStateError);
    await tester.pump();
    request.completeError(StateError('network failed'));
    await tester.pump();
    await failure;
    host.currentState!.visible = false;
    final retry = controller.run(host.currentState!.refresh);
    await tester.pumpAndSettle();
    await retry;
    expect(tester.takeException(), isNull);
  });

  testWidgets('concurrent triggers share one in-flight refresh', (
    tester,
  ) async {
    final controller = UtenRefreshController();
    final request = Completer<void>();
    final host = await _mount(tester, controller, request.future);
    var triggers = 0;
    void trigger() {
      triggers++;
      host.currentState!.refresh();
    }

    final first = controller.run(trigger);
    final second = controller.run(trigger);
    expect(second, same(first));
    expect(triggers, 1);
    await tester.pump();
    request.complete();
    await tester.pumpAndSettle();
    await first;
  });

  testWidgets('switching away from a segment releases its host refresh', (
    tester,
  ) async {
    final controller = UtenRefreshController();
    final request = Completer<void>();
    final host = await _mount(tester, controller, request.future);
    final refresh = controller.run(host.currentState!.refresh);
    await tester.pump();
    host.currentState!.hideSegment();
    await tester.pump();
    await tester.pumpAndSettle();
    await refresh;
    expect(host.currentState, isNotNull);
    expect(request.isCompleted, isFalse);
    final nextRefresh = controller.run(host.currentState!.refresh);
    await tester.pumpAndSettle();
    await nextRefresh;
    request.complete();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'unmount releases pending work and disposed controllers ignore taps',
    (tester) async {
      final controller = UtenRefreshController();
      final request = Completer<void>();
      final host = await _mount(tester, controller, request.future);
      final refresh = controller.run(host.currentState!.refresh);
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await refresh;
      var triggered = false;
      await controller.run(() => triggered = true);
      expect(triggered, isFalse);
      request.complete();
      expect(tester.takeException(), isNull);
    },
  );
}
