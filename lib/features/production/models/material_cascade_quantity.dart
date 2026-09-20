/// Existing stock and committed supply cover the selected batch before any new
/// order. The caller aggregates paths of one action group before applying this.
double materialCascadeNetQty({
  required double grossNeed,
  required double snapshotNeed,
  required double residual,
  required bool allowOver,
}) {
  final coverage = (snapshotNeed - residual).clamp(0.0, double.infinity);
  final net = (grossNeed - coverage).clamp(0.0, double.infinity);
  return allowOver ? net : net.clamp(0.0, residual.clamp(0.0, double.infinity));
}

/// The lower BOM belongs to output still to be manufactured. Final external
/// supply can cover that output; an internal manufacturing commitment keeps its
/// own material responsibility, even when it is not a new order this time.
double materialCascadeManufacturingQty({
  required double grossNeed,
  required double allocatedAvailableQty,
  required double externalFutureCoverageQty,
  required double internalCommittedOutputQty,
}) {
  final shortage = (grossNeed - allocatedAvailableQty).clamp(
    0.0,
    double.infinity,
  );
  final uncovered = (shortage - externalFutureCoverageQty).clamp(
    0.0,
    double.infinity,
  );
  final committed = internalCommittedOutputQty.clamp(0.0, shortage);
  return uncovered > committed ? uncovered : committed;
}

double materialCascadeBaseOutputQty(double quantity, double unitRate) =>
    (_QuantityFraction.from(quantity) * _QuantityFraction.from(unitRate)).value;

/// Client preview of MaterialConsumptionMath: round each BOM edge upwards to
/// four base-unit decimals, before driving the next edge. Submission is still
/// checked against the current analysis by the server.
double? materialCascadeRequiredQty({
  required double parentOutputQty,
  required double? bomQty,
  required String? consumptionBasis,
  required double? basisOutputQty,
  required bool? allowPartialPackage,
  required double legacyPerProductQty,
  required double legacyParentPerProductQty,
}) {
  if (!parentOutputQty.isFinite || parentOutputQty < 0) return null;
  if (parentOutputQty == 0) return 0;
  final basis = consumptionBasis?.trim().toUpperCase() ?? 'PER_UNIT';
  if (!const {'PER_UNIT', 'PER_PACKAGE', 'FIXED_BATCH'}.contains(basis)) {
    return null;
  }
  final parent = _QuantityFraction.from(parentOutputQty);
  final edge = bomQty;
  if (edge == null || !edge.isFinite || edge <= 0) {
    // Only the old linear payload can be reconstructed from cumulative rates.
    // A missing package edge is not safe to estimate as an average.
    if (basis != 'PER_UNIT' ||
        !legacyPerProductQty.isFinite ||
        legacyPerProductQty <= 0 ||
        !legacyParentPerProductQty.isFinite ||
        legacyParentPerProductQty <= 0) {
      return null;
    }
    return (parent *
            _QuantityFraction.from(legacyPerProductQty) /
            _QuantityFraction.from(legacyParentPerProductQty))
        .ceilQuantity();
  }
  final material = _QuantityFraction.from(edge);
  if (basis == 'PER_UNIT') return (parent * material).ceilQuantity();
  if (basisOutputQty == null ||
      !basisOutputQty.isFinite ||
      basisOutputQty <= 0) {
    return null;
  }
  final batches = parent / _QuantityFraction.from(basisOutputQty);
  return ((basis == 'PER_PACKAGE' && allowPartialPackage == true
              ? batches
              : _QuantityFraction(batches.ceil(), BigInt.one)) *
          material)
      .ceilQuantity();
}

/// JSON quantities are decimals. Integer fractions avoid inventing an extra
/// 0.0001 from a binary result such as 0.1 * 0.2 = 0.020000000000000004.
class _QuantityFraction {
  const _QuantityFraction(this.numerator, this.denominator);

  factory _QuantityFraction.from(double value) {
    final scientific = value.toString().toLowerCase().split('e');
    final parts = scientific.first.split('.');
    final fraction = parts.length == 1 ? '' : parts[1];
    final exponent = scientific.length == 1 ? 0 : int.parse(scientific[1]);
    final scale = fraction.length - exponent;
    final coefficient = BigInt.parse('${parts.first}$fraction');
    return scale < 0
        ? _QuantityFraction(
            coefficient * BigInt.from(10).pow(-scale),
            BigInt.one,
          )
        : _QuantityFraction(coefficient, BigInt.from(10).pow(scale));
  }

  final BigInt numerator;
  final BigInt denominator;
  double get value => numerator.toDouble() / denominator.toDouble();
  _QuantityFraction operator *(_QuantityFraction other) => _QuantityFraction(
    numerator * other.numerator,
    denominator * other.denominator,
  );
  _QuantityFraction operator /(_QuantityFraction other) => _QuantityFraction(
    numerator * other.denominator,
    denominator * other.numerator,
  );
  BigInt ceil() => (numerator + denominator - BigInt.one) ~/ denominator;
  double ceilQuantity() =>
      _QuantityFraction(
        numerator * BigInt.from(10000),
        denominator,
      ).ceil().toDouble() /
      10000;
}
