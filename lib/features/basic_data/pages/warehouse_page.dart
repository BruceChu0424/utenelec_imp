// 仓库资料管理页（基础资料 · 扁平主档，无分类树）。
//
// 复刻 color_page：编号/名称/位置/核算/状态。accountable(bool) 用 select 使用/不使用
// （提交 'true'/'false' 字符串，Jackson 自动转 Boolean）。查看全员可见，编辑按 warehouse:edit。
//
// 仓库负责人(仓管员, ADR-115, 2026-09-24)：列表「负责人」列 + 详情「设置负责人」。登记后该仓的
// 仓库类通知只发给负责人(没登记的仓照旧发给整个仓库部门)，仓库任务中心「我的仓库」按它筛选；
// 登记在主仓上 = 负责它下面全部子仓。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/inputs/uten_employee_multi_picker.dart';
import '../../../components/inputs/uten_employee_picker.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/latest_request_guard.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/action_feedback.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../models/warehouse_node.dart';
import '../repositories/warehouse_keeper_repository.dart';
import '../repositories/warehouse_repository.dart';
import '../repositories/master_status_repository.dart';
import '../widgets/master_data_table_view.dart';
import '../widgets/master_detail_sheet.dart';
import '../widgets/master_edit_dialog.dart';

class WarehousePage extends ConsumerStatefulWidget {
  const WarehousePage({super.key});

  @override
  ConsumerState<WarehousePage> createState() => _WarehousePageState();
}

class _WarehousePageState extends ConsumerState<WarehousePage> {
  PagedResult<WarehouseListItem>? _page;
  int _pageNum = 1;
  bool _loading = false;
  String? _error;
  final _loadRequests = LatestRequestGuard();

  Map<String, String?> _filters = {};
  String _keyword = '';
  WarehouseFacets? _facets;
  bool _detailLoading = false;

