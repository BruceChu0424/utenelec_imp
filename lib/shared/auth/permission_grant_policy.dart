/// 权限码的授权策略(ADR-109)。
///
/// 唯一事实源是服务端 `permissions.grant_policy`，随权限目录一起下发。前端只按它
/// 渲染「能否批量 / 能否配给部门 / 能否转授」，不再维护任何本地排除名单；
/// 真正的拦截在服务端与数据库守卫，这里的判断只决定按钮和提示怎么显示。
class PermissionGrantPolicy {
  const PermissionGrantPolicy(this.values);

  /// 服务端没带策略时按普通处理(目录项必带，缺失只会出现在旧测试夹具里)。
  static const normalOnly = PermissionGrantPolicy({normal});

  static const normal = 'NORMAL';
  static const bulkExcluded = 'BULK_EXCLUDED';
  static const individualOnly = 'INDIVIDUAL_ONLY';
  static const nonDelegable = 'NON_DELEGABLE';
  static const superadminOnly = 'SUPERADMIN_ONLY';

  final Set<String> values;

  factory PermissionGrantPolicy.fromJson(Object? json) {
    final parsed = <String>{
      if (json is List)
        for (final value in json)
          if (value is String && value.trim().isNotEmpty) value.trim(),
    };
    return parsed.isEmpty ? normalOnly : PermissionGrantPolicy(parsed);
  }

  bool get isSuperadminOnly => values.contains(superadminOnly);
  bool get isIndividualOnly => values.contains(individualOnly);

  /// 能否配置给整个部门。
  bool get departmentGrantable => !isIndividualOnly && !isSuperadminOnly;

  /// 能否由超级管理员对个人加授。
  bool get individuallyGrantable => !isSuperadminOnly;

  /// 能否由组织负责人在页面上转授。
  bool get delegable =>
      !values.contains(nonDelegable) && !isIndividualOnly && !isSuperadminOnly;

  /// 能否被「全部授权 / 本模块 / 本组」批量带上。
  bool get bulkEligible =>
      !values.contains(bulkExcluded) && !isIndividualOnly && !isSuperadminOnly;

  /// 能否放进全员基础包(与服务端同口径)。
  bool get baselineEligible => bulkEligible;

  /// 目录行上给管理员看的说明标签(大白话，不出现代号)。
  List<String> get labels => [
    if (isSuperadminOnly) '只随超级管理员身份生效',
    if (isIndividualOnly) '只能逐人授予',
    if (values.contains(bulkExcluded)) '不随批量授权',
    if (values.contains(nonDelegable)) '负责人不能转授',
  ];

  /// 不能配置给部门时的原因。
  String get departmentRefusal =>
      isSuperadminOnly ? '这项权限只随超级管理员身份生效，不能配置给部门' : '这项高风险权限只能逐人授予，不能配置给整个部门';
}
