// 部门员工花名册打印（复用通用 A4 打印预览组件，与报表页同口径）。
// 入口：部门管理 → 部门概览卡「打印花名册」按钮。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/print/uten_print_preview.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/performance/ui_work_budget.dart';
import '../../../shared/providers/export_context_epoch_provider.dart';
import '../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../../employee/models/work_years.dart';
import '../../employee/repositories/employee_repository.dart';
import '../models/department_node.dart';
import '../repositories/department_roster_snapshot.dart';

/// 弹出「部门员工花名册」A4 打印预览（含下级部门全员；排序由服务端保证：
/// 部门负责人 → 领导层 → 班组管理 → 普通员工 → 工号）。
Future<void> showDepartmentRosterPrint({
  required BuildContext context,
  required WidgetRef ref,
  required DepartmentNode node,
}) {
  final l10n = AppLocalizations.of(context);
  final boundary = ref.read(sensitiveReadBoundaryProvider);
  final epoch = ref.read(exportContextEpochProvider);
  final repository = ref.read(employeeRepositoryProvider);
  var retired = false;
  bool current() {
    if (retired || !context.mounted) return false;
    retired =
        boundary != ref.read(sensitiveReadBoundaryProvider) ||
        epoch != ref.read(exportContextEpochProvider) ||
        !identical(repository, ref.read(employeeRepositoryProvider));
    return !retired;
  }

  return showUtenPrintPreview(
    context: context,
    applyTableProjection:
        false, // Dedicated roster, independent of the department tree table.
    title: '${node.name} · 员工花名册',
    subtitle: '含下级部门 · 负责人/领导优先排序 · 工龄按打印当天动态计算',
    loader: () async {
      final scope = await boundary.api.captureRequestScope(isCurrent: current);
      final table = await scope.run(
        () => loadDepartmentRosterPrintTable(
          repository: repository,
          departmentId: node.id,
          l10n: l10n,
          isCurrent: () => current() && scope.isCurrent,
        ),
      );
      await scope.verify();
      return table;
    },
  );
}

Future<UtenPrintTable> loadDepartmentRosterPrintTable({
  required EmployeeRepository repository,
  required String departmentId,
  required AppLocalizations l10n,
  required bool Function() isCurrent,
  UiWorkBudget? budget,
}) async {
  final work = budget ?? UiWorkBudget(isCurrent: isCurrent);
  final snapshot = await loadDepartmentRosterSnapshot(
    repository: repository,
    departmentId: departmentId,
    isCurrent: isCurrent,
    budget: work,
  );
  final rows = <List<String>>[];
  final ids = <String>[];
  for (final employee in snapshot.employees) {
    ids.add(employee.id);
    rows.add([
      employee.code,
      employee.fullName,
      _genderText(employee.gender),
      employee.departmentName ?? '',
      employee.positionName ?? '',
      employee.positionLevel ?? '',
      employee.hireDate ?? '',
      workYearsText(l10n, employee.hireDate),
    ]);
    await work.checkpoint(8);
  }
  work.ensureCurrent();
  if (!isCurrent()) throw const UiWorkCancelled();
  return UtenPrintTable(
    columnKeys: const [
      'code',
      'fullName',
      'gender',
      'departmentName',
      'positionName',
      'positionLevel',
      'hireDate',
      'workYears',
    ],
    rowIds: ids,
    headers: const ['工号', '姓名', '性别', '部门', '岗位', '职级', '入职日期', '工龄'],
    rows: rows,
  );
}

String _genderText(String? gender) => switch (gender) {
  'male' => '男',
  'female' => '女',
  _ => '',
};