  /// 仓库 id → 负责人姓名(ADR-115)；加载失败时列显示「—」不挡列表。
  Map<String, List<String>> _keeperNames = const {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadWarehouses(1);
      _loadFacets();
      _loadKeepers();
    });
  }

  bool get _canCreate =>
      ref.read(currentPermissionsProvider).contains(Perm.warehouseCreate);

  bool get _canEdit =>
      ref.read(currentPermissionsProvider).contains(Perm.warehouseEdit);

  bool get _canDelete =>
      ref.read(currentPermissionsProvider).contains(Perm.warehouseDelete);

  bool get _canStatus =>
      ref.read(currentPermissionsProvider).contains(Perm.warehouseStatus);

  Future<void> _loadWarehouses(int page) async {
    final generation = _loadRequests.begin();
    setState(() {
      _loading = true;
      _error = null;
      _pageNum = page;
    });
    try {
      final result = await ref
          .read(warehouseRepositoryProvider)
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
        _error = '加载仓库列表失败';
        _loading = false;
      });
    }
  }

  Future<void> _loadFacets() async {
    try {
      final f = await ref.read(warehouseRepositoryProvider).facets();
      if (!mounted) return;
      setState(() => _facets = f);
    } catch (_) {
      // Facets are optional; the primary list remains usable.
    }
  }

  Future<void> _loadKeepers() async {
    try {
      final assignments = await ref
          .read(warehouseKeeperRepositoryProvider)
          .assignments();
      if (!mounted) return;
      final byWarehouse = <String, List<String>>{};
      for (final a in assignments) {
        byWarehouse.putIfAbsent(a.warehouseId, () => []).add(a.name);
      }
      setState(() => _keeperNames = byWarehouse);
    } catch (_) {
      // 负责人列是附加信息；失败时列显示「—」，主列表照常可用。
    }
  }

  String _keeperLabel(String warehouseId) {
    final names = _keeperNames[warehouseId];
    return names == null || names.isEmpty ? '—' : names.join('、');
  }

  /// 设置负责人：整组替换；保存后刷新负责人列。
  Future<void> _editKeepers(WarehouseDetail d) async {
    final repo = ref.read(warehouseKeeperRepositoryProvider);
    List<WarehouseKeeper> current;
    try {
      current = await repo.keepers(d.id);
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
      return;
    } catch (_) {
      if (mounted) context.appError('加载仓库负责人失败');
      return;
    }
    if (!mounted) return;
    final saved = await showDialog<List<WarehouseKeeper>>(
      context: context,
      builder: (_) => _WarehouseKeepersDialog(
        warehouseId: d.id,
        warehouseName: d.name?.isNotEmpty == true ? d.name! : (d.code ?? '仓库'),
        initial: current,
        repository: repo,
      ),
    );
    if (saved == null || !mounted) return;
    final warnings = [
      for (final keeper in saved)
        if (keeper.noticeWarning case final warning?) '${keeper.name}：$warning',
    ];
    if (warnings.isEmpty) {
      context.appSuccess(saved.isEmpty ? '已清空负责人，该仓通知发给整个仓库部门' : '负责人已保存');
    } else {
      context.appWarning('负责人已保存。${warnings.join('；')}', force: true);
    }
    await _loadKeepers();
  }

  // 表头筛选：列 key → 服务端 query 参数名（上级仓库列在服务端是 parentId；核算列同名）。
  static const _columnToParam = {'parent': 'parentId'};

  void _onFilterChanged(String key, String? value) {
    final paramKey = _columnToParam[key] ?? key;
    setState(() {
      final next = Map<String, String?>.from(_filters);
      if (value == null) {
        next.remove(paramKey); // 选"所有"= 不筛
      } else {
        next[paramKey] = value; // 具体值 或 kMasterFilterNullValue（空值）
      }
      _filters = next;
    });
    _loadWarehouses(1);
  }

  /// 表头筛选回显：把 _filters（服务端参数名）映射回列 key 供表格选中态索引。
  Map<String, String?> get _columnFilters => {
    for (final e in _filters.entries)
      (e.key == 'parentId' ? 'parent' : e.key): e.value,
  };

  void _onKeywordChanged(String kw) {
    setState(() => _keyword = kw);
    _loadWarehouses(1);
  }

  List<MasterFieldDef> _fields({String? excludeId}) => [
    const MasterFieldDef(
      key: 'name',
      label: '仓库名称',
      required: true,
      group: '基础',
    ),
    const MasterFieldDef(
      key: 'code',
      label: '仓库编号',
      group: '基础',
      readOnly: true,
      hint: '保存后自动生成',
    ),
    const MasterFieldDef(
      key: 'location',
      label: '仓库位置',
      group: '基础',
      hint: '如 总仓库/轨道仓',
    ),
    const MasterFieldDef(
      key: 'accountable',
      label: '是否核算',
      group: '基础',
      type: MasterFieldType.select,
      options: [
        MasterSelectOption(value: 'true', label: '使用(参与核算)'),
        MasterSelectOption(value: 'false', label: '不使用(不核算)'),
      ],
    ),
    MasterFieldDef(
      key: 'workshopDepartmentId',
      label: '所属车间',
      group: '基础',
      type: MasterFieldType.custom,
      customBuilder: (field) => _WarehouseWorkshopField(
        initialValue: field.initialValue,
        onChanged: field.onChanged,
      ),
    ),
    // V584 车间内部直送：线边仓=车间自己的料架。直送产出先进它再投给同车间上层工单，
    // 仓库部门不参与；置「是」要求已选所属车间、参与核算、且是叶子仓。
    const MasterFieldDef(
      key: 'isLineSide',
      label: '线边仓',
      group: '基础',
      type: MasterFieldType.select,
      hint: '车间内部直送用；须有所属车间且参与核算',
      options: [
        MasterSelectOption(value: 'false', label: '否'),
        MasterSelectOption(value: 'true', label: '是(车间料架)'),
      ],
    ),
    // V476 主/子层级：上级仓库。不选=独立顶层；父仓仅作查询聚合与下拉分组。
    MasterFieldDef(
      key: 'parentId',
      label: '上级仓库',
      group: '基础',
      type: MasterFieldType.custom,
      hint: '不选=独立顶层仓',
      customBuilder: (field) => _WarehouseParentField(
        initialValue: field.initialValue,
        onChanged: field.onChanged,
        excludeId: excludeId,
      ),
    ),
    const MasterFieldDef(
      key: 'status',
      label: '状态',
      type: MasterFieldType.select,
      options: kMasterStatusOptions,
      required: true,
      group: '基础',
    ),
  ];

  void _showCreate() {
    showMasterEditDialog(
      context: context,
      title: '新增仓库',
      fields: _fields(),
      initialValues: const {
        'accountable': 'true',
        'isLineSide': 'false',
        'status': '使用',
      },
      readOnlyKeys: _canStatus ? null : const {'status'},
      onSubmit: _doCreate,
    );
  }

  Future<bool> _doCreate(Map<String, dynamic> body) async {
    final ok = await context.guardRun(
      () async {
        await ref.read(warehouseRepositoryProvider).create(body);
      },
      success: '仓库已创建', // TODO(l10n): 补 arb
      errorFallback: '创建失败，请稍后重试', // TODO(l10n): 补 arb
    );
    if (!ok) return false;
    await _loadWarehouses(_pageNum);
    return true;
  }

  void _showEdit(WarehouseDetail d) {
    showMasterEditDialog(
      context: context,
      title: '编辑仓库',
      fields: _fields(excludeId: d.id),
      initialValues: {
        'name': d.name ?? '',
        'code': d.code ?? '',
        'location': d.location ?? '',
        'accountable': d.accountable ? 'true' : 'false',
        'workshopDepartmentId': d.workshopDepartmentId ?? '',
        'isLineSide': d.lineSide ? 'true' : 'false',
        'parentId': d.parentId ?? '',
        'status': d.status ?? '',
      },
      readOnlyKeys: _canStatus ? null : const {'status'},
      onSubmit: (body) => _doUpdate(d.id, body),
    );
  }

  Future<bool> _doUpdate(String id, Map<String, dynamic> body) async {
    final ok = await context.guardRun(
      () async {
        await ref.read(warehouseRepositoryProvider).update(id, body);
      },
      success: '仓库已更新', // TODO(l10n): 补 arb
      errorFallback: '更新失败，请稍后重试', // TODO(l10n): 补 arb
    );
    if (!ok) return false;
    await _loadWarehouses(_pageNum);
    return true;
  }

  Future<void> _toggleDetailStatus(WarehouseDetail d) async {
    final next = d.status == '使用' ? '禁用' : '使用';
    final ok = await context.guardRun(
      () => ref
          .read(masterStatusRepositoryProvider)
          .change(resourcePath: ApiEndpoints.warehouse(d.id), status: next),
      success: next == '禁用' ? '已停用' : '已启用',
      errorFallback: '状态变更失败，请稍后重试',
    );
    if (ok && mounted) await _loadWarehouses(_pageNum);
  }

  Future<void> _delete(WarehouseDetail d) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除仓库'),
        content: Text(
          '确定删除「${d.name?.isNotEmpty == true ? d.name! : (d.code ?? '该仓库')}」吗？',
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (!mounted) return;
    final deleted = await context.guardRun(
      () async {
        await ref.read(warehouseRepositoryProvider).delete(d.id);
      },
      success: '仓库已删除', // TODO(l10n): 补 arb
      errorFallback: '删除失败，请稍后重试', // TODO(l10n): 补 arb
    );
    if (!deleted || !mounted) return;
    await _loadWarehouses(_pageNum);
    if (mounted && _page != null && _page!.items.isEmpty && _page!.page > 1) {
      await _loadWarehouses(_page!.page - 1);
    }
  }

  Future<void> _showDetail(String id) async {
    if (_detailLoading) return;
    _detailLoading = true;
    final nav = Navigator.of(context, rootNavigator: true);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const Center(child: CircularProgressIndicator()),
    );
    WarehouseDetail? d;
    try {
      d = await ref.read(warehouseRepositoryProvider).detail(id);
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('加载仓库详情失败');
    }
    if (!mounted) {
      nav.pop();
      return;
    }
    nav.pop();
    if (d == null) {
      _detailLoading = false;
      return;
    }
    final detail = d;
    await showMasterDetailSheet(
      context: context,
      title: detail.name?.isNotEmpty == true
          ? detail.name!
          : (detail.code ?? '仓库详情'),
      rows: _detailRows(detail),
      canEdit: _canEdit,
      canDelete: _canDelete,
      onToggleStatus: _canStatus ? () => _toggleDetailStatus(detail) : null,
      statusActionLabel: detail.status == '使用' ? '停用' : '启用',
      onEdit: () => _showEdit(detail),
      onDelete: () => _delete(detail),
      extraActions: [
        if (_canEdit)
          MasterDetailAction(
            label: '设置负责人',
            icon: Icons.manage_accounts_outlined,
            onPressed: () => _editKeepers(detail),
          ),
      ],
    );
    if (mounted) _detailLoading = false;
  }

  List<MasterDetailRow> _detailRows(WarehouseDetail w) => [
    MasterDetailRow('编号', w.code),
    MasterDetailRow('仓库名称', w.name),
    MasterDetailRow('位置', w.location),
    MasterDetailRow('是否核算', w.accountable ? '是' : '否'),
    MasterDetailRow('线边仓', w.lineSide ? '是(车间内部直送用)' : '否'),
    MasterDetailRow('备注', w.remark),
    MasterDetailRow('状态', w.status),
    MasterDetailRow('所属车间', w.workshopDepartmentName),
    MasterDetailRow('仓库负责人', _keeperLabel(w.id)),
    MasterDetailRow('旧操作员ID', w.legacyOperatorId?.toString()),
    MasterDetailRow('旧系统 ID', w.legacyId?.toString()),
  ];

  List<MasterColumnDef<WarehouseListItem>> get _columns => [
    MasterColumnDef(key: 'code', label: '编号', width: 120, value: (w) => w.code),
    MasterColumnDef(
      key: 'name',
      label: '仓库名称',
      width: 200,
      value: (w) => w.name,
    ),
    MasterColumnDef(
      key: 'parent',
      // V476 主/子层级：子仓行显示主仓名，主仓/独立仓显示「—」。
      label: '上级仓库',
      width: 150,
      value: (w) => w.parentName ?? '—',
    ),
    MasterColumnDef(
      key: 'location',
      label: '位置',
      width: 160,
      value: (w) => w.location,
    ),
    MasterColumnDef(
      key: 'accountable',
      label: '核算',
      width: 90,
      value: (w) => w.accountable ? '是' : '否',
    ),
    // ADR-115：登记后该仓的仓库类通知只发给负责人；主仓负责人管全部子仓。
    MasterColumnDef(
      key: 'keepers',
      label: '负责人',
      width: 180,
      value: (w) => _keeperLabel(w.id),
    ),
    MasterColumnDef(
      key: 'status',
      label: '状态',
      width: 100,
      value: (w) => w.status,
    ),
  ];

  Future<void> _refresh() async {
    await Future.wait([_loadWarehouses(1), _loadFacets(), _loadKeepers()]);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = _page?.total ?? 0;
    return Scaffold(
      appBar: UtenAppBar(
        title: '仓库资料',
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
                        Icons.warehouse_outlined,
                        size: 18,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: UtenSpacing.s8),
                      Text(
                        '仓库 ($total)',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: UtenSpacing.s12),
                      Expanded(
                        child: UtenSearchBar(
                          hint: '搜索仓库(名称/编号)',
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
                          child: const Text('添加仓库'),
                        ),
                      ],
                    ],
                  ),
                ),
                Expanded(
                  child: MasterDataTableView<WarehouseListItem>(
                    columns: _columns,
                    items: _page?.items ?? const [],
                    facets: _facets?.fields ?? const {},
                    nullCounts: _facets?.nullCounts ?? const {},
                    filters: _columnFilters,
                    onFilterChanged: _onFilterChanged,
                    onRowTap: (w) => _showDetail(w.id),
                    isLoading: _loading && _page == null,
                    loadingMore: _loading && _page != null,
                    error: _error,
                    onRetry: () => _loadWarehouses(_pageNum),
                    emptyMessage: '暂无仓库',
                    currentPage: _page?.page ?? 1,
                    totalPages: _page?.totalPages ?? 1,
                    onPageChange: (p) => _loadWarehouses(p),
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

class _WarehouseParentField extends ConsumerStatefulWidget {
  const _WarehouseParentField({
    required this.initialValue,
    required this.onChanged,
    this.excludeId,
  });

  final String? initialValue;
  final ValueChanged<dynamic> onChanged;

  /// 编辑时排除自己（自己不能当自己的上级；服务端另防环）。
  final String? excludeId;

  @override
  ConsumerState<_WarehouseParentField> createState() =>
      _WarehouseParentFieldState();
}

class _WarehouseParentFieldState extends ConsumerState<_WarehouseParentField> {
  String? _value;

  @override
  void initState() {
    super.initState();
    _value = widget.initialValue?.isEmpty == true ? null : widget.initialValue;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(masterNameServiceProvider).ensureLoaded();
    });
  }

  @override
  void didUpdateWidget(_WarehouseParentField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialValue != widget.initialValue) {
      _value = widget.initialValue?.isEmpty == true
          ? null
          : widget.initialValue;
    }
  }

  @override
  Widget build(BuildContext context) {
    final names = ref.watch(masterNameServiceProvider);
    return UtenDropdownField(
      label: '上级仓库',
      hintText: '不选=独立顶层仓',
      value: _value,
      items: [
        for (final e in names.warehouseHierarchy)
          if (e.id != widget.excludeId)
            UtenDropdownItem(
              value: e.id,
              label: e.name,
              enabled: e.id == _value || e.parentId == null,
              indent: e.parentId == null ? 0 : 16,
            ),
      ],
      onChanged: (value) {
        setState(() => _value = value);
        widget.onChanged(value);
      },
    );
  }
}

