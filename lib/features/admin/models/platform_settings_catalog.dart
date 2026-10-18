import '../../../core/router/route_access_policy.dart';
import '../../../core/router/route_names.dart';

/// Navigation only: each destination retains its authoritative settings API,
/// action permissions, concurrency checks and audit trail.
class PlatformSettingsEntry {
  const PlatformSettingsEntry({
    required this.id,
    required this.title,
    required this.description,
    required this.location,
  });

  final String id;
  final String title;
  final String description;
  final String location;
}

const platformSettingsCatalog = <PlatformSettingsEntry>[
  PlatformSettingsEntry(
    id: 'remote-access',
    title: '外网访问与连接',
    description: '指定人员、人数上限与外网入口状态',
    location: RouteName.adminRemoteAccess,
  ),
  PlatformSettingsEntry(
    id: 'security',
    title: '安全与运行设置',
    description: '登录保护、业务提醒、审计留存与服务器更新计划',
    location: RouteName.adminSystemSettings,
  ),
  PlatformSettingsEntry(
    id: 'ai',
    title: 'AI 服务',
    description: '服务商、模型、密钥、连接测试与使用限额',
    location: RouteName.adminAiSettings,
  ),
  PlatformSettingsEntry(
    id: 'expense',
    title: '报销与开票信息',
    description: '财务公司抬头、税号、报销说明与发票要求',
    location: '/expense/settings',
  ),
  PlatformSettingsEntry(
    id: 'permissions',
    title: '账号与权限',
    description: '员工账号、部门与个人授权、数据范围和远程访问',
    location: RouteName.adminPermissions,
  ),
  PlatformSettingsEntry(
    id: 'basic-data',
    title: '基础资料与业务字典',
    description: '货品、客户、供应商、仓库、账户、币种、单位和结算方式',
    location: RouteName.basicinfo,
  ),
  PlatformSettingsEntry(
    id: 'workshop-material',
    title: '车间物料管理',
    description: '各车间的内料仓、来源仓与物料管理方式',
    location: RouteName.workshopMaterialSetup,
  ),
  PlatformSettingsEntry(
    id: 'server-status',
    title: '服务器状态',
    description: '服务器、数据库、备份、存储和定时任务的运行状态',
    location: RouteName.adminServerStatus,
  ),
  PlatformSettingsEntry(
    id: 'audit',
    title: '审计中心',
    description: '核查平台配置与业务操作的修改记录',
    location: RouteName.adminAuditLogs,
  ),
  PlatformSettingsEntry(
    id: 'personal',
    title: '我的偏好设置',
    description: '仅影响本人设备的深浅主题、语言、字号、性能与时间显示',
    location: RouteName.settings,
  ),
];

List<PlatformSettingsEntry> platformSettingsEntriesFor(
  Set<String> permissions,
  bool superAdmin,
) => [
  for (final entry in platformSettingsCatalog)
    if (locationAllowedFor(permissions, superAdmin, entry.location)) entry,
];
