import 'master_reference_options_loader.dart';
// 客户主档「新建/编辑」表单的公共实现（2026-09-14 抽取）。
// 客户分类页（列表内编辑）与客户详情整页（/basicinfo/clients/:id）共用同一套
// 字段与保存流程，避免两处漂移。供应商侧见 supplier_master_edit.dart。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/l10n/gen/app_localizations.dart';
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
import 'basic_data_l10n.dart';
import 'master_edit_owner.dart';

/// Shared reference reads keep both category-page and full-page editors responsive.
Future<List<ReferenceMethodOption>?> loadClientSettlementMethods(
  BuildContext context,
  WidgetRef ref, {
  MasterEditOwner? owner,
}) => loadMasterReferenceOptions<ReferenceMethodOption>(
  context: context,
  ref: ref,
  resourceKey: 'client.settlementMethods',
  title: '正在读取结账方式…',
  load: () => ref.read(referenceMethodRepositoryProvider).settlementMethods(),
  emptyMessage: '暂无可用结账方式，请先维护结账方式字典',
  errorFallback: '加载结账方式失败，请重试',
  owner: owner,
);

Future<List<CurrencyListItem>?> loadClientCurrencies(
  BuildContext context,
  WidgetRef ref, {
  MasterEditOwner? owner,
}) => loadMasterReferenceOptions<CurrencyListItem>(
  context: context,
  ref: ref,
  resourceKey: 'master.currencies',
  title: '正在读取币种…',
  load: () => ref.read(currencyRepositoryProvider).dict(),
  errorFallback: '加载币种失败，请重试',
  owner: owner,
);

/// Financial master-data fields have one shared write policy across every client editor.
const clientFinancialFieldKeys = <String>{
  'bank',
  'bankAccount',
  'taxId',
  'credit',
  'initTotal',
  'tday',
  'defaultSettlementMethodId',
  'defaultCurrencyId',
  'creditFloor',
};

MasterFieldDef _clientFieldAccess(
  MasterFieldDef field, {
  required bool ordinaryWritable,
  required bool financialWritable,
}) {
  final locked = clientFinancialFieldKeys.contains(field.key)
      ? !financialWritable
      : !ordinaryWritable;
  return MasterFieldDef(
    key: field.key,
    label: field.label,
    type: field.type,
    required: field.required,
    hint: field.hint,
    info: locked && clientFinancialFieldKeys.contains(field.key)
        ? '财务资料由有维护权限的财务人员修改。'
        : field.info,
    group: field.group,
    options: field.options,
    selectInteger: field.selectInteger,
    readOnly: field.readOnly || locked,
    onAddNew: field.onAddNew,
    customBuilder: field.customBuilder,
    legacyDraftKeys: field.legacyDraftKeys,
    identifierDomain: field.identifierDomain,
    identifierId: field.identifierId,
  );
}

/// 客户主档可编辑字段（与后端 ClientSaveRequest 对齐；含义不明的遗留字段不进表单）。
///
/// [l10n] supplies the labels of fields added after the arb migration (外文名称).
List<MasterFieldDef> buildClientFields(
  Map<String, String> iv,
  List<ReferenceMethodOption> settlementMethods, {
  required AppLocalizations l10n,
  List<CurrencyListItem> currencies = const [],
  bool legacyCreditSnapshot = false,
  bool showAccess = false,
  bool ordinaryWritable = true,
  bool financialWritable = false,
}) =>
    [
          // 归属（负责人/可见人）在编辑页只**展示**不编辑：它走独立的 access 接口
          //（变更原因 + 版本 CAS + 审计事件），混进普通字段提交会绕开那套守卫。
          // 由客户详情的「负责人和可见人」或列表同名入口统一维护。
          if (showAccess) ...const <MasterFieldDef>[
            MasterFieldDef(
              key: 'ownerEmployeeName',
              label: '负责人',
              group: '归属',
              readOnly: true,
              hint: '未设置',
              info: '客户可设置多位负责人。请在客户详情点击「负责人和可见人」维护。',
            ),
            MasterFieldDef(
              key: 'accessViewerNames',
              label: '可见人',
              group: '归属',
              readOnly: true,
              hint: '未设置',
              info: '可见人只能查看该客户及其单据，不能修改。请在客户详情点击「负责人和可见人」维护。',
            ),
          ],
          ...<MasterFieldDef>[
            const MasterFieldDef(
              key: 'name',
              label: '名称',
              required: true,
              group: '基础',
            ),
            MasterFieldDef(
              key: 'code',
              label: '编号',
              group: '基础',
              hint: '留空按分类前缀自动生成；手工编号必须唯一',
              identifierDomain: 'CLIENT',
              identifierId: iv['_entityId'],
            ),
            const MasterFieldDef(key: 'fullName', label: '全称', group: '基础'),
          ],
          // ADR-134: foreign (usually English) company name, matched against customer
          // files; also filled in by learning when sales save a document.
          MasterFieldDef(
            key: 'nameEn',
            label: l10n.clientNameEnLabel,
            hint: l10n.clientNameEnHint,
            info: l10n.clientNameEnInfo,
            group: '基础',
          ),
          ...const <MasterFieldDef>[
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
            hint: '订单未指定时使用；关联按系统内部编号保存，改名不受影响',
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
                  !SalesShipmentPolicy.selectable.contains(
                    iv['defaultShipmentPolicy'],
                  ))
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
            readOnly: legacyCreditSnapshot,
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
        ]
        .map(
          (field) => _clientFieldAccess(
            field,
            ordinaryWritable: ordinaryWritable,
            financialWritable: financialWritable,
          ),
        )
        .toList(growable: false);

