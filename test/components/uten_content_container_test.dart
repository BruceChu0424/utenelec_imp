import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_content_container.dart';
import 'package:uten_imp/components/layout/uten_page_layout.dart';

const _contentKey = Key('page-content');

void main() {
  testWidgets(
    'a pass-through shell does not claim margins that belong inside its page viewport',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1920, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: UtenContentContainer(
              key: Key('pass-through-shell'),
              applyGutter: false,
              selectable: false,
              child: UtenContentContainer(
                selectable: false,
                child: SizedBox.expand(key: _contentKey),
              ),
            ),
          ),
        ),
      );
      expect(
        tester.getRect(find.byKey(const Key('pass-through-shell'))).right,
        1920,
      );
      expect(tester.getRect(find.byKey(_contentKey)).left, 24);
      expect(tester.getRect(find.byKey(_contentKey)).right, 1896);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'business content and dashboard keep the same single page gutter',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1920, 900);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: UtenContentContainer(
              selectable: false,
              child: Column(
                children: [
                  Expanded(
                    child: SizedBox.expand(key: Key('dashboard-content')),
                  ),
                  Expanded(
                    child: UtenContentContainer(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: SizedBox.expand(key: _contentKey),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      final dashboard = tester.getRect(
        find.byKey(const Key('dashboard-content')),
      );
      final business = tester.getRect(find.byKey(_contentKey));
      expect(business.left, dashboard.left);
      expect(business.right, dashboard.right);
      expect(business.width, 1920 - 48);
      expect(business.height, dashboard.height - 24);
    },
  );

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
      for (final (width, gutter) in [
        (1366.0, 16.0),
        (1440.0, 24.0),
        (1920.0, 24.0),
        (2560.0, 24.0),
        (4600.0, 24.0),
        (1200.0, 16.0),
      ]) {
        parentWidth.value = width;
        await tester.pump();

        final content = tester.getRect(find.byKey(_contentKey));
        expect(content.width, closeTo(width - gutter - 24, 0.01));
        expect(content.left, closeTo(gutter, 0.01));
        expect(content.right, closeTo(width - 24, 0.01));
        expect(tester.takeException(), isNull);
      }
    });
  }

  test('page margins stay bounded in window pixels at each UI zoom', () {
    for (final zoom in [.85, 1.0, 1.5, 2.0]) {
      expect(
        UtenContentContainer.gutterForWidth(1200 / zoom, fontZoom: zoom) * zoom,
        closeTo(16, .01),
      );
      expect(
        UtenContentContainer.gutterForWidth(1800 / zoom, fontZoom: zoom) * zoom,
        closeTo(24, .01),
      );
    }
    expect(UtenContentContainer.gutterForWidth(40), 4);
  });

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
    final narrow = tester.getRect(find.byKey(_contentKey));
    expect(narrow.width, 320);
    expect(narrow.left, 16);
    expect(narrow.right, 336);
    expect(narrow.center.dx, 176);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a local panel retains symmetric16 rather than page end24', (
    tester,
  ) async {
    final parentWidth = ValueNotifier(360.0);
    addTearDown(parentWidth.dispose);
    await _pumpContainer(
      tester,
      parentWidth,
      const UtenPageScrollRoleScope.local(
        child: UtenContentContainer(
          selectable: false,
          child: SizedBox.expand(key: _contentKey),
        ),
      ),
    );
    final local = tester.getRect(find.byKey(_contentKey));
    expect(local.left, 16);
    expect(local.right, 344);
    expect(local.width, 328);
    expect(local.center.dx, 180);
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
