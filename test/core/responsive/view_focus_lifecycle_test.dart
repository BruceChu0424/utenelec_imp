import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/responsive/view_focus_binding.dart';

class _TestBinding extends AutomatedTestWidgetsFlutterBinding
    with UtenViewFocusEvents {}

class _FocusOnDetach extends SingleChildRenderObjectWidget {
  const _FocusOnDetach({required this.onDetach, required super.child});

  final VoidCallback onDetach;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _FocusOnDetachRenderBox(onDetach);
}

class _FocusOnDetachRenderBox extends RenderProxyBox {
  _FocusOnDetachRenderBox(this.onDetach);
  final VoidCallback onDetach;

  @override
  void detach() {
    super.detach();
    // A native view-focus notification may be synchronous with removing a
    // rendered subtree, before its Focus elements have been deactivated.
    onDetach();
  }
}

class _ViewFocusRecorder with WidgetsBindingObserver {
  final events = <(ui.ViewFocusEvent, SchedulerPhase)>[];

  @override
  void didChangeViewFocus(ui.ViewFocusEvent event) {
    events.add((event, WidgetsBinding.instance.schedulerPhase));
  }
}

class _ThrowingObserver with WidgetsBindingObserver {
  @override
  void didChangeViewFocus(ui.ViewFocusEvent event) {
    throw StateError('view-focus observer probe');
  }
}

Future<void> _retiringScope(WidgetTester tester, VoidCallback onDetach) async {
  var armed = false;
  await tester.pumpWidget(
    MaterialApp(
      home: const Scaffold(body: Text('Retained route')),
      builder: (context, child) => Stack(
        children: [
          child!,
          _FocusOnDetach(
            onDetach: () {
              if (armed) onDetach();
            },
            child: FocusScope(
              child: Column(
                children: [
                  TextButton(
                    onPressed: () {},
                    child: const Text('Retiring first'),
                  ),
                  TextButton(
                    onPressed: () {},
                    child: const Text('Retiring second'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );
  armed = true;
}

Future<void> _replacement(WidgetTester tester) => tester.pumpWidget(
  MaterialApp(
    home: Column(
      children: [
        TextButton(onPressed: () {}, child: const Text('Current first')),
        TextButton(onPressed: () {}, child: const Text('Current second')),
      ],
    ),
  ),
);

ui.ViewFocusEvent _event(
  WidgetTester tester,
  ui.ViewFocusDirection direction, {
  ui.ViewFocusState state = ui.ViewFocusState.focused,
  int? viewId,
}) => ui.ViewFocusEvent(
  viewId: viewId ?? tester.view.viewId,
  state: state,
  direction: direction,
);

void main() {
  _TestBinding();

  late _ViewFocusRecorder recorder;
  setUp(() {
    recorder = _ViewFocusRecorder();
    WidgetsBinding.instance.addObserver(recorder);
  });
  tearDown(() => WidgetsBinding.instance.removeObserver(recorder));

  for (final direction in [
    ui.ViewFocusDirection.forward,
    ui.ViewFocusDirection.backward,
  ]) {
    testWidgets('$direction during render detach waits for finalization', (
      tester,
    ) async {
      final event = _event(tester, direction);
      await _retiringScope(tester, () {
        tester.binding.handleViewFocusChanged(event);
        expect(recorder.events, isEmpty);
      });
      await _replacement(tester);
      expect(recorder.events, hasLength(1));
      expect(recorder.events.single.$1, same(event));
      expect(recorder.events.single.$2, SchedulerPhase.postFrameCallbacks);
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('stable view focus retains synchronous native direction', (
    tester,
  ) async {
    await _replacement(tester);
    for (final direction in ui.ViewFocusDirection.values) {
      final event = _event(tester, direction);
      tester.binding.handleViewFocusChanged(event);
      expect(recorder.events.last.$1, same(event));
      expect(recorder.events.last.$2, SchedulerPhase.idle);
    }
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  for (final superseding in [
    ui.ViewFocusState.unfocused,
    ui.ViewFocusState.focused,
  ]) {
    testWidgets('$superseding undefined event cancels an older traversal', (
      tester,
    ) async {
      final replacement = _event(
        tester,
        ui.ViewFocusDirection.undefined,
        state: superseding,
      );
      await _retiringScope(tester, () {
        tester.binding.handleViewFocusChanged(
          _event(tester, ui.ViewFocusDirection.forward),
        );
        tester.binding.handleViewFocusChanged(replacement);
        expect(recorder.events.single.$1, same(replacement));
        expect(recorder.events.single.$2, SchedulerPhase.persistentCallbacks);
      });
      await _replacement(tester);
      await tester.pump();
      expect(recorder.events, hasLength(1));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('the latest directional intent wins only for its own view', (
    tester,
  ) async {
    final latest = _event(tester, ui.ViewFocusDirection.backward);
    final otherView = _event(
      tester,
      ui.ViewFocusDirection.undefined,
      state: ui.ViewFocusState.unfocused,
      viewId: tester.view.viewId + 1000,
    );
    await _retiringScope(tester, () {
      tester.binding.handleViewFocusChanged(
        _event(tester, ui.ViewFocusDirection.forward),
      );
      tester.binding.handleViewFocusChanged(latest);
      tester.binding.handleViewFocusChanged(otherView);
      expect(recorder.events.single.$1, same(otherView));
    });
    await _replacement(tester);
    await tester.pump();
    expect(recorder.events.map((item) => item.$1), [otherView, latest]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a retired render view cancels its pending directional event', (
    tester,
  ) async {
    await _retiringScope(tester, () {
      tester.binding.handleViewFocusChanged(
        _event(tester, ui.ViewFocusDirection.forward),
      );
    });
    await tester.pumpWidget(
      const ViewCollection(views: []),
      wrapWithView: false,
    );
    await tester.pump();
    expect(recorder.events, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a replacement view with the same id cannot inherit old focus', (
    tester,
  ) async {
    final view = tester.view;
    await _retiringScope(tester, () {
      tester.binding.handleViewFocusChanged(
        _event(tester, ui.ViewFocusDirection.forward),
      );
    });
    await tester.pumpWidget(
      View(
        key: UniqueKey(),
        view: view,
        child: MaterialApp(
          home: TextButton(onPressed: () {}, child: const Text('New view')),
        ),
      ),
      wrapWithView: false,
    );
    await tester.pump();
    expect(recorder.events, isEmpty);
    expect(tester.binding.renderViews.single.flutterView.viewId, view.viewId);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ordinary observer errors keep the Flutter error contract', (
    tester,
  ) async {
    await _replacement(tester);
    final throwing = _ThrowingObserver();
    tester.binding.addObserver(throwing);
    addTearDown(() => tester.binding.removeObserver(throwing));
    tester.binding.handleViewFocusChanged(
      _event(tester, ui.ViewFocusDirection.undefined),
    );
    expect(
      tester.takeException(),
      isA<StateError>().having(
        (error) => error.message,
        'message',
        'view-focus observer probe',
      ),
    );
  });
}
