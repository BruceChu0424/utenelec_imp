import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/responsive/display_zoom.dart';

const _window = Size(390, 1000);

Future<void> _pumpZoom(WidgetTester tester, double factor, Widget child) async {
  tester.view.physicalSize = _window;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      builder: (_, routed) =>
          UtenDisplayZoomBox(fontFactor: factor, child: routed!),
      home: Scaffold(body: child),
    ),
  );
  await tester.pump();
}

void main() {
  for (final factor in [0.75, 0.85, 1.0, 2.0]) {
    testWidgets(
      '$factor: all four window corners receive taps and drag positions',
      (tester) async {
        final taps = <String, int>{};
        final deltas = <String, Offset>{};
        final positions = <String, Offset>{};
        await _pumpZoom(
          tester,
          factor,
          Stack(
            children: [
              for (final corner in [
                'top-left',
                'top-right',
                'bottom-left',
                'bottom-right',
              ])
                Positioned(
                  left: corner.endsWith('left') ? 0 : null,
                  right: corner.endsWith('right') ? 0 : null,
                  top: corner.startsWith('top') ? 0 : null,
                  bottom: corner.startsWith('bottom') ? 0 : null,
                  child: GestureDetector(
                    key: ValueKey(corner),
                    behavior: HitTestBehavior.opaque,
                    onTap: () => taps.update(
                      corner,
                      (count) => count + 1,
                      ifAbsent: () => 1,
                    ),
                    onPanUpdate: (details) {
                      deltas.update(
                        corner,
                        (delta) => delta + details.delta,
                        ifAbsent: () => details.delta,
                      );
                      positions[corner] = details.localPosition;
                    },
                    child: const SizedBox(width: 64, height: 64),
                  ),
                ),
            ],
          ),
        );
        for (final corner in [
          'top-left',
          'top-right',
          'bottom-left',
          'bottom-right',
        ]) {
          final rect = tester.getRect(find.byKey(ValueKey(corner)));
          final at = Offset(
            corner.endsWith('right') ? _window.width - 2 : 2,
            corner.startsWith('bottom') ? _window.height - 2 : 2,
          );
          expect(
            rect.contains(at),
            isTrue,
            reason: '$corner is visibly within the window',
          );
          await tester.tapAt(at);
          expect(
            taps[corner],
            1,
            reason: '$corner must receive its visible edge tap',
          );
          final movement = Offset(
            corner.endsWith('right') ? -24 : 24,
            corner.startsWith('bottom') ? -24 : 24,
          );
          final drag = await tester.startGesture(at);
          await drag.moveBy(movement);
          await tester.pump();
          await drag.moveBy(movement);
          await tester.pump();
          await drag.up();
          expect(deltas[corner]!.dx.abs(), greaterThan(0));
          expect(deltas[corner]!.dy.abs(), greaterThan(0));
          final expectedLocal = (at + movement * 2 - rect.topLeft) / factor;
          expect(positions[corner]!.dx, closeTo(expectedLocal.dx, 1e-6));
          expect(positions[corner]!.dy, closeTo(expectedLocal.dy, 1e-6));
          expect(
            taps[corner],
            1,
            reason: 'drag must not invoke the tap callback',
          );
        }
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '$factor: scroll started at the visible bottom-right reaches content',
      (tester) async {
        final controller = ScrollController();
        addTearDown(controller.dispose);
        await _pumpZoom(
          tester,
          factor,
          SingleChildScrollView(
            controller: controller,
            child: SizedBox(
              width: double.infinity,
              height: 3000 / factor,
              child: const Align(
                alignment: Alignment.topLeft,
                child: Text('Scrollable content'),
              ),
            ),
          ),
        );
        final start = Offset(_window.width - 2, _window.height - 2);
        final gesture = await tester.startGesture(start);
        await gesture.moveBy(const Offset(0, -24));
        await tester.pump();
        final before = controller.offset;
        await gesture.moveBy(const Offset(0, -80));
        await tester.pump();
        expect(controller.offset, greaterThan(before));
        expect((controller.offset - before) * factor, closeTo(80, 0.001));
        await gesture.up();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '$factor: bottom-right menu opens inside the window and selects once',
      (tester) async {
        final selections = <String>[];
        await _pumpZoom(
          tester,
          factor,
          Align(
            alignment: Alignment.bottomRight,
            child: PopupMenuButton<String>(
              key: const ValueKey('edge-menu'),
              onSelected: selections.add,
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'chosen', child: Text('Edge action')),
              ],
              child: const SizedBox(width: 64, height: 64),
            ),
          ),
        );
        await tester.tapAt(Offset(_window.width - 2, _window.height - 2));
        await tester.pumpAndSettle();
        final action = find.text('Edge action');
        expect(action, findsOneWidget);
        final rect = tester.getRect(action);
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(_window.width));
        expect(rect.top, greaterThanOrEqualTo(0));
        expect(rect.bottom, lessThanOrEqualTo(_window.height));
        await tester.tap(action);
        await tester.pumpAndSettle();
        expect(selections, ['chosen']);
        expect(action, findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
