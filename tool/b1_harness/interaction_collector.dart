import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// Bounded, optional instrumentation for synthetic browser harnesses.
/// Business requests never pass through this collector.
class B1InteractionCollector extends ChangeNotifier {
  final _clock = Stopwatch()..start();
  final _gaps = <double>[];
  final _builds = <double>[];
  final _rasters = <double>[];
  Ticker? _ticker;
  int? _lastTick;
  int _sampleStart = 0;
  bool sampling = false;
  static const _maxSamples = 200000;

  void _append(List<double> target, double value) {
    if (target.length < _maxSamples) target.add(value);
  }

  void _frames(List<ui.FrameTiming> timings) {
    if (!sampling) return;
    for (final timing in timings) {
      if (timing.timestampInMicroseconds(ui.FramePhase.buildStart) <=
          _sampleStart) {
        continue;
      }
      _append(_builds, timing.buildDuration.inMicroseconds / 1000);
      _append(_rasters, timing.rasterDuration.inMicroseconds / 1000);
    }
  }

  void start() {
    _gaps.clear();
    _builds.clear();
    _rasters.clear();
    _lastTick = null;
    _sampleStart =
        SchedulerBinding.instance.currentSystemFrameTimeStamp.inMicroseconds;
    if (_ticker == null) {
      SchedulerBinding.instance.addTimingsCallback(_frames);
      _ticker = Ticker((_) {
        final now = _clock.elapsedMicroseconds;
        if (sampling && _lastTick != null) {
          _append(_gaps, (now - _lastTick!) / 1000);
        }
        _lastTick = now;
      });
    }
    sampling = true;
    _ticker!.start();
    notifyListeners();
  }

  void stop() {
    sampling = false;
    _ticker?.stop();
    notifyListeners();
  }

  static double percentile(List<double> values, double probability) {
    if (values.isEmpty) return 0;
    final sorted = List<double>.of(values)..sort();
    return sorted[((sorted.length - 1) * probability).ceil()];
  }

  Map<String, Object> snapshot() => {
    'sampleCap': _maxSamples,
    'frameGapsMs': {
      'count': _gaps.length,
      'p95': percentile(_gaps, .95),
      'p99': percentile(_gaps, .99),
      'max': percentile(_gaps, 1),
      'atLeast200ms': _gaps.where((gap) => gap >= 200).length,
    },
    'buildMs': {
      'count': _builds.length,
      'p95': percentile(_builds, .95),
      'p99': percentile(_builds, .99),
      'max': percentile(_builds, 1),
    },
    'rasterMs': {
      'count': _rasters.length,
      'p95': percentile(_rasters, .95),
      'p99': percentile(_rasters, .99),
      'max': percentile(_rasters, 1),
    },
  };

  @override
  void dispose() {
    _ticker?.dispose();
    SchedulerBinding.instance.removeTimingsCallback(_frames);
    super.dispose();
  }
}
