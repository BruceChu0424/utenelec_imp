import 'dart:math' as math;

/// Internal to the ancestor row window; intentionally not exported by its API.
/// Stores measured deltas from one estimate, using at most the next power-of-two
/// number of cells. Prefixes, measured updates and offset lookup are logarithmic.
class RowExtentIndex {
  RowExtentIndex({this.onWork});

  /// Presentation geometry only, much smaller than the window's .5px measure
  /// threshold. Never used to accept negative input heights/business values.
  static const geometryEpsilon = 1e-7;

  /// Optional numeric diagnostics only. Counts actual tree cells visited/copied.
  final void Function(String operation, int cells)? onWork;
  List<double> _tree = [0];
  int _count = 0;
  double _estimate = 0;
  double _total = 0;

  int get rowCount => _count;
  int get capacity => _tree.length - 1;
  int get length => _count + 1;
  double get last => _total;
  double get estimate => _estimate;

  void reset({
    required int count,
    required double estimate,
    required Iterable<double> deltas,
  }) {
    RangeError.checkNotNegative(count, 'count');
    _validHeight(estimate);
    var reserved = count == 0 ? 0 : 1;
    while (reserved < count) {
      reserved *= 2;
    }
    _tree = List<double>.filled(reserved + 1, 0);
    _count = count;
    _estimate = estimate;
    var index = 0;
    for (final delta in deltas) {
      if (index >= count) throw StateError('Too many row extents');
      _validHeight(estimate + delta);
      _tree[++index] = delta;
    }
    if (index != count) throw StateError('Missing row extents');
    for (var i = 1; i <= reserved; i++) {
      final parent = i + (i & -i);
      if (parent <= reserved) _tree[parent] += _tree[i];
    }
    onWork?.call('resetCells', reserved);
    _total = _geometry(estimate * count + _sum(count));
  }

  /// The prefix [0, common) is unchanged; old suffix deltas are removed before
  /// its rows move or disappear. Capacity shrinks only on a full reset.
  void replaceTail({
    required int common,
    required int count,
    required Iterable<double> deltas,
  }) {
    RangeError.checkValueInInterval(
      common,
      0,
      math.min(_count, count),
      'common',
    );
    _reserve(count);
    for (var index = common; index < _count; index++) {
      final previous = _sum(index + 1) - _sum(index);
      if (previous != 0) _add(index, -previous);
    }
    _count = common;
    for (final delta in deltas) {
      if (_count >= count) throw StateError('Too many appended row extents');
      _validHeight(_estimate + delta);
      if (delta != 0) _add(_count, delta);
      _count++;
    }
    if (_count != count) throw StateError('Missing appended row extents');
    _total = _geometry(_estimate * count + _sum(count));
  }

  double operator [](int prefixLength) {
    RangeError.checkValueInInterval(prefixLength, 0, _count, 'prefixLength');
    if (prefixLength == _count) return _total;
    return _geometry(prefixLength * _estimate + _sum(prefixLength));
  }

  void setHeight(int index, double height) {
    RangeError.checkValidIndex(index, this, 'index', _count);
    _validHeight(height);
    final oldDelta = _sum(index + 1) - _sum(index);
    final difference = height - _estimate - oldDelta;
    if (difference.abs() <= geometryEpsilon) return;
    _add(index, difference);
    // Re-read one logarithmic prefix instead of carrying rounding error from
    // every historical measurement into a separate running total.
    _total = _geometry(_estimate * _count + _sum(_count));
  }

  /// Same boundary as the original prefix binary search: an offset exactly on
  /// a row's end selects the next row, and zero-height rows are skipped.
  int rowAt(double offset) {
    if (_count == 0) return 0;
    var index = 0;
    var before = 0.0;
    var bit = capacity;
    var visits = 0;
    while (bit > 0) {
      final next = index + bit;
      if (next <= _count) {
        visits++;
        final through = before + bit * _estimate + _tree[next];
        if (through <= offset + geometryEpsilon) {
          index = next;
          before = through;
        }
      }
      bit ~/= 2;
    }
    onWork?.call('lookupCells', visits);
    return math.min(index, _count - 1);
  }

  double _sum(int count) {
    var sum = 0.0;
    var visits = 0;
    for (var index = count; index > 0; index -= index & -index) {
      sum += _tree[index];
      visits++;
    }
    onWork?.call('prefixCells', visits);
    return sum;
  }

  void _add(int row, double delta) {
    var visits = 0;
    for (var index = row + 1; index <= capacity; index += index & -index) {
      _tree[index] += delta;
      visits++;
    }
    onWork?.call('updateCells', visits);
  }

  void _reserve(int count) {
    if (count <= capacity) return;
    final old = _tree;
    final oldCapacity = capacity;
    final previousTotal = _sum(_count);
    var reserved = math.max(1, oldCapacity);
    while (reserved < count) {
      reserved *= 2;
    }
    final grown = List<double>.filled(reserved + 1, 0);
    grown.setRange(0, old.length, old);
    for (
      var boundary = math.max(1, oldCapacity * 2);
      boundary <= reserved;
      boundary *= 2
    ) {
      grown[boundary] = previousTotal;
    }
    _tree = grown;
    onWork?.call('growCopiedCells', old.length);
  }

  static void _validHeight(double value) {
    if (!value.isFinite || value < 0) {
      throw ArgumentError.value(
        value,
        'height',
        'Expected finite nonnegative extent',
      );
    }
  }

  static double _geometry(double value) {
    if (value.isFinite && value.abs() <= geometryEpsilon) return 0;
    _validHeight(value);
    return value;
  }
}
