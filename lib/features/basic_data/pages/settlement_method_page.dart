// 结算方式管理页（基础资料 · 扁平字典 + 账期策略维护，V453）。
//
// 结算方式是销售/采购/委外结账条件与应付到期日的 UUID 权威字典（ADR-035/047）。
// 本页只做两件事：看全量（含禁用行、系统角色、账期口径）和维护账期策略与
// 可选改名（settlement_method:edit）；系统角色（CASH/MONTHLY）口径由迁移锁定，
// 页面置灰并提示。新增仍走 settlement_method:create（可随带账期）。
// 停用/删除不在此页开放：活动客户/供应商默认与单据引用受 DB 守卫保护。
//
// 2026-09-16 列表表格化：卡片列表改为 MasterDataTableView（横排 autofilter 列头），
// 状态/系统角色/到期基准/到期规则四列接后端 facets（settlement-admin/facets），
// 表头筛选落到服务端查询；编号/名称等自由文本列不筛选；全量小字典仍不分页，
// 关键词保持本地过滤。范式同 color_page（V4xx 批次）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/buttons/uten_export_button.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/print/uten_print_preview.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/action_feedback.dart';
import '../../../shared/auth/permissions.dart';
import '../models/master_facet.dart';
import '../models/settlement_method_admin.dart';
import '../repositories/reference_method_repository.dart';
import '../widgets/master_data_table_view.dart';
import '../widgets/master_edit_dialog.dart';

class SettlementMethodPage extends ConsumerStatefulWidget {
  const SettlementMethodPage({super.key});

  @override
  ConsumerState<SettlementMethodPage> createState() =>
      _SettlementMethodPageState();
}

class _SettlementMethodPageState extends ConsumerState<SettlementMethodPage> {
  List<SettlementMethodAdminItem>? _items;
  bool _loading = false;
  String? _error;
  String _keyword = '';

  /// 表头筛选（字段→原始值；空值哨兵见 master_facet.dart）。落到服务端查询。
  Map<String, String?> _filters = {};
  SettlementMethodFacets? _facets;

  bool get _canCreate => ref
      .read(currentPermissionsProvider)
      .contains(Perm.settlementMethodCreate);

