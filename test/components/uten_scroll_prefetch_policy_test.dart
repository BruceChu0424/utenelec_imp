import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_scroll_prefetch_policy.dart';

FixedScrollMetrics _metrics({
  double? viewport = 600,
  double? pixels = 2000,
  double? maximum = 5000,
  AxisDirection axis = AxisDirection.down,
}) => FixedScrollMetrics(
  minScrollExtent: 0,
  maxScrollExtent: maximum,
  pixels: pixels,
  viewportDimension: viewport,
  axisDirection: axis,
  devicePixelRatio: 1,
);

void main() {
  for (final zoom in [.85, 1.0, 1.5, 2.0]) {
    test(
      'look-ahead and both boundary distances use window units at $zoom',
      () {
        final normal = _metrics(viewport: 600 / zoom);
        expect(
          UtenScrollPrefetchPolicy.distanceOf(normal, fontZoom: zoom) * zoom,
          closeTo(450, .000001),
        );
        expect(
          UtenScrollPrefetchPolicy.distanceOf(
                _metrics(viewport: 100 / zoom),
                fontZoom: zoom,
              ) *
              zoom,
          closeTo(200, .000001),
        );
        expect(
          UtenScrollPrefetchPolicy.distanceOf(
                _metrics(viewport: 3000 / zoom),
                fontZoom: zoom,
              ) *
              zoom,
          closeTo(1200, .000001),
        );
        // Begin reading before the loaded edge is reached, in either direction.
        for (final prepend in [false, true]) {
          for (final remaining in [440.0, 460.0]) {
            final position = _metrics(
              viewport: 600 / zoom,
              maximum: 5000 / zoom,
              pixels: (prepend ? remaining : 5000 - remaining) / zoom,
            );
            expect(
              UtenScrollPrefetchPolicy.isNearEdge(
                position,
                prepend: prepend,
                fontZoom: zoom,
              ),
              remaining == 440,
            );
            expect(position.extentBefore, greaterThan(0));
            expect(position.extentAfter, greaterThan(0));
          }
        }
      },
    );
  }

  test('unready, invalid and horizontal metrics never request a page', () {
    for (final metrics in [
      _metrics(viewport: null),
      _metrics(pixels: null),
      _metrics(maximum: null),
      _metrics(pixels: double.nan),
      _metrics(maximum: double.infinity),
      _metrics(viewport: double.infinity),
      _metrics(pixels: 0, axis: AxisDirection.right),
    ]) {
      for (final prepend in [false, true]) {
        expect(
          UtenScrollPrefetchPolicy.isNearEdge(metrics, prepend: prepend),
          isFalse,
        );
      }
    }
  });

  testWidgets('SDK updates without dragDetails retain both scroll directions', (
    tester,
  ) async {
    late BuildContext notificationContext;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Builder(
          builder: (context) {
            notificationContext = context;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    final metrics = _metrics();
    for (final delta in [-32.0, 32.0]) {
      final update = ScrollUpdateNotification(
        metrics: metrics,
        context: notificationContext,
        scrollDelta: delta,
      );
      expect(update.dragDetails, isNull);
      expect(UtenScrollPrefetchPolicy.directionOf(update), delta.sign.toInt());
      expect(
        UtenScrollPrefetchPolicy.directionOf(
          OverscrollNotification(
            metrics: metrics,
            context: notificationContext,
            overscroll: delta,
          ),
        ),
        delta.sign.toInt(),
      );
    }
    for (final delta in [0.0, double.nan, double.infinity]) {
      expect(
        UtenScrollPrefetchPolicy.directionOf(
          ScrollUpdateNotification(
            metrics: metrics,
            context: notificationContext,
            scrollDelta: delta,
          ),
        ),
        0,
      );
    }
    expect(
      UtenScrollPrefetchPolicy.directionOf(
        ScrollUpdateNotification(
          metrics: _metrics(axis: AxisDirection.right),
          context: notificationContext,
          scrollDelta: 32,
        ),
      ),
      0,
    );
    expect(
      UtenScrollPrefetchPolicy.directionOf(
        ScrollStartNotification(metrics: metrics, context: notificationContext),
      ),
      0,
    );
    expect(
      UtenScrollPrefetchPolicy.directionOf(
        ScrollEndNotification(metrics: metrics, context: notificationContext),
      ),
      0,
    );
  });
}