/// 客户编辑弹窗（分类页与详情页共用）。[onSaved] 在保存成功后回调（刷新各自数据）。
Future<void> showClientMasterEdit(
  BuildContext context,
  WidgetRef ref,
  ClientDetail d, {
  String? fallbackCategoryId,
  VoidCallback? onSaved,
}) async {
  final permissions = ref.read(currentPermissionsProvider);
  final ordinaryWritable = d.writable && permissions.contains(Perm.clientEdit);
  final financialWritable =
      d.financialWritable && permissions.contains(Perm.clientFinance);
  if (!ordinaryWritable && !financialWritable) return;
  final owner = MasterEditOwner(
    context,
    ref,
    permissions: {
      Perm.clientView,
      if (ordinaryWritable) Perm.clientEdit,
      if (financialWritable) Perm.clientFinance,
    },
  );
  try {
    if (!await owner.bindRequests()) return;
    if (!context.mounted) return;
    await _showClientMasterEditOwned(
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

Future<void> _showClientMasterEditOwned(
  BuildContext context,
  WidgetRef ref,
  ClientDetail d,
  MasterEditOwner owner, {
  String? fallbackCategoryId,
  VoidCallback? onSaved,
}) async {
  final settlementMethods = d.financialWritable
      ? await loadClientSettlementMethods(context, ref, owner: owner)
      : const <ReferenceMethodOption>[];
  if (!context.mounted || !owner.isCurrent || settlementMethods == null) return;
  // V592 默认币种下拉；加载失败不阻断编辑（只是该项没有选项）。
  var currencies = d.financialWritable
      ? await loadClientCurrencies(context, ref, owner: owner) ??
            const <CurrencyListItem>[]
      : const <CurrencyListItem>[];
  if (!context.mounted || !owner.isCurrent) return;
  if (d.defaultCurrencyId != null &&
      !currencies.any((currency) => currency.id == d.defaultCurrencyId)) {
    currencies = [
      ...currencies,
      CurrencyListItem(
        id: d.defaultCurrencyId!,
        name: '${d.defaultCurrencyName ?? '当前值'}（已停用）',
      ),
    ];
  }
  final permissions = ref.read(currentPermissionsProvider);
  final canAssign =
      permissions.contains(Perm.clientAssign) && d.accessManageable;
  // 可见人不在 ClientDetail 里，只能问 access 接口；无 client:assign 的人问了会
  // 被拒，所以按权限判定后再取，取不到就只显示负责人（失败不挡编辑）。
  ClientAccessSettings? access;
  if (canAssign) {
    try {
      access = await owner.run(
        () => ref.read(clientRepositoryProvider).access(d.id),
      );
    } catch (_) {
      access = null;
    }
    if (!context.mounted || !owner.isCurrent) return;
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
    '_entityId': d.id,
    'name': d.name ?? '',
    'code': d.code ?? '',
    'fullName': d.fullName ?? '',
    'nameEn': d.nameEn ?? '',
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
        access?.effectiveOwners.map((item) => item.name).join('、') ??
        d.ownersLabel,
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
      l10n: basicDataL10n(context),
      currencies: currencies,
      legacyCreditSnapshot: d.legacyId != null,
      showAccess: true,
      ordinaryWritable: d.writable && permissions.contains(Perm.clientEdit),
      financialWritable:
          d.financialWritable && permissions.contains(Perm.clientFinance),
    ),
    initialValues: iv,
    fixedValues: {
      'categoryId': d.categoryId ?? fallbackCategoryId,
      if (d.version != null) 'version': d.version,
    },
    readOnlyKeys: readOnlyKeys.isEmpty ? null : readOnlyKeys,
    submissionOwner: owner,
    onSubmit: (body) async {
      await ref.read(clientRepositoryProvider).update(d.id, body);
      return true;
    },
    onAccepted: () {
      if (!owner.isCurrent) return;
      context.appSuccess('客户已更新');
      onSaved?.call();
    },
  );
}
