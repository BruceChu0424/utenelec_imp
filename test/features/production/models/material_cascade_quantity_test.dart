import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:uten_imp/features/production/models/material_cascade_quantity.dart';

void main() {
  test('quantity preview cost is measured separately from widget rendering', () {
    for (final size in [300, 1000, 10000]) {
      final watch = Stopwatch()..start();
      var total = 0.0;
      for (var i = 0; i < size; i++) {
        total += materialCascadeRequiredQty(
          parentOutputQty: 123.45,
          bomQty: 0.2,
          consumptionBasis: 'PER_PACKAGE',
          basisOutputQty: 12,
          allowPartialPackage: false,
          legacyPerProductQty: 1,
          legacyParentPerProductQty: 1,
        )!;
      }
      expect(total, closeTo(size * 2.2, 0.0001));
      debugPrint(
        'cascade pure decimal edges: $size rows / ${watch.elapsedMicroseconds}us',
      );
    }
  });
  test(
    'existing stock and supply cover the partial batch before new orders',
    () {
      double net(double gross, {bool allowOver = true}) =>
          materialCascadeNetQty(
            grossNeed: gross,
            snapshotNeed: 100,
            residual: 20,
            allowOver: allowOver,
          );
      expect(net(10), 0);
      expect(net(90), 10);
      expect(net(100), 20);
      expect(net(150), 70);
      expect(net(150, allowOver: false), 20);
    },
  );
  test(
    'manufacturing driver excludes final supply and preserves internal commitments',
    () {
      double output(double stock, double external, double internal) =>
          materialCascadeManufacturingQty(
            grossNeed: 100,
            allocatedAvailableQty: stock,
            externalFutureCoverageQty: external,
            internalCommittedOutputQty: internal,
          );
      expect(output(80, 0, 0), 20);
      expect(output(0, 80, 0), 20);
      expect(output(0, 0, 80), 100);
      expect(output(0, 80, 50), 50);
      expect(output(120, 0, 50), 0);
      expect(materialCascadeBaseOutputQty(0.1, 0.2), 0.02);
    },
  );
  double? required(
    double parent,
    double? edge, {
    String basis = 'PER_UNIT',
    double package = 1,
    bool partial = false,
  }) => materialCascadeRequiredQty(
    parentOutputQty: parent,
    bomQty: edge,
    consumptionBasis: basis,
    basisOutputQty: package,
    allowPartialPackage: partial,
    legacyPerProductQty: 3,
    legacyParentPerProductQty: 2,
  );

  test('decimal edges round upwards once without binary phantom units', () {
    expect(required(0.1, 0.2), 0.02);
    expect(required(0.0001, 0.0001), 0.0001);
    expect(required(3, 0.333333), 1);
    expect(required(0, 3), 0);
    expect(required(1000000, 0.000001), 1);
  });

  test(
    'whole packages and fixed batches round before multiplying the edge',
    () {
      expect(required(5, 3, basis: 'PER_PACKAGE', package: 4), 6);
      expect(required(4, 3, basis: 'PER_PACKAGE', package: 4), 3);
      expect(
        required(5, 3, basis: 'PER_PACKAGE', package: 4, partial: true),
        3.75,
      );
      expect(
        required(5, 3, basis: 'FIXED_BATCH', package: 4, partial: true),
        6,
      );
      expect(
        required(1, 1, basis: 'PER_PACKAGE', package: 3, partial: true),
        0.3334,
      );
    },
  );

  test('each rounded child output drives the next edge', () {
    final child = required(5, 3, basis: 'PER_PACKAGE', package: 4)!;
    expect(required(child, 0.2, basis: 'FIXED_BATCH', package: 4), 0.4);
  });

  test(
    'old linear payload falls back but missing nonlinear rules fail closed',
    () {
      expect(required(4, null), 6);
      expect(required(4, null, basis: 'FIXED_BATCH'), isNull);
      expect(required(4, 3, basis: 'UNKNOWN'), isNull);
      expect(required(4, 3, basis: 'PER_PACKAGE', package: 0), isNull);
      expect(required(double.infinity, 1), isNull);
    },
  );
}
