import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_ancestor_row_window.dart';

class _MountProbe extends StatefulWidget {
  const _MountProbe(this.id, this.record, {this.mountWork = Duration.zero});
  final int id;
  final ValueChanged<int> record;
  final Duration mountWork;
  @override
  State<_MountProbe> createState() => _MountProbeState();
}

class _MountProbeState extends State<_MountProbe> {
  @override
  void initState() {
    super.initState();
    widget.record(widget.id);
    // Exercise actual Element mount work, after the window's cheap admission
    // loop. A real clock is intentional: WidgetTester frame time is fake.
    if (widget.mountWork > Duration.zero) {
      final clock = Stopwatch()..start();
      while (clock.elapsed < widget.mountWork) {}
    }
  }

  @override
  Widget build(BuildContext context) =>
      SizedBox(height: 52, child: Text('row-${widget.id}'));
}

void main() {
  for (final expensive in [false, true]) {
    testWidgets(
      'first-frame insertion admission still shares the mount budget: $expensive',
      (tester) async {
        final controllers = List.generate(
          6,
          (_) => UtenDeferredRowMountController(),
        );
        var mounts = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  for (var i = 0; i < controllers.length; i++)
                    UtenDeferredRowMount(
                      key: ValueKey(i),
                      controller: controllers[i],
                      estimatedExtent: 52,
                      admitOnFirstFrame: true,
                      expensive: expensive,
                      builder: (_) => _MountProbe(i, (_) => mounts++),
                    ),
                ],
              ),
            ),
          ),
        );
        expect(mounts, expensive ? 1 : 4);
        expect(
          find.byType(UtenRowMountPlaceholder),
          findsNWidgets(expensive ? 5 : 2),
        );
        await tester.pumpAndSettle();
        expect(mounts, 6);
        expect(
          controllers.every((controller) => controller.hasMountedContent),
          isTrue,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final deferred in [true, false]) {
    testWidgets('new sliver shells preserve deferred=$deferred admission', (
      tester,
    ) async {
      final controllers = List.generate(
        4,
        (_) => UtenDeferredRowMountController(),
      );
      var mounts = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                for (var i = 0; i < controllers.length; i++)
                  UtenDeferredRowMount(
                    key: ValueKey(i),
                    controller: controllers[i],
                    estimatedExtent: 52,
                    deferNewMounts: deferred,
                    builder: (_) => _MountProbe(i, (_) => mounts++),
                  ),
              ],
            ),
          ),
        ),
      );
      expect(mounts, deferred ? 0 : 4);
      if (deferred) {
        expect(find.byType(UtenRowMountPlaceholder), findsNWidgets(4));
        await tester.pump();
        expect(mounts, 1);
      }
      await tester.pumpAndSettle();
      expect(mounts, 4);
      expect(controllers.every((c) => c.hasMountedContent), isTrue);
      expect(controllers.every((c) => !c.isMounting), isTrue);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'distinct frames with the same clock timestamp make bounded progress',
    (tester) async {
      final window = UtenAncestorRowWindowController<int>();
      var mounts = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [
                UtenAncestorRowWindow<int>(
                  controller: window,
                  rows: List.generate(1000, (i) => i),
                  viewportOnly: true,
                  rowBuilder: (_, row, _) => _MountProbe(row, (_) => mounts++),
                ),
              ],
            ),
          ),
        ),
      );
      final first = mounts;
      expect(
        first,
        0,
        reason: 'The first frame lays out only the light shell.',
      );
      for (var i = 0; i < 4; i++) {
        final before = mounts;
        await tester.pump();
        expect(mounts - before, lessThanOrEqualTo(1));
      }
      expect(mounts, greaterThan(first));
      await tester.pumpAndSettle();
      expect(window.isMounting, isFalse);
    },
  );

  testWidgets(
    'expensive Element mounts stay limited to one new row per frame',
    (tester) async {
      final window = UtenAncestorRowWindowController<int>();
      var mounts = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [
                UtenAncestorRowWindow<int>(
                  controller: window,
                  rows: List.generate(1000, (i) => i),
                  viewportOnly: true,
                  rowBuilder: (_, row, _) => _MountProbe(
                    row,
                    (_) => mounts++,
                    mountWork: const Duration(milliseconds: 6),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      expect(mounts, 0);
      await tester.pump();
      expect(mounts, 1);
      for (var frame = 0; frame < 4; frame++) {
        final before = mounts;
        await tester.pump();
        expect(mounts - before, 1);
      }
      await tester.pumpAndSettle();
      expect(window.isMounting, isFalse);
      expect(find.byType(UtenRowMountPlaceholder), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'reveal waits for actual mount frames before spending geometry retries',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 1400);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final window = UtenAncestorRowWindowController<int>();
      final mountFrames = <Duration>{};
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [
                UtenAncestorRowWindow<int>(
                  controller: window,
                  rows: List.generate(1000, (i) => i),
                  viewportOnly: true,
                  rowBuilder: (_, row, _) => _MountProbe(
                    row,
                    (_) => mountFrames.add(
                      SchedulerBinding.instance.currentFrameTimeStamp,
                    ),
                    mountWork: const Duration(milliseconds: 6),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      mountFrames.clear();
      final revealed = window.reveal(500);
      await tester.pumpAndSettle();
      expect(mountFrames.length, greaterThan(16));
      expect(await revealed, isTrue);
      expect(window.isMounting, isFalse);
      final rect = tester.getRect(find.text('row-500'));
      expect(rect.top, greaterThanOrEqualTo(0));
      expect(rect.bottom, lessThanOrEqualTo(1400));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'hidden ticker mode ends pending settlement and stops new row mounts',
    (tester) async {
      final window = UtenAncestorRowWindowController<int>();
      final active = ValueNotifier(true);
      addTearDown(active.dispose);
      var mounts = 0;
      final body = ListView(
        children: [
          UtenAncestorRowWindow<int>(
            controller: window,
            rows: List.generate(1000, (index) => index),
            viewportOnly: true,
            rowBuilder: (_, row, _) => _MountProbe(row, (_) => mounts++),
          ),
        ],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: active,
              child: body,
              builder: (_, enabled, child) =>
                  TickerMode(enabled: enabled, child: child!),
            ),
          ),
        ),
      );
      expect(window.isMounting, isTrue);
      var finished = false;
      final settled = window.settled.then((_) => finished = true);
      active.value = false;
      await tester.pumpAndSettle();
      await settled;
      expect(finished, isTrue);
      expect(window.isMounting, isFalse);
      final before = mounts;
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(mounts, before);
      expect(tester.binding.hasScheduledFrame, isFalse);
      expect(await window.reveal(999), isFalse);
      active.value = true;
      await tester.pumpAndSettle();
      expect(mounts, greaterThan(before));
      expect(window.isMounting, isFalse);
      expect(find.byType(UtenRowMountPlaceholder), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('leaving the owner route cancels pending mounting and reveal', (
    tester,
  ) async {
    final window = UtenAncestorRowWindowController<int>();
    final navigator = GlobalKey<NavigatorState>();
    var mounts = 0;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: Scaffold(
          body: ListView(
            children: [
              UtenAncestorRowWindow<int>(
                controller: window,
                rows: List.generate(1000, (i) => i),
                viewportOnly: true,
                rowBuilder: (_, row, _) => _MountProbe(row, (_) => mounts++),
              ),
            ],
          ),
        ),
      ),
    );
    final settled = window.settled;
    final reveal = window.reveal(998);
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('other owner')),
      ),
    );
    await tester.pumpAndSettle();
    await settled;
    expect(await reveal, isFalse);
    expect(window.isMounting, isFalse);
    final before = mounts;
    await tester.pump(const Duration(milliseconds: 100));
    expect(mounts, before);
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'new Elements are admitted in real frame batches and settled follows actual layout',
    (tester) async {
      final windows = [
        UtenAncestorRowWindowController<int>(),
        UtenAncestorRowWindowController<int>(),
      ];
      final mounts = <Duration, int>{};
      final rows = List.generate(1000, (index) => index);
      void record(int _) {
        final stamp = SchedulerBinding.instance.currentFrameTimeStamp;
        mounts.update(stamp, (count) => count + 1, ifAbsent: () => 1);
      }

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                for (final window in windows)
                  Expanded(
                    child: ListView(
                      children: [
                        UtenAncestorRowWindow<int>(
                          controller: window,
                          rows: rows,
                          viewportOnly: true,
                          rowBuilder: (_, row, _) => _MountProbe(row, record),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
      expect(mounts.values.fold(0, (a, b) => a + b), lessThanOrEqualTo(1));
      expect(windows.any((window) => window.isMounting), isTrue);
      expect(find.byType(LinearProgressIndicator), findsWidgets);
      for (final progress in find.byType(LinearProgressIndicator).evaluate()) {
        final blocker = progress.findAncestorWidgetOfExactType<IgnorePointer>();
        expect(blocker?.ignoring, isTrue);
      }
      var completed = false;
      final settled = Future.wait([
        for (final window in windows) window.settled,
      ]).then((_) => completed = true);
      expect(completed, isFalse);
      await tester.pumpAndSettle();
      await settled;
      expect(completed, isTrue);
      expect(windows.every((window) => !window.isMounting), isTrue);
      expect(mounts.length, greaterThan(1));
      expect(mounts.values.every((count) => count <= 1), isTrue);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(windows.every((window) => window.mountedRowCount >= 5), isTrue);
      expect(rows, hasLength(1000));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a source change abandons pending rows and settles only the current window',
    (tester) async {
      final window = UtenAncestorRowWindowController<int>();
      final source = ValueNotifier(List.generate(1000, (index) => index));
      addTearDown(source.dispose);
      final mounts = <Duration, int>{};
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [
                ValueListenableBuilder<List<int>>(
                  valueListenable: source,
                  builder: (_, rows, _) => UtenAncestorRowWindow<int>(
                    controller: window,
                    rows: rows,
                    viewportOnly: true,
                    rowBuilder: (_, row, _) => _MountProbe(row, (_) {
                      final stamp =
                          SchedulerBinding.instance.currentFrameTimeStamp;
                      mounts.update(
                        stamp,
                        (count) => count + 1,
                        ifAbsent: () => 1,
                      );
                    }),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      expect(window.isMounting, isTrue);
      var completed = false;
      final settled = window.settled.then((_) => completed = true);
      source.value = List.generate(1000, (index) => 2000 + index);
      // This test groups observations by timestamp; advance the fake clock to
      // distinguish frames. The zero-clock-frame regression is tested above.
      await tester.pump(const Duration(milliseconds: 1));
      expect(completed, isFalse);
      await tester.pumpAndSettle();
      await settled;
      expect(find.text('row-0'), findsNothing);
      expect(find.text('row-2000'), findsOneWidget);
      expect(window.isMounting, isFalse);
      expect(mounts.values.every((count) => count <= 1), isTrue);
      expect(tester.takeException(), isNull);
    },
  );
}
