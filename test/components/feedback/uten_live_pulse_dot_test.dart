import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/feedback/uten_live_pulse_dot.dart';
import 'package:uten_imp/core/performance/performance_tier.dart';
import 'package:uten_imp/shared/providers/performance_provider.dart';

void main() {
  Finder circles() => find.descendant(
    of: find.byType(UtenLivePulseDot),
    matching: find.byType(Container),
  );

  Color dotColor(WidgetTester tester) =>
      (tester.widgetList<Container>(circles()).last.decoration!
              as BoxDecoration)
          .color!;

  testWidgets('one pulse per successful sample, then back to a plain dot', (
    tester,
  ) async {
    final harness = GlobalKey<_HarnessState>();
    await tester.pumpWidget(_harness(harness));
    expect(circles(), findsOneWidget, reason: '首帧不脉冲');

    harness.currentState!.sample();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(circles(), findsNWidgets(2), reason: '脉冲中多一圈光晕');

    await tester.pump(const Duration(milliseconds: 400));
    expect(circles(), findsOneWidget, reason: '一次性脉冲结束，不循环');

    await tester.pump(const Duration(seconds: 5));
    expect(circles(), findsOneWidget);
  });

  testWidgets('a rebuild without a new sample does not pulse', (tester) async {
    final harness = GlobalKey<_HarnessState>();
    await tester.pumpWidget(_harness(harness));
    harness.currentState!.rebuild();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(circles(), findsOneWidget);
  });

  for (final quiet in [_Quiet.lite, _Quiet.reducedMotion, _Quiet.offstage]) {
    testWidgets('$quiet keeps the dot completely static', (tester) async {
      final harness = GlobalKey<_HarnessState>();
      await tester.pumpWidget(_harness(harness, quiet: quiet));
      harness.currentState!.sample();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      expect(circles(), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 400));
      expect(circles(), findsOneWidget);
    });
  }

  testWidgets('stale samples turn the dot grey and stop the pulse', (
    tester,
  ) async {
    final harness = GlobalKey<_HarnessState>();
    await tester.pumpWidget(_harness(harness));
    final live = dotColor(tester);
    harness.currentState!.markStale();
    await tester.pump();
    final stale = dotColor(tester);
    expect(stale, isNot(live));
    expect(
      stale,
      Theme.of(
        tester.element(find.byType(UtenLivePulseDot)),
      ).colorScheme.outline,
    );
    harness.currentState!.sample();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(circles(), findsOneWidget);
  });

  testWidgets('the dot is decorative unless it is given a label', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final harness = GlobalKey<_HarnessState>();
    await tester.pumpWidget(_harness(harness));
    expect(find.bySemanticsLabel('正在刷新'), findsNothing);
    harness.currentState!.setLabel('正在刷新');
    await tester.pump();
    expect(find.bySemanticsLabel('正在刷新'), findsOneWidget);
    handle.dispose();
  });
}

enum _Quiet { none, lite, reducedMotion, offstage }

Widget _harness(GlobalKey<_HarnessState> key, {_Quiet quiet = _Quiet.none}) =>
    ProviderScope(
      overrides: [
        performanceProvider.overrideWith(
          quiet == _Quiet.lite ? _LiteTier.new : _StandardTier.new,
        ),
      ],
      child: _Harness(key: key, quiet: quiet),
    );

class _Harness extends StatefulWidget {
  const _Harness({super.key, required this.quiet});
  final _Quiet quiet;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  int _pulse = 0;
  bool _stale = false;
  String? _label;

  void sample() => setState(() => _pulse++);
  void rebuild() => setState(() {});
  void markStale() => setState(() => _stale = true);
  void setLabel(String label) => setState(() => _label = label);

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(
        disableAnimations: widget.quiet == _Quiet.reducedMotion,
      ),
      child: Scaffold(
        body: TickerMode(
          enabled: widget.quiet != _Quiet.offstage,
          child: Center(
            child: UtenLivePulseDot(
              pulse: _pulse,
              stale: _stale,
              semanticsLabel: _label,
            ),
          ),
        ),
      ),
    ),
  );
}

class _StandardTier extends PerformanceNotifier {
  @override
  PerformanceTier build() => PerformanceTier.standard;
}

class _LiteTier extends PerformanceNotifier {
  @override
  PerformanceTier build() => PerformanceTier.lite;
}
