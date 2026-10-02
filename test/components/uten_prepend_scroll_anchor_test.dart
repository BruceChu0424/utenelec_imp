import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_prepend_scroll_anchor.dart';

FixedScrollMetrics _metrics({double pixels = 20, double maximum = 100}) =>
    FixedScrollMetrics(
      minScrollExtent: 0,
      maxScrollExtent: maximum,
      pixels: pixels,
      viewportDimension: 400,
      axisDirection: AxisDirection.down,
      devicePixelRatio: 1,
    );

double _adjust(
  ScrollPhysics physics, {
  double oldPixels = 20,
  double pixels = 20,
  double maximum = 100,
}) => physics.adjustPositionForNewDimensions(
  oldPosition: _metrics(pixels: oldPixels),
  newPosition: _metrics(pixels: pixels, maximum: maximum),
  isScrolling: false,
  velocity: 0,
);

void main() {
  test('measured extent corrects current pixels exactly once', () {
    final anchor = UtenPrependScrollAnchor();
    final physics = anchor.wrap(const ClampingScrollPhysics());
    anchor.prepare(83.5);
    expect(anchor.pending, isTrue);

    // Use the current position even if it moved since the previous metrics.
    expect(_adjust(physics, pixels: 27), 110.5);
    expect(anchor.pending, isFalse);
    expect(_adjust(physics, pixels: 110.5, maximum: 300), 110.5);
  });

  test('does not clamp measured height to a lazy extent estimate', () {
    final anchor = UtenPrependScrollAnchor()..prepare(1000);
    final physics = anchor.wrap(const ClampingScrollPhysics());
    expect(_adjust(physics, maximum: 80), 1020);
    expect(anchor.pending, isFalse);
  });

  test('applyTo retains correction state and the parent physics chain', () {
    final anchor = UtenPrependScrollAnchor();
    final original = anchor.wrap(const ClampingScrollPhysics());
    final applied = original.applyTo(const AlwaysScrollableScrollPhysics());
    expect(applied.parent, isA<ClampingScrollPhysics>());
    expect(applied.parent!.parent, isA<AlwaysScrollableScrollPhysics>());
    expect(applied.shouldAcceptUserOffset(_metrics()), isTrue);

    anchor.prepare(45);
    expect(_adjust(applied), 65);
    expect(anchor.pending, isFalse);
    expect(_adjust(original), 20);
  });

  test('reset cancels a stale correction and restores parent behavior', () {
    final anchor = UtenPrependScrollAnchor();
    final physics = anchor.wrap(const _ParentAdjustment());
    anchor.prepare(200);
    anchor.reset();
    expect(anchor.pending, isFalse);
    expect(_adjust(physics), 27);

    anchor.prepare(200);
    anchor.prepare(15);
    expect(_adjust(physics), 35);
    expect(_adjust(physics), 27);
  });

  test('zero cancels pending work and invalid measurements are rejected', () {
    final anchor = UtenPrependScrollAnchor()..prepare(20);
    anchor.prepare(0);
    expect(anchor.pending, isFalse);
    for (final value in [-1.0, double.infinity, double.nan]) {
      expect(() => anchor.prepare(value), throwsArgumentError);
      expect(anchor.pending, isFalse);
    }
  });
}

class _ParentAdjustment extends ScrollPhysics {
  const _ParentAdjustment();

  @override
  double adjustPositionForNewDimensions({
    required ScrollMetrics oldPosition,
    required ScrollMetrics newPosition,
    required bool isScrolling,
    required double velocity,
  }) => newPosition.pixels + 7;
}