class _WarehouseWorkshopField extends ConsumerStatefulWidget {
  const _WarehouseWorkshopField({
    required this.initialValue,
    required this.onChanged,
  });

  final String? initialValue;
  final ValueChanged<dynamic> onChanged;

  @override
  ConsumerState<_WarehouseWorkshopField> createState() =>
      _WarehouseWorkshopFieldState();
}

class _WarehouseWorkshopFieldState
    extends ConsumerState<_WarehouseWorkshopField> {
  String? _value;

  @override
  void initState() {
    super.initState();
    _value = widget.initialValue?.isEmpty == true ? null : widget.initialValue;
  }

  @override
  void didUpdateWidget(_WarehouseWorkshopField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialValue != widget.initialValue) {
      _value = widget.initialValue?.isEmpty == true
          ? null
          : widget.initialValue;
    }
  }

  @override
  Widget build(BuildContext context) {
    final options = ref.watch(warehouseWorkshopOptionsProvider);
    return options.when(
      loading: () => const LinearProgressIndicator(),
      error: (_, _) => const Text('车间列表加载失败'),
      data: (rows) => UtenDropdownField(
        label: '所属车间',
        hintText: '请选择生产部直属车间',
        value: _value,
        items: [
          for (final row in rows)
            UtenDropdownItem(value: row.id, label: '${row.name}(${row.code})'),
        ],
        onChanged: (value) {
          setState(() => _value = value);
          widget.onChanged(value);
        },
      ),
    );
  }
}

