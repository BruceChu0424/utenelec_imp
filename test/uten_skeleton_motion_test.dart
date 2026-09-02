import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/feedback/uten_skeleton.dart';
import 'package:uten_imp/core/performance/performance_tier.dart';
import 'package:uten_imp/shared/providers/performance_provider.dart';

void main() {
  testWidgets(
    'skeleton stops for TickerMode reduced motion and lite then resumes',
    (tester) async {
      final harnessKey = GlobalKey<_SkeletonHarnessState>();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            performanceProvider.overrideWith(_TestPerformanceNotifier.new),
          ],
          child: _SkeletonHarness(key: harnessKey),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      Color color() {
        final container = tester.widget<Container>(
          find.descendant(
            of: find.byKey(const Key('motion-aware-skeleton')),
            matching: find.byType(Container),
          ),
        );
        return (container.decoration! as BoxDecoration).color!;
      }

      final active = color();
      await tester.pump(const Duration(milliseconds: 200));
      expect(color(), isNot(active));

      harnessKey.currentState!.setTickerEnabled(false);
      await tester.pump();
      final tickerPaused = color();
      await tester.pump(const Duration(milliseconds: 300));
      expect(color(), tickerPaused);

      harnessKey.currentState!.setTickerEnabled(true);
      await tester.pump();
      final tickerResumed = color();
      await tester.pump(const Duration(milliseconds: 200));
      expect(color(), isNot(tickerResumed));

      harnessKey.currentState!.setDisableAnimations(true);
      await tester.pump();
      final reducedMotion = color();
      await tester.pump(const Duration(milliseconds: 300));
      expect(color(), reducedMotion);

      harnessKey.currentState!.setDisableAnimations(false);
      await tester.pump();
      final motionRestored = color();
      await tester.pump(const Duration(milliseconds: 200));
      expect(color(), isNot(motionRestored));

      final context = tester.element(
        find.byKey(const Key('motion-aware-skeleton')),
      );
      final notifier = ProviderScope.containerOf(
        context,
      ).read(performanceProvider.notifier);
      (notifier as _TestPerformanceNotifier).setTier(PerformanceTier.lite);
      await tester.pump();
      final lite = color();
      await tester.pump(const Duration(milliseconds: 300));
      expect(color(), lite);

      notifier.setTier(PerformanceTier.standard);
      await tester.pump();
      final standard = color();
      await tester.pump(const Duration(milliseconds: 200));
      expect(color(), isNot(standard));
    },
  );
}

class _SkeletonHarness extends StatefulWidget {
  const _SkeletonHarness({super.key});

  @override
  State<_SkeletonHarness> createState() => _SkeletonHarnessState();
}

class _SkeletonHarnessState extends State<_SkeletonHarness> {
  bool _tickerEnabled = true;
  bool _disableAnimations = false;

  void setTickerEnabled(bool enabled) =>
      setState(() => _tickerEnabled = enabled);

  void setDisableAnimations(bool disabled) =>
      setState(() => _disableAnimations = disabled);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: _disableAnimations),
        child: Scaffold(
          body: TickerMode(
            enabled: _tickerEnabled,
            child: const UtenSkeleton(
              key: Key('motion-aware-skeleton'),
              width: 120,
              height: 20,
            ),
          ),
        ),
      ),
    );
  }
}

class _TestPerformanceNotifier extends PerformanceNotifier {
  @override
  PerformanceTier build() => PerformanceTier.standard;

  void setTier(PerformanceTier tier) => state = tier;
}
