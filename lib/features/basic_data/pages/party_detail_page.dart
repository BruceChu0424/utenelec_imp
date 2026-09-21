// 客户/供应商详情整页（V579，2026-09-14；2026-09-17 布局改版）。
//
// 改版对齐员工详情/我的页的家族范式（用户 2026-09-17 口径：原五张全宽大卡片
// 字小且乱 → 全部重新布局）：
//  - Hero 身份卡：圆形首字标识 + 大号名称 + 状态/等级徽章 + 编号/分类/负责人元信息；
//    客户附「信誉分/信用额度/期初应收/铺底额」统计行（大号数字）。
//  - Tab 分区（UtenCollapsingHeaderScrollView：头部随滚动收起、Tab 栏吸顶）：
//    客户＝概览/销售条款与财务/联系方式/地址/跟进与行为记录；供应商＝概览/联系方式/
//    地址/跟进记录。正文键值一律「14 号灰标签 + 16 号加重值」，长文本（地址/备注）整行铺开。
//  - 就地编辑（2026-09-15 退役弹窗的延续）：客户点「编辑」后**各分区原地变输入**——
//    概览 Tab 渲染 基础/联系/地址/资质/其他 分组表单，销售条款与财务 Tab 渲染 财务
//    分组表单；右下悬浮组换「取消/保存」，保存时合并两张表单一次提交，校验失败自动
//    跳回出错的那张表单所在 Tab。供应商沿用 showSupplierMasterEdit 弹窗。
//  - 联系方式/地址为多值子表（party_contact_methods / party_addresses），跟进记录
//    （party_activity_records）客户行为/投诉/违约扣信誉分等；信誉分首条按 100±delta 起算。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../components/layout/uten_form_grid.dart';
import '../../../components/layout/uten_section_header.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/action_feedback.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/sales_shipment_policy.dart';
import '../models/client_node.dart';
import '../models/party_directory_models.dart';
import '../repositories/client_repository.dart';
import '../repositories/master_status_repository.dart';
import '../repositories/party_directory_repository.dart';
import '../models/supplier_node.dart';
import '../repositories/supplier_repository.dart';
import '../widgets/client_access_panel.dart';
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

