// 客户/供应商详情整页（V579，2026-09-14）。
//
// 双击列表行进入（替代原 560 宽弹窗——用户反馈弹窗太小、一行固定两列不够看）：
//  - 页宽即内容宽，基本信息用 UtenFormGrid 按容器宽自适应列数（屏幕越大一行越多）；
//  - 联系方式/地址为多值子表（party_contact_methods / party_addresses），
//    支持添加多条「手机/电话/传真/邮箱/网址」与「收货/开票/其它」地址；
//  - 跟进记录（party_activity_records）：客户行为/投诉/违约扣信誉分等；
//    客户信誉分 credit_score 首条评分按 100±delta 初始化；
//  - 操作（右下悬浮组）：编辑（公共 showClientMasterEdit/showSupplierMasterEdit）、
//    负责人和可见人（客户）、启停、删除。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../components/layout/uten_form_grid.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/action_feedback.dart';
import '../../../shared/auth/permissions.dart';
import '../models/client_node.dart';
import '../models/party_directory_models.dart';
import '../repositories/client_repository.dart';
import '../repositories/master_status_repository.dart';
import '../repositories/party_directory_repository.dart';
import '../models/supplier_node.dart';
import '../repositories/supplier_repository.dart';
import '../widgets/client_access_panel.dart';
import '../../../components/buttons/click_guard.dart';
import '../widgets/client_master_edit.dart';
import '../models/currency_node.dart';
import '../models/reference_method_option.dart';
import '../widgets/master_edit_dialog.dart';
import '../widgets/supplier_master_edit.dart';

class PartyDetailPage extends ConsumerStatefulWidget {
  const PartyDetailPage({super.key, required this.partyType, required this.id});

  /// client / supplier。
  final String partyType;
  final String id;

  @override
  ConsumerState<PartyDetailPage> createState() => _PartyDetailPageState();
}

class _PartyDetailPageState extends ConsumerState<PartyDetailPage> {
  bool get _isClient => widget.partyType == 'client';

  ClientDetail? _client;
  SupplierDetail? _supplier;
  List<PartyContactMethod> _contacts = const [];
  List<PartyAddress> _addresses = const [];
  List<PartyActivityRecord> _activities = const [];
  int? _creditScore;

  // ===== 就地编辑（2026-09-15 用户口径：详情页直接编辑，不再弹窗） =====
  bool _editing = false;
  final GlobalKey<MasterEditFormState> _editFormKey =
      GlobalKey<MasterEditFormState>();
  List<ReferenceMethodOption> _editSettlements = const [];
  List<CurrencyListItem> _editCurrencies = const [];
  bool _scoreLoaded = false;

  bool _loading = true;
  bool _busy = false;
  String? _error;

  PartyDirectoryRepository get _directoryRepo => ref.read(
    _isClient
        ? clientDirectoryRepositoryProvider
        : supplierDirectoryRepositoryProvider,
  );

  // ---- 权限（按 partyType 取对应码） ----
  bool _has(String perm) =>
      ref.read(isSuperAdminProvider) ||
      ref.read(currentPermissionsProvider).contains(perm);

  bool get _canEdit => _has(_isClient ? Perm.clientEdit : Perm.supplierEdit);
  bool get _canStatus =>
      _has(_isClient ? Perm.clientStatus : Perm.supplierStatus);
  bool get _canDelete =>
      _has(_isClient ? Perm.clientDelete : Perm.supplierDelete);
  bool get _canAssign => _isClient && _has(Perm.clientAssign);