  bool get _canEdit =>
      ref.read(currentPermissionsProvider).contains(Perm.settlementMethodEdit);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _load();
      _loadFacets();
    });
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = await ref
          .read(referenceMethodRepositoryProvider)
          .settlementAdminList(filters: _filters);
      if (!mounted) return;
      setState(() {
        _items = items;
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
        _error = '加载结算方式失败';
        _loading = false;
      });
    }
  }

  /// 拉字段 facet（表头筛选下拉选项）。失败静默降级为空下拉，不阻塞列表。
  Future<void> _loadFacets() async {
    try {
      final f = await ref
          .read(referenceMethodRepositoryProvider)
          .settlementAdminFacets();
      if (!mounted) return;
      setState(() => _facets = f);
    } catch (_) {
      // Facets are optional; the primary list remains usable.
    }
  }

  void _onFilterChanged(String key, String? value) {
    setState(() {
      final next = Map<String, String?>.from(_filters);
      if (value == null) {
        next.remove(key);
      } else {
        next[key] = value;
      }
      _filters = next;
    });
    _load();
  }

  Future<void> _refresh() async {
    await Future.wait([_load(), _loadFacets()]);
  }

  List<SettlementMethodAdminItem> get _filtered {
    final items = _items ?? const <SettlementMethodAdminItem>[];
    final kw = _keyword.trim();
    if (kw.isEmpty) return items;
    return items
        .where(
          (m) =>
              m.name.toLowerCase().contains(kw.toLowerCase()) ||
              (m.code ?? '').toLowerCase().contains(kw.toLowerCase()),
        )
        .toList();
  }

  // ---- 新增（可随带账期） ------------------------------------------------

  void _showCreate() {
    showMasterEditDialog(
      context: context,
      title: '新增结算方式', // TODO(l10n): 补 arb
      fields: _termsFields(),
      initialValues: const {
        'termsBase': 'RECEIPT_DATE',
        'dueRule': 'NET_DAYS',
        'defaultDueDays': '0',
        'monthsAhead': '0',
      },
      onSubmit: _doCreate,
    );
  }

  Future<bool> _doCreate(Map<String, dynamic> body) async {
    final name = (body['name'] as String?)?.trim() ?? '';
    if (name.isEmpty) {
      context.appError('结算方式名称不能为空');
      return false;
    }
    final ok = await context.guardRun(
      () async {
        await ref
            .read(referenceMethodRepositoryProvider)
            .createSettlement(name, terms: _termsOf(body));
      },
      success: '结算方式已创建', // TODO(l10n): 补 arb
      errorFallback: '创建失败，请稍后重试', // TODO(l10n): 补 arb
    );
    if (!ok) return false;
    await _refresh();
    return true;
  }

  // ---- 账期维护 ----------------------------------------------------------

  void _showEditTerms(SettlementMethodAdminItem m) {
    if (m.lockedBySystemRole) {
      context.appInfo('系统角色(${m.systemRole})的账期口径由迁移锁定：现金=收货当天到期，月结=月末+30天');
      return;
    }
    if (!_canEdit) {
      context.appInfo('${m.name}：${settlementTermsSummary(m)}');
      return;
    }
    showMasterEditDialog(
      context: context,
      title: '维护账期 · ${m.name}', // TODO(l10n): 补 arb
      fields: _termsFields(hintName: m.name),
      initialValues: {
        'name': m.name,
        'termsBase': m.termsBase,
        'dueRule': m.dueRule,
        'defaultDueDays': m.defaultDueDays.toString(),
        'fixedDayOfMonth': m.fixedDayOfMonth?.toString() ?? '',
        'monthsAhead': m.monthsAhead.toString(),
      },
      onSubmit: (body) => _doUpdateTerms(m, body),
    );
  }

  Future<bool> _doUpdateTerms(
    SettlementMethodAdminItem m,
    Map<String, dynamic> body,
  ) async {
    final ok = await context.guardRun(
      () async {
        await ref
            .read(referenceMethodRepositoryProvider)
            .updateSettlementTerms(m.id, body);
      },
      success: '账期已更新', // TODO(l10n): 补 arb
      errorFallback: '更新失败，请稍后重试', // TODO(l10n): 补 arb
    );
    if (!ok) return false;
    await _refresh();
    return true;
  }

  /// 组装提交用的账期策略体（新建套 terms 键；编辑直接平铺——两端各自与后端
  /// DTO 对齐）。固定日仅在 FIXED_DAY_OF_MONTH 时上送，其余规则强制 null。
  Map<String, dynamic> _termsOf(Map<String, dynamic> body) {
    final rule = body['dueRule'] as String?;
    final fixedDay = body['fixedDayOfMonth'];
    return {
      'name': body['name'],
      'termsBase': body['termsBase'],
      'dueRule': rule,
      'defaultDueDays': body['defaultDueDays'],
      'fixedDayOfMonth': rule == 'FIXED_DAY_OF_MONTH' ? fixedDay : null,
      'monthsAhead': body['monthsAhead'],
    };
  }

  // ---- 字段定义 ----------------------------------------------------------

  List<MasterFieldDef> _termsFields({String? hintName}) => [
    MasterFieldDef(
      key: 'name',
      label: '名称',
      required: true,
      group: '基础',
      hint: hintName,
    ),
    MasterFieldDef(
      key: 'termsBase',
      label: '到期基准',
      type: MasterFieldType.select,
      required: true,
      options: [
        for (final entry in settlementTermsBaseLabels.entries)
          MasterSelectOption(value: entry.key, label: entry.value),
      ],
      group: '账期',
      hint: '质检验收/对账确认/发票基准开放前，到期日保持未定并阻断月结冻结',
    ),
    MasterFieldDef(
      key: 'dueRule',
      label: '到期规则',
      type: MasterFieldType.select,
      required: true,
      options: [
        for (final entry in settlementDueRuleLabels.entries)
          MasterSelectOption(value: entry.key, label: entry.value),
      ],
      group: '账期',
    ),
    const MasterFieldDef(
      key: 'defaultDueDays',
      label: '默认天数',
      type: MasterFieldType.integer,
      required: true,
      group: '账期',
      hint: '0-3650；供应商正数结算天数优先于该默认值',
    ),
    const MasterFieldDef(
      key: 'fixedDayOfMonth',
      label: '固定日',
      type: MasterFieldType.integer,
      group: '账期',
      hint: '1-31；仅「固定日」规则填写，其它规则留空',
    ),
    const MasterFieldDef(
      key: 'monthsAhead',
      label: '跨月数',
      type: MasterFieldType.integer,
      required: true,
      group: '账期',
      hint: '0-120；月末/固定日规则跨几个月后到期',
    ),
  ];

  // ---- 导出 / 打印（V717 settlement_method:export） --------------------------

  /// 导出查询参数（与 _load 一致；字典不分页无 page/size）。
  Map<String, dynamic> get _exportQuery => masterFilterQueryParams(_filters);

  /// 打印预览数据：按当前筛选口径拉全量，列/格式化与页面表格一致。
  Future<UtenPrintTable> _printLoader() async {
    final items = await ref
        .read(referenceMethodRepositoryProvider)
        .settlementAdminList(filters: _filters);
    return UtenPrintTable(
      headers: [for (final c in _columns) c.label],
      rows: [
        for (final item in items)
          [for (final c in _columns) c.value(item) ?? ''],
      ],
    );
  }

  // ---- 列定义 -----------------------------------------------------------

  static final _columns = <MasterColumnDef<SettlementMethodAdminItem>>[
    MasterColumnDef(key: 'code', label: '编号', width: 110, value: (m) => m.code),
    MasterColumnDef(key: 'name', label: '名称', width: 170, value: (m) => m.name),
    MasterColumnDef(
      key: 'status',
      label: '状态',
      width: 90,
      value: (m) => m.status,
    ),
    MasterColumnDef(
      key: 'systemRole',
      label: '系统角色',
      width: 130,
      value: (m) =>
          m.lockedBySystemRole ? settlementSystemRoleLabel(m.systemRole) : null,
    ),
    MasterColumnDef(
      key: 'termsBase',
      label: '到期基准',
      width: 150,
      value: (m) => settlementTermsBaseLabel(m.termsBase),
    ),
    MasterColumnDef(
      key: 'dueRule',
      label: '到期规则',
      width: 140,
      value: (m) => settlementDueRuleLabel(m.dueRule),
    ),
    const MasterColumnDef(
      key: 'terms',
      label: '账期口径',
      width: 320,
      value: settlementTermsSummary,
    ),
  ];

  /// facet 桶加展示标签（下拉显示中文口径，筛选仍回传原始值）。
  Map<String, List<MasterFacetBucket>> get _labeledFacets {
    final source = _facets?.fields ?? const {};
    return {
      for (final entry in source.entries)
        entry.key: [
          for (final bucket in entry.value)
            MasterFacetBucket(
              value: bucket.value,
              count: bucket.count,
              label: switch (entry.key) {
                'systemRole' => settlementSystemRoleLabel(bucket.value),
                'termsBase' => settlementTermsBaseLabel(bucket.value),
                'dueRule' => settlementDueRuleLabel(bucket.value),
                _ => bucket.display,
              },
            ),
        ],
    };
  }

  // ---- 展示 --------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = _filtered;
    final total = _items?.length ?? 0;
    return Scaffold(
      appBar: UtenAppBar(
        title: '结算方式',
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.basicinfo),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新',
            onPressed: _refresh,
          ),
        ],
      ),
      body: SafeArea(
        child: UtenContentContainer(
          child: Padding(
            padding: const EdgeInsets.only(top: UtenSpacing.s8),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.only(
                    bottom: UtenSpacing.s8,
                    left: UtenSpacing.s4,
                    right: UtenSpacing.s4,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.event_note_rounded,
                        size: 18,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: UtenSpacing.s8),
                      Text(
                        '结算方式 ($total)',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: UtenSpacing.s12),
                      Expanded(
                        child: UtenSearchBar(
                          hint: '搜索结算方式(名称/编号)',
                          initialValue: _keyword,
                          onChanged: (kw) =>
                              setState(() => _keyword = kw), // 本地过滤，小字典
                        ),
                      ),
                      if (_canCreate) ...[
                        const SizedBox(width: UtenSpacing.s8),
                        UtenButton(
                          type: UtenButtonType.tonal,
                          icon: Icons.add_rounded,
                          onPressed: _showCreate,
                          child: const Text('添加结算方式'), // TODO(l10n): 补 arb
                        ),
                      ],
                    ],
                  ),
                ),
                Expanded(
                  child: MasterDataTableView<SettlementMethodAdminItem>(
                    columns: _columns,
                    items: items,
                    // 导出/打印（V717 settlement_method:export）：打印预览用本页列
                    // 渲染，导出列集服务端与表格对齐——「表格显示啥导出啥」。
                    toolbarActions: [
                      UtenPrintPreviewButton(
                        title: '结算方式', // TODO(l10n): 补 arb
                        subtitle: '全部行', // TODO(l10n): 补 arb
                        loader: _printLoader,
                        exportEndpoint:
                            '/master/reference-methods/settlement-admin/export',
                        exportPermission: Perm.settlementMethodExport,
                        exportReport: '',
                        exportQuery: _exportQuery,
                        exportFilename: '结算方式', // TODO(l10n): 补 arb
                        type: UtenButtonType.primary,
                        size: UtenButtonSize.large,
                      ),
                      UtenExportButton(
                        endpoint:
                            '/master/reference-methods/settlement-admin/export',
                        requiredPermission: Perm.settlementMethodExport,
                        report: '',
                        queryParams: _exportQuery,
                        filename: '结算方式', // TODO(l10n): 补 arb
                        label: '导出结算方式', // TODO(l10n): 补 arb
                        type: UtenButtonType.primary,
                        size: UtenButtonSize.large,
                      ),
                    ],
                    facets: _labeledFacets,
                    nullCounts: _facets?.nullCounts ?? const {},
                    filters: _filters,
                    onFilterChanged: _onFilterChanged,
                    // 行底色按状态：使用=浅蓝、禁用=浅红（同 color_page）。
                    rowColor: (m) => switch (m.status) {
                      '使用' => Colors.lightBlue.withValues(alpha: 0.13),
                      '禁用' => Colors.red.withValues(alpha: 0.10),
                      _ => null,
                    },
                    // 点行 = 维护账期/查看口径（系统角色锁定时仅提示）。
                    onRowTap: _showEditTerms,
                    isLoading: _loading && _items == null,
                    loadingMore: _loading && _items != null,
                    error: _error,
                    onRetry: _load,
                    emptyMessage: _keyword.trim().isEmpty
                        ? '暂无结算方式'
                        : '没有匹配的结算方式', // TODO(l10n): 补 arb
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
