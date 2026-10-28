// 员工联系方式编辑对话框（ADR-021）：
// - 更换手机号（有账号且登录名实际变化时同步账号并撤销旧会话）
// - 车辆管理（整体替换：车牌必填，车型/品牌/颜色/备注非必填）
// - 备用手机号管理（整体替换：号码必填，标签默认「备用」）
// 文案硬编码中文（与 HR 运维页同惯例）。
import '../../../components/inputs/uten_field_hint_icon.dart';
import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'package:flutter/material.dart';

import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../models/employee_api_models.dart';

// ============================================================
// 更换手机号
// ============================================================

/// 返回新手机号；取消返回 null。仅做本地格式校验（1 开头 11 位），后端独立校验。
Future<String?> showEmployeeChangePhoneDialog(
  BuildContext context,
  String? currentPhone, {
  bool? hasAccount,
}) async {
  final l10n = AppLocalizations.of(context);
  final controller = TextEditingController();
  String? error;
  try {
    return await UtenDialog.showAndWaitForExit<String>(
      context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => UtenAlertDialog(
          title: Text(l10n.employeeChangePhoneTitle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.employeeChangePhoneCurrent(currentPhone ?? '—')),
              const SizedBox(height: UtenSpacing.s8),
              Container(
                padding: const EdgeInsets.all(UtenSpacing.s8),
                decoration: BoxDecoration(
                  color: Theme.of(
                    ctx,
                  ).colorScheme.errorContainer.withValues(alpha: 0.4),
                  borderRadius: UtenRadius.smAll,
                ),
                child: Text(
                  hasAccount == false
                      ? l10n.employeeChangePhoneNoAccountNotice
                      : l10n.employeeChangePhoneAccountNotice,
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
              ),
              const SizedBox(height: UtenSpacing.s12),
              TextField(
                controller: controller,
                keyboardType: TextInputType.phone,
                maxLength: 11,
                decoration: UtenInputDecoration(
                  InputDecoration(
                    labelText: l10n.employeeChangePhoneNewLabel,
                    hintText: l10n.employeeOnboardHintPhone,
                    error: utenFieldError(error),
                  ),
                ),
                onChanged: (_) => setState(() => error = null),
              ),
            ],
          ),
          actionsAlignment: MainAxisAlignment.center,
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(l10n.commonCancel),
            ),
            FilledButton(
              onPressed: () {
                final v = controller.text.trim();
                if (!RegExp(r'^1[3-9]\d{9}$').hasMatch(v)) {
                  setState(() => error = l10n.employeeOnboardPhoneInvalid);
                  return;
                }
                Navigator.pop(ctx, v);
              },
              child: Text(l10n.employeeChangePhoneConfirm),
            ),
          ],
        ),
      ),
    );
  } finally {
    controller.dispose();
  }
}

// ============================================================
// 车辆管理
// ============================================================

/// 车辆整体编辑。返回提交用 List<Map>（取消返回 null）。
Future<List<Map<String, dynamic>>?> showEmployeeVehiclesDialog(
  BuildContext context,
  List<EmployeeVehicleView> current,
) async {
  final vehicles = current
      .map(
        (v) => _VehicleDraft(
          plateNo: v.plateNo ?? '',
          vehicleType: v.vehicleType ?? '',
          brandModel: v.brandModel ?? '',
          color: v.color ?? '',
          remark: v.remark ?? '',
        ),
      )
      .toList();
  String? error;

  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => UtenAlertDialog(
        scrollable: false,
        title: const Text('车辆管理'),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('可登记多辆车；只有车牌号必填，其余可留空。'),
              const SizedBox(height: UtenSpacing.s8),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
                  child: Text(
                    error!,
                    style: TextStyle(color: Theme.of(ctx).colorScheme.error),
                  ),
                ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (var i = 0; i < vehicles.length; i++)
                      _vehicleEditor(ctx, vehicles[i], () {
                        setState(() => vehicles.removeAt(i));
                      }, () => setState(() {})),
                  ],
                ),
              ),
              TextButton.icon(
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('添加车辆'),
                onPressed: () => setState(() => vehicles.add(_VehicleDraft())),
              ),
            ],
          ),
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final plates = <String>{};
              for (final v in vehicles) {
                final norm = v.plateNo
                    .replaceAll(RegExp(r'\s+'), '')
                    .toUpperCase();
                if (!RegExp(r'^[\u4e00-\u9fa5A-Z0-9]{7,8}$').hasMatch(norm)) {
                  setState(() => error = '车牌号格式不正确：${v.plateNo}(7-8 位)');
                  return;
                }
                if (!plates.add(norm)) {
                  setState(() => error = '车牌号重复：$norm');
                  return;
                }
              }
              Navigator.pop(ctx, true);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    ),
  );
  if (ok != true) return null;
  return [
    for (final v in vehicles)
      {
        'plateNo': v.plateNo.trim(),
        if (v.vehicleType.trim().isNotEmpty)
          'vehicleType': v.vehicleType.trim(),
        if (v.brandModel.trim().isNotEmpty) 'brandModel': v.brandModel.trim(),
        if (v.color.trim().isNotEmpty) 'color': v.color.trim(),
        if (v.remark.trim().isNotEmpty) 'remark': v.remark.trim(),
      },
  ];
}

class _VehicleDraft {
  _VehicleDraft({
    this.plateNo = '',
    this.vehicleType = '',
    this.brandModel = '',
    this.color = '',
    this.remark = '',
  });
  String plateNo;
  String vehicleType;
  String brandModel;
  String color;
  String remark;
}

