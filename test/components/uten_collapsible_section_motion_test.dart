import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_collapsible_section.dart';
import 'package:uten_imp/core/performance/performance_tier.dart';
import 'package:uten_imp/core/theme/uten_anim.dart';
import 'package:uten_imp/shared/providers/performance_provider.dart';

class _Tier extends PerformanceNotifier {
  @override
  PerformanceTier build() => PerformanceTier.standard;

  void setTier(PerformanceTier tier) => state = tier;
}

void main() {
  testWidgets(
    'section retains its content and stops hidden tickers and lite motion',
    (tester) async {
      final container = ProviderContainer(
        overrides: [performanceProvider.overrideWith(_Tier.new)],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(
              body: UtenCollapsibleSection(
                title: '产品明细',
                child: SizedBox(key: Key('section-content'), height: 120),
              ),
            ),
          ),
        ),
      );
      final content = tester.element(find.byKey(const Key('section-content')));
      expect(TickerMode.valuesOf(content).enabled, isTrue);
      await tester.tap(find.text('产品明细'));
      await tester.pump();
      expect(TickerMode.valuesOf(content).enabled, isFalse);
      expect(
        tester.widget<AnimatedRotation>(find.byType(AnimatedRotation)).duration,
        UtenAnim.normal,
      );
      await tester.pump(UtenAnim.normal);
      (container.read(performanceProvider.notifier) as _Tier).setTier(
        PerformanceTier.lite,
      );
      await tester.pump();
      expect(
        tester.widget<AnimatedRotation>(find.byType(AnimatedRotation)).duration,
        Duration.zero,
      );
      expect(
        tester
            .widget<SizeTransition>(find.byType(SizeTransition))
            .sizeFactor
            .value,
        0,
      );
      await tester.tap(find.text('产品明细'));
      await tester.pump();
      expect(
        tester.element(find.byKey(const Key('section-content'))),
        same(content),
      );
      expect(TickerMode.valuesOf(content).enabled, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'system reduced motion disables section transitions outside provider scope',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: true),
            child: Scaffold(
              body: UtenCollapsibleSection(title: '明细', child: Text('详细内容')),
            ),
          ),
        ),
      );
      expect(
        tester.widget<AnimatedRotation>(find.byType(AnimatedRotation)).duration,
        Duration.zero,
      );
      expect(
        tester
            .widget<SizeTransition>(find.byType(SizeTransition))
            .sizeFactor
            .value,
        1,
      );
      await tester.tap(find.text('明细'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
