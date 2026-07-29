// 制单信息只读字段（所有单据 新建/编辑页 UtenFormGrid 内共用）。
//
// 责任制设计：制单员/制单时间为服务端权威字段——建单时后端按当前登录用户写入
// maker_id（employees.id）+ 审计 created_at，前端只读展示，不可修改。
// - 新建态：制单员 = 当前登录用户姓名（sessionProvider）；制单时间提示"保存时自动记录"；
// - 编辑态：显示服务端 detail 返回的 makerName / createdAt（ISO → 本地 yyyy-MM-dd HH:mm）。
//
// 用法（UtenFormGrid children 内展开）：
//   ...utenMakerAuditCells(ref, makerName: _makerName, createdAt: _createdAt),
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../shared/providers/session_provider.dart';

/// 制单信息两个只读格子：制单员 + 制单时间。
/// [makerName] / [createdAt] 传服务端返回值；新建态传 null。
List<Widget> utenMakerAuditCells(
  WidgetRef ref, {
  String? makerName,
  String? createdAt,
}) {
  final me = ref.watch(sessionProvider).user;
  final maker = (makerName != null && makerName.isNotEmpty)
      ? makerName
      : (me?.name ?? '');
  final timeText = utenFmtIsoTime(createdAt);
  return [
    TextFormField(
      key: ValueKey('maker_$maker'),
      readOnly: true,
      initialValue: maker,
      decoration: InputDecoration(
        labelText: '制单员', // TODO(l10n): 补 arb
        hintText: maker.isEmpty ? '当前登录人' : null,
        filled: true,
        suffixIcon: const Icon(Icons.lock_outline, size: 16),
      ),
    ),
    TextFormField(
      key: ValueKey('mtime_$timeText'),
      readOnly: true,
      initialValue: timeText,
      decoration: InputDecoration(
        labelText: '制单时间', // TODO(l10n): 补 arb
        hintText: timeText.isEmpty ? '保存时自动记录' : null,
        filled: timeText.isEmpty,
        suffixIcon: timeText.isEmpty
            ? const Icon(Icons.autorenew_outlined, size: 18)
            : const Icon(Icons.lock_outline, size: 16),
      ),
    ),
  ];
}

/// ISO 时间串 → 本地 'yyyy-MM-dd HH:mm'；空/解析失败返回 ''。
/// 制单时间等审计时间展示共用（编辑页只读格 + 详情页信息行）。
String utenFmtIsoTime(String? iso) {
  if (iso == null || iso.isEmpty) return '';
  final d = DateTime.tryParse(iso);
  if (d == null) return '';
  return DateFormat('yyyy-MM-dd HH:mm').format(d.toLocal());
}
