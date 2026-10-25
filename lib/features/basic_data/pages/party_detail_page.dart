// 客户/供应商详情整页（V579，2026-09-14；2026-09-17 布局改版）。
//
// 改版对齐员工详情/我的页的家族范式（用户 2026-09-17 口径：原五张全宽大卡片
// 字小且乱 → 全部重新布局）：
//  - Hero 身份卡：圆形首字标识 + 大号名称 + 状态/等级徽章 + 编号/分类/负责人元信息；
//    客户附「信誉分/信用额度/期初应收/铺底额」统计行（大号数字）。
//  - Tab 分区（UtenCollapsingHeaderScrollView：头部随滚动收起、Tab 栏吸顶）：
//    客户＝概览/销售条款与财务/联系方式/地址/跟进与行为记录；供应商＝概览/联系方式/
//    地址/跟进记录。查看与编辑共用字段定义、分组顺序和按内容宽度自适应的网格。
//  - 就地编辑（2026-09-15 退役弹窗的延续）：客户点「编辑」后**各分区原地变输入**——
//    概览 Tab 渲染 基础/联系/地址/资质/其他 分组表单，销售条款与财务 Tab 渲染 财务
//    分组表单；右下悬浮组换「取消/保存」，保存时合并两张表单一次提交，校验失败自动
//    跳回出错的那张表单所在 Tab。供应商沿用 showSupplierMasterEdit 弹窗。
//  - 联系方式/地址为多值子表（party_contact_methods / party_addresses），跟进记录
//    （party_activity_records）客户行为/投诉/违约扣信誉分等；信誉分首条按 100±delta 起算。
import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_refresh_button.dart';
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
import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/page_search_lifecycle.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/action_feedback.dart';
import '../../../core/ui/human_error_message.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../../../shared/models/sales_shipment_policy.dart';
import '../models/client_node.dart';
import '../models/party_directory_models.dart';
import '../repositories/client_repository.dart';
import '../repositories/master_status_repository.dart';
import '../repositories/party_directory_repository.dart';
import '../models/supplier_node.dart';
import '../repositories/supplier_repository.dart';
import '../widgets/basic_data_l10n.dart';
import '../widgets/client_access_panel.dart';
import '../widgets/client_goods_alias_tab.dart';
import '../widgets/client_master_edit.dart';
import '../models/currency_node.dart';
import '../models/reference_method_option.dart';
import '../widgets/master_edit_dialog.dart';
import '../widgets/master_read_only_fields.dart';
import '../widgets/master_operation_history_panel.dart';
import '../widgets/master_status_confirmation.dart';
import '../widgets/master_edit_owner.dart';
import '../widgets/supplier_master_edit.dart';
import '../widgets/uten_detail_tab_bar.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/models/subcontract_short_delivery.dart';
import '../../../shared/repositories/subcontract_loss_summary_loader.dart';

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

  /// ADR-098 供应商「委外损耗」汇总（有委外订货查看权限才拉；失败静默不影响主档）。
  SubcontractSupplierLossSummary? _lossSummary;
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
    length: _isClient ? 6 : 4,
    vsync: this,
  );

  bool _loading = true;
  bool _busy = false;
  bool _confirmingChange = false;
  bool _openingEditor = false;
  int _loadEpoch = 0;
  String? _error;
  MasterEditOwner? _readOwner;
  MasterEditOwner? _editOwner;
  MasterEditOwner? _changeOwner;
  late final _pageLifecycle = PageSearchLifecycle(
    onLeave: () {
      _readOwner?.invalidate();
      _editOwner?.invalidate();
      _changeOwner?.invalidate();
    },
    onReturn: () => _load(clearCurrent: true),
  );

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
    ref.listenManual(sensitiveReadBoundaryProvider, (previous, next) {
      if (previous == next) return;
      _clearPrivateData();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && ref.read(sensitiveReadBoundaryProvider) == next) {
          _load(clearCurrent: true);
        }
      });
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _pageLifecycle.attach(context);
  }

  void _clearPrivateData() {
    if (!mounted) return;
    _loadEpoch++;
    _readOwner?.invalidate();
    _changeOwner?.invalidate();
    setState(() {
      _stopInlineEdit();
      _client = null;
      _supplier = null;
      _contacts = const [];
      _addresses = const [];
      _activities = const [];
      _lossSummary = null;
      _creditScore = null;
      _scoreLoaded = false;
      _editSettlements = const [];
      _editCurrencies = const [];
      _busy = false;
      _confirmingChange = false;
      _openingEditor = false;
      _loading = true;
      _error = null;
    });
  }

  @override
  void didUpdateWidget(covariant PartyDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.id != widget.id || oldWidget.partyType != widget.partyType) {
      _clearPrivateData();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load(clearCurrent: true);
      });
    }
  }

  @override
  void dispose() {
    _pageLifecycle.dispose();
    _readOwner?.dispose();
    _editOwner?.dispose();
    _changeOwner?.dispose();
    _tab.dispose();
    _editController?.dispose();
    super.dispose();
  }

  Future<void> _load({bool clearCurrent = false}) async {
    if (_busy) return;
    final epoch = ++_loadEpoch;
    final id = widget.id;
    final type = widget.partyType;
    _readOwner?.invalidate();
    final owner = MasterEditOwner(
      context,
      ref,
      permissions: {_isClient ? Perm.clientView : Perm.supplierView},
      requireWrite: false,
      isCurrent: () =>
          epoch == _loadEpoch && widget.id == id && widget.partyType == type,
    );
    _readOwner = owner;
    bool current() => mounted && owner.isCurrent;
    setState(() {
      _loading = true;
      _error = null;
      if (clearCurrent) {
        _client = null;
        _supplier = null;
        _contacts = const [];
        _addresses = const [];
        _activities = const [];
        _lossSummary = null;
        _creditScore = null;
        _scoreLoaded = false;
      }
    });
    try {
      if (!_has(_isClient ? Perm.clientView : Perm.supplierView)) {
        setState(() {
          _loading = false;
          _error = '当前没有资料查看权限';
        });
        return;
      }
      if (!await owner.bindRequests()) return;
      if (_isClient) {
        final detail = await owner.run(
          () => ref.read(clientRepositoryProvider).detail(id),
        );
        if (!current()) return;
        setState(() => _client = detail);
      } else {
        final detail = await owner.run(
          () => ref.read(supplierRepositoryProvider).detail(id),
        );
        if (!current()) return;
        setState(() => _supplier = detail);
        unawaited(_loadSubcontractLossSummary());
      }
      final results = await owner.run(
        () => Future.wait([
          _directoryRepo.contactMethods(widget.id),
          _directoryRepo.addresses(widget.id),
          _directoryRepo.activityRecords(widget.id),
          if (_isClient) _directoryRepo.creditScore(widget.id),
        ]),
      );
      if (!current()) return;
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
      if (!current()) return;
      setState(() {
        _client = null;
        _supplier = null;
        _error = e.message;
        _loading = false;
      });
    } catch (error) {
      if (!current()) return;
      setState(() {
        _client = null;
        _supplier = null;
        _error =
            humanErrorMessage(error) ??
            basicDataL10n(context).productionDailyReportLoadFailed;
        _loading = false;
      });
    } finally {
      if (identical(_readOwner, owner)) _readOwner = null;
      owner.dispose();
    }
  }

  Future<void> _reloadAfterHistory() => _load(clearCurrent: true);

  /// ADR-098：供应商「委外损耗」段——已结清委外订货行的加权损耗率与最近几次短交结案。
  Future<void> _loadSubcontractLossSummary() async {
    final perms = ref.read(currentPermissionsProvider);
    final allowed =
        ref.read(isSuperAdminProvider) ||
        perms.contains(Perm.subcontractOrderView);
    if (!allowed) return;
    final epoch = _loadEpoch;
    final id = widget.id;
    final owner = MasterEditOwner(
      context,
      ref,
      permissions: {Perm.supplierView, Perm.subcontractOrderView},
      requireWrite: false,
      isCurrent: () => epoch == _loadEpoch && widget.id == id && !_isClient,
    );
    try {
      if (!await owner.bindRequests()) return;
      final summary = await owner.run(
        () =>
            loadSubcontractSupplierLossSummary(ref.read(apiClientProvider), id),
      );
      if (!mounted || !owner.isCurrent) return;
      setState(() => _lossSummary = summary);
    } catch (_) {
      // 汇总失败静默：主档详情本身不受影响。
    } finally {
      owner.dispose();
    }
  }

  Future<void> _reloadChildren() async {
    final epoch = _loadEpoch;
    final boundary = ref.read(sensitiveReadBoundaryProvider);
    bool current() =>
        mounted &&
        epoch == _loadEpoch &&
        ref.read(sensitiveReadBoundaryProvider) == boundary;
    try {
      final results = await Future.wait([
        _directoryRepo.contactMethods(widget.id),
        _directoryRepo.addresses(widget.id),
        _directoryRepo.activityRecords(widget.id),
        if (_isClient) _directoryRepo.creditScore(widget.id),
      ]);
      if (!current()) return;
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
      if (mounted && current()) context.appError(e.message);
    } catch (_) {
      if (mounted && current()) context.appError('刷新失败，请稍后重试');
    }
  }

  String? get _title {
    if (_isClient) {
      return _client?.name ?? _client?.code ?? '客户详情';
    }
    return _supplier?.name ?? _supplier?.code ?? '供应商详情';
  }

  List<String> get _tabLabels => _isClient
      ? [
          '概览',
          '销售条款与财务',
          '联系方式',
          '地址',
          '跟进与行为记录',
          // ADR-134: learned customer wording of our goods.
          basicDataL10n(context).clientGoodsAliasTab,
        ]
      : const ['概览', '联系方式', '地址', '跟进记录'];

  @override
  Widget build(BuildContext context) {
    ref.watch(currentPermissionsProvider);
    ref.watch(isSuperAdminProvider);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: UtenAppBar(
        title: _isClient ? '客户详情' : '供应商详情',
        leading: UtenBackButton(onPressed: () => Navigator.maybePop(context)),
        actions: [
          MasterOperationHistoryActions(
            entityType: _isClient ? 'clients' : 'suppliers',
            recordId: widget.id,
            enabled: !_loading && !_busy && !_editing && !_openingEditor,
            onChanged: _reloadAfterHistory,
          ),
          UtenRefreshButton(
            enabled: !_busy && !_editing && !_openingEditor,
            busy: _loading,
            onRefresh: _load,
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
                  if (_busy && !_confirmingChange)
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

  // 基础资料详情共用分类栏，保持 TabController 与正文同步。
  PreferredSizeWidget _tabBar(ThemeData theme) => buildUtenDetailTabBar(
    context,
    controller: _tab,
    labelStyle: theme.textTheme.titleSmall?.copyWith(
      fontWeight: FontWeight.w600,
    ),
    tabs: [for (final label in _tabLabels) Tab(text: label)],
  );

  /// Tab → 内容：客户 0 概览/1 条款财务/2 联系/3 地址/4 跟进/5 货品对照；
  /// 供应商 0 概览/1 联系/2 地址/3 跟进（无条款 Tab）。
  Widget _tabView(ThemeData theme, int index) {
    if (index == 0) return _overviewTab(theme);
    if (_isClient) {
      if (index == 1) return _termsTab(theme);
      if (index == 5) return ClientGoodsAliasTab(clientId: widget.id);
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
        0,
        UtenSpacing.s16,
        0,
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
      key: const Key('party-identity-card'),
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
                          // 停用=灰（ADR-169：基础资料主档停用归中性终态，
                          // 原红档把「停用」当异常）。
                          type: active
                              ? UtenStatusBadgeType.success
                              : UtenStatusBadgeType.neutral,
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
    crossAxisAlignment: CrossAxisAlignment.stretch,
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

  // ======================= Tab 1：概览 =======================

  Widget _overviewTab(ThemeData theme) {
    if (_isClient) {
      if (_editing) return _tabBody([_editFormCard(theme, finance: false)]);
      return _tabBody([
        _clientReadOnlyFields(finance: false),
        const SizedBox(height: UtenSpacing.s20),
        _section(
          theme,
          title: '归属与访问',
          icon: Icons.visibility_outlined,
          child: UtenFormGrid(
            columns: 4,
            maxColumns: 4,
            minFieldWidth: 260,
            children: [
              _kv(theme, '分类', _client?.categoryName),
              _kv(theme, '当前访问', _client?.accessReasonLabel),
            ],
          ),
        ),
      ]);
    }
    final detail = _supplier!;
    final values = supplierInitialValues(detail);
    final fields = buildSupplierFields(context, values, const [], ref);
    return _tabBody([
      UtenCard(
        key: const Key('party-overview-card'),
        child: MasterReadOnlyFields(
          fields: fields,
          valueOf: (field) => switch (field.key) {
            'ownerEmployeeId' => detail.ownerEmployeeName ?? detail.empId,
            'defaultSettlementMethodId' => detail.defaultSettlementMethodName,
            'defaultCurrencyId' => detail.defaultCurrencyName,
            _ => values[field.key],
          },
        ),
      ),
      if (_lossSummary != null) ...[
        const SizedBox(height: UtenSpacing.s20),
        _section(
          theme,
          title: '委外损耗',
          icon: Icons.analytics_outlined,
          description: '已结清的委外订货行（自然到齐或接受损耗结案）的损耗统计；每一次短交的判定记录见右侧。',
          trailing: _has(Perm.subcontractOrderView)
              ? TextButton.icon(
                  key: const Key('supplier-subcontract-loss-open'),
                  onPressed: () {
                    if (!_has(Perm.subcontractOrderView)) return;
                    goFrom(
                      context,
                      RouteName.subcontractShortDeliveriesWith(
                        supplierId: widget.id,
                      ),
                    );
                  },
                  icon: const Icon(Icons.open_in_new_rounded, size: 18),
                  label: const Text('短交记录'),
                )
              : null,
          child: _subcontractLossBody(theme, _lossSummary!),
        ),
      ],
    ]);
  }

  Widget _clientReadOnlyFields({required bool finance}) {
    final detail = _client!;
    final values = _clientInitialValues(detail);
    return UtenCard(
      key: ValueKey(finance ? 'party-finance-card' : 'party-overview-card'),
      child: MasterReadOnlyFields(
        fields: [
          for (final field in _clientEditFields(detail))
            if ((field.group == '财务') == finance) field,
        ],
        valueOf: (field) => switch (field.key) {
          'defaultSettlementMethodId' => detail.defaultSettlementMethodName,
          'defaultCurrencyId' => detail.defaultCurrencyName,
          'defaultShipmentPolicy' => _shipmentPolicyLabelOf(
            detail.defaultShipmentPolicy,
          ),
          _ => values[field.key],
        },
      ),
    );
  }

  Widget _subcontractLossBody(
    ThemeData theme,
    SubcontractSupplierLossSummary s,
  ) {
    if (s.isEmpty) {
      return Text(
        '还没有结清的委外订货行，暂无损耗统计。',
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }
    final lossColor = s.lossPct > 0 ? theme.colorScheme.error : null;
    final stats = <({String label, String value, Color? color, String? tip})>[
      (
        label: '加权损耗率',
        value: formatSubcontractPct(s.lossPct),
        color: lossColor,
        tip: '累计损耗 / 累计订货，接受损耗结案的行按改量前的原订货量算',
      ),
      (
        label: '累计损耗 / 订货',
        value:
            '${formatSubcontractQty(s.lossQty)} / ${formatSubcontractQty(s.orderedQty)}',
        color: null,
        tip: null,
      ),
      (
        label: '结清行数',
        value: s.settledLineCount.toString(),
        color: null,
        tip: '自然到齐 + 接受损耗结案的订货行',
      ),
      (
        label: '接受损耗次数 / 最高一次',
        value: '${s.acceptedLossCount} / ${formatSubcontractPct(s.maxLossPct)}',
        color: null,
        tip: null,
      ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < stats.length; i++) ...[
              if (i > 0)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: UtenSpacing.s16,
                  ),
                  child: Container(
                    width: 1,
                    height: 44,
                    color: theme.colorScheme.outlineVariant.withValues(
                      alpha: 0.5,
                    ),
                  ),
                ),
              Expanded(child: _statBlock(theme, stats[i])),
            ],
          ],
        ),
        if (s.byGoods.isNotEmpty) ...[
          const SizedBox(height: UtenSpacing.s16),
          Text(
            '按货品',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: UtenSpacing.s8),
          for (final g in s.byGoods.take(8))
            Padding(
              padding: const EdgeInsets.only(bottom: UtenSpacing.s4),
              child: Text(
                '${g.goodsName ?? ''} ${g.goodsCode ?? ''}：'
                '结清 ${g.settledLineCount} 行，订 ${formatSubcontractQty(g.orderedQty)}，'
                '损耗 ${formatSubcontractQty(g.lossQty)}(${formatSubcontractPct(g.lossPct)})，'
                '最高一次 ${formatSubcontractPct(g.maxLossPct)}',
                style: theme.textTheme.bodyMedium,
              ),
            ),
        ],
        if (s.recentCases.isNotEmpty) ...[
          const SizedBox(height: UtenSpacing.s16),
          Text(
            '最近接受损耗的记录',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: UtenSpacing.s8),
          for (final c in s.recentCases)
            Padding(
              padding: const EdgeInsets.only(bottom: UtenSpacing.s4),
              child: Text(
                '${ChinaDateTime.formatIsoInstant(c.closedAt, fallback: '—')} · '
                '${c.orderBillNo} · ${c.goodsLabel}：订 ${formatSubcontractQty(c.orderedQty, c.unitName)}，'
                '损耗 ${formatSubcontractQty(c.lossQty ?? 0, c.unitName)}(${formatSubcontractPct(c.lossPct)})',
                style: theme.textTheme.bodyMedium,
              ),
            ),
        ],
      ],
    );
  }

  // ======================= Tab 2（客户）：销售条款与财务 =======================

  /// V592 默认销售条款单一事实源：三项默认（结账方式/货运策略/币种）+ 财务字段。
  Widget _termsTab(ThemeData theme) => _tabBody([
    _editing
        ? _editFormCard(theme, finance: true)
        : _clientReadOnlyFields(finance: true),
  ]);

  Map<String, String> _clientInitialValues(ClientDetail d) => {
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
      l10n: basicDataL10n(context),
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
      key: ValueKey(finance ? 'party-finance-card' : 'party-overview-card'),
      child: MasterEditForm(
        contentPadding: EdgeInsets.zero,
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
    final owner = _editOwner;
    _editOwner = null;
    owner?.invalidate();
    final controller = _editController;
    _editController = null;
    _editing = false;
    if (controller != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
    }
    if (owner != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => owner.dispose());
    }
  }

  /// 出错字段所在的 Tab：财务分组在「销售条款与财务」(1)，其余在概览(0)。
  int _editTabOf(String? fieldKey) {
    final field = fieldKey == null ? null : _editController?.fieldOf(fieldKey);
    return field?.group == '财务' ? 1 : 0;
  }

  Future<void> _saveInlineEdit() async {
    if (_busy || !_canEdit || !_writable) return;
    final d = _client;
    final controller = _editController;
    final owner = _editOwner;
    if (d == null || controller == null || owner == null || !owner.isCurrent) {
      return;
    }
    // 一次校验整套字段（跨两个 Tab）；失败就跳到出错字段所在 Tab 并明确提示，绝不静默。
    final body = controller.buildBody();
    if (body == null) {
      _tab.animateTo(_editTabOf(controller.errorFieldKey));
      final message = controller.error;
      if (message != null && mounted) context.appError(message);
      return;
    }
    setState(() => _busy = true);
    try {
      await owner.run(
        () => ref.read(clientRepositoryProvider).update(d.id, body),
      );
      if (!mounted ||
          !owner.isCurrent ||
          !identical(_editController, controller)) {
        return;
      }
      context.appSuccess('客户已更新');
    } on ApiException catch (e) {
      if (!mounted ||
          !owner.isCurrent ||
          !identical(_editController, controller)) {
        return;
      }
      // 编号查重 409：编号字段描红 + 显文案，保持编辑态让用户改（编号在概览表单）。
      if (e.message.contains('编号已存在')) {
        _tab.animateTo(0);
        controller.setFieldError('code', e.message);
        return;
      }
      context.appApiError(e);
      return;
    } catch (_) {
      if (mounted && owner.isCurrent) context.appError('更新失败，请稍后重试');
      return;
    } finally {
      if (mounted && identical(_editOwner, owner)) {
        setState(() => _busy = false);
      }
    }
    if (!mounted || !owner.isCurrent) return;
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
    var confirmedValue = '';
    var confirmedRemark = '';
    var confirmedKind = kind;
    var confirmedPrimary = primary;
    late final bool? ok;
    try {
      ok = await UtenDialog.showAndWaitForExit<bool>(
        context,
        onPopped: (_) {
          confirmedValue = valueCtl.text;
          confirmedRemark = remarkCtl.text;
          confirmedKind = kind;
          confirmedPrimary = primary;
        },

        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setDialogState) => UtenAlertDialog(
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
                    decoration: const UtenInputDecoration(
                      InputDecoration(labelText: '内容(必填)'),
                    ),
                  ),
                  const SizedBox(height: UtenSpacing.s12),
                  TextField(
                    controller: remarkCtl,
                    decoration: const UtenInputDecoration(
                      InputDecoration(labelText: '备注(选填)'),
                    ),
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
    } finally {
      valueCtl.dispose();
      remarkCtl.dispose();
    }
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await _directoryRepo.addContactMethod(
        widget.id,
        kind: confirmedKind,
        value: confirmedValue.trim(),
        primary: confirmedPrimary,
        remark: confirmedRemark.trim(),
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
      builder: (ctx) => UtenAlertDialog(
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
    var confirmedAddress = '';
    var confirmedKind = kind;
    var confirmedDefaultAddress = defaultAddress;
    late final bool? ok;
    try {
      ok = await UtenDialog.showAndWaitForExit<bool>(
        context,
        onPopped: (_) {
          confirmedAddress = addressCtl.text;
          confirmedKind = kind;
          confirmedDefaultAddress = defaultAddress;
        },

        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setDialogState) => UtenAlertDialog(
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
                    decoration: const UtenInputDecoration(
                      InputDecoration(labelText: '地址(必填)'),
                    ),
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
    } finally {
      addressCtl.dispose();
    }
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await _directoryRepo.addAddress(
        widget.id,
        kind: confirmedKind,
        address: confirmedAddress.trim(),
        defaultAddress: confirmedDefaultAddress,
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
      builder: (ctx) => UtenAlertDialog(
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
    var confirmedContent = '';
    var confirmedScore = '';
    var confirmedKind = kind;
    late final bool? ok;
    try {
      ok = await UtenDialog.showAndWaitForExit<bool>(
        context,
        onPopped: (_) {
          confirmedContent = contentCtl.text;
          confirmedScore = scoreCtl.text;
          confirmedKind = kind;
        },

        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setDialogState) => UtenAlertDialog(
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
                      for (final entry
                          in PartyActivityRecord.kindLabels.entries)
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
                    decoration: const UtenInputDecoration(
                      InputDecoration(labelText: '内容(必填)'),
                    ),
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
    } finally {
      contentCtl.dispose();
      scoreCtl.dispose();
    }
    if (ok != true || !mounted) return;
    final delta = _isClient ? (int.tryParse(confirmedScore.trim()) ?? 0) : 0;
    setState(() => _busy = true);
    try {
      await _directoryRepo.addActivityRecord(
        widget.id,
        kind: confirmedKind,
        content: confirmedContent.trim(),
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
          type: active ? UtenButtonType.danger : UtenButtonType.secondary,
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
    if (_loading || _busy || _openingEditor || !_canEdit || !_writable) return;
    final epoch = _loadEpoch;
    final detail = _client;
    final owner = !_isClient || detail == null
        ? null
        : MasterEditOwner(
            context,
            ref,
            permissions: {Perm.clientView, Perm.clientEdit},
            isCurrent: () =>
                epoch == _loadEpoch &&
                identical(_client, detail) &&
                _canEdit &&
                _writable,
          );
    if (owner != null) {
      _editOwner = owner;
      owner.addListener(() {
        if (mounted && !owner.isCurrent && identical(_editOwner, owner)) {
          _clearPrivateData();
        }
      });
    }
    setState(() => _openingEditor = true);
    try {
      if (owner != null && !await owner.bindRequests()) return;
      await _openEditor(owner: owner, client: detail);
    } finally {
      if (mounted && epoch == _loadEpoch) {
        setState(() => _openingEditor = false);
      }
      if (owner != null && !_editing && identical(_editOwner, owner)) {
        _editOwner = null;
        owner.dispose();
      }
    }
  }

  Future<void> _openEditor({
    MasterEditOwner? owner,
    ClientDetail? client,
  }) async {
    // 客户：详情页**就地编辑**（分区变输入，不再弹窗）；供应商沿用弹窗。
    if (_isClient && client != null && owner != null) {
      final settlements =
          await loadClientSettlementMethods(context, ref, owner: owner) ??
          const <ReferenceMethodOption>[];
      if (!mounted || !owner.isCurrent) return;
      final currencies =
          await loadClientCurrencies(context, ref, owner: owner) ??
          const <CurrencyListItem>[];
      if (!mounted || !owner.isCurrent) return;
      setState(() {
        _editSettlements = settlements;
        _editCurrencies = currencies;
        _startInlineEdit(client);
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
    if (_loading || _busy || _editing || !_canStatus || !_writable) return;
    final version = _isClient ? _client?.version : _supplier?.version;
    final snapshot = _isClient ? _client : _supplier;
    final type = widget.partyType;
    final id = widget.id;
    final label = _title ?? (_isClient ? '客户' : '供应商');
    final resource = _isClient
        ? ApiEndpoints.client(id)
        : ApiEndpoints.supplier(id);
    final owner = MasterEditOwner(
      context,
      ref,
      permissions: {
        _isClient ? Perm.clientView : Perm.supplierView,
        _isClient ? Perm.clientStatus : Perm.supplierStatus,
      },
      isCurrent: () =>
          widget.id == id &&
          widget.partyType == type &&
          identical(snapshot, _isClient ? _client : _supplier) &&
          _canStatus &&
          _writable &&
          !_editing,
    );
    _changeOwner = owner;
    owner.addListener(() {
      if (mounted && !owner.isCurrent && identical(_changeOwner, owner)) {
        setState(() {
          _busy = false;
          _confirmingChange = false;
        });
      }
    });
    setState(() {
      _busy = true;
      _confirmingChange = true;
    });
    try {
      if (!await owner.bindRequests() || !mounted || !owner.isCurrent) return;
      if (!await confirmMasterStatusChange(
            context,
            disabling: active,
            label: label,
            dialogScopeBuilder: owner.ownDialog,
          ) ||
          !mounted ||
          !owner.isCurrent) {
        return;
      }
      setState(() => _confirmingChange = false);
      await owner.run(
        () => ref
            .read(masterStatusRepositoryProvider)
            .change(
              resourcePath: resource,
              status: active ? '禁用' : '使用',
              version: version,
            ),
      );
      if (!mounted || !owner.isCurrent) return;
      context.appSuccess(active ? '已停用' : '已启用');
      setState(() => _busy = false);
      await _load();
    } catch (error) {
      if (mounted && owner.isCurrent) context.appApiError(error);
    } finally {
      if (identical(_changeOwner, owner)) {
        _changeOwner = null;
        if (mounted) {
          setState(() {
            _busy = false;
            _confirmingChange = false;
          });
        }
      }
      owner.dispose();
    }
  }

  Future<void> _delete() async {
    if (_loading || _busy || _editing || !_canDelete || !_writable) return;
    final name = _title ?? '';
    final snapshot = _isClient ? _client : _supplier;
    final type = widget.partyType;
    final id = widget.id;
    final owner = MasterEditOwner(
      context,
      ref,
      permissions: {
        _isClient ? Perm.clientView : Perm.supplierView,
        _isClient ? Perm.clientDelete : Perm.supplierDelete,
      },
      isCurrent: () =>
          widget.id == id &&
          widget.partyType == type &&
          identical(snapshot, _isClient ? _client : _supplier) &&
          _canDelete &&
          _writable &&
          !_editing,
    );
    _changeOwner = owner;
    owner.addListener(() {
      if (mounted && !owner.isCurrent && identical(_changeOwner, owner)) {
        setState(() {
          _busy = false;
          _confirmingChange = false;
        });
      }
    });
    setState(() {
      _busy = true;
      _confirmingChange = true;
    });
    try {
      if (!await owner.bindRequests() || !mounted || !owner.isCurrent) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => owner.ownDialog(
          ctx,
          UtenAlertDialog(
            title: Text(_isClient ? '删除客户' : '删除供应商'),
            content: Text('确定删除「$name」吗？'),
            actionsAlignment: MainAxisAlignment.center,
            actions: [
              TextButton(
                onPressed: () {
                  if (ctx.mounted) Navigator.pop(ctx, false);
                },
                child: const Text('取消'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(ctx).colorScheme.error,
                ),
                onPressed: () {
                  if (ctx.mounted) Navigator.pop(ctx, true);
                },
                child: const Text('删除'),
              ),
            ],
          ),
        ),
      );
      if (confirmed != true || !mounted || !owner.isCurrent) return;
      setState(() => _confirmingChange = false);
      await owner.run(
        () => type == 'client'
            ? ref.read(clientRepositoryProvider).delete(id)
            : ref.read(supplierRepositoryProvider).delete(id),
      );
      if (!mounted || !owner.isCurrent) return;
      context.appSuccess(type == 'client' ? '客户已删除' : '供应商已删除');
      backTo(
        context,
        defaultPath: type == 'client'
            ? RouteName.basicinfoClient
            : RouteName.basicinfoSupplier,
      );
    } catch (error) {
      if (mounted && owner.isCurrent) context.appApiError(error);
    } finally {
      if (identical(_changeOwner, owner)) {
        _changeOwner = null;
        if (mounted) {
          setState(() {
            _busy = false;
            _confirmingChange = false;
          });
        }
      }
      owner.dispose();
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
      borderRadius: BorderRadius.circular(UtenRadius.control),
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

String _shortDateTime(String? iso) =>
    ChinaDateTime.formatIsoInstant(iso, fallback: iso ?? '—');

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
