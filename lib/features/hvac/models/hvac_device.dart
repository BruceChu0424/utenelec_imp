// 空调设备 model（Phase 4）
// 文档：docs/04-数据模型/实体字典.md#HvacDevice

import 'package:flutter/material.dart';

enum HvacMode { cool, heat, fan }

enum HvacFan { low, mid, high, auto }

class HvacDevice {
  const HvacDevice({
    required this.id,
    required this.name,
    required this.building,
    required this.floor,
    required this.online,
    required this.power,
    required this.currentTemp,
    required this.targetTemp,
    required this.mode,
    required this.fan,
  });

  final String id;
  final String name; // 位置名，如「A车间」
  final String building;
  final String floor;
  final bool online; // 在线/离线
  final bool power; // 开/关
  final double currentTemp; // 实测温度
  final double targetTemp; // 目标温度
  final HvacMode mode;
  final HvacFan fan;

  HvacDevice copyWith({
    bool? online,
    bool? power,
    double? currentTemp,
    double? targetTemp,
    HvacMode? mode,
    HvacFan? fan,
  }) => HvacDevice(
    id: id,
    name: name,
    building: building,
    floor: floor,
    online: online ?? this.online,
    power: power ?? this.power,
    currentTemp: currentTemp ?? this.currentTemp,
    targetTemp: targetTemp ?? this.targetTemp,
    mode: mode ?? this.mode,
    fan: fan ?? this.fan,
  );
}

extension HvacModeX on HvacMode {
  String get label => switch (this) {
    HvacMode.cool => '制冷',
    HvacMode.heat => '制热',
    HvacMode.fan => '送风',
  };
  IconData get icon => switch (this) {
    HvacMode.cool => Icons.ac_unit_rounded,
    HvacMode.heat => Icons.local_fire_department_rounded,
    HvacMode.fan => Icons.air_rounded,
  };
}

extension HvacFanX on HvacFan {
  String get label => switch (this) {
    HvacFan.low => '低',
    HvacFan.mid => '中',
    HvacFan.high => '高',
    HvacFan.auto => '自动',
  };
}
