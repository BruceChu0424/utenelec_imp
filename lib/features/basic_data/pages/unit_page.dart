// 基本单位资料管理页（基础资料 · 扁平主档，无分类树）。
//
// 与货品/模具/客户/供应商/颜色同级，扁平字典（编号/名称/状态 3 字段）：
// AppBar + 区段标题（含添加）+ 全屏主档表格。复用 MasterDataTableView +
// showMasterEditDialog + showMasterDetailSheet，CRUD/详情/并发防护流程与货品 _DetailPane 一致。
// 查看全员可见（路由不设守卫），编辑按 unit:edit 权限显隐。
// 文档：见 docs/03-页面/基础资料页.md。
import 'package:flutter/material.dart';
import '../../../shared/drafts/form_draft_dialog_resume.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/buttons/uten_export_button.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/print/uten_print_preview.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/latest_request_guard.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/action_feedback.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/paged_result.dart';
import '../models/master_facet.dart';
import '../models/unit_node.dart';
import '../repositories/unit_repository.dart';
import '../repositories/master_status_repository.dart';
import '../widgets/master_data_table_view.dart';
import '../widgets/master_detail_sheet.dart';
import '../widgets/master_edit_dialog.dart';

/// 编辑表单里「计量维度」字段 key(与后端 UnitSaveRequest 同名)。
const kUnitDimensionField = 'measurementDimension';

/// 编辑表单里「等于哪种重量单位」字段 key(与后端 UnitSaveRequest 同名)。
const kUnitMassUnitField = 'massUnitCode';

class UnitPage extends ConsumerStatefulWidget {
  const UnitPage({super.key});

  @override
  ConsumerState<UnitPage> createState() => _UnitPageState();
}

class _UnitPageState extends ConsumerState<UnitPage> {
  PagedResult<UnitListItem>? _page;
  int _pageNum = 1;
  bool _loading = false;
  String? _error;
  final _loadRequests = LatestRequestGuard();

  Map<String, String?> _filters = {};
  String _keyword = '';
  UnitFacets? _facets;

