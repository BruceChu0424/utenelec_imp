import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/layout/uten_adaptive_hierarchy_pane.dart';
import 'package:uten_imp/components/layout/uten_split_view.dart';

void main() {
  for (final tooltipInLeading in [true, false]) {
    for (final show in [false, true]) {
      testWidgets('minimal ${tooltipInLeading ? 'leading' : 'trailing'} '
          '${show ? 'visible' : 'closed'} Tooltip survives real split boundary',
          (tester) async {
        SharedPreferences.setMockInitialValues({});
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(1600, 1000);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final width = ValueNotifier<double>(1280);
        addTearDown(width.dispose);
        final tooltipKey = GlobalKey<TooltipState>();
        Widget pane(bool leading) => Align(
          alignment: Alignment.topLeft,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (leading == tooltipInLeading)
                Tooltip(
                  key: tooltipKey,
                  message: 'retained tooltip overlay',
                  child: const Text('source control'),
                ),
              if (!leading)
                const TextField(key: ValueKey('unsaved-input')),
            ],
          ),
        );
        await tester.pumpWidget(MaterialApp(
          theme: ThemeData(platform: TargetPlatform.windows),
          home: Scaffold(
            body: ValueListenableBuilder<double>(
              valueListenable: width,
              builder: (_, value, child) => Align(
                alignment: Alignment.topLeft,
                child: SizedBox(width: value, child: child),
              ),
              child: UtenSplitView(
                // Real category pages use 840. The default 600 would make
                // 1280 -> 714 remain split and produce an invalid green probe.
                minTwoPaneWidth: 840,
                leading: pane(true),
                trailing: pane(false),
              ),
            ),
          ),
        ));
        await tester.pumpAndSettle();
        expect(tester.widget<UtenAdaptiveHierarchyPane>(
            find.byType(UtenAdaptiveHierarchyPane)).canSplit, isTrue);
        await tester.enterText(find.byKey(const ValueKey('unsaved-input')),
            'unsaved exact 7.125');
        if (show) {
          expect(tooltipKey.currentState!.ensureTooltipVisible(), isTrue);
          await tester.pumpAndSettle();
          expect(find.text('retained tooltip overlay'), findsOneWidget);
        }
        width.value = 714;
        await tester.pumpAndSettle();
        expect(tester.widget<UtenAdaptiveHierarchyPane>(
            find.byType(UtenAdaptiveHierarchyPane)).canSplit, isFalse);
        expect(tester.takeException(), isNull,
            reason: 'a retained Tooltip must not reactivate an unrelated '
                'deferred render child during parent LayoutBuilder layout');
        expect(find.text('unsaved exact 7.125'), findsOneWidget);
      });
    }
  }
}
