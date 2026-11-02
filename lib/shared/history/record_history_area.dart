import '../../core/router/route_names.dart';
import 'package:flutter/material.dart';

import '../../features/basic_data/widgets/master_inline_edit.dart';
import 'record_history_labels.dart';

/// Presentation and transport differences; object visibility remains server-owned.
enum RecordHistoryArea {
  master,
  companyFiles,
  permissions;

  String get apiPath => switch (this) {
    master => '/master/record-history',
    companyFiles => '/company-files/record-history',
    permissions => '/admin/permission-history',
  };
  String get parentPath => switch (this) {
    master => RouteName.basicinfo,
    companyFiles => RouteName.companyFiles,
    permissions => RouteName.adminPermissions,
  };
  String get routePath => switch (this) {
    master => RouteName.basicinfoHistory,
    companyFiles => RouteName.companyFilesHistory,
    permissions => RouteName.adminPermissionsHistory,
  };
  String get tableKey => switch (this) {
    master => 'master.record.history',
    companyFiles => 'company.files.history',
    permissions => 'admin.permissions.history',
  };
  Map<String, String> get viewPermissions => switch (this) {
    master => masterHistoryViewPermissions,
    companyFiles => const {
      'files': 'company_file:view',
      'folders': 'company_file:view',
    },
    permissions => const {
      'users': 'authorization:manage',
      'departments': 'authorization:manage',
      'baseline': 'authorization:manage',
      'templates': 'authorization:manage',
      'configuration': 'authorization:manage',
    },
  };
  List<String> get sourceTypes => switch (this) {
    master => const ['CATEGORY', 'BOM', 'EXTENSION', 'RECORD'],
    companyFiles => const ['RECORD', 'ACCESS', 'PASSWORD', 'ORDER'],
    permissions => const ['ACCESS', 'SCOPE', 'TEMPLATE'],
  };
  bool canRead(bool superAdmin, Set<String> grants) => switch (this) {
    permissions => superAdmin && grants.contains('authorization:manage'),
    _ => superAdmin || viewPermissions.values.any(grants.contains),
  };
  String title(BuildContext context) => switch (this) {
    master => masterEditText(context, '修改历史', 'Change history', '변경 기록'),
    companyFiles => masterEditText(
      context,
      '公司资料修改历史',
      'Company file history',
      '회사 자료 변경 기록',
    ),
    permissions => masterEditText(
      context,
      '权限修改历史',
      'Permission history',
      '권한 변경 기록',
    ),
  };
}
