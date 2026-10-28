import 'master_reference_options_loader.dart';
// 供应商主档「编辑」表单的公共实现（2026-09-14 抽取）。
// 供应商分类页（列表内编辑）与供应商详情整页（/basicinfo/suppliers/:id）共用。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/inputs/uten_employee_picker.dart';
import '../../../core/ui/action_feedback.dart';
import '../../../shared/auth/permissions.dart';
import '../../employee/repositories/employee_repository.dart';
import '../../employee/models/employee_api_models.dart';
import '../../employee/widgets/department_employee_picker.dart';
import '../models/currency_node.dart';
import 'client_master_edit.dart' show loadClientCurrencies;
import '../models/reference_method_option.dart';
import '../models/supplier_node.dart';
import '../repositories/reference_method_repository.dart';
import '../repositories/supplier_repository.dart';
import '../widgets/master_edit_dialog.dart';
import 'master_edit_owner.dart';

Future<List<ReferenceMethodOption>?> loadSupplierSettlementMethods(
  BuildContext context,
  WidgetRef ref, {
  MasterEditOwner? owner,
}) => loadMasterReferenceOptions<ReferenceMethodOption>(
  context: context,
  ref: ref,
  resourceKey: 'supplier.settlementMethods',
  title: '正在读取结账方式…',
  load: () => ref.read(referenceMethodRepositoryProvider).settlementMethods(),
  emptyMessage: '暂无可用结算方式，请先维护结账方式字典',
  errorFallback: '加载结算方式失败，请重试',
  owner: owner,
);

/// 供应商主档可编辑字段（与后端 SupplierSaveRequest 对齐）。
List<MasterFieldDef> buildSupplierFields(
  BuildContext context,
  Map<String, String> iv,
  List<ReferenceMethodOption> settlementMethods,
  WidgetRef ref, {
  List<CurrencyListItem> currencies = const [],
  MasterEditOwner? owner,
}) => [
  ...<MasterFieldDef>[
    const MasterFieldDef(key: 'name', label: '名称', required: true, group: '基础'),
    MasterFieldDef(
      key: 'code',
      label: '编号',
      group: '基础',
      hint: '留空按分类前缀自动生成；手工编号也必须唯一',
      identifierDomain: 'SUPPLIER',
      identifierId: iv['_entityId'],
    ),
    const MasterFieldDef(key: 'description', label: '描述/全称', group: '基础'),
    const MasterFieldDef(key: 'place', label: '地区', group: '地址'),
  ],
  MasterFieldDef(
    key: 'ownerEmployeeId',
    label: '业务员',
    type: MasterFieldType.custom,
    group: '资质',
    customBuilder: (ctx) => DepartmentEmployeePickerField(
      label: '业务员',
      hint: '选择在职员工',
      initialId: ctx.initialValue,
      initialName: iv['ownerEmployeeName'],
      initialLoader: (employeeId) async {
        Future<EmployeeProfile> read() =>
            ref.read(employeeRepositoryProvider).getById(employeeId);
        final employee = owner == null ? await read() : await owner.run(read);
        return UtenEmployeePickerItem(
          id: employee.id,
          name: employee.fullName ?? '',
          employeeCode: employee.code,
          accountStatus: employee.accountDeleted
              ? 'notProvisioned'
              : employee.accountStatus ?? 'notProvisioned',
          employmentStatus: employee.status,
          departmentId: employee.departmentId,
          departmentName: employee.departmentName,
        );
      },
      onChanged: ctx.onChanged,
      onPick: () => showUtenDepartmentEmployeePicker(
        context,
        ref,
        title: '选择业务员',
        dialogScopeBuilder: owner?.ownDialog,
        isCurrent: owner == null ? null : () => owner.isCurrent,
      ),
    ),
  ),
  ...const <MasterFieldDef>[
    MasterFieldDef(key: 'legalPerson', label: '法人', group: '资质'),
    // 2026-09-14 口径：联系人必填、手机不再必填（多联系方式在详情页登记）。
    MasterFieldDef(key: 'linkman', label: '联系人', required: true, group: '联系'),
    MasterFieldDef(key: 'mobile', label: '手机', group: '联系'),
    MasterFieldDef(key: 'phone', label: '电话', group: '联系'),
    MasterFieldDef(key: 'phone2', label: '电话2', group: '联系'),
    MasterFieldDef(key: 'fax', label: '传真', group: '联系'),
    MasterFieldDef(key: 'postcode', label: '邮编', group: '联系'),
    MasterFieldDef(key: 'address', label: '地址', group: '地址'),
    MasterFieldDef(key: 'email', label: '邮箱', group: '联系'),
    MasterFieldDef(key: 'website', label: '网址', group: '联系'),
    MasterFieldDef(key: 'shipVia', label: '运输方式', group: '地址'),
    MasterFieldDef(key: 'shipAddress', label: '收货地址', group: '地址'),
    MasterFieldDef(key: 'bank', label: '开户行', group: '财务'),
    MasterFieldDef(key: 'bankAccount', label: '银行账号', group: '财务'),
    MasterFieldDef(key: 'taxId', label: '税号', group: '财务'),
    MasterFieldDef(
      key: 'initTotal',
      label: '期初应付',
      type: MasterFieldType.money,
      group: '财务',
    ),
    MasterFieldDef(
      key: 'tday',
      label: '结算天数',
      type: MasterFieldType.integer,
      group: '财务',
    ),
  ],
  MasterFieldDef(
    key: 'defaultSettlementMethodId',
    label: '默认结算方式',
    type: MasterFieldType.select,
    options: [
      for (final method in settlementMethods)
        MasterSelectOption(
          value: method.id,
          label: method.code.isEmpty
              ? method.name
              : '${method.name} · ${method.code}',
        ),
    ],
    group: '财务',
    hint: '采购/委外订货开单时预填结账方式；不影响既有单据与应付',
  ),
  ...const <MasterFieldDef>[
    MasterFieldDef(
      key: 'status',
      label: '状态',
      type: MasterFieldType.select,
      options: kMasterStatusOptions,
      required: true,
      group: '基础',
    ),
    MasterFieldDef(key: 'remark', label: '备注', group: '其他'),
  ],
];

