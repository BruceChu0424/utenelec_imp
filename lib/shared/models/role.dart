// 角色枚举
// 文档：docs/03-页面/页面总览.md（权限矩阵）

/// 用户角色
///
/// `displayNameZh` / `displayNameEn` 直接作为枚举 getter 定义，
/// 不用 extension——extension 在 dart2js release 构建偶发被 tree-shaking 误删。
enum Role {
  /// 普通员工
  employee('员工', 'Employee'),

  /// 人事
  hr('人事', 'HR'),

  /// 财务
  finance('财务', 'Finance'),

  /// 实验室
  lab('实验室', 'Lab'),

  /// 车间/生产
  production('车间', 'Production'),

  /// 管理层
  manager('管理层', 'Manager'),

  /// 系统管理员
  admin('管理员', 'Admin'),

  /// 保安（门岗访客核验）
  security('保安', 'Security');

  const Role(this.displayNameZh, this.displayNameEn);

  final String displayNameZh;
  final String displayNameEn;

  String get code => name;
}
