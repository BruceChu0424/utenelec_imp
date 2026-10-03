import '../../features/finance/config/finance_doc_config.dart';
import '../../features/production/repositories/production_material_increment_repository.dart'
    show productionMaterialIncrementPermission;
import '../../features/purchase/config/purchase_doc_config.dart';
import '../../features/sales/config/sales_doc_config.dart';
import '../../features/subcontract/config/subcontract_doc_config.dart';
import '../auth/permissions.dart';
import 'form_draft_catalog.dart';

/// History never exposes a generic JSON viewer. These values are a read-only
/// projection; the immutable recovery payload is neither rewritten nor redacted.
class FormDraftHistoryField {
  const FormDraftHistoryField(this.label, this.value);
  final String label;
  final String value;
}

class FormDraftHistorySection {
  const FormDraftHistorySection(this.label, this.fields);
  final String label;
  final List<FormDraftHistoryField> fields;
}

class FormDraftHistoryProjection {
  const FormDraftHistoryProjection(this.title, this.sections);
  final String title;
  final List<FormDraftHistorySection> sections;
}

typedef _HistoryPolicy = ({
  String title,
  String viewPermission,
  bool commercial,
  bool priceVisible,
});

_HistoryPolicy? _policy(FormDraft draft, Set<String> permissions) {
  if (!formDraftRouteIsLocal(draft.route)) return null;
  final path = Uri.parse(draft.route).path;
  if (FormDraftCatalog.dailyReport.groups(draft)) {
    // Retained report history is metadata-only. Reading it never grants the
    // dedicated raw recovery or proof-confirmation capability.
    return (
      title: FormDraftCatalog.dailyReport.title,
      viewPermission: Perm.productionDailyReportView,
      commercial: false,
      priceVisible: false,
    );
  }
  if (draft.module == BadgeModule.workshop &&
      path == '/production/material-increment-requests/new' &&
      draft.permission == productionMaterialIncrementPermission) {
    // Segment content additionally requires current server-side workshop scope.
    // Only the fixed workflow label is projected until that check is available.
    return (
      title: '申请追加用料',
      viewPermission: permissions.contains(Perm.productionPlanApprove)
          ? Perm.productionPlanApprove
          : Perm.productionExecutionView,
      commercial: false,
      priceVisible: false,
    );
  }
  for (final config in const [
    FinanceDocConfig.receipt,
    FinanceDocConfig.payment,
    FinanceDocConfig.expense,
    FinanceDocConfig.otherIncome,
    FinanceDocConfig.bankTransfer,
  ]) {
    if (draft.module == BadgeModule.finance &&
        path == '${config.listLocation}/new' &&
        draft.permission == config.createPerm) {
      // Finance line schemas and account visibility need their own projection.
      // Preserve discoverability without treating all stored monetary data as
      // authorized by the generic document permission.
      return (
        title: config.label,
        viewPermission: config.listPerm,
        commercial: false,
        priceVisible: false,
      );
    }
  }
  for (final config in const [
    SalesDocConfig.quote,
    SalesDocConfig.order,
    SalesDocConfig.shipment,
    SalesDocConfig.otherShipment,
    SalesDocConfig.customerShipment,
    SalesDocConfig.returnDoc,
  ]) {
    if (draft.module == BadgeModule.sales &&
        path == '/sales/${config.type.pathSegment}/new' &&
        draft.permission == config.createPerm) {
      return (
        title: config.label,
        viewPermission: config.listPerm,
        commercial: true,
        priceVisible: permissions.contains(Perm.salesOrderPriceView),
      );
    }
  }
  for (final config in const [
    PurchaseDocConfig.request,
    PurchaseDocConfig.order,
    PurchaseDocConfig.receipt,
    PurchaseDocConfig.returnDoc,
  ]) {
    if (draft.module == BadgeModule.purchase &&
        path == '/purchase/${config.type.pathSegment}/new' &&
        draft.permission == config.createPerm) {
      return (
        title: config.label,
        viewPermission: config.listPerm,
        commercial: true,
        priceVisible: config.canViewCommercial(permissions),
      );
    }
  }
  for (final config in const [
    SubcontractDocConfig.inquiry,
    SubcontractDocConfig.application,
    SubcontractDocConfig.order,
    SubcontractDocConfig.receipt,
    SubcontractDocConfig.materialIssue,
    SubcontractDocConfig.returnDoc,
    SubcontractDocConfig.materialReturn,
    SubcontractDocConfig.waste,
  ]) {
    if (draft.module == BadgeModule.subcontract &&
        path == '/subcontract/${config.type.pathSegment}/new' &&
        draft.permission == config.createPerm) {
      return (
        title: config.label,
        viewPermission: config.listPerm,
        commercial: true,
        priceVisible: config.canViewCommercial(permissions),
      );
    }
  }
  for (final descriptor in FormDraftCatalog.all.values) {
    if (descriptor.groups(draft)) {
      return (
        title: descriptor.title,
        viewPermission: descriptor.permission,
        commercial: false,
        priceVisible: false,
      );
    }
  }
  return null;
}

/// The persisted permission is an identity claim, never a grant. Commercial
/// history needs today's view permission, even after create/edit is revoked.
bool canReadFormDraftHistory(FormDraft draft, Set<String> permissions) {
  final policy = _policy(draft, permissions);
  return policy != null && permissions.contains(policy.viewPermission);
}

String? formDraftHistoryTitle(FormDraft draft, Set<String> permissions) =>
    canReadFormDraftHistory(draft, permissions)
    ? _policy(draft, permissions)!.title
    : null;

Map<Object?, Object?> _map(Object? value) => value is Map ? value : const {};