/// 供应商编辑弹窗（分类页与详情页共用）。[onSaved] 在保存成功后回调。
Future<void> showSupplierMasterEdit(
  BuildContext context,
  WidgetRef ref,
  SupplierDetail d, {
  String? fallbackCategoryId,
  VoidCallback? onSaved,
}) async {
  final owner = MasterEditOwner(
    context,
    ref,
    permissions: {Perm.supplierView, Perm.supplierEdit},
  );
  try {
    if (!await owner.bindRequests()) return;
    if (!context.mounted) return;
    await _showSupplierMasterEditOwned(
      context,
      ref,
      d,
      owner,
      fallbackCategoryId: fallbackCategoryId,
      onSaved: onSaved,
    );
  } finally {
    owner.dispose();
  }
}

Future<void> _showSupplierMasterEditOwned(
  BuildContext context,
  WidgetRef ref,
  SupplierDetail d,
  MasterEditOwner owner, {
  String? fallbackCategoryId,
  VoidCallback? onSaved,
}) async {
  final settlementMethods = await loadSupplierSettlementMethods(
    context,
    ref,
    owner: owner,
  );
  if (!context.mounted || !owner.isCurrent || settlementMethods == null) return;
  // V593 默认币种下拉；加载失败不阻断编辑（只是该项没有选项）。
  final currencies =
      await loadClientCurrencies(context, ref, owner: owner) ??
      const <CurrencyListItem>[];
  if (!context.mounted || !owner.isCurrent) return;
  if (d.defaultSettlementMethodId != null &&
      !settlementMethods.any(
        (method) => method.id == d.defaultSettlementMethodId,
      )) {
    context.appError('该供应商保存的默认结算方式已不可用，请先在列表里修正后再编辑');
    return;
  }
  final iv = supplierInitialValues(d);
  final permissions = ref.read(currentPermissionsProvider);
  await showMasterEditDialog(
    context: context,
    title: '编辑供应商',
    fields: buildSupplierFields(
      context,
      iv,
      settlementMethods,
      ref,
      currencies: currencies,
      owner: owner,
    ),
    initialValues: iv,
    fixedValues: {
      'categoryId': d.categoryId ?? fallbackCategoryId,
      if (d.version != null) 'version': d.version,
    },
    readOnlyKeys: permissions.contains(Perm.supplierStatus)
        ? null
        : const {'status'},
    submissionOwner: owner,
    onSubmit: (body) async {
      await ref.read(supplierRepositoryProvider).update(d.id, body);
      return true;
    },
    onAccepted: () {
      if (!owner.isCurrent) return;
      context.appSuccess('供应商已更新');
      onSaved?.call();
    },
  );
}

Map<String, String> supplierInitialValues(SupplierDetail d) => {
  '_entityId': d.id,
  'name': d.name ?? '',
  'code': d.code ?? '',
  'description': d.description ?? '',
  'place': d.place ?? '',
  'ownerEmployeeId': d.ownerEmployeeId ?? '',
  'ownerEmployeeName': d.ownerEmployeeName ?? d.empId ?? '',
  'legalPerson': d.legalPerson ?? '',
  'linkman': d.linkman ?? '',
  'mobile': d.mobile ?? '',
  'phone': d.phone ?? '',
  'phone2': d.phone2 ?? '',
  'fax': d.fax ?? '',
  'postcode': d.postcode ?? '',
  'address': d.address ?? '',
  'email': d.email ?? '',
  'website': d.website ?? '',
  'shipVia': d.shipVia ?? '',
  'shipAddress': d.shipAddress ?? '',
  'bank': d.bank ?? '',
  'bankAccount': d.bankAccount ?? '',
  'taxId': d.taxId ?? '',
  'initTotal': d.initTotal?.toString() ?? '',
  'tday': d.tday?.toString() ?? '',
  'defaultSettlementMethodId': d.defaultSettlementMethodId ?? '',
  'defaultCurrencyId': d.defaultCurrencyId ?? '',
  'defaultTaxRate': d.defaultTaxRate?.toString() ?? '',
  'status': d.status ?? '',
  'remark': d.remark ?? '',
};
