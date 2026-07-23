// 生产 Mock 仓库（Phase 4）

import '../models/production.dart';

class MockProductionRepository {
  MockProductionRepository();
  List<ProductionLine>? _lines;
  List<ProductionOutput>? _outputs;

  Future<T> _delay<T>(T Function() cb) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return cb();
  }

  Future<List<ProductionLine>> lines() async =>
      _delay(() => [..._ensureLines()]);

  Future<List<ProductionOutput>> outputs() async =>
      _delay(() => [..._ensureOutputs()]);

  Future<ProductionOutput> addOutput(ProductionOutput o) async =>
      _delay(() {
        _ensureOutputs().insert(0, o);
        return o;
      });

  List<ProductionLine> _ensureLines() {
    if (_lines != null) return _lines!;
    _lines = [
      const ProductionLine(
        id: 'line-1', name: '一号线', order: 'WO-1023',
        progress: 0.75, takt: 30, outputToday: 1280,
        status: LineStatus.running, alertCount: 0,
      ),
      const ProductionLine(
        id: 'line-2', name: '二号线', order: 'WO-1024',
        progress: 0.35, takt: 30, outputToday: 640,
        status: LineStatus.changeover, alertCount: 1,
      ),
      const ProductionLine(
        id: 'line-3', name: '三号线', order: 'WO-1025',
        progress: 0.5, takt: 45, outputToday: 420,
        status: LineStatus.running, alertCount: 0,
      ),
      const ProductionLine(
        id: 'line-4', name: '组装线', order: 'WO-1026',
        progress: 0.1, takt: null, outputToday: 0,
        status: LineStatus.stopped, alertCount: 2,
      ),
    ];
    return _lines!;
  }

  List<ProductionOutput> _ensureOutputs() {
    if (_outputs != null) return _outputs!;
    final now = DateTime.now();
    _outputs = [
      ProductionOutput(
        id: 'o1', line: '一号线', product: '产品A', shift: Shift.day,
        qualified: 1280, unqualified: 18, date: now, operatorName: '张优腾',
      ),
      ProductionOutput(
        id: 'o2', line: '二号线', product: '产品B', shift: Shift.day,
        qualified: 640, unqualified: 9, date: now, operatorName: '李秀英',
      ),
      ProductionOutput(
        id: 'o3', line: '三号线', product: '产品C', shift: Shift.day,
        qualified: 420, unqualified: 6, date: now, operatorName: '王强',
      ),
      ProductionOutput(
        id: 'o4', line: '一号线', product: '产品A', shift: Shift.night,
        qualified: 1100, unqualified: 15, date: now.subtract(const Duration(days: 1)),
        operatorName: '徐磊',
      ),
    ];
    return _outputs!;
  }
}
