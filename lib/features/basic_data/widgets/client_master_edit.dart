// 客户主档「新建/编辑」表单的公共实现（2026-09-14 抽取）。
// 客户分类页（列表内编辑）与客户详情整页（/basicinfo/clients/:id）共用同一套
// 字段与保存流程，避免两处漂移。供应商侧见 supplier_master_edit.dart。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/ui/action_feedback.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/sales_shipment_policy.dart';
import '../models/client_access_models.dart';
import '../models/client_node.dart';
import '../models/reference_method_option.dart';
import '../repositories/client_repository.dart';
import '../repositories/reference_method_repository.dart';
import '../models/currency_node.dart';
import '../repositories/currency_repository.dart';
import '../widgets/master_edit_dialog.dart';

/// 加载启用中的结账方式（客户编辑表单「默认结账方式」下拉用）。
/// 模块级互斥防重复弹加载框；调用方负责 mounted 检查。
bool _settlementOptionsLoading = false;
Future<List<ReferenceMethodOption>?> loadClientSettlementMethods(
  BuildContext context,
  WidgetRef ref,
) async {
  if (_settlementOptionsLoading) return null;
  _settlementOptionsLoading = true;
  final nav = Navigator.of(context, rootNavigator: true);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const Center(child: CircularProgressIndicator()),
  );
  try {
    final methods = await ref
        .read(referenceMethodRepositoryProvider)
        .settlementMethods();
    if (methods.isEmpty) {
      if (context.mounted) context.appError('暂无可用结账方式，请先维护结账方式字典');
      return null;
    }
    return methods;
  } on ApiException catch (e) {
    if (context.mounted) context.appError(e.message);
  } catch (_) {
    if (context.mounted) context.appError('加载结账方式失败，请重试');
  } finally {
    if (nav.canPop()) nav.pop();
    _settlementOptionsLoading = false;
  }
  return null;
}

/// 加载币种字典（客户编辑表单「默认币种」下拉用；V592 默认销售条款）。
Future<List<CurrencyListItem>?> loadClientCurrencies(
  BuildContext context,
  WidgetRef ref,
) async {
  try {
    return await ref.read(currencyRepositoryProvider).dict();
  } on ApiException catch (e) {
    if (context.mounted) context.appError(e.message);
  } catch (_) {
    if (context.mounted) context.appError('加载币种失败，请重试');
  }
  return null;
}

