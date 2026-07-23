// 告警 Mock 仓库（Phase 5）

import '../models/alert.dart';

class MockAlertRepository {
  MockAlertRepository();
  List<Alert>? _data;

  Future<T> _delay<T>(T Function() cb) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return cb();
  }

  Future<List<Alert>> list({AlertStatus? status, AlertLevel? level}) async {
    return _delay(() {
      var result = [..._ensure()];
      if (status != null) result = result.where((a) => a.status == status).toList();
      if (level != null) result = result.where((a) => a.level == level).toList();
      result.sort((a, b) => b.time.compareTo(a.time));
      return result;
    });
  }

  List<Alert> _ensure() {
    if (_data != null) return _data!;
    final now = DateTime.now();
    _data = [
      Alert(id: 'a1', type: AlertType.inventory, level: AlertLevel.high,
          status: AlertStatus.pending, content: '螺丝 B 型 库存为 0，已缺货',
          source: 'M002 · 1号库', time: now.subtract(const Duration(minutes: 30))),
      Alert(id: 'a2', type: AlertType.equipment, level: AlertLevel.high,
          status: AlertStatus.pending, content: '1号厂房 原料仓空调离线',
          source: 'hvac-003', time: now.subtract(const Duration(hours: 1))),
      Alert(id: 'a3', type: AlertType.quality, level: AlertLevel.medium,
          status: AlertStatus.processing, content: '涂料 B 型 含水率超标（8.2% > 6.0%）',
          source: 'S202607-002', time: now.subtract(const Duration(hours: 3)), handler: '赵敏'),
      Alert(id: 'a4', type: AlertType.output, level: AlertLevel.medium,
          status: AlertStatus.pending, content: '组装线今日产量为 0，疑似停机',
          source: '组装线', time: now.subtract(const Duration(hours: 5))),
      Alert(id: 'a5', type: AlertType.contract, level: AlertLevel.low,
          status: AlertStatus.resolved, content: '李秀英 合同将于 30 天内到期',
          source: 'E0002', time: now.subtract(const Duration(days: 1)), handler: '吴经理'),
      Alert(id: 'a6', type: AlertType.approval, level: AlertLevel.low,
          status: AlertStatus.resolved, content: '报销单 claim-001 审批超时 24h',
          source: 'claim-001', time: now.subtract(const Duration(days: 2)), handler: '冯总监'),
    ];
    return _data!;
  }
}
