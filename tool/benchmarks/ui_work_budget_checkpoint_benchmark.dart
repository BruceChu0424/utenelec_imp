// Reproducible microbenchmark; does not modify the production budget or fixture.
// Native: dart run tool/benchmarks/ui_work_budget_checkpoint_benchmark.dart
// Web: dart compile js -O2 -o <output.js> <this file>, load from a local page.
// Keep this separate from end-to-end table/transport/IME acceptance.
import 'dart:async';
import 'dart:convert';

import 'package:uten_imp/core/performance/ui_work_budget.dart';

class _FastPrototype {
  _FastPrototype({
    required this.current,
    required this.slice,
    required this.maxItems,
  });
  final bool Function()? current;
  final Duration slice;
  final int maxItems;
  final _clock = Stopwatch()..start();
  var _items = 0;
  void ensureCurrent() {
    if (current?.call() == false) throw const UiWorkCancelled();
  }

  Future<void>? checkpointIfNeeded() {
    ensureCurrent();
    _items++;
    if (_items < maxItems && _clock.elapsed < slice) {
      return null;
    }
    debugUiWorkSliceObserver?.call('presentation', _clock.elapsed);
    return _yield();
  }

  Future<void> _yield() async {
    await Future<void>.delayed(Duration.zero);
    ensureCurrent();
    _items = 0;
    _clock.reset();
  }
}

Future<Map<String, Object>> _sample(String mode, int rows) async {
  var checks = 0, yields = 0, checksum = 0;
  bool current() {
    checks++;
    return true;
  }

  final clock = Stopwatch();
  debugUiWorkSliceObserver = (_, _) => yields++;
  if (mode == 'original-await') {
    final budget = UiWorkBudget(isCurrent: current);
    clock.start();
    for (var row = 0; row < rows; row++) {
      checksum = (checksum + (row ^ (row >> 3))) % 1000000007;
      await budget.checkpoint();
    }
    budget.ensureCurrent();
  } else {
    final budget = _FastPrototype(
      current: current,
      slice: const Duration(milliseconds: 4),
      maxItems: 256,
    );
    clock.start();
    for (var row = 0; row < rows; row++) {
      checksum = (checksum + (row ^ (row >> 3))) % 1000000007;
      final pause = budget.checkpointIfNeeded();
      if (pause != null) await pause;
    }
    // Preserve a publication fence for retirement queued by the last converter.
    await Future<void>.value();
    budget.ensureCurrent();
  }
  clock.stop();
  debugUiWorkSliceObserver = null;
  return {
    'mode': mode,
    'rows': rows,
    'micros': clock.elapsedMicroseconds,
    'realTimerYields': yields,
    'currentChecks': checks,
    'checksum': checksum,
  };
}

Future<void> main() async {
  const rounds = int.fromEnvironment('CHECKPOINT_ROUNDS', defaultValue: 5);
  final sizes = <int>{
    100000,
    const int.fromEnvironment('CHECKPOINT_LARGE_ROWS', defaultValue: 1000000),
  };
  for (var warmup = 0; warmup < 3; warmup++) {
    await _sample('original-await', 25000);
    await _sample('nullable-fast', 25000);
  }
  final samples = <Map<String, Object>>[];
  for (final rows in sizes) {
    for (var round = 0; round < rounds; round++) {
      final modes = round.isEven
          ? ['original-await', 'nullable-fast']
          : ['nullable-fast', 'original-await'];
      final pair = <Map<String, Object>>[];
      for (final mode in modes) {
        final result = await _sample(mode, rows);
        result['round'] = round;
        samples.add(result);
        pair.add(result);
      }
      if (pair[0]['checksum'] != pair[1]['checksum']) {
        throw StateError('Microbenchmark work differs');
      }
    }
  }
  final medians = <Map<String, Object>>[];
  for (final rows in sizes) {
    int median(String mode) {
      final values =
          samples
              .where(
                (sample) => sample['rows'] == rows && sample['mode'] == mode,
              )
              .map((sample) => sample['micros'] as int)
              .toList()
            ..sort();
      return values[values.length ~/ 2];
    }

    final original = median('original-await');
    final fast = median('nullable-fast');
    medians.add({
      'rows': rows,
      'originalMicros': original,
      'fastMicros': fast,
      'reductionPercent': (original - fast) * 100 / original,
    });
  }
  // ignore: avoid_print -- Standalone benchmark stdout is its result protocol.
  print(
    'CHECKPOINT_BENCH ${jsonEncode({'syntheticOnly': true, 'web': const bool.fromEnvironment('dart.library.js_interop'), 'budgetMillis': 4, 'budgetItems': 256, 'rounds': rounds, 'boundary': 'microbenchmark including real zero-duration timer turns; not ERP load/paint latency', 'medians': medians, 'samples': samples})}',
  );
}
