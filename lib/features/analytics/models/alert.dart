// 异常告警 model（Phase 5）

import 'package:flutter/material.dart';

enum AlertType { inventory, equipment, quality, output, approval, contract }
enum AlertLevel { high, medium, low }
enum AlertStatus { pending, processing, resolved }

extension AlertTypeX on AlertType {
  String get label => switch (this) {
        AlertType.inventory => '库存',
        AlertType.equipment => '设备',
        AlertType.quality => '质量',
        AlertType.output => '产量',
        AlertType.approval => '审批',
        AlertType.contract => '合同',
      };
  IconData get icon => switch (this) {
        AlertType.inventory => Icons.inventory_2_outlined,
        AlertType.equipment => Icons.hvac_outlined,
        AlertType.quality => Icons.science_outlined,
        AlertType.output => Icons.show_chart_outlined,
        AlertType.approval => Icons.task_alt_rounded,
        AlertType.contract => Icons.description_outlined,
      };
}

extension AlertLevelX on AlertLevel {
  String get label => switch (this) {
        AlertLevel.high => '高',
        AlertLevel.medium => '中',
        AlertLevel.low => '低',
      };
}

extension AlertStatusX on AlertStatus {
  String get label => switch (this) {
        AlertStatus.pending => '未处理',
        AlertStatus.processing => '处理中',
        AlertStatus.resolved => '已解决',
      };
}

class Alert {
  const Alert({
    required this.id,
    required this.type,
    required this.level,
    required this.status,
    required this.content,
    required this.time,
    this.source,
    this.handler,
  });

  final String id;
  final AlertType type;
  final AlertLevel level;
  final AlertStatus status;
  final String content;
  final DateTime time;
  final String? source;
  final String? handler;
}
