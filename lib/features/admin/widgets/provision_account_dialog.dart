// 开通账号对话框（权限设置页 · 按员工）。
//
// 与人事-员工详情页的「开通账号」同后端端点（POST /org/employees/{id}/account，
// account:support)：登录账号=手机号，初始密码为证件号后六位，没有证件号或不足六位时
// 系统随机生成 (只显示一次、限时有效)，首登强制改密。候选列表走
// /admin/users/provision-candidates(在册未开户员工，最小信息集、不含 PII 明文)；
// 缺手机号的员工置灰并提示原因。证件号码有问题不影响开通，
// 确认弹窗会提前提醒，开通后人事任务中心跟进核对。
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/inputs/uten_employee_picker.dart';
import '../../../components/layout/uten_adaptive_panel.dart';
import '../../employee/widgets/employee_account_provision_flow.dart';
import '../models/admin_models.dart';
import '../repositories/admin_repository.dart';

/// 弹出「开通账号」选择器；成功开通后回调 [onProvisioned]（外层刷新账号列表）。
Future<void> showProvisionAccountDialog(
  BuildContext context, {
  required VoidCallback onProvisioned,
}) {
  return showUtenAdaptivePanel<void>(
    context: context,
    drawerWidth: math.max(720, MediaQuery.sizeOf(context).width * 0.5),
    builder: (dialogContext) => _ProvisionAccountDialog(
      // 凭据弹窗要在选择器关闭之后展示，必须用仍存活的外层上下文。
      parentContext: context,
      onProvisioned: onProvisioned,
    ),
  );
}

class _ProvisionAccountDialog extends ConsumerStatefulWidget {
  const _ProvisionAccountDialog({
    required this.parentContext,
    required this.onProvisioned,
  });

  /// 发起页面的上下文：选择器 pop 后展示一次性凭据弹窗用。
  final BuildContext parentContext;
  final VoidCallback onProvisioned;

  @override
  ConsumerState<_ProvisionAccountDialog> createState() =>
      _ProvisionAccountDialogState();
}

class _ProvisionAccountDialogState
    extends ConsumerState<_ProvisionAccountDialog> {
  final _candidates = <String, AccountProvisionCandidate>{};
  bool _provisioning = false;

  Future<List<UtenEmployeePickerItem>> _load(String? keyword) async {
    final rows = await ref
        .read(adminRepositoryProvider)
        .provisionCandidates(search: keyword);
    for (final row in rows) {
      _candidates[row.employeeId] = row;
    }
    return [
      for (final row in rows)
        UtenEmployeePickerItem(
          id: row.employeeId,
          name: row.name,
          employeeCode: row.code,
          departmentId: row.departmentId,
          departmentName: row.departmentName,
          enabled: row.provisionable,
          disabledReason: row.provisionable
              ? null
              : '请先在员工档案中补全${row.missingHint}',
        ),
    ];
  }

  Future<void> _provision(AccountProvisionCandidate candidate) async {
    if (_provisioning) return;
    setState(() => _provisioning = true);
    try {
      final result = await showProvisionSelectedEmployeeAccountFlow(
        widget.parentContext,
        ref: ref,
        employeeId: candidate.employeeId,
        employeeName: candidate.name,
        employeeCode: candidate.code,
        hasAccount: false,
      );
      if (!mounted || result == null) return;
      Navigator.pop(context);
      widget.onProvisioned();
    } finally {
      if (mounted) setState(() => _provisioning = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_provisioning,
    child: AbsorbPointer(
      absorbing: _provisioning,
      child: UtenEmployeeSelectionPanel(
        loader: _load,
        title: '选择开通账号的员工',
        emptyMessage: '没有匹配的待开通员工',
        onConfirm: (selection) {
          if (selection.isEmpty || _provisioning) return;
          final candidate = _candidates[selection.single.id];
          if (candidate != null && candidate.provisionable) {
            _provision(candidate);
          }
        },
      ),
    ),
  );
}
