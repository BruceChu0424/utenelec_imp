import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_collapsible_content.dart';
import 'package:uten_imp/core/performance/performance_tier.dart';
import 'package:uten_imp/core/theme/uten_anim.dart';
import 'package:uten_imp/shared/providers/performance_provider.dart';

class _Tier extends PerformanceNotifier {
  @override
  PerformanceTier build() => PerformanceTier.standard;

  void setTier(PerformanceTier tier) => state = tier;
}

void main() {
  testWidgets('lazy content closes visibly and becomes inaccessible at once', (
    tester,
  ) async {
    final focus = FocusNode();
    addTearDown(focus.dispose);
    var expanded = false;
    var calls = 0;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return Column(
                children: [
                  UtenCollapsibleContent(
                    key: const Key('reveal'),
                    expanded: expanded,
                    maintainState: false,
                    child: SizedBox(
                      height: 120,
                      child: TextButton(
                        focusNode: focus,
                        onPressed: () => calls++,
                        child: const Text('内部操作'),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
    expect(find.text('内部操作'), findsNothing);
    update(() => expanded = true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final partial = tester.getSize(find.byKey(const Key('reveal'))).height;
    expect(partial, greaterThan(0));
    expect(partial, lessThan(120));
    await tester.pumpAndSettle();
    final element = tester.element(find.text('内部操作'));
    focus.requestFocus();
    await tester.pump();
    expect(focus.hasFocus, isTrue);
    update(() => expanded = false);
    await tester.pump();
    expect(find.text('内部操作'), findsOneWidget);
    expect(tester.element(find.text('内部操作')), same(element));
    expect(focus.hasFocus, isFalse);
    expect(TickerMode.valuesOf(element).enabled, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(calls, 0);
    await tester.pump(const Duration(milliseconds: 100));
    final closing = tester.getSize(find.byKey(const Key('reveal'))).height;
    expect(closing, greaterThan(0));
    expect(closing, lessThan(120));
    await tester.pumpAndSettle();
    expect(find.text('内部操作'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('switching to lite settles an active reveal immediately', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [performanceProvider.overrideWith(_Tier.new)],
    );
    addTearDown(container.dispose);
    var expanded = true;
    late StateSetter update;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return Column(
                  children: [
                    UtenCollapsibleContent(
                      key: const Key('reveal'),
                      expanded: expanded,
                      child: const SizedBox(height: 120, child: Text('保留内容')),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
    final element = tester.element(find.text('保留内容'));
    update(() => expanded = false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    (container.read(performanceProvider.notifier) as _Tier).setTier(
      PerformanceTier.lite,
    );
    await tester.pump();
    expect(tester.getSize(find.byKey(const Key('reveal'))).height, 0);
    update(() => expanded = true);
    await tester.pump();
    expect(tester.getSize(find.byKey(const Key('reveal'))).height, 120);
    expect(tester.element(find.text('保留内容')), same(element));
    await tester.pump(UtenAnim.normal);
    expect(tester.takeException(), isNull);
  });
}
