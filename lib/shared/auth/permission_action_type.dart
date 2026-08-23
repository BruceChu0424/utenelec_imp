/// 权限目录的动作分类。
///
/// 原始值由后端 `permissions.action_type` / JSON `actionType` 提供。前端只负责
/// 展示和筛选，不根据权限 code 推断，避免新增权限时两端分类漂移。
enum PermissionActionType {
  view('查看'),
  create('新增'),
  edit('编辑'),
  delete('删除'),
  approve('审批'),
  importData('导入'),
  exportData('导出'),
  execute('执行'),
  configure('配置'),
  assign('分配'),
  other('其它');

  const PermissionActionType(this.label);

  final String label;

  /// 后端未知值安全降级为 [other]，但不会按 code 猜测动作类型。
  static PermissionActionType fromJson(Object? value) {
    final normalized = value?.toString().trim().toUpperCase() ?? '';
    return switch (normalized) {
      'VIEW' => PermissionActionType.view,
      'CREATE' => PermissionActionType.create,
      'EDIT' => PermissionActionType.edit,
      'DELETE' => PermissionActionType.delete,
      'APPROVE' => PermissionActionType.approve,
      'IMPORT' => PermissionActionType.importData,
      'EXPORT' => PermissionActionType.exportData,
      'EXECUTE' => PermissionActionType.execute,
      'CONFIGURE' => PermissionActionType.configure,
      'ASSIGN' => PermissionActionType.assign,
      _ => PermissionActionType.other,
    };
  }

  String get wireValue => switch (this) {
    PermissionActionType.view => 'VIEW',
    PermissionActionType.create => 'CREATE',
    PermissionActionType.edit => 'EDIT',
    PermissionActionType.delete => 'DELETE',
    PermissionActionType.approve => 'APPROVE',
    PermissionActionType.importData => 'IMPORT',
    PermissionActionType.exportData => 'EXPORT',
    PermissionActionType.execute => 'EXECUTE',
    PermissionActionType.configure => 'CONFIGURE',
    PermissionActionType.assign => 'ASSIGN',
    PermissionActionType.other => 'OTHER',
  };
}
