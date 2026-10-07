// 模拟身份（admin「切换人」）：目标选择器 + 切换流程编排。
// 进入切换人要求再认证，由网络层弹统一的「重新输入密码」框 (ADR-110)，本文件不再自带密码框。
// 触发自工作台页头「切换人」与模拟横幅「切换」。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/inputs/uten_employee_picker.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/providers/session_provider.dart';
import '../models/impersonation.dart';
import '../repositories/impersonation_repository.dart';

/// 「切换人」入口编排：
/// 1) 未进模拟模式 → enterImpersonationMode (服务端要求再认证，统一密码框)；
/// 2) 打开目标选择器（始终以 admin 凭证加载）；
/// 3) 选中 → startImpersonation → 回工作台看目标视角。
Future<void> openSwitchPerson(BuildContext context, WidgetRef ref) async {
  final l10n = AppLocalizations.of(context);
  final session = ref.read(sessionProvider);

  if (!session.isImpersonationModeActive) {
    try {
      await ref.read(sessionProvider.notifier).enterImpersonationMode();
    } on ApiException catch (e) {
      if (context.mounted) {
        context.appError(
          e.message.isEmpty ? l10n.impersonationWrongPassword : e.message,
        );
      }
      return;
    } catch (_) {
      if (context.mounted) context.appError(l10n.impersonationStartFailed);
      return;
    }
  }
  if (!context.mounted) return;
  final target = await showImpersonationTargetPicker(context, ref);
  if (target == null) return;
  try {
    await ref
        .read(sessionProvider.notifier)
        .startImpersonation(targetEmployeeId: target.employeeId);
    if (context.mounted) context.go('/dashboard');
  } on ApiException catch (e) {
    if (context.mounted) {
      context.appError(
        e.message.isEmpty ? l10n.impersonationStartFailed : e.message,
      );
    }
  } catch (_) {
    if (context.mounted) context.appError(l10n.impersonationStartFailed);
  }
}

/// 目标候选仍使用管理员模拟身份接口；选人统一为部门/人员双栏并确认后返回。
Future<ImpersonationTarget?> showImpersonationTargetPicker(
  BuildContext context,
  WidgetRef ref,
) async {
  final l10n = AppLocalizations.of(context);
  final recentIds = ref
      .read(sessionProvider)
      .recentImpersonatedEmployeeIds
      .toSet();
  final targets = <String, ImpersonationTarget>{};
  final picked = await showUtenEmployeePickerPanel(
    context,
    title: l10n.impersonationTargetPickerTitle,
    emptyMessage: l10n.impersonationNoTargets,
    loader: (keyword) async {
      final rows = await ref
          .read(impersonationRepositoryProvider)
          .searchTargets(keyword);
      for (final row in rows) {
        targets[row.employeeId] = row;
      }
      return [
        for (final row in rows)
          UtenEmployeePickerItem(
            id: row.employeeId,
            name: row.name,
            employeeCode: row.employeeCode,
            departmentId: row.departmentId,
            departmentName: row.departmentName,
            subtitle: [
              if (row.positionName?.isNotEmpty == true) row.positionName!,
              if (recentIds.contains(row.employeeId)) l10n.impersonationRecent,
            ].join(' · '),
          ),
      ];
    },
  );
  return picked == null ? null : targets[picked.id];
}
