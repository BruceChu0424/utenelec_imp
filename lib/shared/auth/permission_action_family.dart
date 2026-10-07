// 页面权限展示用的动作族分组（V812 权限抽屉口径）。
//
// 服务端 action_type 是唯一事实源；本枚举只做展示层归并：
// 「编辑」族把 CREATE 与 EDIT 合并成一颗开关（用户口径：新增/修改统一为编辑，
// 删除因风险高保持独立），其余动作一一对应。展开族行仍可看到单个权限码的
// 原生动作徽标，细粒度授权路径不受影响。

import 'package:flutter/material.dart';

import 'permission_action_type.dart';

enum PermissionActionFamily {
  view('查看', Icons.visibility_outlined),
  edit('编辑', Icons.edit_outlined),
  delete('删除', Icons.delete_outline_rounded),
  approve('审核', Icons.fact_check_outlined),
  execute('执行·办理', Icons.play_circle_outline),
  importData('导入', Icons.file_upload_outlined),
  exportData('导出', Icons.file_download_outlined),
  assign('分配', Icons.person_add_alt_1_outlined),
  configure('配置', Icons.tune),
  other('其它', Icons.more_horiz_rounded);

  const PermissionActionFamily(this.label, this.icon);

  final String label;
  final IconData icon;

  /// 编辑族展开时的明细说明（新增与修改两颗开关在里面）。
  String get detailHint => switch (this) {
    edit => '含新增与修改',
    _ => '',
  };

  static PermissionActionFamily of(PermissionActionType type) => switch (type) {
    PermissionActionType.view => view,
    PermissionActionType.create => edit,
    PermissionActionType.edit => edit,
    PermissionActionType.delete => delete,
    PermissionActionType.approve => approve,
    PermissionActionType.execute => execute,
    PermissionActionType.importData => importData,
    PermissionActionType.exportData => exportData,
    PermissionActionType.configure => configure,
    PermissionActionType.assign => assign,
    PermissionActionType.other => other,
  };
}
