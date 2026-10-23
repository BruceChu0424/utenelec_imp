import 'dart:js_interop';
import 'package:web/web.dart' as web;

/// Optional diagnostic only. Inclusive widget/layout spans cannot be added
/// together or treated as acceptance timings. No document values are recorded.
class B0WidgetProbe {
  web.PerformanceObserver? _observer;
  bool _recording = false;
  final _stats = <String, List<double>>{};

  void start() {
    final observer = web.PerformanceObserver(
      ((web.PerformanceObserverEntryList entries, web.PerformanceObserver _) {
        _record(entries.getEntries().toDart);
      }).toJS,
    );
    observer.observe(
      web.PerformanceObserverInit(entryTypes: ['measure'.toJS].toJS),
    );
    _observer = observer;
  }

  void _record(List<web.PerformanceEntry> entries) {
    if (!_recording) return;
    for (final entry in entries) {
      if (entry.duration < .2) continue;
      final stats = _stats.putIfAbsent(entry.name, () => [0, 0, 0]);
      stats[0]++;
      stats[1] += entry.duration;
      if (entry.duration > stats[2]) stats[2] = entry.duration;
    }
  }

  void reset() {
    _observer?.takeRecords();
    _stats.clear();
    _recording = _observer != null;
  }

  Map<String, Object?> summary() {
    final pending = _observer?.takeRecords();
    if (pending != null) _record(pending.toDart);
    _recording = false;
    final entries = _stats.entries.toList();
    List<Map<String, Object>> top(int metric) {
      entries.sort((a, b) => b.value[metric].compareTo(a.value[metric]));
      return [
        for (final entry in entries.take(25))
          {
            'type': entry.key,
            'count': entry.value[0].toInt(),
            'inclusiveTotalMs': entry.value[1],
            'maxMs': entry.value[2],
          },
      ];
    }

    return _observer == null ? const {} : {'byTotal': top(1), 'byMax': top(2)};
  }

  void dispose() => _observer?.disconnect();
}
