import 'package:flutter/material.dart';

import '../../../components/data_display/uten_status_badge.dart';

class FinanceAssetCapabilities {
  const FinanceAssetCapabilities({
    required this.canView,
    required this.canEdit,
    required this.canApprove,
    required this.canPost,
    required this.canDispose,
    required this.canManagePeriod,
  });

  final bool canView;
  final bool canEdit;
  final bool canApprove;
  final bool canPost;
  final bool canDispose;
  final bool canManagePeriod;
}

String financeAssetStatusLabel(String status) {
  return switch (status.trim().toUpperCase()) {
    'DRAFT' => '草稿',
    'SUBMITTED' || 'PENDING_APPROVAL' => '待审批',
    'APPROVED' => '已审批',
    'ACTIVE' => '使用中',
    'IDLE' => '闲置',
    'SUSPENDED' => '暂停',
    'DISPOSED' => '已处置',
    'DISPOSAL_PENDING' => '待处置',
    'TERMINATED' => '已终止',
    'TERMINATION_PENDING' => '待终止',
    'COMPLETED' => '已完成',
    'PREVIEWED' => '已预览',
    'POSTED' => '已过账',
    'REVERSED' => '已冲销',
    'CLOSED' => '已关闭',
    'OPEN' => '开放',
    'REJECTED' => '已驳回',
    final value when value.isNotEmpty => value,
    _ => '未知',
  };
}

UtenStatusBadgeType financeAssetStatusType(String status) {
  return switch (status.trim().toUpperCase()) {
    'ACTIVE' ||
    'APPROVED' ||
    'POSTED' ||
    'COMPLETED' => UtenStatusBadgeType.success,
    'SUBMITTED' ||
    'PENDING_APPROVAL' ||
    'DISPOSAL_PENDING' ||
    'TERMINATION_PENDING' ||
    'PREVIEWED' ||
    'IDLE' => UtenStatusBadgeType.warning,
    'REJECTED' ||
    'DISPOSED' ||
    'TERMINATED' ||
    'REVERSED' => UtenStatusBadgeType.danger,
    'SUSPENDED' => UtenStatusBadgeType.info,
    'OPEN' => UtenStatusBadgeType.accent,
    _ => UtenStatusBadgeType.neutral,
  };
}

Widget financeAssetStatusBadge(String status, {Key? key}) {
  return UtenStatusBadge(
    key: key,
    label: financeAssetStatusLabel(status),
    type: financeAssetStatusType(status),
  );
}

String? validateRequired(String? value, String label) {
  if (value == null || value.trim().isEmpty) return '请填写$label';
  return null;
}

String? validateMaxLength(String? value, int maxLength, String label) {
  if ((value ?? '').trim().length > maxLength) {
    return '$label不能超过 $maxLength 个字符';
  }
  return null;
}

String? validateRequiredMaxLength(String? value, int maxLength, String label) {
  return validateRequired(value, label) ??
      validateMaxLength(value, maxLength, label);
}

String? validateFinanceAmount(String? value, {String label = '金额'}) {
  final raw = value?.trim() ?? '';
  if (raw.isEmpty) return '请填写$label';
  if (!RegExp(r'^\d{1,16}(?:\.\d{1,2})?$').hasMatch(raw)) {
    return '$label应为不超过 16 位整数、2 位小数的正数';
  }
  final digits = raw.replaceAll('.', '').replaceFirst(RegExp(r'^0+'), '');
  if (digits.isEmpty) return '$label必须大于 0';
  return null;
}

String? validateNonNegativeFinanceAmount(String? value, {String label = '金额'}) {
  final raw = value?.trim() ?? '';
  if (raw.isEmpty) return '请填写$label';
  if (!RegExp(r'^\d{1,16}(?:\.\d{1,2})?$').hasMatch(raw)) {
    return '$label应为不超过 16 位整数、2 位小数的非负数';
  }
  return null;
}

String? validateSalvageRate(String? value) {
  final raw = value?.trim() ?? '';
  if (raw.isEmpty) return null;
  if (!RegExp(r'^(?:0(?:\.\d{1,6})?|1(?:\.0{1,6})?)$').hasMatch(raw)) {
    return '残值率应在 0 到 1 之间，例如 0.05';
  }
  return null;
}

String? validateUsefulMonths(String? value) {
  final raw = value?.trim() ?? '';
  final months = int.tryParse(raw);
  if (months == null || months < 1 || months > 1200) {
    return '月份应为 1 到 1200 的整数';
  }
  return null;
}

String? validateFinancePeriod(String? value, {bool required = true}) {
  final raw = value?.trim() ?? '';
  if (raw.isEmpty) return required ? '请填写期间' : null;
  final match = RegExp(r'^(\d{4})-(\d{2})$').firstMatch(raw);
  if (match == null) return '期间格式应为 YYYY-MM';
  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  if (year < 1900 || year > 9999 || month < 1 || month > 12) {
    return '请输入真实有效的会计期间';
  }
  return null;
}

String? validateFinanceDate(String? value, {required bool required}) {
  final raw = value?.trim() ?? '';
  if (raw.isEmpty) return required ? '请填写日期' : null;
  final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(raw);
  if (match == null) return '日期格式应为 YYYY-MM-DD';
  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final day = int.parse(match.group(3)!);
  try {
    final parsed = DateTime.utc(year, month, day);
    if (parsed.year != year || parsed.month != month || parsed.day != day) {
      return '请输入真实有效的日期';
    }
  } on ArgumentError {
    return '请输入真实有效的日期';
  }
  return null;
}

bool actionAllowed(Set<String> allowedActions, String action) {
  return allowedActions.contains(action.toUpperCase());
}

String currentFinancePeriod() {
  final now = DateTime.now();
  return '${now.year}-${now.month.toString().padLeft(2, '0')}';
}
