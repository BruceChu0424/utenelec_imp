// 我的车辆 / 备用手机号自助管理卡（ADR-021，直改即时生效、不需 HR 审核）。
// 原独立页「我的车辆与号码」吸收进「我的」联系与车辆 Tab（我的页 v7）；
// 数据直接来自 GET /profile/me 的 vehicles / phones，管理走本人自助接口，
// 成功后 invalidate(myEmployeeProfileProvider) 刷新整个档案区。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/cards/uten_card.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/ui/app_notification.dart';
import '../../employee/models/employee_api_models.dart';
import '../../employee/widgets/employee_contact_edit_dialog.dart';
import '../providers/profile_change_providers.dart';
import '../repositories/my_vehicle_phone_repository.dart';

/// 车辆卡：列表只读展示 + 「管理」弹窗整体替换。
class MyVehiclesManageCard extends ConsumerWidget {
  const MyVehiclesManageCard({super.key, required this.vehicles});

  final List<EmployeeVehicleView> vehicles;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return UtenCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              Icons.directions_car_outlined,
              color: theme.colorScheme.primary,
            ),
            title: const Text(
              '我的车辆',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: const Text('登记常用车辆，方便行政/门岗按车牌找到你'),
            trailing: TextButton.icon(
              icon: const Icon(Icons.edit_outlined, size: 16),
              label: const Text('管理'),
              onPressed: () => _edit(context, ref),
            ),
          ),
          if (vehicles.isEmpty)
            const Padding(
              padding: EdgeInsets.only(bottom: 16),
              child: Text('未登记车辆'),
            )
          else
            for (final v in vehicles)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(
                  v.plateNo ?? '',
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1,
                  ),
                ),
                subtitle: Text(_vehicleDetail(v)),
              ),
        ],
      ),
    );
  }

  static String _vehicleDetail(EmployeeVehicleView v) {
    final detail = [
      ?v.vehicleType,
      ?v.brandModel,
      ?v.color,
      ?v.remark,
    ].where((s) => s.trim().isNotEmpty).join(' · ');
    return detail.isEmpty ? '—' : detail;
  }

  Future<void> _edit(BuildContext context, WidgetRef ref) async {
    final result = await showEmployeeVehiclesDialog(context, vehicles);
    if (result == null || !context.mounted) return;
    await _replaceSelf(
      context,
      ref,
      () => ref.read(myVehiclePhoneRepositoryProvider).replaceVehicles(result),
      '车辆信息已更新',
    );
  }
}

/// 备用手机号卡：列表只读展示 + 「管理」弹窗整体替换。
class MyPhonesManageCard extends ConsumerWidget {
  const MyPhonesManageCard({super.key, required this.phones});

  final List<EmployeePhoneView> phones;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return UtenCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.add_call, color: theme.colorScheme.primary),
            title: const Text(
              '备用手机号',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: const Text('主手机号用于登录；此处登记额外联系号码'),
            trailing: TextButton.icon(
              icon: const Icon(Icons.edit_outlined, size: 16),
              label: const Text('管理'),
              onPressed: () => _edit(context, ref),
            ),
          ),
          if (phones.isEmpty)
            const Padding(
              padding: EdgeInsets.only(bottom: 16),
              child: Text('未登记备用手机号'),
            )
          else
            for (final p in phones)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(p.phone ?? ''),
                subtitle: Text(p.label ?? '备用'),
              ),
        ],
      ),
    );
  }

  Future<void> _edit(BuildContext context, WidgetRef ref) async {
    final result = await showEmployeePhonesDialog(context, phones);
    if (result == null || !context.mounted) return;
    await _replaceSelf(
      context,
      ref,
      () => ref.read(myVehiclePhoneRepositoryProvider).replacePhones(result),
      '备用手机号已更新',
    );
  }
}

/// 提交自助替换并刷新本人档案；失败走统一 API 错误提示。
Future<void> _replaceSelf(
  BuildContext context,
  WidgetRef ref,
  Future<void> Function() replace,
  String successMessage,
) async {
  try {
    await replace();
    ref.invalidate(myEmployeeProfileProvider);
    if (!context.mounted) return;
    context.appSuccess(successMessage);
  } on ApiException catch (e) {
    if (!context.mounted) return;
    context.appApiError(e);
  }
}