  /// 详情弹窗加载中（防并发）。与 [_loading]（分页列表加载）是两回事。
  bool _detailLoading = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadUnits(1);
      _loadFacets();
    });
  }

  bool get _canCreate =>
      ref.read(currentPermissionsProvider).contains(Perm.unitCreate);

  bool get _canEdit =>
      ref.read(currentPermissionsProvider).contains(Perm.unitEdit);

  bool get _canDelete =>
      ref.read(currentPermissionsProvider).contains(Perm.unitDelete);

  bool get _canStatus =>
      ref.read(currentPermissionsProvider).contains(Perm.unitStatus);

  // ---- 分页 -------------------------------------------------------------

  Future<void> _loadUnits(int page) async {
    final generation = _loadRequests.begin();
    setState(() {
      _loading = true;
      _error = null;
      _pageNum = page;
    });
    try {
      final result = await ref
          .read(unitRepositoryProvider)
          .list(
            page: page,
            keyword: _keyword.trim().isEmpty ? null : _keyword,
            filters: _filters,
          );
      if (!mounted || !_loadRequests.isCurrent(generation)) return;
      setState(() {
        _page = result;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted || !_loadRequests.isCurrent(generation)) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || !_loadRequests.isCurrent(generation)) return;
      setState(() {
        _error = '加载单位列表失败'; // TODO(l10n): 补 arb
        _loading = false;
      });
    }
  }

  /// 拉字段 facet（筛选栏下拉选项）。失败静默降级为空下拉，不阻塞列表。
  Future<void> _loadFacets() async {
    try {
      final f = await ref.read(unitRepositoryProvider).facets();
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
    _loadUnits(1);
  }

  /// 计量维度列固定枚举桶：六个维度全量可选（服务端 facet 只聚合有数据的维度，
  /// 固定枚举保证下拉文案齐全），计数用服务端命中数、无数据时 0（菜单只在 >0 时显数）。
  List<MasterFacetBucket> _dimensionBuckets() {
    final counts = <String, int>{
      for (final b
          in _facets?.fields['dimension'] ?? const <MasterFacetBucket>[])
        b.value: b.count,
    };
    return [
      for (final e in kUnitMeasurementDimensions.entries)
        MasterFacetBucket(
          value: e.key,
          label: e.value,
          count: counts[e.key] ?? 0,
        ),
    ];
  }

  /// 表头筛选桶：dimension 列换成固定枚举桶（其余列用服务端 facet 原桶）。
  Map<String, List<MasterFacetBucket>> get _columnFacets => {
    ...(_facets?.fields ?? const <String, List<MasterFacetBucket>>{}),
    'dimension': _dimensionBuckets(),
  };

  void _onKeywordChanged(String kw) {
    setState(() => _keyword = kw);
    _loadUnits(1);
  }

  // ---- 新建/编辑/删除 ---------------------------------------------------

  /// 计量维度选项(value='' 表示未设置/清除；提交时服务端落 unit_measurement_profiles)。
  static const _dimensionOptions = [
    MasterSelectOption(value: '', label: '未设置'),
    MasterSelectOption(value: 'COUNT', label: '数量'),
    MasterSelectOption(value: 'MASS', label: '重量'),
    MasterSelectOption(value: 'LENGTH', label: '长度'),
    MasterSelectOption(value: 'AREA', label: '面积'),
    MasterSelectOption(value: 'VOLUME', label: '体积'),
    MasterSelectOption(value: 'OTHER', label: '其他'),
  ];

  static const _unitFields = [
    MasterFieldDef(key: 'name', label: '单位名称', required: true, group: '基础'),
    MasterFieldDef(key: 'code', label: '单位编号', group: '基础', hint: '留空自动生成'),
    MasterFieldDef(
      key: 'status',
      label: '状态',
      type: MasterFieldType.select,
      options: kMasterStatusOptions,
      required: true,
      group: '基础',
    ),
    MasterFieldDef(
      key: kUnitDimensionField,
      label: '计量维度',
      type: MasterFieldType.select,
      options: _dimensionOptions,
      group: '基础',
      hint: '数量/重量等',
    ),
    // 只在计量维度选「重量」时出现(V743/ADR-135)；可不选。
    MasterFieldDef(
      key: kUnitMassUnitField,
      label: '等于哪种重量单位',
      type: MasterFieldType.custom,
      group: '基础',
      customBuilder: _massUnitField,
    ),
  ];

  static Widget _massUnitField(MasterFieldContext field) =>
      UnitMassUnitCodeField(field: field);

  /// 提交前收口：计量维度不是「重量」时不带重量单位(字段隐藏后控制器里可能还留着旧选择)。
  static Map<String, dynamic> _withMassUnitScope(Map<String, dynamic> body) {
    final next = Map<String, dynamic>.of(body);
    if (next[kUnitDimensionField] != 'MASS') next[kUnitMassUnitField] = null;
    return next;
  }

  Future<void> _showCreate() async {
    await showMasterEditDialog(
      context: context,
      draftSpec: FormDraftCatalog.unit.spec(title: '新增单位'),
      title: '新增单位', // TODO(l10n): 补 arb
      fields: _unitFields,
      initialValues: const {
        'status': '使用',
        kUnitDimensionField: '',
        kUnitMassUnitField: '',
      },
      readOnlyKeys: _canStatus ? null : const {'status'},
      onSubmit: _doCreate,
    );
  }

  Future<bool> _doCreate(Map<String, dynamic> body) async {
    // Preserve the actual API failure for the shared draft submission fence.
    await ref.read(unitRepositoryProvider).create(_withMassUnitScope(body));
    if (mounted) {
      context.appSuccess('单位已创建');
      await _loadUnits(_pageNum);
    }
    return true;
  }

  void _showEdit(UnitDetail d) {
    showMasterEditDialog(
      context: context,
      title: '编辑单位', // TODO(l10n): 补 arb
      fields: _unitFields,
      initialValues: {
        'name': d.name ?? '',
        'code': d.code ?? '',
        'status': d.status ?? '',
        kUnitDimensionField: d.measurementDimension ?? '',
        kUnitMassUnitField: d.massUnitCode ?? '',
      },
      readOnlyKeys: _canStatus ? null : const {'status'},
      onSubmit: (body) => _doUpdate(d.id, body),
    );
  }

  Future<bool> _doUpdate(String id, Map<String, dynamic> body) async {
    final ok = await context.guardRun(
      () async {
        await ref
            .read(unitRepositoryProvider)
            .update(id, _withMassUnitScope(body));
      },
      success: '单位已更新', // TODO(l10n): 补 arb
      errorFallback: '更新失败，请稍后重试', // TODO(l10n): 补 arb
    );
    if (!ok) return false;
    await _loadUnits(_pageNum);
    return true;
  }

  Future<void> _toggleDetailStatus(UnitDetail d) async {
    final next = d.status == '使用' ? '禁用' : '使用';
    final ok = await context.guardRun(
      () => ref
          .read(masterStatusRepositoryProvider)
          .change(resourcePath: ApiEndpoints.unit(d.id), status: next),
      success: next == '禁用' ? '已停用' : '已启用',
      errorFallback: '状态变更失败，请稍后重试',
    );
    if (ok && mounted) await _loadUnits(_pageNum);
  }

  Future<void> _delete(UnitDetail d) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除单位'), // TODO(l10n): 补 arb
        content: Text(
          '确定删除「${d.name?.isNotEmpty == true ? d.name! : (d.code ?? '该单位')}」吗？', // TODO(l10n): 补 arb
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'), // TODO(l10n): 补 arb
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: UtenColors.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'), // TODO(l10n): 补 arb
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (!mounted) return;
    final deleted = await context.guardRun(
      () async {
        await ref.read(unitRepositoryProvider).delete(d.id);
      },
      success: '单位已删除', // TODO(l10n): 补 arb
      errorFallback: '删除失败，请稍后重试', // TODO(l10n): 补 arb
    );
    if (!deleted || !mounted) return;
    await _loadUnits(_pageNum);
    if (mounted && _page != null && _page!.items.isEmpty && _page!.page > 1) {
      await _loadUnits(_page!.page - 1);
    }
  }

  /// 点行：拉详情弹框。独立 [_detailLoading] 防并发 + rootNavigator 防 go_router 误 pop。
  Future<void> _showDetail(String id) async {
    if (_detailLoading) return;
    _detailLoading = true;
    final nav = Navigator.of(context, rootNavigator: true);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const Center(child: CircularProgressIndicator()),
    );
    UnitDetail? d;
    try {
      d = await ref.read(unitRepositoryProvider).detail(id);
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('加载单位详情失败'); // TODO(l10n): 补 arb
    }
    if (!mounted) {
      nav.pop();
      return;
    }
    nav.pop(); // 关 loading
    if (d == null) {
      _detailLoading = false;
      return;
    }
    final detail = d;
    await showMasterDetailSheet(
      context: context,
      title: detail.name?.isNotEmpty == true
          ? detail.name!
          : (detail.code ?? '单位详情'),
      rows: _detailRows(detail),
      canEdit: _canEdit,
      canDelete: _canDelete,
      onToggleStatus: _canStatus ? () => _toggleDetailStatus(detail) : null,
      statusActionLabel: detail.status == '使用' ? '停用' : '启用',
      onEdit: () => _showEdit(detail),
      onDelete: () => _delete(detail),
    );
    if (mounted) _detailLoading = false;
  }

  List<MasterDetailRow> _detailRows(UnitDetail u) => [
    MasterDetailRow('编号', u.code), // TODO(l10n): 补 arb
    MasterDetailRow('单位名称', u.name), // TODO(l10n): 补 arb
    MasterDetailRow('状态', u.status), // TODO(l10n): 补 arb
    MasterDetailRow('计量维度', unitDimensionLabel(u.measurementDimension)),
    if (u.measurementDimension == 'MASS')
      MasterDetailRow(
        '等于哪种重量单位',
        unitMassUnitLabel(u.measurementDimension, u.massUnitCode),
      ),
    MasterDetailRow('旧系统 ID', u.legacyId?.toString()), // TODO(l10n): 补 arb
  ];

  // ---- 列定义 -----------------------------------------------------------

  /// 导出查询参数（与 _loadUnits 一致，不含 page/size；V717）。
  Map<String, dynamic> get _exportQuery => <String, dynamic>{
    if (_keyword.trim().isNotEmpty) 'keyword': _keyword.trim(),
    ...masterFilterQueryParams(_filters),
  };

  /// 打印预览数据：按当前筛选口径拉全量（上限 2000 行），列/格式化与页面表格一致。
  Future<UtenPrintTable> _printLoader() async {
    final result = await ref
        .read(unitRepositoryProvider)
        .list(
          size: 2000,
          keyword: _keyword.trim().isEmpty ? null : _keyword,
          filters: _filters,
        );
    return UtenPrintTable(
      columnKeys: [for (final c in _columns) c.key],
      rowIds: [for (final item in result.items) item.id],
      headers: [for (final c in _columns) c.label],
      rows: [
        for (final item in result.items)
          [for (final c in _columns) c.value(item) ?? ''],
      ],
    );
  }

  static final _columns = <MasterColumnDef<UnitListItem>>[
    MasterColumnDef(key: 'code', label: '编号', width: 120, value: (u) => u.code),
    MasterColumnDef(
      key: 'name',
      label: '单位名称',
      width: 220,
      value: (u) => u.name,
    ),
    MasterColumnDef(
      key: 'status',
      label: '状态',
      width: 100,
      value: (u) => u.status,
    ),
    MasterColumnDef(
      key: 'dimension',
      label: '计量维度',
      width: 110,
      value: (u) => unitDimensionLabel(u.measurementDimension),
    ),
    // 与服务端导出「重量单位」列同口径：非重量维度留空，重量维度没选写「未指定」。
    MasterColumnDef(
      key: 'massUnit',
      label: '重量单位',
      width: 100,
      value: (u) => unitMassUnitLabel(u.measurementDimension, u.massUnitCode),
    ),
  ];

  Future<void> _refresh() async {
    await Future.wait([_loadUnits(1), _loadFacets()]);
  }

  @override
  Widget build(BuildContext context) => FormDraftDialogResume(
    descriptor: FormDraftCatalog.unit,
    onResume: (_) => _showCreate(),
    child: _buildDraftHost(context),
  );

  Widget _buildDraftHost(BuildContext context) {
    ref.watch(currentPermissionsProvider);
    final theme = Theme.of(context);
    final total = _page?.total ?? 0;
    return Scaffold(
      appBar: UtenAppBar(
        title: '基本单位', // TODO(l10n): 补 arb
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.basicinfo),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新', // TODO(l10n): 补 arb
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
                        Icons.straighten_outlined,
                        size: 18,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: UtenSpacing.s8),
                      Text(
                        '单位 ($total)', // TODO(l10n): 补 arb
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: UtenSpacing.s12),
                      Expanded(
                        child: UtenSearchBar(
                          hint: '搜索单位(名称/编号)', // TODO(l10n): 补 arb
                          initialValue: _keyword,
                          onChanged: _onKeywordChanged,
                        ),
                      ),
                      if (_canCreate) ...[
                        const SizedBox(width: UtenSpacing.s8),
                        UtenButton(
                          type: UtenButtonType.tonal,
                          icon: Icons.add_rounded,
                          onPressed: _showCreate,
                          child: const Text('添加单位'), // TODO(l10n): 补 arb
                        ),
                      ],
                    ],
                  ),
                ),
                Expanded(
                  child: MasterDataTableView<UnitListItem>(
                    columnEditingEnabled: _canEdit,
                    tableKey:
                        'features.basic_data.pages.unit_page.UnitPageState._buildDraftHost.1',
                    columns: _columns,
                    items: _page?.items ?? const [],
                    // 导出/打印（V717 unit:export）：打印预览用本页列渲染，
                    // 导出列集服务端与表格对齐——「表格显示啥导出啥」。
                    toolbarActions: [
                      UtenPrintPreviewButton(
                        title: '单位资料', // TODO(l10n): 补 arb
                        subtitle: '最多前 2000 行', // TODO(l10n): 补 arb
                        loader: _printLoader,
                        exportEndpoint: '/master/units/export',
                        exportPermission: Perm.unitExport,
                        exportReport: '',
                        exportQuery: _exportQuery,
                        exportFilename: '单位资料', // TODO(l10n): 补 arb
                        type: UtenButtonType.primary,
                        size: UtenButtonSize.large,
                      ),
                      UtenExportButton(
                        endpoint: '/master/units/export',
                        requiredPermission: Perm.unitExport,
                        report: '',
                        queryParams: _exportQuery,
                        filename: '单位资料', // TODO(l10n): 补 arb
                        label: '导出单位', // TODO(l10n): 补 arb
                        type: UtenButtonType.primary,
                        size: UtenButtonSize.large,
                      ),
                    ],
                    facets: _columnFacets,
                    nullCounts: _facets?.nullCounts ?? const {},
                    filters: _filters,
                    onFilterChanged: _onFilterChanged,
                    onRowTap: (u) => _showDetail(u.id),
                    isLoading: _loading && _page == null,
                    loadingMore: _loading && _page != null,
                    error: _error,
                    onRetry: () => _loadUnits(_pageNum),
                    emptyMessage: '暂无单位', // TODO(l10n): 补 arb
                    currentPage: _page?.page ?? 1,
                    totalPages: _page?.totalPages ?? 1,
                    paginationScope: _keyword,
                    onPageChange: (p) => _loadUnits(p),
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

/// 「等于哪种重量单位」下拉(V743/ADR-135)：只在同一张表单的计量维度选了「重量」时出现，
/// 可不选(重量单位没指定就不做折算)。选中值存在表单控制器的自定义值里(草稿随之保存)，
/// 计量维度改离「重量」时隐藏，提交前由页面把它清空。
class UnitMassUnitCodeField extends StatelessWidget {
  const UnitMassUnitCodeField({super.key, required this.field});

  final MasterFieldContext field;

  @override
  Widget build(BuildContext context) {
    final form = context.findAncestorStateOfType<MasterEditFormState>();
    if (form == null) return const SizedBox.shrink();
    final controller = form.controller;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (controller.selectValues[kUnitDimensionField] != 'MASS') {
          return const SizedBox.shrink();
        }
        final current = controller.customValues[kUnitMassUnitField];
        return UtenDropdownField(
          label: '等于哪种重量单位',
          value: current is String && current.isNotEmpty ? current : null,
          hintText: '可不选',
          info: '选了以后, 用这个单位做基本单位的货品按数量直接算出重量, 仓库不用另外称重',
          items: [
            for (final e in kUnitMassUnitCodes.entries)
              UtenDropdownItem(value: e.key, label: e.value),
          ],
          onChanged: field.onChanged,
        );
      },
    );
  }
}
