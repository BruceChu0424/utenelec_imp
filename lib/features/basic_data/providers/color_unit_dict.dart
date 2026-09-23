// 颜色/单位字典 provider + 货品编辑内联新建 helper。
//
// 货品编辑表单的颜色/单位下拉选项来自这两个 provider，行取自会话级主档字典仓库
// (ADR-108，与单据名解析共用同一份，不再各拉一遍)。本端新建/改名颜色、单位后网络层
// 自动作废对应字典并推进修订号，这里随之重取。新建后返回 UUID，自动选中。
// 弹窗本体是共享的 showNameAddSheet（master_dict_add.dart，币种/结账方式新增同款）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_endpoints.dart';
import '../../../shared/providers/master_dictionary_repository.dart';
import '../models/color_node.dart';
import '../models/unit_node.dart';
import '../repositories/color_repository.dart';
import '../repositories/unit_repository.dart';
import 'master_dict_add.dart';

/// 颜色字典(货品编辑颜色下拉 + 单据颜色名解析共用一份)。写后自动随修订号重取。
final colorDictProvider = FutureProvider<List<ColorListItem>>((ref) async {
  ref.watch(masterDictionaryRevisionProvider);
  final rows = await ref
      .watch(masterDictionaryRepositoryProvider)
      .load(ApiEndpoints.colorsDict);
  return rows.map(ColorListItem.fromJson).toList();
});

/// 单位字典(同上)。
final unitDictProvider = FutureProvider<List<UnitListItem>>((ref) async {
  ref.watch(masterDictionaryRevisionProvider);
  final rows = await ref
      .watch(masterDictionaryRepositoryProvider)
      .load(ApiEndpoints.unitsDict);
  return rows.map(UnitListItem.fromJson).toList();
});

/// 货品编辑内联新建颜色：弹窗输入名称 → 预查重 → POST → 刷新字典 → 返回 UUID（自动选中）。
/// 取消/失败返回 null。
Future<String?> showColorAddSheet(BuildContext context, WidgetRef ref) {
  return showNameAddSheet(
    context: context,
    title: '添加颜色',
    exists: (name) =>
        ref
            .read(colorDictProvider)
            .valueOrNull
            ?.any((c) => (c.name ?? '').toLowerCase() == name.toLowerCase()) ??
        false,
    create: (name) async {
      final d = await ref.read(colorRepositoryProvider).create({
        'name': name,
        'status': '使用',
      });
      ref.invalidate(colorDictProvider);
      return d.id;
    },
  );
}

/// 货品编辑内联新建单位（同上）。
Future<String?> showUnitAddSheet(BuildContext context, WidgetRef ref) {
  return showNameAddSheet(
    context: context,
    title: '添加单位',
    exists: (name) =>
        ref
            .read(unitDictProvider)
            .valueOrNull
            ?.any((u) => (u.name ?? '').toLowerCase() == name.toLowerCase()) ??
        false,
    create: (name) async {
      final d = await ref.read(unitRepositoryProvider).create({
        'name': name,
        'status': '使用',
      });
      ref.invalidate(unitDictProvider);
      return d.id;
    },
  );
}