/// 设置仓库负责人(ADR-115)：多选在职员工，整组替换。
class _WarehouseKeepersDialog extends StatefulWidget {
  const _WarehouseKeepersDialog({
    required this.warehouseId,
    required this.warehouseName,
    required this.initial,
    required this.repository,
  });

  final String warehouseId;
  final String warehouseName;
  final List<WarehouseKeeper> initial;
  final WarehouseKeeperRepository repository;

  @override
  State<_WarehouseKeepersDialog> createState() =>
      _WarehouseKeepersDialogState();
}

class _WarehouseKeepersDialogState extends State<_WarehouseKeepersDialog> {
  late List<UtenEmployeePickerItem> _selection = [
    for (final keeper in widget.initial) _itemOf(keeper),
  ];

  /// 候选里带回的账号/部门事实，保存前给出「收不到通知」提示。
  late final Map<String, WarehouseKeeper> _known = {
    for (final keeper in widget.initial) keeper.employeeId: keeper,
  };
  bool _saving = false;
  String? _error;

  static UtenEmployeePickerItem _itemOf(WarehouseKeeper keeper) =>
      UtenEmployeePickerItem(
        id: keeper.employeeId,
        name: keeper.name,
        employeeCode: keeper.code,
        departmentName: keeper.departmentName,
      );

