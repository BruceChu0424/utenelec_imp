// 我的车辆与备用手机号（ADR-021）：员工自助维护，直改即时生效（不需 HR 审核）。
// 数据：/api/profile/me/vehicles、/api/profile/me/phones（仅本人）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/feedback/uten_empty.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../employee/models/employee_api_models.dart';
import '../../employee/widgets/employee_contact_edit_dialog.dart';
import '../repositories/my_vehicle_phone_repository.dart';

class MyVehiclePhonePage extends ConsumerStatefulWidget {
  const MyVehiclePhonePage({super.key});

  @override
  ConsumerState<MyVehiclePhonePage> createState() => _MyVehiclePhonePageState();
}

class _MyVehiclePhonePageState extends ConsumerState<MyVehiclePhonePage> {
  List<EmployeeVehicleView>? _vehicles;
  List<EmployeePhoneView>? _phones;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final repo = ref.read(myVehiclePhoneRepositoryProvider);
      final results = await Future.wait([repo.vehicles(), repo.phones()]);
      if (!mounted) return;
      setState(() {
        _vehicles = results[0] as List<EmployeeVehicleView>;
        _phones = results[1] as List<EmployeePhoneView>;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = '加载失败，请稍后重试');
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget body;
    if (_error != null) {
      body = UtenEmpty.error(
        message: _error,
        actionLabel: '重试',
        onAction: _load,
      );
    } else if (_vehicles == null || _phones == null) {
      body = const Center(child: CircularProgressIndicator());
    } else {
      body = RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(UtenSpacing.s12),
          children: [
            _vehicleSection(context),
            const SizedBox(height: UtenSpacing.s12),
            _phoneSection(context),
          ],
        ),
      );
    }
    if (context.breakpoint.isCompact) {
      body = UtenContentContainer(child: body);
    }
    return Scaffold(
      appBar: const UtenAppBar(title: '我的车辆与号码', showBackButton: true),
      body: body,
    );
  }

  Widget _vehicleSection(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
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
              onPressed: _editVehicles,
            ),
          ),
          if (_vehicles!.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Text('未登记车辆'),
            )
          else
            for (final v in _vehicles!)
              ListTile(
                dense: true,
                title: Text(
                  v.plateNo ?? '',
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1,
                  ),
                ),
                subtitle: Text(
                  [
                        ?v.vehicleType,
                        ?v.brandModel,
                        ?v.color,
                        ?v.remark,
                      ].join(' · ').isEmpty
                      ? '—'
                      : [
                          ?v.vehicleType,
                          ?v.brandModel,
                          ?v.color,
                          ?v.remark,
                        ].join(' · '),
                ),
              ),
        ],
      ),
    );
  }

  Widget _phoneSection(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            leading: Icon(
              Icons.add_call,
              color: theme.colorScheme.primary,
            ),
            title: const Text(
              '备用手机号',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: const Text('主手机号用于登录；此处登记额外联系号码'),
            trailing: TextButton.icon(
              icon: const Icon(Icons.edit_outlined, size: 16),
              label: const Text('管理'),
              onPressed: _editPhones,
            ),
          ),
          if (_phones!.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Text('未登记备用手机号'),
            )
          else
            for (final p in _phones!)
              ListTile(
                dense: true,
                title: Text(p.phone ?? ''),
                subtitle: Text(p.label ?? '备用'),
              ),
        ],
      ),
    );
  }

  Future<void> _editVehicles() async {
    final result = await showEmployeeVehiclesDialog(context, _vehicles!);
    if (result == null || !mounted) return;
    try {
      await ref.read(myVehiclePhoneRepositoryProvider).replaceVehicles(result);
      if (!mounted) return;
      context.appSuccess('车辆信息已更新');
      _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      context.appApiError(e);
    }
  }

  Future<void> _editPhones() async {
    final result = await showEmployeePhonesDialog(context, _phones!);
    if (result == null || !mounted) return;
    try {
      await ref.read(myVehiclePhoneRepositoryProvider).replacePhones(result);
      if (!mounted) return;
      context.appSuccess('备用手机号已更新');
      _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      context.appApiError(e);
    }
  }
}