/// 客户主档可编辑字段（与后端 ClientSaveRequest 对齐；含义不明的遗留字段不进表单）。
List<MasterFieldDef> buildClientFields(
  Map<String, String> iv,
  List<ReferenceMethodOption> settlementMethods, {
  List<CurrencyListItem> currencies = const [],
  bool legacyCreditSnapshot = false,
  bool showAccess = false,
}) => [
  // 归属（负责人/可见人）在编辑页只**展示**不编辑：它走独立的 access 接口
  //（变更原因 + 版本 CAS + 审计事件），混进普通字段提交会绕开那套守卫。
  // 要改点行菜单「负责人和可见人」（2026-09-11 用户要求编辑页也看得到）。
  if (showAccess) ...const <MasterFieldDef>[
    MasterFieldDef(
      key: 'ownerEmployeeName',
      label: '负责人',
      group: '归属',
      readOnly: true,
      hint: '未设置',
      info: '负责人决定这个客户的单据归谁。修改请用列表行右键「负责人和可见人」。',
    ),
    MasterFieldDef(
      key: 'accessViewerNames',
      label: '可见人',
      group: '归属',
      readOnly: true,
      hint: '未设置',
      info: '可见人只能查看该客户及其单据，不能修改。修改请用列表行右键「负责人和可见人」。',
    ),
  ],
  ...const <MasterFieldDef>[
    MasterFieldDef(key: 'name', label: '名称', required: true, group: '基础'),
    // 2026-09-19 口径：编号全自动——readOnly 字段不上送，新建由服务端按分类
    // 前缀发号、编辑保留原号；「留空自动生成/手工编号」双轨入口退役。
    MasterFieldDef(
      key: 'code',
      label: '编号',
      group: '基础',
      readOnly: true,
      hint: '保存后按分类前缀自动生成',
    ),
    MasterFieldDef(key: 'fullName', label: '全称', group: '基础'),
    MasterFieldDef(key: 'clientRank', label: '等级', group: '基础'),
    MasterFieldDef(
      key: 'status',
      label: '状态',
      type: MasterFieldType.select,
      options: kMasterStatusOptions,
      required: true,
      group: '基础',
    ),
    // 2026-09-19 口径：除「基础」组（名称/状态）外全部选填——联系人不再必填
    //（多联系方式在客户详情页按「手机/电话/邮箱…」逐条登记，这里只留快捷字段）。
    MasterFieldDef(key: 'linkman', label: '联系人', group: '联系'),
    MasterFieldDef(key: 'mobile', label: '手机', group: '联系'),
    MasterFieldDef(key: 'phone', label: '电话', group: '联系'),
    MasterFieldDef(key: 'phone2', label: '电话2', group: '联系'),
    MasterFieldDef(key: 'fax', label: '传真', group: '联系'),
    MasterFieldDef(key: 'email', label: '邮箱', group: '联系'),
    MasterFieldDef(key: 'website', label: '网址', group: '联系'),
    MasterFieldDef(key: 'postcode', label: '邮编', group: '联系'),
    MasterFieldDef(key: 'region', label: '区域', group: '地址'),
    MasterFieldDef(key: 'placeId', label: '地区', group: '地址'),
    MasterFieldDef(key: 'address', label: '地址', group: '地址'),
    MasterFieldDef(key: 'shipAddress', label: '收货地址', group: '地址'),
    MasterFieldDef(key: 'shipVia', label: '运输方式', group: '地址'),
    MasterFieldDef(key: 'legalPerson', label: '法人', group: '资质'),
  ],
  ...const <MasterFieldDef>[
    MasterFieldDef(key: 'bank', label: '开户行', group: '财务'),
    MasterFieldDef(key: 'bankAccount', label: '银行账号', group: '财务'),
    MasterFieldDef(key: 'taxId', label: '税号', group: '财务'),
  ],
  MasterFieldDef(
    key: 'defaultSettlementMethodId',
    label: '默认结账方式',
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
    hint: '订单未指定时使用；关联以系统 UUID 保存',
  ),
  // V592 默认销售条款（单一事实源）：新建销售订货单选客户后预填这三项；
  // 每次下单自动记住最新选择，这里可手工预置。货运策略选项词表对齐销售
  // 订货单（新单只提供两档）；存量历史值(如 CUSTOMER_CONFIRM)按当前值追加
  // 成选项，防止 select 初值不在选项里被 initState 静默置空、保存时清掉。
  MasterFieldDef(
    key: 'defaultShipmentPolicy',
    label: '默认货运策略',
    type: MasterFieldType.select,
    options: [
      for (final policy in SalesShipmentPolicy.selectable)
        MasterSelectOption(
          value: policy,
          label: salesShipmentPolicyLabel(policy),
        ),
      if (iv['defaultShipmentPolicy'] != null &&
          iv['defaultShipmentPolicy']!.isNotEmpty &&
          !SalesShipmentPolicy.selectable.contains(iv['defaultShipmentPolicy']))
        MasterSelectOption(
          value: iv['defaultShipmentPolicy']!,
          label:
              '${salesShipmentPolicyLabel(iv['defaultShipmentPolicy'])}（历史值）',
        ),
    ],
    group: '财务',
    hint: '新建销售订货单预填；每次下单自动记住最新选择',
  ),
  MasterFieldDef(
    key: 'defaultCurrencyId',
    label: '默认币种',
    type: MasterFieldType.select,
    options: [
      for (final currency in currencies)
        MasterSelectOption(
          value: currency.id,
          label: currency.code == null || currency.code!.isEmpty
              ? currency.name ?? currency.id
              : '${currency.name ?? ''} · ${currency.code}',
        ),
    ],
    group: '财务',
    hint: '新建销售订货单预填；每次下单自动记住最新选择',
  ),
  MasterFieldDef(
    key: 'credit',
    label: legacyCreditSnapshot ? '旧库 Credit 快照（只读）' : '信用额度',
    type: MasterFieldType.money,
    group: '财务',
    hint: legacyCreditSnapshot ? '仅用于旧库对照，不参与铺底或发货放行计算' : null,
  ),
  ...const <MasterFieldDef>[
    MasterFieldDef(
      key: 'initTotal',
      label: '期初应收',
      type: MasterFieldType.money,
      group: '财务',
    ),
    MasterFieldDef(
      key: 'creditFloor',
      label: '铺底额',
      type: MasterFieldType.money,
      group: '财务',
    ),
    MasterFieldDef(
      key: 'tday',
      label: '结算天数',
      type: MasterFieldType.integer,
      group: '财务',
    ),
    MasterFieldDef(key: 'remark', label: '备注', group: '其他'),
  ],
];