  Future<List<UtenEmployeePickerItem>> _load(String? keyword) async {
    final candidates = await widget.repository.candidates(keyword);
    for (final candidate in candidates) {
      _known[candidate.employeeId] = candidate;
    }
    return [for (final candidate in candidates) _itemOf(candidate)];
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final saved = await widget.repository.replace(widget.warehouseId, [
        for (final item in _selection) item.id,
      ]);
      if (mounted) Navigator.of(context).pop(saved);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = '保存失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final warnings = [
      for (final item in _selection)
        if (_known[item.id]?.noticeWarning case final warning?)
          '${item.name}：$warning',
    ];
    return AlertDialog(
      title: Text('设置负责人 · ${widget.warehouseName}'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '登记后，这个仓(含下级子仓)的领料、采购/委外到货、IQC 入库、产成品、'
              '销售出库等仓库通知只发给负责人；不登记则照旧发给整个仓库部门。'
              '仓库任务中心选「我的仓库」即可只看自己负责的仓。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: UtenSpacing.s12),
            UtenEmployeeMultiPicker(
              key: const Key('warehouse-keeper-picker'),
              label: '负责人',
              sheetTitle: '选择仓库负责人',
              initialSelection: _selection,
              enabled: !_saving,
              loader: _load,
              onChanged: (next) => setState(() => _selection = next),
            ),
            for (final warning in warnings)
              Padding(
                padding: const EdgeInsets.only(top: UtenSpacing.s4),
                child: Text(
                  warning,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: UtenSpacing.s8),
                child: Text(
                  _error!,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? '保存中…' : '保存'),
        ),
      ],
    );
  }
}
