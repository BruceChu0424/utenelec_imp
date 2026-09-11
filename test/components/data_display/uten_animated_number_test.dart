import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/data_display/uten_animated_number.dart';
import 'package:uten_imp/core/performance/performance_tier.dart';
import 'package:uten_imp/shared/providers/performance_provider.dart';

void main() {
  String shown(WidgetTester tester) =>
      tester.widget<Text>(find.byType(Text)).data!;

  testWidgets('rich rolls once from the old value to the new one', (
    tester,
  ) async {
    await tester.pumpWidget(_harness(10, tier: PerformanceTier.rich));
    expect(shown(tester), '10');
    await tester.pumpWidget(_harness(90, tier: PerformanceTier.rich));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    final mid = double.parse(shown(tester));
    expect(mid, greaterThan(10));
    expect(mid, lessThan(90));
    await tester.pumpAndSettle();
    expect(shown(tester), '90');
  });

  for (final tier in [PerformanceTier.lite, PerformanceTier.standard]) {
    testWidgets('$tier shows the final value with no intermediate frame', (
      tester,
    ) async {
      await tester.pumpWidget(_harness(10, tier: tier));
      await tester.pumpWidget(_harness(90, tier: tier));
      await tester.pump();
      expect(shown(tester), '90');
    });
  }

  testWidgets('system reduced motion overrides the rich tier', (tester) async {
    await tester.pumpWidget(
      _harness(10, tier: PerformanceTier.rich, reducedMotion: true),
    );
    await tester.pumpWidget(
      _harness(90, tier: PerformanceTier.rich, reducedMotion: true),
    );
    await tester.pump();
    expect(shown(tester), '90');
  });

  testWidgets('a missing value shows the placeholder and never rolls from 0', (
    tester,
  ) async {
    await tester.pumpWidget(_harness(null, tier: PerformanceTier.rich));
    expect(shown(tester), '—');
    await tester.pumpWidget(_harness(90, tier: PerformanceTier.rich));
    await tester.pump();
    expect(shown(tester), '90');
  });

  testWidgets('numbers stay tabular and honour the custom formatter', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        1234.5,
        tier: PerformanceTier.standard,
        format: (value) => '${value.toStringAsFixed(2)} ms',
      ),
    );
    expect(shown(tester), '1234.50 ms');
    expect(
      tester.widget<Text>(find.byType(Text)).style!.fontFeatures,
      contains(const FontFeature.tabularFigures()),
    );
  });
}

Widget _harness(
  double? value, {
  required PerformanceTier tier,
  bool reducedMotion = false,
  UtenNumberFormatter? format,
}) => ProviderScope(
  overrides: [performanceProvider.overrideWith(() => _FixedTier(tier))],
  child: MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: reducedMotion),
      child: Scaffold(
        body: UtenAnimatedNumber(value: value, format: format),
      ),
    ),
  ),
);

class _FixedTier extends PerformanceNotifier {
  _FixedTier(this.tier);
  final PerformanceTier tier;

  @override
  PerformanceTier build() => tier;
}
