// 报销项（按类别分项）
// 文档：docs/04-数据模型/实体字典.md#ExpenseItem

import 'package:flutter/material.dart';

/// 报销类别
enum ExpenseCategory {
  /// 交通费
  transport('交通费', Icons.directions_car_rounded, 0xFF3B82F6),

  /// 差旅费（住宿）
  travel('差旅费', Icons.hotel_rounded, 0xFF8B5CF6),

  /// 餐饮
  meal('餐饮', Icons.restaurant_rounded, 0xFFF59E0B),

  /// 办公用品
  office('办公用品', Icons.inventory_2_outlined, 0xFF14B8A6),

  /// 通讯费
  communication('通讯费', Icons.phone_rounded, 0xFFEC4899),

  /// 业务招待
  entertainment('业务招待', Icons.cake_rounded, 0xFFF43F5E),

  /// 培训费
  training('培训费', Icons.school_rounded, 0xFF0EA5E9),

  /// 其他
  other('其他', Icons.more_horiz_rounded, 0xFF64748B);

  const ExpenseCategory(this.label, this.icon, this.colorHex);
  final String label;
  final IconData icon;
  final int colorHex;

  Color get color => Color(colorHex);
}

/// 报销项
class ExpenseItem {
  const ExpenseItem({
    required this.id,
    required this.category,
    required this.amount,
    required this.date,
    this.description,
  });

  final String id;

  /// 类别
  final ExpenseCategory category;

  /// 金额
  final double amount;

  /// 发生日期
  final DateTime date;

  /// 说明
  final String? description;
}
