// 部门员工花名册打印（复用通用 A4 打印预览组件，与报表页同口径）。
// 入口：部门管理 → 部门概览卡「打印花名册」按钮。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/print/uten_print_preview.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../employee/models/employee_api_models.dart';
import '../../employee/models/work_years.dart';
import '../../employee/repositories/employee_repository.dart';
import '../models/department_node.dart';

/// 弹出「部门员工花名册」A4 打印预览（含下级部门全员；排序由服务端保证：
/// 部门负责人 → 领导层 → 班组管理 → 普通员工 → 工号）。
Future<void> showDepartmentRosterPrint({
  required BuildContext context,
  required WidgetRef ref,
  required DepartmentNode node,
}) {
  final l10n = AppLocalizations.of(context);
  return showUtenPrintPreview(
    context: context,
    title: '${node.name} · 员工花名册',
    subtitle: '含下级部门 · 负责人/领导优先排序 · 工龄按打印当天动态计算',
    loader: () async {
      final employees = await _loadAllEmployees(ref, node.id);
      return UtenPrintTable(
        headers: const ['工号', '姓名', '性别', '部门', '岗位', '职级', '入职日期', '工龄'],
        rows: [
          for (final e in employees)
            [
              e.code,
              e.fullName,
              _genderText(e.gender),
              e.departmentName ?? '',
              e.positionName ?? '',
              e.positionLevel ?? '',
              e.hireDate ?? '',
              workYearsText(l10n, e.hireDate),
            ],
        ],
      );
    },
  );
}

/// 分页拉全（部门人数规模有限；500 上限防御异常循环）。
Future<List<EmployeeSummary>> _loadAllEmployees(
  WidgetRef ref,
  String departmentId,
) async {
  final repo = ref.read(employeeRepositoryProvider);
  final all = <EmployeeSummary>[];
  var page = 1;
  while (true) {
    final r = await repo.list(
      page: page,
      size: 100,
      departmentId: departmentId,
      includeSubtree: true,
    );
    all.addAll(r.items);
    if (page >= r.totalPages || all.length >= 500) break;
    page++;
  }
  return all;
}

String _genderText(String? gender) => switch (gender) {
  'male' => '男',
  'female' => '女',
  _ => '',
};