const formDraftHistoryReadOnlyProjectionKey =
    '_formDraftHistoryReadOnlyProjection';

const _headerFields = {
  'billDate': '单据日期',
  'deliverDate': '交货日期',
  'validUntil': '有效期',
  'createdDocId': '已创建单据标识',
  'clientId': '客户标识',
  'supplierId': '供应商标识',
  'warehouseId': '仓库标识',
  'currencyId': '币种标识',
  'settlementMethodId': '结算方式标识',
};
const _goodsFields = {'name': '货品名称', 'nameEn': '英文名称', 'code': '货品编号'};
const _rowFields = {
  'documentItemId': '单据明细标识',
  'orderItemId': '来源订单明细标识',
  'outItemId': '来源出货明细标识',
  'requestItemId': '来源申请明细标识',
  'receiptItemId': '来源收货明细标识',
  'unitId': '单位标识',
  'colorId': '颜色标识',
  'stockPlace': '库位',
  'supplierId': '供应商标识',
  'currencyId': '币种标识',
};
Map<String, String> _rowTextFields(bool priceVisible) => {
  'qty': '数量',
  'weight': '重量',
  'inboundQty': '进仓数量（历史参考）',
  'circumference': '围数',
  'clientModel': '客户型号',
  'clientGoodsName': '客户货品名称',
  if (priceVisible) ...{
    'price': '单价',
    'discount': '折扣',
    'machiningPrice': '加工单价',
    'materialPrice': '材料单价',
    'dieCastPrice': '压铸单价',
  },
};
const _peopleHeaderFields = {
  'hireDate': '入职日期',
  'confirmedDate': '转正日期',
  'departmentId': '部门标识',
};
Map<String, String> _peopleFields(Set<String> permissions) => {
  'name': '姓名',
  if (permissions.contains(Perm.employeePiiView)) ...{
    'idNumber': '证件号码',
    'phone': '联系电话',
    'email': '邮箱',
    'bankAccount': '银行账号',
    'bankBranch': '开户行',
  },
  if (permissions.contains(Perm.employeeCompensationView)) 'baseSalary': '基本工资',
};

Map<String, dynamic> _select(
  Map<Object?, Object?> data,
  Iterable<String> keys,
) => {
  for (final key in keys)
    if (data[key] case final String value when value.isNotEmpty)
      key: value
    else if (data[key] case final num value)
      key: value,
};

/// Public history APIs expose this typed, detached view, not a recoverable
/// editor snapshot. Persisted originals are never modified. The marker blocks
/// accidental save-back of a projection that intentionally omits private data.
FormDraft? projectFormDraftHistorySnapshot(
  FormDraft draft,
  Set<String> permissions,
) {
  if (!canReadFormDraftHistory(draft, permissions)) return null;
  final policy = _policy(draft, permissions)!;
  final data = <String, dynamic>{formDraftHistoryReadOnlyProjectionKey: true};
  if (policy.commercial) {
    data.addAll(_select(draft.data, _headerFields.keys));
    if (draft.data['rows'] case final List<Object?> rows) {
      data['rows'] = [
        for (final value in rows)
          {
            ..._select(_map(value), _rowFields.keys),
            'goods': _select(_map(_map(value)['goods']), _goodsFields.keys),
            'text': _select(
              _map(_map(value)['text']),
              _rowTextFields(policy.priceVisible).keys,
            ),
          },
      ];
    }
  } else if (FormDraftCatalog.employeeOnboarding.groups(draft)) {
    data.addAll(_select(draft.data, _peopleHeaderFields.keys));
    data['fields'] = _select(
      _map(draft.data['fields']),
      _peopleFields(permissions).keys,
    );
  }
  return FormDraft.fromJson({
    ...draft.toJson(),
    'title': policy.title,
    'data': data,
  });
}

List<FormDraftHistoryField> _fields(
  Map<Object?, Object?> data,
  Map<String, String> labels,
) => [
  for (final entry in labels.entries)
    if (data[entry.key] case final String value when value.isNotEmpty)
      FormDraftHistoryField(entry.value, value)
    else if (data[entry.key] case final num value)
      FormDraftHistoryField(entry.value, value.toString()),
];

/// Only known schema paths are visited. In particular attachments, frozen
/// commands, AI responses, arbitrary extra columns and nested JSON are absent.
/// Their access policies cannot be inferred from a key such as 'value'.
FormDraftHistoryProjection? projectFormDraftHistory(
  FormDraft draft,
  Set<String> permissions,
) {
  if (!canReadFormDraftHistory(draft, permissions)) return null;
  final policy = _policy(draft, permissions)!;
  final sections = <FormDraftHistorySection>[];
  if (policy.commercial) {
    final header = _fields(draft.data, _headerFields);
    if (header.isNotEmpty) sections.add(FormDraftHistorySection('表头', header));
    final rows = draft.data['rows'];
    if (rows is List) {
      for (var i = 0; i < rows.length; i++) {
        final row = _map(rows[i]);
        final fields = [
          ..._fields(_map(row['goods']), _goodsFields),
          ..._fields(row, _rowFields),
          ..._fields(_map(row['text']), _rowTextFields(policy.priceVisible)),
        ];
        sections.add(FormDraftHistorySection('明细 ${i + 1}', fields));
      }
    }
  } else if (FormDraftCatalog.employeeOnboarding.groups(draft)) {
    final fields = [
      ..._fields(draft.data, _peopleHeaderFields),
      ..._fields(_map(draft.data['fields']), _peopleFields(permissions)),
    ];
    sections.add(FormDraftHistorySection('入职资料', fields));
  }
  return FormDraftHistoryProjection(policy.title, sections);
}