/// 客户编辑弹窗（分类页与详情页共用）。[onSaved] 在保存成功后回调（刷新各自数据）。
Future<void> showClientMasterEdit(
  BuildContext context,
  WidgetRef ref,
  ClientDetail d, {
  String? fallbackCategoryId,
  VoidCallback? onSaved,
}) async {
  final settlementMethods = await loadClientSettlementMethods(context, ref);
  if (!context.mounted || settlementMethods == null) return;
  // V592 默认币种下拉；加载失败不阻断编辑（只是该项没有选项）。
  final currencies =
      await loadClientCurrencies(context, ref) ?? const <CurrencyListItem>[];
  if (!context.mounted) return;
  final permissions = ref.read(currentPermissionsProvider);
  final canAssign =
      permissions.contains(Perm.clientAssign) && d.accessManageable;
  // 可见人不在 ClientDetail 里，只能问 access 接口；无 client:assign 的人问了会
  // 被拒，所以按权限判定后再取，取不到就只显示负责人（失败不挡编辑）。
  ClientAccessSettings? access;
  if (canAssign) {
    try {
      access = await ref.read(clientRepositoryProvider).access(d.id);
    } catch (_) {
      access = null;
    }
    if (!context.mounted) return;
  }
  // 当前默认结账方式已停用时不再拦死编辑（2026-09-15 用户口径「点击编辑报错」）：
  // 追加一个带「已停用」标注的选项保住原值，用户可顺手改掉。
  final settlementOptions = [...settlementMethods];
  if (d.defaultSettlementMethodId != null &&
      !settlementOptions.any((m) => m.id == d.defaultSettlementMethodId)) {
    settlementOptions.add(
      ReferenceMethodOption(
        id: d.defaultSettlementMethodId!,
        code: '',
        name: '${d.defaultSettlementMethodName ?? '当前值'}（已停用）',
      ),
    );
  }
  final iv = <String, String>{
    'name': d.name ?? '',
    'code': d.code ?? '',
    'fullName': d.fullName ?? '',
    'clientRank': d.clientRank ?? '',
    'region': d.region ?? '',
    'placeId': d.placeId ?? '',
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
    'credit': d.credit?.toString() ?? '',
    'initTotal': d.initTotal?.toString() ?? '',
    'creditFloor': d.creditFloor?.toString() ?? '',
    'tday': d.tday?.toString() ?? '',
    'defaultSettlementMethodId': d.defaultSettlementMethodId ?? '',
    'defaultShipmentPolicy': d.defaultShipmentPolicy ?? '',
    'defaultCurrencyId': d.defaultCurrencyId ?? '',
    'status': d.status ?? '',
    'remark': d.remark ?? '',
    'ownerEmployeeName':
        access?.ownerEmployeeName ?? d.ownerEmployeeName ?? d.empId ?? '',
    'accessViewerNames': access == null
        ? ''
        : access.viewers.map((viewer) => viewer.name).join('、'),
  };
  final readOnlyKeys = <String>{
    if (!permissions.contains(Perm.clientStatus)) 'status',
    if (d.legacyId != null) 'credit',
  };
  await showMasterEditDialog(
    context: context,
    title: '编辑客户', // TODO(l10n): 补 arb
    fields: buildClientFields(
      iv,
      settlementOptions,
      currencies: currencies,
      legacyCreditSnapshot: d.legacyId != null,
      showAccess: true,
    ),
    initialValues: iv,
    fixedValues: {
      'categoryId': d.categoryId ?? fallbackCategoryId,
      if (d.version != null) 'version': d.version,
    },
    readOnlyKeys: readOnlyKeys.isEmpty ? null : readOnlyKeys,
    onSubmit: (body) async {
      final ok = await context.guardRun(
        () async {
          await ref.read(clientRepositoryProvider).update(d.id, body);
        },
        success: '客户已更新', // TODO(l10n): 补 arb
        errorFallback: '更新失败，请稍后重试', // TODO(l10n): 补 arb
      );
      if (!ok) return false;
      onSaved?.call();
      return true;
    },
  );
}
