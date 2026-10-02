import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_content_container.dart';

const _contentKey = Key('page-content');

void main() {
  final variants = <String, Widget Function(Widget)>{
    'standard': (child) => UtenContentContainer(child: child),
    'narrow': (child) => UtenContentContainer.narrow(child: child),
    'wide': (child) => UtenContentContainer.wide(child: child),
  };

  for (final variant in variants.entries) {
    testWidgets('${variant.key} content follows parent width beyond old caps', (
      tester,
    ) async {
      final parentWidth = ValueNotifier(1440.0);
      addTearDown(parentWidth.dispose);
      await _pumpContainer(
        tester,
        parentWidth,
        variant.value(const SizedBox.expand(key: _contentKey)),
      );

      // Keep the MediaQuery viewport unchanged. Only the parent content area
      // changes, as it does when navigation collapses or a split pane resizes.
      // 4600dp also exceeds the wide variant's former 4000dp maximum.
      for (final width in [1440.0, 1920.0, 2560.0, 4600.0, 1200.0]) {
        parentWidth.value = width;
        await tester.pump();

        final content = tester.getRect(find.byKey(_contentKey));
        expect(content.width, closeTo(width - 64, 0.01));
        expect(content.left, closeTo(32, 0.01));
        expect(content.right, closeTo(width - 32, 0.01));
        expect(tester.takeException(), isNull);
      }
    });
  }

  testWidgets('an explicit width limit still fits narrow parents', (
    tester,
  ) async {
    final parentWidth = ValueNotifier(1600.0);
    addTearDown(parentWidth.dispose);
    await _pumpContainer(
      tester,
      parentWidth,
      const UtenContentContainer(
        maxWidth: 480,
        child: SizedBox.expand(key: _contentKey),
      ),
    );

    expect(tester.getSize(find.byKey(_contentKey)).width, 480);
    expect(tester.getCenter(find.byKey(_contentKey)).dx, 800);

    parentWidth.value = 360;
    await tester.pump();
    expect(tester.getSize(find.byKey(_contentKey)).width, 328);
    expect(tester.getCenter(find.byKey(_contentKey)).dx, 180);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpContainer(
  WidgetTester tester,
  ValueNotifier<double> parentWidth,
  Widget container,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(6000, 600);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: ValueListenableBuilder<double>(
            valueListenable: parentWidth,
            child: container,
            builder: (context, width, child) =>
                SizedBox(width: width, height: 240, child: child),
          ),
        ),
      ),
    ),
  );
}