  bool get _writable =>
      _isClient ? (_client?.writable ?? false) : (_supplier != null);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    if (_busy) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (_isClient) {
        final detail = await ref
            .read(clientRepositoryProvider)
            .detail(widget.id);
        if (!mounted) return;
        setState(() => _client = detail);
      } else {
        final detail = await ref
            .read(supplierRepositoryProvider)
            .detail(widget.id);
        if (!mounted) return;
        setState(() => _supplier = detail);
      }
      final results = await Future.wait([
        _directoryRepo.contactMethods(widget.id),
        _directoryRepo.addresses(widget.id),
        _directoryRepo.activityRecords(widget.id),
        if (_isClient) _directoryRepo.creditScore(widget.id),
      ]);
      if (!mounted) return;
      setState(() {
        _contacts = results[0] as List<PartyContactMethod>;
        _addresses = results[1] as List<PartyAddress>;
        _activities = results[2] as List<PartyActivityRecord>;
        if (_isClient) {
          _creditScore = results[3] as int?;
          _scoreLoaded = true;
        }
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = '详情加载失败，请检查网络或权限后重试';
        _loading = false;
      });
    }
  }

  Future<void> _reloadChildren() async {
    try {
      final results = await Future.wait([
        _directoryRepo.contactMethods(widget.id),
        _directoryRepo.addresses(widget.id),
        _directoryRepo.activityRecords(widget.id),
        if (_isClient) _directoryRepo.creditScore(widget.id),
      ]);
      if (!mounted) return;
      setState(() {
        _contacts = results[0] as List<PartyContactMethod>;
        _addresses = results[1] as List<PartyAddress>;
        _activities = results[2] as List<PartyActivityRecord>;
        if (_isClient) {
          _creditScore = results[3] as int?;
          _scoreLoaded = true;
        }
      });
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('刷新失败，请稍后重试');
    }
  }

  String? get _title {
    if (_isClient) {
      return _client?.name ?? _client?.code ?? '客户详情';
    }
    return _supplier?.name ?? _supplier?.code ?? '供应商详情';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: UtenAppBar(
        title: _isClient ? '客户详情' : '供应商详情',
        leading: UtenBackButton(onPressed: () => Navigator.maybePop(context)),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _loading || _busy ? null : _load,
            icon: const Icon(Icons.refresh_rounded, size: 20),
          ),
        ],
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator(strokeWidth: 2.5))
            : _error != null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(UtenSpacing.s16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _error!,
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                      const SizedBox(height: UtenSpacing.s12),
                      UtenButton(
                        type: UtenButtonType.secondary,
                        icon: Icons.refresh_rounded,
                        onPressed: _load,
                        child: const Text('重试'),
                      ),
                    ],
                  ),
                ),
              )
            : Stack(
                children: [
                  AbsorbPointer(
                    absorbing: _busy,
                    child: UtenContentContainer(
                      child: ListView(
                        padding: const EdgeInsets.fromLTRB(
                          UtenSpacing.s12,
                          UtenSpacing.s12,
                          UtenSpacing.s12,
                          UtenFloatingActionGroup.scrollClearance,
                        ),
                        children: [
                          _headerCard(theme),
                          const SizedBox(height: UtenSpacing.s12),
                          // 编辑态整页换成表单（2026-09-15：不再弹窗，详情页就地编辑）。
                          if (_editing)
                            _inlineEditCard(theme)
                          else ...[
                            _basicInfoCard(theme),
                            const SizedBox(height: UtenSpacing.s12),
                            if (_isClient) ...[
                              _termsCard(theme),
                              const SizedBox(height: UtenSpacing.s12),
                            ],
                            _contactsCard(theme),
                            const SizedBox(height: UtenSpacing.s12),
                            _addressesCard(theme),
                            const SizedBox(height: UtenSpacing.s12),
                            _activitiesCard(theme),
                          ],
                        ],
                      ),
                    ),
                  ),
                  if (_busy)
                    const Positioned.fill(
                      child: UtenBusyOverlay(title: '正在处理'),
                    ),
                ],
              ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButtonAnimator: FloatingActionButtonAnimator.noAnimation,
      floatingActionButton: _loading || _error != null
          ? null
          : UtenFloatingActionGroup(children: _actions(theme)),
    );
  }

  // ======================= 头部卡：名称 + 状态 + 信誉分 =======================

  Widget _headerCard(ThemeData theme) {
    final status = _isClient ? _client?.status : _supplier?.status;
    final active = status == null || status == '使用';
    final code = _isClient ? _client?.code : _supplier?.code;
    final owner = _isClient
        ? (_client?.ownerEmployeeName?.trim().isNotEmpty == true
              ? _client!.ownerEmployeeName
              : '未分配')
        : (_supplier?.ownerEmployeeName?.trim().isNotEmpty == true
              ? _supplier!.ownerEmployeeName
              : '未分配');
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    _title ?? '',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: UtenSpacing.s8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color:
                        (active
                                ? theme.colorScheme.primary
                                : theme.colorScheme.error)
                            .withValues(alpha: 0.12),
                    borderRadius: UtenRadius.smAll,
                  ),
                  child: Text(
                    status ?? '—',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: active
                          ? theme.colorScheme.primary
                          : theme.colorScheme.error,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: UtenSpacing.s8),
            Wrap(
              spacing: UtenSpacing.s16,
              runSpacing: UtenSpacing.s4,
              children: [
                Text(
                  '编号：${code?.isNotEmpty == true ? code : '—'}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                Text(
                  _isClient ? '负责人：$owner' : '业务员：$owner',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (_isClient && _scoreLoaded)
                  Text(
                    _creditScore == null
                        ? '信誉分：未评估（首条扣分/加分记录按 100 起算）'
                        : '信誉分：$_creditScore',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: (_creditScore ?? 100) < 60
                          ? theme.colorScheme.error
                          : theme.colorScheme.onSurfaceVariant,
                      fontWeight: _creditScore == null ? null : FontWeight.w700,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ======================= 基本信息卡（响应式网格） =======================

  Widget _kv(ThemeData theme, String label, String? value) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        label,
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: 2),
      Text(
        value == null || value.trim().isEmpty ? '—' : value,
        style: theme.textTheme.bodyMedium,
      ),
    ],
  );

  Widget _basicInfoCard(ThemeData theme) {
    final rows = <Widget>[];
    if (_isClient) {
      final d = _client!;
      // 2026-09-15 去重口径：手机/电话/电话2/传真/邮箱/网址已在下方「联系方式」
      // 卡按多条记录展示（主选那条同步回单据列），这里不再平铺重复；财务与
      // 默认销售条款拆到独立的「销售条款与财务」卡。
      rows.addAll([
        _kv(theme, '全称', d.fullName),
        _kv(theme, '等级', d.clientRank),
        _kv(theme, '分类', d.categoryName),
        _kv(theme, '当前访问', d.accessReasonLabel),
        _kv(theme, '联系人', d.linkman),
        _kv(theme, '区域', d.region),
        _kv(theme, '地区', d.placeId),
        _kv(theme, '地址', d.address),
        _kv(theme, '收货地址', d.shipAddress),
        _kv(theme, '运输方式', d.shipVia),
        _kv(theme, '邮编', d.postcode),
        _kv(theme, '法人', d.legalPerson),
        _kv(theme, '备注', d.remark),
      ]);
    } else {
      final d = _supplier!;
      rows.addAll([
        _kv(theme, '描述/全称', d.description),
        _kv(theme, '分类', d.categoryName),
        _kv(theme, '联系人', d.linkman),
        _kv(theme, '手机', d.mobile),
        _kv(theme, '电话', d.phone),
        _kv(theme, '电话2', d.phone2),
        _kv(theme, '传真', d.fax),
        _kv(theme, '邮箱', d.email),
        _kv(theme, '网址', d.website),
        _kv(theme, '邮编', d.postcode),
        _kv(theme, '地区', d.place),
        _kv(theme, '地址', d.address),
        _kv(theme, '收货地址', d.shipAddress),
        _kv(theme, '运输方式', d.shipVia),
        _kv(theme, '法人', d.legalPerson),
        _kv(theme, '默认结算方式', d.defaultSettlementMethodName),
        _kv(theme, '默认币种', d.defaultCurrencyName),
        _kv(theme, '默认税率', d.defaultTaxRate?.toString()),
        _kv(theme, '期初应付', d.initTotal?.toString()),
        _kv(theme, '结算天数', d.tday?.toString()),
        _kv(theme, '开户行', d.bank),
        _kv(theme, '银行账号', d.bankAccount),
        _kv(theme, '税号', d.taxId),
        _kv(theme, '备注', d.remark),
      ]);
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '基本信息',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: UtenSpacing.s12),
            // 容器宽自适应列数：大屏一行 4-5 列，窄屏自动回退（UtenFormGrid 断点）。
            UtenFormGrid(children: rows),
          ],
        ),
      ),
    );
  }

  // ======================= 销售条款与财务（客户） =======================

  /// V592 默认销售条款单一事实源：三项默认（结账方式/货运策略/币种）+ 财务字段。
  Widget _termsCard(ThemeData theme) {
    final d = _client!;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '销售条款与财务',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: UtenSpacing.s4),
            Text(
              '新建销售订货单选客户后按默认结账方式/货运策略/币种预填；每次下单自动记住最新选择，点「编辑」也可直接改。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: UtenSpacing.s12),
            UtenFormGrid(
              children: [
                _kv(
                  theme,
                  '销售货款类型',
                  salesPaymentTypeLabelOf(d.salesPaymentType),
                ),
                _kv(theme, '默认结账方式', d.defaultSettlementMethodName),
                _kv(theme, '默认货运策略', d.defaultShipmentPolicy),
                _kv(theme, '默认币种', d.defaultCurrencyName),
                _kv(theme, '信用额度', d.credit?.toString()),
                _kv(theme, '期初应收', d.initTotal?.toString()),
                _kv(theme, '铺底额', d.creditFloor?.toString()),
                _kv(theme, '结算天数', d.tday?.toString()),
                _kv(theme, '开户行', d.bank),
                _kv(theme, '银行账号', d.bankAccount),
                _kv(theme, '税号', d.taxId),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ======================= 就地编辑卡（客户，2026-09-15 退役弹窗） =======================

  Widget _inlineEditCard(ThemeData theme) {
    final d = _client!;
    final permissions = ref.read(currentPermissionsProvider);
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
      'salesPaymentType': d.salesPaymentType ?? '',
      'defaultSettlementMethodId': d.defaultSettlementMethodId ?? '',
      'defaultShipmentPolicy': d.defaultShipmentPolicy ?? '',
      'defaultCurrencyId': d.defaultCurrencyId ?? '',
      'status': d.status ?? '',
      'remark': d.remark ?? '',
    };
    // 当前默认结账方式/币种已停用：追加带「已停用」标注的选项保住原值，
    // 用户可顺手改掉（2026-09-15 之前这里直接报错拦死编辑）。
    final settlementOptions = [..._editSettlements];
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
    var currencyOptions = _editCurrencies;
    if (d.defaultCurrencyId != null &&
        !currencyOptions.any((c) => c.id == d.defaultCurrencyId)) {
      currencyOptions = [
        ...currencyOptions,
        CurrencyListItem(
          id: d.defaultCurrencyId!,
          name: '${d.defaultCurrencyName ?? '当前值'}（已停用）',
        ),
      ];
    }
    final readOnlyKeys = <String>{
      if (!permissions.contains(Perm.clientStatus)) 'status',
      if (d.legacyId != null) 'credit',
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '编辑客户',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '取消编辑',
                  icon: const Icon(Icons.close_rounded),
                  onPressed: _busy
                      ? null
                      : () => setState(() => _editing = false),
                ),
              ],
            ),
            const Divider(height: 1),
            MasterEditForm(
              key: _editFormKey,
              fields: buildClientFields(
                iv,
                settlementOptions,
                currencies: currencyOptions,
                legacyCreditSnapshot: d.legacyId != null,
              ),
              initialValues: iv,
              fixedValues: {
                'categoryId': d.categoryId,
                if (d.version != null) 'version': d.version,
              },
              readOnlyKeys: readOnlyKeys.isEmpty ? null : readOnlyKeys,
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.only(top: UtenSpacing.s12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  UtenButton(
                    type: UtenButtonType.secondary,
                    onPressed: _busy
                        ? null
                        : () => setState(() => _editing = false),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: UtenSpacing.s12),
                  UtenActionButton(
                    label: const Text('保存'),
                    onAction: _saveInlineEdit,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _saveInlineEdit() async {
    final d = _client;
    if (d == null) return;
    final body = _editFormKey.currentState?.buildBody();
    if (body == null) return; // 校验失败，错文案已在表单内
    late final bool ok;
    try {
      ok = await context.guardRun(
        () async {
          await ref.read(clientRepositoryProvider).update(d.id, body);
        },
        success: '客户已更新',
        errorFallback: '更新失败，请稍后重试',
      );
    } on ApiException catch (e) {
      // 编号查重 409：编号字段描红 + 显文案，保持编辑态让用户改。
      if (e.message.contains('编号已存在')) {
        _editFormKey.currentState?.setFieldError('code', e.message);
        return;
      }
      if (mounted) context.appApiError(e);
      return;
    } catch (_) {
      if (mounted) context.appError('更新失败，请稍后重试');
      return;
    }
    if (!ok || !mounted) return;
    setState(() => _editing = false);
    await _load();
  }

  // ======================= 联系方式 =======================

  Widget _contactsCard(ThemeData theme) => _sectionCard(
    theme,
    title: '联系方式(${_contacts.length})',
    icon: Icons.contact_phone_outlined,
    description: '可登记多条手机/电话/传真/邮箱；主选那条同步回列表与单据展示列。',
    onAdd: _canEdit ? _addContact : null,
    addLabel: '添加联系方式',
    child: _contacts.isEmpty
        ? _emptyHint(theme, '暂无联系方式，点击「添加联系方式」登记')
        : Column(
            children: [
              for (final contact in _contacts)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    contact.kind == 'EMAIL'
                        ? Icons.mail_outline
                        : contact.kind == 'WEBSITE'
                        ? Icons.language_rounded
                        : contact.kind == 'FAX'
                        ? Icons.print_outlined
                        : contact.kind == 'MOBILE'
                        ? Icons.smartphone_rounded
                        : Icons.call_outlined,
                    size: 20,
                    color: theme.colorScheme.primary,
                  ),
                  title: Text(contact.value, style: theme.textTheme.bodyMedium),
                  subtitle: Text(
                    '${contact.kindLabel}${contact.primary ? ' · 主选' : ''}'
                    '${(contact.remark?.isNotEmpty ?? false) ? ' · ${contact.remark}' : ''}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  trailing: _canEdit
                      ? IconButton(
                          tooltip: '删除',
                          icon: Icon(
                            Icons.delete_outline,
                            size: 18,
                            color: theme.colorScheme.error,
                          ),
                          onPressed: () => _deleteContact(contact),
                        )
                      : null,
                ),
            ],
          ),
  );

  Future<void> _addContact() async {
    String kind = 'MOBILE';
    final valueCtl = TextEditingController();
    final remarkCtl = TextEditingController();
    bool primary = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('添加联系方式'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                UtenDropdownField(
                  label: '类型',
                  value: kind,
                  allowClear: false,
                  searchable: false,
                  items: [
                    for (final entry in PartyContactMethod.kindLabels.entries)
                      UtenDropdownItem(value: entry.key, label: entry.value),
                  ],
                  onChanged: (value) {
                    if (value != null) setDialogState(() => kind = value);
                  },
                ),
                const SizedBox(height: UtenSpacing.s12),
                TextField(
                  controller: valueCtl,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: '内容(必填)'),
                ),
                const SizedBox(height: UtenSpacing.s12),
                TextField(
                  controller: remarkCtl,
                  decoration: const InputDecoration(labelText: '备注(选填)'),
                ),
                CheckboxListTile(
                  value: primary,
                  dense: true,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: const Text('设为主选（同步回单据与列表显示列）'),
                  onChanged: (value) =>
                      setDialogState(() => primary = value ?? false),
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
                if (valueCtl.text.trim().isEmpty) {
                  ctx.appError('请填写联系方式内容');
                  return;
                }
                Navigator.pop(ctx, true);
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    Future<void>.delayed(const Duration(milliseconds: 300), () {
      valueCtl.dispose();
      remarkCtl.dispose();
    });
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await _directoryRepo.addContactMethod(
        widget.id,
        kind: kind,
        value: valueCtl.text.trim(),
        primary: primary,
        remark: remarkCtl.text.trim(),
      );
      if (!mounted) return;
      context.appSuccess('联系方式已添加');
      await _reloadChildren();
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('添加失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteContact(PartyContactMethod contact) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除联系方式'),
        content: Text('确定删除「${contact.kindLabel} ${contact.value}」吗？'),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await _directoryRepo.deleteContactMethod(widget.id, contact.id);
      if (!mounted) return;
      context.appSuccess('已删除');
      await _reloadChildren();
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('删除失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ======================= 地址 =======================

  Widget _addressesCard(ThemeData theme) => _sectionCard(
    theme,
    title: '地址(${_addresses.length})',
    icon: Icons.location_on_outlined,
    description: '收货/开票/其它地址可登记多条；默认地址用于开单预填。',
    onAdd: _canEdit ? _addAddress : null,
    addLabel: '添加地址',
    child: _addresses.isEmpty
        ? _emptyHint(theme, '暂无地址，点击「添加地址」登记')
        : Column(
            children: [
              for (final address in _addresses)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    address.kind == 'SHIPPING'
                        ? Icons.local_shipping_outlined
                        : address.kind == 'BILLING'
                        ? Icons.receipt_long_outlined
                        : Icons.place_outlined,
                    size: 20,
                    color: theme.colorScheme.primary,
                  ),
                  title: Text(address.address),
                  subtitle: Text(
                    '${address.kindLabel}${address.defaultAddress ? ' · 默认' : ''}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  trailing: _canEdit
                      ? IconButton(
                          tooltip: '删除',
                          icon: Icon(
                            Icons.delete_outline,
                            size: 18,
                            color: theme.colorScheme.error,
                          ),
                          onPressed: () => _deleteAddress(address),
                        )
                      : null,
                ),
            ],
          ),
  );

  Future<void> _addAddress() async {
    String kind = 'SHIPPING';
    final addressCtl = TextEditingController();
    bool defaultAddress = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('添加地址'),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                UtenDropdownField(
                  label: '类型',
                  value: kind,
                  allowClear: false,
                  searchable: false,
                  items: [
                    for (final entry in PartyAddress.kindLabels.entries)
                      UtenDropdownItem(value: entry.key, label: entry.value),
                  ],
                  onChanged: (value) {
                    if (value != null) setDialogState(() => kind = value);
                  },
                ),
                const SizedBox(height: UtenSpacing.s12),
                TextField(
                  controller: addressCtl,
                  autofocus: true,
                  maxLines: 2,
                  decoration: const InputDecoration(labelText: '地址(必填)'),
                ),
                CheckboxListTile(
                  value: defaultAddress,
                  dense: true,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: const Text('设为默认地址'),
                  onChanged: (value) =>
                      setDialogState(() => defaultAddress = value ?? false),
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
                if (addressCtl.text.trim().isEmpty) {
                  ctx.appError('请填写地址');
                  return;
                }
                Navigator.pop(ctx, true);
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    Future<void>.delayed(const Duration(milliseconds: 300), addressCtl.dispose);
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await _directoryRepo.addAddress(
        widget.id,
        kind: kind,
        address: addressCtl.text.trim(),
        defaultAddress: defaultAddress,
      );
      if (!mounted) return;
      context.appSuccess('地址已添加');
      await _reloadChildren();
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('添加失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteAddress(PartyAddress address) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除地址'),
        content: Text('确定删除「${address.kindLabel}」这条地址吗？'),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await _directoryRepo.deleteAddress(widget.id, address.id);
      if (!mounted) return;
      context.appSuccess('已删除');
      await _reloadChildren();
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('删除失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ======================= 跟进记录 =======================

  Widget _activitiesCard(ThemeData theme) => _sectionCard(
    theme,
    title: _isClient
        ? '跟进与行为记录(${_activities.length})'
        : '跟进记录(${_activities.length})',
    icon: Icons.history_edu_outlined,
    description: _isClient ? '跟进/投诉/违约等记录；违约可扣信誉分，奖励加分。' : '供应商跟进/合作问题记录。',
    onAdd: _canEdit ? _addActivity : null,
    addLabel: '添加记录',
    child: _activities.isEmpty
        ? _emptyHint(theme, '暂无记录')
        : Column(
            children: [
              for (final record in _activities)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: _activityIcon(theme, record.kind),
                  title: Text(record.content),
                  subtitle: Text(
                    '${record.kindLabel} · ${_shortDateTime(record.createdAt)}'
                    '${record.scoreDelta != 0 ? ' · 信誉分${record.scoreDelta > 0 ? '+' : ''}${record.scoreDelta}' : ''}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: record.scoreDelta < 0
                          ? theme.colorScheme.error
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
  );

  Widget _activityIcon(ThemeData theme, String kind) => Icon(
    switch (kind) {
      'FOLLOW_UP' => Icons.phone_in_talk_rounded,
      'COMPLAINT' => Icons.sentiment_dissatisfied_rounded,
      'PENALTY' => Icons.gavel_rounded,
      'REWARD' => Icons.emoji_events_rounded,
      _ => Icons.notes_rounded,
    },
    size: 20,
    color: kind == 'PENALTY'
        ? theme.colorScheme.error
        : kind == 'REWARD'
        ? Colors.amber.shade700
        : theme.colorScheme.primary,
  );

  Future<void> _addActivity() async {
    String kind = 'FOLLOW_UP';
    final contentCtl = TextEditingController();
    final scoreCtl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('添加记录'),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                UtenDropdownField(
                  label: '类型',
                  value: kind,
                  allowClear: false,
                  searchable: false,
                  items: [
                    for (final entry in PartyActivityRecord.kindLabels.entries)
                      UtenDropdownItem(value: entry.key, label: entry.value),
                  ],
                  onChanged: (value) {
                    if (value != null) setDialogState(() => kind = value);
                  },
                ),
                const SizedBox(height: UtenSpacing.s12),
                TextField(
                  controller: contentCtl,
                  autofocus: true,
                  maxLines: 3,
                  maxLength: 2000,
                  decoration: const InputDecoration(labelText: '内容(必填)'),
                ),
                if (_isClient) ...[
                  const SizedBox(height: UtenSpacing.s4),
                  TextField(
                    controller: scoreCtl,
                    keyboardType: const TextInputType.numberWithOptions(
                      signed: true,
                    ),
                    decoration: const UtenInputDecoration(
                      InputDecoration(labelText: '信誉分变动(选填，如 -10 / +5)'),
                      info: '留空或 0 表示不调整；首条评分记录按 100 分起算，累计夹在 0-200。',
                    ),
                  ),
                ],
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
                if (contentCtl.text.trim().isEmpty) {
                  ctx.appError('请填写记录内容');
                  return;
                }
                Navigator.pop(ctx, true);
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    Future<void>.delayed(const Duration(milliseconds: 300), () {
      contentCtl.dispose();
      scoreCtl.dispose();
    });
    if (ok != true || !mounted) return;
    final delta = _isClient ? (int.tryParse(scoreCtl.text.trim()) ?? 0) : 0;
    setState(() => _busy = true);
    try {
      await _directoryRepo.addActivityRecord(
        widget.id,
        kind: kind,
        content: contentCtl.text.trim(),
        scoreDelta: delta,
      );
      if (!mounted) return;
      context.appSuccess('记录已添加');
      await _reloadChildren();
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('添加失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ======================= 操作 =======================

  List<Widget> _actions(ThemeData theme) {
    final children = <Widget>[
      UtenButton(
        key: const Key('party-detail-back'),
        type: UtenButtonType.secondary,
        size: UtenButtonSize.large,
        onPressed: () => Navigator.maybePop(context),
        child: const Text('返回'),
      ),
    ];
    if (_editing) return children;
    if (_canEdit && _writable) {
      children.add(
        UtenButton(
          key: const Key('party-detail-edit'),
          size: UtenButtonSize.large,
          icon: Icons.edit_outlined,
          onPressed: _busy ? null : _edit,
          child: const Text('编辑'),
        ),
      );
    }
    if (_isClient && _canAssign && (_client?.accessManageable ?? false)) {
      children.add(
        UtenButton(
          key: const Key('party-detail-access'),
          type: UtenButtonType.secondary,
          size: UtenButtonSize.large,
          icon: Icons.manage_accounts_outlined,
          onPressed: _busy ? null : _editAccess,
          child: const Text('负责人和可见人'),
        ),
      );
    }
    if (_canStatus && _writable) {
      final active = (_isClient ? _client?.status : _supplier?.status) == '使用';
      children.add(
        UtenButton(
          key: const Key('party-detail-toggle-status'),
          type: UtenButtonType.secondary,
          size: UtenButtonSize.large,
          icon: active ? Icons.pause_circle_outline : Icons.play_circle_outline,
          onPressed: _busy ? null : () => _toggleStatus(active),
          child: Text(active ? '停用' : '启用'),
        ),
      );
    }
    if (_canDelete && _writable) {
      children.add(
        UtenButton(
          key: const Key('party-detail-delete'),
          type: UtenButtonType.danger,
          size: UtenButtonSize.large,
          icon: Icons.delete_outline,
          onPressed: _busy ? null : _delete,
          child: const Text('删除'),
        ),
      );
    }
    return children;
  }

  Future<void> _edit() async {
    // 2026-09-15 用户口径：客户在详情页**就地编辑**（不再弹窗）；供应商沿用弹窗。
    if (_isClient && _client != null) {
      final settlements =
          await loadClientSettlementMethods(context, ref) ??
          const <ReferenceMethodOption>[];
      if (!mounted) return;
      final currencies =
          await loadClientCurrencies(context, ref) ??
          const <CurrencyListItem>[];
      if (!mounted) return;
      setState(() {
        _editSettlements = settlements;
        _editCurrencies = currencies;
        _editing = true;
      });
      return;
    }
    if (!_isClient && _supplier != null) {
      await showSupplierMasterEdit(context, ref, _supplier!, onSaved: _load);
    }
  }

  Future<void> _editAccess() async {
    final client = _client;
    if (client == null) return;
    final repository = ref.read(clientRepositoryProvider);
    final saved = await showClientAccessPanel(
      context: context,
      ref: ref,
      clientId: client.id,
      clientName: client.name ?? client.code ?? '客户',
      loader: repository.access,
      saver: repository.updateAccess,
    );
    if (saved != null && mounted) await _load();
  }

  Future<void> _toggleStatus(bool active) async {
    final version = _isClient ? _client?.version : _supplier?.version;
    final ok = await context.guardRun(
      () => ref
          .read(masterStatusRepositoryProvider)
          .change(
            resourcePath: _isClient
                ? ApiEndpoints.client(widget.id)
                : ApiEndpoints.supplier(widget.id),
            status: active ? '禁用' : '使用',
            version: version,
          ),
      success: active ? '已停用' : '已启用',
    );
    if (ok && mounted) await _load();
  }

  Future<void> _delete() async {
    final name = _title ?? '';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_isClient ? '删除客户' : '删除供应商'),
        content: Text('确定删除「$name」吗？'),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final ok = await context.guardRun(
      () => _isClient
          ? ref.read(clientRepositoryProvider).delete(widget.id)
          : ref.read(supplierRepositoryProvider).delete(widget.id),
      success: _isClient ? '客户已删除' : '供应商已删除',
      errorFallback: '删除失败，请稍后重试',
    );
    if (!ok || !mounted) return;
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop(true);
    }
  }

  // ======================= 通用小件 =======================

  Widget _sectionCard(
    ThemeData theme, {
    required String title,
    required IconData icon,
    String? description,
    required Widget child,
    VoidCallback? onAdd,
    String? addLabel,
  }) => Card(
    child: Padding(
      padding: const EdgeInsets.all(UtenSpacing.s12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: UtenSpacing.s8),
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (onAdd != null)
                UtenButton(
                  type: UtenButtonType.tonal,
                  size: UtenButtonSize.small,
                  icon: Icons.add_rounded,
                  onPressed: onAdd,
                  child: Text(addLabel ?? '添加'),
                ),
            ],
          ),
          if (description != null) ...[
            const SizedBox(height: UtenSpacing.s4),
            Text(
              description,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: UtenSpacing.s8),
          child,
        ],
      ),
    ),
  );

  Widget _emptyHint(ThemeData theme, String message) => Padding(
    padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s8),
    child: Text(
      message,
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    ),
  );
}

String _shortDateTime(String? iso) {
  if (iso == null || iso.length < 16) return iso ?? '—';
  return '${iso.substring(0, 10)} ${iso.substring(11, 16)}';
}

/// 销售货款类型显示标签（月结/现金/定金/待分类）。
String salesPaymentTypeLabelOf(String? value) => switch (value?.trim()) {
  ClientSalesPaymentType.monthly => '月结',
  ClientSalesPaymentType.cash => '现金',
  ClientSalesPaymentType.deposit => '定金',
  _ => '待人工分类',
};