Widget _vehicleEditor(
  BuildContext ctx,
  _VehicleDraft v,
  VoidCallback onRemove,
  VoidCallback onChanged,
) {
  InputDecoration deco(String label, {String? hint}) => InputDecoration(
    labelText: label,
    hintText: hint,
    isDense: true,
    border: const OutlineInputBorder(),
  );
  return Card(
    margin: const EdgeInsets.only(bottom: UtenSpacing.s8),
    child: Padding(
      padding: const EdgeInsets.all(UtenSpacing.s8),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: TextFormField(
                  errorBuilder: utenTextFieldErrorBuilder,
                  initialValue: v.plateNo,
                  decoration: UtenInputDecoration(
                    deco('车牌号 *', hint: '如 粤T12345'),
                  ),
                  onChanged: (x) => v.plateNo = x,
                ),
              ),
              IconButton(
                tooltip: '删除',
                icon: const Icon(Icons.delete_outline_rounded, size: 20),
                onPressed: onRemove,
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s8),
          Row(
            children: [
              Expanded(
                child: TextFormField(
                  errorBuilder: utenTextFieldErrorBuilder,
                  initialValue: v.vehicleType,
                  decoration: UtenInputDecoration(deco('车型')),
                  onChanged: (x) => v.vehicleType = x,
                ),
              ),
              const SizedBox(width: UtenSpacing.s8),
              Expanded(
                child: TextFormField(
                  errorBuilder: utenTextFieldErrorBuilder,
                  initialValue: v.brandModel,
                  decoration: UtenInputDecoration(deco('品牌型号')),
                  onChanged: (x) => v.brandModel = x,
                ),
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s8),
          Row(
            children: [
              Expanded(
                child: TextFormField(
                  errorBuilder: utenTextFieldErrorBuilder,
                  initialValue: v.color,
                  decoration: UtenInputDecoration(deco('颜色')),
                  onChanged: (x) => v.color = x,
                ),
              ),
              const SizedBox(width: UtenSpacing.s8),
              Expanded(
                child: TextFormField(
                  errorBuilder: utenTextFieldErrorBuilder,
                  initialValue: v.remark,
                  decoration: UtenInputDecoration(deco('备注')),
                  onChanged: (x) => v.remark = x,
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

// ============================================================
// 备用手机号管理
// ============================================================

/// 备用手机号整体编辑。返回提交用 List<Map>（取消返回 null）。
Future<List<Map<String, dynamic>>?> showEmployeePhonesDialog(
  BuildContext context,
  List<EmployeePhoneView> current,
) async {
  final phones = current
      .map((p) => _PhoneDraft(label: p.label ?? '备用', phone: p.phone ?? ''))
      .toList();
  String? error;

  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => UtenAlertDialog(
        scrollable: false,
        title: const Row(
          children: [
            Flexible(child: Text('备用手机号管理')),
            UtenFieldHintIcon(
              info:
                  '主手机号用于登录，在这里之外的「更换手机号」维护；'
                  '此处登记额外联系号码(不参与登录)。',
              dense: true,
            ),
          ],
        ),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
                  child: Text(
                    error!,
                    style: TextStyle(color: Theme.of(ctx).colorScheme.error),
                  ),
                ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (var i = 0; i < phones.length; i++)
                      Padding(
                        padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 90,
                              child: TextFormField(
                                errorBuilder: utenTextFieldErrorBuilder,
                                initialValue: phones[i].label,
                                decoration: const UtenInputDecoration(
                                  InputDecoration(
                                    labelText: '标签',
                                    isDense: true,
                                    border: OutlineInputBorder(),
                                  ),
                                ),
                                onChanged: (x) => phones[i].label = x,
                              ),
                            ),
                            const SizedBox(width: UtenSpacing.s8),
                            Expanded(
                              child: TextFormField(
                                errorBuilder: utenTextFieldErrorBuilder,
                                initialValue: phones[i].phone,
                                keyboardType: TextInputType.phone,
                                decoration: const UtenInputDecoration(
                                  InputDecoration(
                                    labelText: '手机号',
                                    isDense: true,
                                    border: OutlineInputBorder(),
                                  ),
                                ),
                                onChanged: (x) => phones[i].phone = x,
                              ),
                            ),
                            IconButton(
                              tooltip: '删除',
                              icon: const Icon(
                                Icons.delete_outline_rounded,
                                size: 20,
                              ),
                              onPressed: () =>
                                  setState(() => phones.removeAt(i)),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              TextButton.icon(
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('添加号码'),
                onPressed: () => setState(() => phones.add(_PhoneDraft())),
              ),
            ],
          ),
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final seen = <String>{};
              for (final p in phones) {
                final norm = p.phone.replaceAll(RegExp(r'[\s\-()]'), '');
                if (!RegExp(r'^1[3-9]\d{9}$').hasMatch(norm)) {
                  setState(() => error = '手机号格式不正确：${p.phone}');
                  return;
                }
                if (!seen.add(norm)) {
                  setState(() => error = '手机号重复：$norm');
                  return;
                }
              }
              Navigator.pop(ctx, true);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    ),
  );
  if (ok != true) return null;
  return [
    for (final p in phones)
      {
        'label': p.label.trim().isEmpty ? '备用' : p.label.trim(),
        'phone': p.phone.trim(),
      },
  ];
}

class _PhoneDraft {
  _PhoneDraft({this.label = '备用', this.phone = ''});
  String label;
  String phone;
}