class _PartyDetailPageState extends ConsumerState<PartyDetailPage>
    with SingleTickerProviderStateMixin {
  bool get _isClient => widget.partyType == 'client';

  ClientDetail? _client;
  SupplierDetail? _supplier;
  List<PartyContactMethod> _contacts = const [];
  List<PartyAddress> _addresses = const [];
  List<PartyActivityRecord> _activities = const [];
  int? _creditScore;

  // ===== 就地编辑（2026-09-15 起：详情页原地变输入；2026-09-17 按分区拆到两个 Tab；
  // 2026-09-20 起两张分区表单共用一个页面持有的值容器，不随 Tab 页释放） =====
  bool _editing = false;
  MasterEditFormController? _editController;
  List<ReferenceMethodOption> _editSettlements = const [];
  List<CurrencyListItem> _editCurrencies = const [];
  bool _scoreLoaded = false;

  late final TabController _tab = TabController(
    length: _isClient ? 5 : 4,
    vsync: this,
  );

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

  @override
  void dispose() {
    _tab.dispose();
    _editController?.dispose();
    super.dispose();
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

  List<String> get _tabLabels => _isClient
      ? const ['概览', '销售条款与财务', '联系方式', '地址', '跟进与行为记录']
      : const ['概览', '联系方式', '地址', '跟进记录'];

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
                      // Builder 推迟 tabBar：preferredSize 要在数据加载后取。
                      child: Builder(
                        builder: (context) {
                          final tabBar = _tabBar(theme);
                          return UtenCollapsingHeaderScrollView(
                            // 头部身份卡随上滑收起腾出空间，Tab 栏顶到上沿后吸顶，
                            // 各 Tab 正文内滚（ListView 无显式 controller，
                            // 自动拾取注入的 PrimaryScrollController 参与联动）。
                            collapsingHeader: Column(
                              children: [
                                const SizedBox(height: UtenSpacing.s16),
                                _heroCard(theme),
                                const SizedBox(height: UtenSpacing.s12),
                              ],
                            ),
                            pinnedHeader: Container(
                              color: theme.scaffoldBackgroundColor,
                              child: tabBar,
                            ),
                            pinnedHeaderExtent: tabBar.preferredSize.height,
                            body: TabBarView(
                              controller: _tab,
                              children: [
                                for (var i = 0; i < _tab.length; i++)
                                  _tabView(theme, i),
                              ],
                            ),
                          );
                        },
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

  TabBar _tabBar(ThemeData theme) => TabBar(
    controller: _tab,
    isScrollable: true,
    tabAlignment: TabAlignment.start,
    labelStyle: theme.textTheme.titleSmall?.copyWith(
      fontWeight: FontWeight.w600,
    ),
    tabs: [for (final label in _tabLabels) Tab(text: label)],
  );

  /// Tab → 内容：客户 0 概览/1 条款财务/2 联系/3 地址/4 跟进；
  /// 供应商 0 概览/1 联系/2 地址/3 跟进（无条款 Tab）。
  Widget _tabView(ThemeData theme, int index) {
    if (index == 0) return _overviewTab(theme);
    if (_isClient) {
      if (index == 1) return _termsTab(theme);
      index -= 2;
    } else {
      index -= 1;
    }
    return switch (index) {
      0 => _contactsTab(theme),
      1 => _addressesTab(theme),
      _ => _activitiesTab(theme),
    };
  }

  /// Tab 正文：竖向 ListView；编辑态禁用下拉刷新（刷新会重建表单丢未保存修改）。
  Widget _tabBody(List<Widget> sections) {
    final list = ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(
        UtenSpacing.s16,
        UtenSpacing.s16,
        UtenSpacing.s16,
        UtenFloatingActionGroup.scrollClearance,
      ),
      children: sections,
    );
    return _editing ? list : RefreshIndicator(onRefresh: _load, child: list);
  }

  // ======================= Hero 身份卡 =======================

  Widget _heroCard(ThemeData theme) {
    final status = _isClient ? _client?.status : _supplier?.status;
    final active = status == null || status == '使用';
    final code = _isClient ? _client?.code : _supplier?.code;
    final fullName = _isClient ? _client?.fullName : _supplier?.description;
    final category = _isClient
        ? _client?.categoryName
        : _supplier?.categoryName;
    final rank = _isClient ? _client?.clientRank?.trim() : null;
    final linkman = _isClient ? _client?.linkman : _supplier?.linkman;
    final owner = _isClient
        ? (_client?.ownerEmployeeName?.trim().isNotEmpty == true
              ? _client!.ownerEmployeeName
              : '未分配')
        : (_supplier?.ownerEmployeeName?.trim().isNotEmpty == true
              ? _supplier!.ownerEmployeeName
              : '未分配');
    final meta1 = [
      if (code?.isNotEmpty == true) '编号 $code',
      if (category?.isNotEmpty == true) '分类 $category',
      if (fullName?.isNotEmpty == true)
        _isClient ? '全称 $fullName' : '描述 $fullName',
    ].join(' · ');
    final meta2 = [
      _isClient ? '负责人 $owner' : '业务员 $owner',
      if (linkman?.isNotEmpty == true) '联系人 $linkman',
    ].join(' · ');
    final name = (_title?.trim().isNotEmpty == true)
        ? _title!.trim()
        : (_isClient ? '客户' : '供应商');
    return UtenCard(
      padding: const EdgeInsets.all(UtenSpacing.s20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _heroAvatar(theme, name),
              const SizedBox(width: UtenSpacing.s16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: UtenSpacing.s8,
                      runSpacing: UtenSpacing.s4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          name,
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        UtenStatusBadge(
                          label: status ?? '—',
                          type: active
                              ? UtenStatusBadgeType.success
                              : UtenStatusBadgeType.danger,
                        ),
                        if (rank?.isNotEmpty == true)
                          UtenStatusBadge(
                            label: rank!,
                            type: UtenStatusBadgeType.info,
                          ),
                      ],
                    ),
                    if (meta1.isNotEmpty) ...[
                      const SizedBox(height: UtenSpacing.s4),
                      Text(
                        meta1,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                    if (meta2.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        meta2,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (_isClient) ...[
            const SizedBox(height: UtenSpacing.s16),
            const Divider(height: 1),
            const SizedBox(height: UtenSpacing.s12),
            _statsRow(theme),
          ],
        ],
      ),
    );
  }

  /// 圆形首字标识（无名称回退业务图标）。
  Widget _heroAvatar(ThemeData theme, String name) {
    final initial = name.isNotEmpty ? name.characters.first : null;
    return Container(
      width: 56,
      height: 56,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: theme.colorScheme.primary.withValues(alpha: 0.10),
      ),
      alignment: Alignment.center,
      child: initial != null
          ? Text(
              initial,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.primary,
              ),
            )
          : Icon(
              _isClient ? Icons.business_rounded : Icons.factory_rounded,
              size: 26,
              color: theme.colorScheme.primary,
            ),
    );
  }

  /// 客户关键指标行：信誉分 / 信用额度 / 期初应收 / 铺底额（大号数字）。
  Widget _statsRow(ThemeData theme) {
    final d = _client!;
    final scoreColor = (_creditScore ?? 100) < 60
        ? theme.colorScheme.error
        : theme.colorScheme.primary;
    final stats = <({String label, String value, Color? color, String? tip})>[
      (
        label: '信誉分',
        value: !_scoreLoaded ? '—' : (_creditScore?.toString() ?? '未评估'),
        color: scoreColor,
        tip: '首条扣分/加分记录按 100 分起算，累计夹在 0-200',
      ),
      (label: '信用额度', value: _fmtMoney(d.credit), color: null, tip: null),
      (label: '期初应收', value: _fmtMoney(d.initTotal), color: null, tip: null),
      (label: '铺底额', value: _fmtMoney(d.creditFloor), color: null, tip: null),
    ];
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < stats.length; i++) ...[
          if (i > 0)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s16),
              child: Container(
                width: 1,
                height: 44,
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
              ),
            ),
          Expanded(child: _statBlock(theme, stats[i])),
        ],
      ],
    );
  }

  Widget _statBlock(
    ThemeData theme,
    ({String label, String value, Color? color, String? tip}) stat,
  ) {
    final column = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          stat.label,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          stat.value,
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w700,
            color: stat.color,
          ),
        ),
      ],
    );
    return stat.tip == null
        ? column
        : Tooltip(message: stat.tip!, child: column);
  }

  // ======================= 分区与键值排版 =======================

  /// 键值瓦片：14 号灰标签上、16 号加重值下（改版前 12/14 号，用户嫌小）。
  Widget _kv(ThemeData theme, String label, String? value) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        label,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: 2),
      Text(
        value == null || value.trim().isEmpty ? '—' : value.trim(),
        style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w500),
      ),
    ],
  );

  Widget _section(
    ThemeData theme, {
    required String title,
    required IconData icon,
    String? description,
    Widget? trailing,
    EdgeInsetsGeometry cardPadding = const EdgeInsets.all(UtenSpacing.s16),
    required Widget child,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      UtenSectionHeader(title: title, icon: icon, trailing: trailing),
      if (description != null) ...[
        const SizedBox(height: UtenSpacing.s4),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s4),
          child: Text(
            description,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
      const SizedBox(height: UtenSpacing.s8),
      UtenCard(padding: cardPadding, child: child),
    ],
  );

  /// 长文本整行铺开（地址/收货地址/备注）。
  Widget _fullKv(ThemeData theme, String label, String? value) => Padding(
    padding: const EdgeInsets.only(top: UtenSpacing.s12),
    child: _kv(theme, label, value),
  );

  Widget _remarkBody(ThemeData theme, String? remark) {
    final has = remark?.trim().isNotEmpty == true;
    return Text(
      has ? remark!.trim() : '—',
      style: theme.textTheme.bodyLarge?.copyWith(
        height: 1.6,
        color: has ? null : theme.colorScheme.onSurfaceVariant,
      ),
    );
  }

  // ======================= Tab 1：概览 =======================

  Widget _overviewTab(ThemeData theme) {
    if (_isClient) {
      final d = _client!;
      // 编辑态：概览分区原地变输入（基础/联系/地址/资质/其他 分组表单）。
      if (_editing) {
        return _tabBody([_editFormCard(theme, finance: false)]);
      }
      // 2026-09-15 去重口径：手机/电话等已在「联系方式」Tab 按多条记录展示，
      // 概览不再平铺重复；财务在「销售条款与财务」Tab。
      return _tabBody([
        _section(
          theme,
          title: '基本信息',
          icon: Icons.badge_outlined,
          child: UtenFormGrid(
            children: [
              _kv(theme, '全称', d.fullName),
              _kv(theme, '等级', d.clientRank),
              _kv(theme, '分类', d.categoryName),
              _kv(theme, '当前访问', d.accessReasonLabel),
              _kv(theme, '法人', d.legalPerson),
            ],
          ),
        ),
        const SizedBox(height: UtenSpacing.s16),
        _section(
          theme,
          title: '地址与物流',
          icon: Icons.local_shipping_outlined,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              UtenFormGrid(
                children: [
                  _kv(theme, '区域', d.region),
                  _kv(theme, '地区', d.placeId),
                  _kv(theme, '邮编', d.postcode),
                  _kv(theme, '运输方式', d.shipVia),
                ],
              ),
              _fullKv(theme, '地址', d.address),
              _fullKv(theme, '收货地址', d.shipAddress),
            ],
          ),
        ),
        const SizedBox(height: UtenSpacing.s16),
        _section(
          theme,
          title: '备注',
          icon: Icons.notes_outlined,
          child: _remarkBody(theme, d.remark),
        ),
      ]);
    }
    final d = _supplier!;
    return _tabBody([
      _section(
        theme,
        title: '基本信息',
        icon: Icons.badge_outlined,
        child: UtenFormGrid(
          children: [
            _kv(theme, '描述/全称', d.description),
            _kv(theme, '分类', d.categoryName),
            _kv(theme, '法人', d.legalPerson),
          ],
        ),
      ),
      const SizedBox(height: UtenSpacing.s16),
      _section(
        theme,
        title: '联系方式',
        icon: Icons.contact_phone_outlined,
        description: '快捷字段；多条明细在「联系方式」Tab 按类型逐条登记。',
        child: UtenFormGrid(
          children: [
            _kv(theme, '手机', d.mobile),
            _kv(theme, '电话', d.phone),
            _kv(theme, '电话2', d.phone2),
            _kv(theme, '传真', d.fax),
            _kv(theme, '邮箱', d.email),
            _kv(theme, '网址', d.website),
            _kv(theme, '邮编', d.postcode),
          ],
        ),
      ),
      const SizedBox(height: UtenSpacing.s16),
      _section(
        theme,
        title: '地址与物流',
        icon: Icons.local_shipping_outlined,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            UtenFormGrid(
              children: [
                _kv(theme, '地区', d.place),
                _kv(theme, '运输方式', d.shipVia),
              ],
            ),
            _fullKv(theme, '地址', d.address),
            _fullKv(theme, '收货地址', d.shipAddress),
          ],
        ),
      ),
      const SizedBox(height: UtenSpacing.s16),
      _section(
        theme,
        title: '财务与税务',
        icon: Icons.account_balance_outlined,
        child: UtenFormGrid(
          children: [
            _kv(theme, '默认结算方式', d.defaultSettlementMethodName),
            _kv(theme, '默认币种', d.defaultCurrencyName),
            _kv(theme, '默认税率', _fmtMoney(d.defaultTaxRate)),
            _kv(theme, '期初应付', _fmtMoney(d.initTotal)),
            _kv(theme, '结算天数', d.tday?.toString()),
            _kv(theme, '开户行', d.bank),
            _kv(theme, '银行账号', d.bankAccount),
            _kv(theme, '税号', d.taxId),
          ],
        ),
      ),
      const SizedBox(height: UtenSpacing.s16),
      _section(
        theme,
        title: '备注',
        icon: Icons.notes_outlined,
        child: _remarkBody(theme, d.remark),
      ),
    ]);
  }

  // ======================= Tab 2（客户）：销售条款与财务 =======================

  /// V592 默认销售条款单一事实源：三项默认（结账方式/货运策略/币种）+ 财务字段。
  Widget _termsTab(ThemeData theme) {
    final d = _client!;
    if (_editing) {
      return _tabBody([_editFormCard(theme, finance: true)]);
    }
    return _tabBody([
      _section(
        theme,
        title: '默认销售条款',
        icon: Icons.receipt_long_outlined,
        description: '新建销售订货单选客户后按默认结账方式/货运策略/币种预填；每次下单自动记住最新选择，点「编辑」也可直接改。',
        child: UtenFormGrid(
          children: [
            _kv(theme, '默认结账方式', d.defaultSettlementMethodName),
            _kv(
              theme,
              '默认货运策略',
              // 词表复用销售侧 salesShipmentPolicyLabel；空值交 _kv 显示「—」
              //（其自带 null→「未返回」文案是订单语境，不适用主档）。
              _shipmentPolicyLabelOf(d.defaultShipmentPolicy),
            ),
            _kv(theme, '默认币种', d.defaultCurrencyName),
          ],
        ),
      ),
      const SizedBox(height: UtenSpacing.s16),
      _section(
        theme,
        title: '信用与应收',
        icon: Icons.account_balance_wallet_outlined,
        child: UtenFormGrid(
          children: [
            _kv(theme, '信用额度', _fmtMoney(d.credit)),
            _kv(theme, '期初应收', _fmtMoney(d.initTotal)),
            _kv(theme, '铺底额', _fmtMoney(d.creditFloor)),
            _kv(theme, '结算天数', d.tday?.toString()),
          ],
        ),
      ),
      const SizedBox(height: UtenSpacing.s16),
      _section(
        theme,
        title: '银行与税务',
        icon: Icons.account_balance_outlined,
        child: UtenFormGrid(
          children: [
            _kv(theme, '开户行', d.bank),
            _kv(theme, '银行账号', d.bankAccount),
            _kv(theme, '税号', d.taxId),
          ],
        ),
      ),
    ]);
  }

  // ======================= 就地编辑（客户） =======================

  Map<String, String> _clientInitialValues(ClientDetail d) => {
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
  };

  /// 就地编辑的整套字段（概览分组 + 财务分组）：点「编辑」时建一次交给
  /// [MasterEditFormController]，两个 Tab 各按 group 取子集渲染。
  List<MasterFieldDef> _clientEditFields(ClientDetail d) {
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
    return buildClientFields(
      _clientInitialValues(d),
      settlementOptions,
      currencies: currencyOptions,
      legacyCreditSnapshot: d.legacyId != null,
    );
  }

  /// finance=true 渲染财务分组，否则渲染其余分组；两张表单共用 [_editController]，
  /// 所以任一 Tab 被 TabBarView 释放/重建都不丢值。
  Widget _editFormCard(ThemeData theme, {required bool finance}) {
    final d = _client!;
    final controller = _editController!;
    final permissions = ref.read(currentPermissionsProvider);
    final readOnlyKeys = <String>{
      if (!permissions.contains(Perm.clientStatus)) 'status',
      if (d.legacyId != null) 'credit',
    };
    return UtenCard(
      child: MasterEditForm(
        controller: controller,
        fields: [
          for (final f in controller.fields)
            if ((f.group == '财务') == finance) f,
        ],
        readOnlyKeys: readOnlyKeys.isEmpty ? null : readOnlyKeys,
      ),
    );
  }

  /// 进入编辑态：整套字段 + 初值 + 固定值（分类/乐观锁版本）装进一个值容器。
  void _startInlineEdit(ClientDetail d) {
    _editController?.dispose();
    _editController = MasterEditFormController(
      fields: _clientEditFields(d),
      initialValues: _clientInitialValues(d),
      fixedValues: {
        'categoryId': d.categoryId,
        if (d.version != null) 'version': d.version,
      },
    );
  }

  /// 退出编辑态（取消/保存成功）：表单 widget 本帧还挂在树上并监听着值容器，
  /// 延后到帧末再释放。
  void _stopInlineEdit() {
    final controller = _editController;
    _editController = null;
    _editing = false;
    if (controller != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
    }
  }

  /// 出错字段所在的 Tab：财务分组在「销售条款与财务」(1)，其余在概览(0)。
  int _editTabOf(String? fieldKey) {
    final field = fieldKey == null ? null : _editController?.fieldOf(fieldKey);
    return field?.group == '财务' ? 1 : 0;
  }

  Future<void> _saveInlineEdit() async {
    final d = _client;
    final controller = _editController;
    if (d == null || controller == null) return;
    // 一次校验整套字段（跨两个 Tab）；失败就跳到出错字段所在 Tab 并明确提示，绝不静默。
    final body = controller.buildBody();
    if (body == null) {
      _tab.animateTo(_editTabOf(controller.errorFieldKey));
      final message = controller.error;
      if (message != null && mounted) context.appError(message);
      return;
    }
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
      // 编号查重 409：编号字段描红 + 显文案，保持编辑态让用户改（编号在概览表单）。
      if (e.message.contains('编号已存在')) {
        _tab.animateTo(0);
        controller.setFieldError('code', e.message);
        return;
      }
      if (mounted) context.appApiError(e);
      return;
    } catch (_) {
      if (mounted) context.appError('更新失败，请稍后重试');
      return;
    }
    if (!ok || !mounted) return;
    setState(_stopInlineEdit);
    await _load();
  }

  // ======================= 联系方式 Tab =======================

  Widget _contactsTab(ThemeData theme) => _tabBody([
    _section(
      theme,
      title: '联系方式 (${_contacts.length})',
      icon: Icons.contact_phone_outlined,
      description: '可登记多条手机/电话/传真/邮箱；主选那条同步回列表与单据展示列。',
      trailing: _canEdit ? _addButton('添加联系方式', _addContact) : null,
      cardPadding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s16,
        vertical: UtenSpacing.s4,
      ),
      child: _contacts.isEmpty
          ? _emptyHint(
              theme,
              Icons.contact_phone_outlined,
              '暂无联系方式，点击「添加联系方式」登记',
            )
          : Column(
              children: [
                for (var i = 0; i < _contacts.length; i++) ...[
                  if (i > 0) const Divider(height: 1, indent: 54),
                  _contactRow(theme, _contacts[i]),
                ],
              ],
            ),
    ),
  ]);

  Widget _contactRow(ThemeData theme, PartyContactMethod contact) {
    final (icon, color) = switch (contact.kind) {
      'EMAIL' => (Icons.mail_outline, Colors.blue.shade700),
      'WEBSITE' => (Icons.language_rounded, Colors.blue.shade700),
      'FAX' => (Icons.print_outlined, theme.colorScheme.onSurfaceVariant),
      'MOBILE' => (Icons.smartphone_rounded, theme.colorScheme.primary),
      _ => (Icons.call_outlined, theme.colorScheme.primary),
    };
    return ListTile(
      contentPadding: EdgeInsets.zero,
      minLeadingWidth: 0,
      leading: _rowIcon(icon, color),
      title: Text(
        contact.value,
        style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w500),
      ),
      subtitle: Text(
        '${contact.kindLabel}${contact.primary ? ' · 主选' : ''}'
        '${(contact.remark?.isNotEmpty ?? false) ? ' · ${contact.remark}' : ''}',
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: _canEdit
          ? IconButton(
              tooltip: '删除',
              icon: Icon(
                Icons.delete_outline,
                size: 20,
                color: theme.colorScheme.error,
              ),
              onPressed: () => _deleteContact(contact),
            )
          : null,
    );
  }

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

  // ======================= 地址 Tab =======================

  Widget _addressesTab(ThemeData theme) => _tabBody([
    _section(
      theme,
      title: '地址 (${_addresses.length})',
      icon: Icons.location_on_outlined,
      description: '收货/开票/其它地址可登记多条；默认地址用于开单预填。',
      trailing: _canEdit ? _addButton('添加地址', _addAddress) : null,
      cardPadding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s16,
        vertical: UtenSpacing.s4,
      ),
      child: _addresses.isEmpty
          ? _emptyHint(theme, Icons.location_on_outlined, '暂无地址，点击「添加地址」登记')
          : Column(
              children: [
                for (var i = 0; i < _addresses.length; i++) ...[
                  if (i > 0) const Divider(height: 1, indent: 54),
                  _addressRow(theme, _addresses[i]),
                ],
              ],
            ),
    ),
  ]);

  Widget _addressRow(ThemeData theme, PartyAddress address) {
    final (icon, color) = switch (address.kind) {
      'SHIPPING' => (Icons.local_shipping_outlined, theme.colorScheme.primary),
      'BILLING' => (Icons.receipt_long_outlined, Colors.blue.shade700),
      _ => (Icons.place_outlined, theme.colorScheme.onSurfaceVariant),
    };
    return ListTile(
      contentPadding: EdgeInsets.zero,
      minLeadingWidth: 0,
      leading: _rowIcon(icon, color),
      title: Text(
        address.address,
        style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w500),
      ),
      subtitle: Text(
        '${address.kindLabel}${address.defaultAddress ? ' · 默认' : ''}',
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: _canEdit
          ? IconButton(
              tooltip: '删除',
              icon: Icon(
                Icons.delete_outline,
                size: 20,
                color: theme.colorScheme.error,
              ),
              onPressed: () => _deleteAddress(address),
            )
          : null,
    );
  }

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

  // ======================= 跟进记录 Tab =======================

  Widget _activitiesTab(ThemeData theme) => _tabBody([
    _section(
      theme,
      title: _isClient
          ? '跟进与行为记录 (${_activities.length})'
          : '跟进记录 (${_activities.length})',
      icon: Icons.history_edu_outlined,
      description: _isClient ? '跟进/投诉/违约等记录；违约可扣信誉分，奖励加分。' : '供应商跟进/合作问题记录。',
      trailing: _canEdit ? _addButton('添加记录', _addActivity) : null,
      cardPadding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s16,
        vertical: UtenSpacing.s4,
      ),
      child: _activities.isEmpty
          ? _emptyHint(theme, Icons.history_edu_outlined, '暂无记录')
          : Column(
              children: [
                for (var i = 0; i < _activities.length; i++) ...[
                  if (i > 0) const Divider(height: 1, indent: 54),
                  _activityRow(theme, _activities[i]),
                ],
              ],
            ),
    ),
  ]);

  Widget _activityRow(ThemeData theme, PartyActivityRecord record) {
    final (icon, color) = switch (record.kind) {
      'FOLLOW_UP' => (Icons.phone_in_talk_rounded, theme.colorScheme.primary),
      'COMPLAINT' => (
        Icons.sentiment_dissatisfied_rounded,
        Colors.deepOrange.shade700,
      ),
      'PENALTY' => (Icons.gavel_rounded, theme.colorScheme.error),
      'REWARD' => (Icons.emoji_events_rounded, Colors.amber.shade800),
      _ => (Icons.notes_rounded, theme.colorScheme.onSurfaceVariant),
    };
    Widget? deltaChip;
    if (_isClient && record.scoreDelta != 0) {
      final up = record.scoreDelta > 0;
      final color = up ? theme.colorScheme.primary : theme.colorScheme.error;
      deltaChip = Container(
        padding: const EdgeInsets.symmetric(
          horizontal: UtenSpacing.s8,
          vertical: 3,
        ),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(UtenRadius.pill),
        ),
        child: Text(
          '信誉分 ${up ? '+' : ''}${record.scoreDelta}',
          style: theme.textTheme.labelMedium?.copyWith(
            color: color,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
    }
    return ListTile(
      contentPadding: EdgeInsets.zero,
      minLeadingWidth: 0,
      leading: _rowIcon(icon, color),
      title: Text(
        record.content,
        style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w500),
      ),
      subtitle: Text(
        '${record.kindLabel} · ${_shortDateTime(record.createdAt)}',
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: deltaChip,
    );
  }

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
    // 编辑态：右下只留 取消/保存（保存合并两张分区表单一次提交）。
    if (_editing) {
      children.addAll([
        UtenButton(
          key: const Key('party-detail-cancel'),
          type: UtenButtonType.secondary,
          size: UtenButtonSize.large,
          icon: Icons.close_rounded,
          onPressed: _busy ? null : () => setState(_stopInlineEdit),
          child: const Text('取消'),
        ),
        UtenButton(
          key: const Key('party-detail-save'),
          size: UtenButtonSize.large,
          icon: Icons.save_outlined,
          onPressed: _busy ? null : _saveInlineEdit,
          child: const Text('保存'),
        ),
      ]);
      return children;
    }
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
    // 客户：详情页**就地编辑**（分区变输入，不再弹窗）；供应商沿用弹窗。
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
        _startInlineEdit(_client!);
        _editing = true;
      });
      _tab.animateTo(0);
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

  Widget _addButton(String label, VoidCallback onPressed) => UtenButton(
    type: UtenButtonType.tonal,
    size: UtenButtonSize.small,
    icon: Icons.add_rounded,
    onPressed: onPressed,
    child: Text(label),
  );

  /// 行首图标瓦片：38×38 圆角底 + 20 号图标，比裸图标更有层次。
  Widget _rowIcon(IconData icon, Color color) => Container(
    width: 38,
    height: 38,
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Icon(icon, size: 20, color: color),
  );

  Widget _emptyHint(ThemeData theme, IconData icon, String message) => Padding(
    padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s16),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: UtenSpacing.s8),
        Text(
          message,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    ),
  );
}

String _shortDateTime(String? iso) {
  if (iso == null || iso.length < 16) return iso ?? '—';
  return '${iso.substring(0, 10)} ${iso.substring(11, 16)}';
}

/// 金额/税率显示：整数不带 .0，小数保留两位。
String _fmtMoney(double? v) {
  if (v == null) return '—';
  if (v == v.truncateToDouble()) return v.truncate().toString();
  return v.toStringAsFixed(2);
}

/// 默认货运策略显示标签：词表复用销售侧 [salesShipmentPolicyLabel]；
/// 空值返回 null 交 [_kv] 显示「—」。
String? _shipmentPolicyLabelOf(String? value) {
  final v = value?.trim();
  if (v == null || v.isEmpty) return null;
  return salesShipmentPolicyLabel(v);
}
