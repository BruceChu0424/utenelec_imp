// 空调 Mock 仓库（Phase 4）

import 'dart:async';

import '../models/hvac_device.dart';

class MockHvacRepository {
  MockHvacRepository();
  List<HvacDevice>? _data;

  Future<T> _delay<T>(T Function() cb) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return cb();
  }

  List<HvacDevice> _ensure() {
    if (_data != null) return _data!;
    _data = _seed();
    return _data!;
  }

  Future<List<HvacDevice>> list({String? building}) async {
    return _delay(() {
      var result = [..._ensure()];
      if (building != null && building != '全部') {
        result = result.where((d) => d.building == building).toList();
      }
      return result;
    });
  }

  Future<HvacDevice?> getById(String id) async {
    return _delay(() => _ensure().firstWhere((d) => d.id == id));
  }

  Future<HvacDevice> update(HvacDevice device) async {
    return _delay(() {
      final list = _ensure();
      final idx = list.indexWhere((d) => d.id == device.id);
      if (idx >= 0) list[idx] = device;
      return device;
    });
  }

  Future<List<String>> buildings() async {
    return _delay(() => ['全部', '1号厂房', '2号厂房', '办公楼']);
  }

  List<HvacDevice> _seed() {
    return [
      const HvacDevice(
        id: 'hvac-001',
        name: 'A车间',
        building: '1号厂房',
        floor: '1F',
        online: true,
        power: true,
        currentTemp: 22,
        targetTemp: 24,
        mode: HvacMode.cool,
        fan: HvacFan.auto,
      ),
      const HvacDevice(
        id: 'hvac-002',
        name: 'B车间',
        building: '1号厂房',
        floor: '1F',
        online: true,
        power: true,
        currentTemp: 26,
        targetTemp: 25,
        mode: HvacMode.fan,
        fan: HvacFan.mid,
      ),
      const HvacDevice(
        id: 'hvac-003',
        name: '原料仓',
        building: '1号厂房',
        floor: '1F',
        online: false,
        power: false,
        currentTemp: 0,
        targetTemp: 22,
        mode: HvacMode.cool,
        fan: HvacFan.low,
      ),
      const HvacDevice(
        id: 'hvac-004',
        name: '成品仓',
        building: '1号厂房',
        floor: '2F',
        online: true,
        power: true,
        currentTemp: 24,
        targetTemp: 23,
        mode: HvacMode.cool,
        fan: HvacFan.low,
      ),
      const HvacDevice(
        id: 'hvac-005',
        name: '办公室A',
        building: '办公楼',
        floor: '2F',
        online: true,
        power: true,
        currentTemp: 25,
        targetTemp: 26,
        mode: HvacMode.cool,
        fan: HvacFan.auto,
      ),
      const HvacDevice(
        id: 'hvac-006',
        name: '会议室',
        building: '办公楼',
        floor: '3F',
        online: true,
        power: false,
        currentTemp: 27,
        targetTemp: 24,
        mode: HvacMode.cool,
        fan: HvacFan.auto,
      ),
      const HvacDevice(
        id: 'hvac-007',
        name: '实验室',
        building: '2号厂房',
        floor: '1F',
        online: true,
        power: true,
        currentTemp: 21,
        targetTemp: 22,
        mode: HvacMode.cool,
        fan: HvacFan.mid,
      ),
      const HvacDevice(
        id: 'hvac-008',
        name: '装配区',
        building: '2号厂房',
        floor: '1F',
        online: true,
        power: true,
        currentTemp: 28,
        targetTemp: 26,
        mode: HvacMode.fan,
        fan: HvacFan.high,
      ),
    ];
  }
}
