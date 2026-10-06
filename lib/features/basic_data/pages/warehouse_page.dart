// 仓库资料管理页(基础资料)。
//
// 主档形态(ADR-145)：全公司只有一个主仓(编号 001)，只作汇总、负责人范围和导航；其余仓都是
// 它的直属子仓。列表主仓置顶、子仓缩进；「上级仓库」只读、固定是主仓(新建不传，服务端补)；
// 「仓库用途」(良品仓/不良品仓)可筛选可编辑；内料仓由「车间内料仓」页开通，这里只读。
// 停用/删除被拒时原样展示服务端原因(还有库存/还是货品所属仓库/未结预留/主仓等)。
// accountable(bool) 用 select 使用/不使用(提交 'true'/'false' 字符串，Jackson 自动转 Boolean)。
// 查看全员可见，编辑按 warehouse:edit。
//
// 仓库负责人(仓管员, ADR-115 / ADR-149)：列表「负责人」列 + 详情「设置负责人」。负责关系决定
// 谁看、谁收仓库任务(服务端唯一判定)：登记在主仓上 = 仓库主管(看全部、可挑任一仓)；登记在子仓上
// = 只看、只收自己负责的仓；没登记负责人的仓交主管，没登记的同事也看得到。
import 'package:flutter/material.dart';
import '../../../shared/drafts/form_draft_dialog_resume.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/buttons/uten_export_button.dart';
import '../../../components/inputs/uten_employee_multi_picker.dart';
import '../../../components/inputs/uten_employee_picker.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/print/uten_print_preview.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/latest_request_guard.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/action_feedback.dart';
import '../../../shared/auth/permissions.dart';
import '../models/master_facet.dart';
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
    final l10n = AppLocalizations.of(context);
    final warnings = [
      for (final keeper in saved)
        if (keeper.warningOf(l10n) case final warning?)
          '${keeper.name}: $warning',
    ];
    if (warnings.isEmpty) {
      context.appSuccess(
        saved.isEmpty ? l10n.warehouseKeeperCleared : l10n.warehouseKeeperSaved,
      );
    } else {
      context.appWarning(
        l10n.warehouseKeeperSavedWithWarnings(warnings.join('; ')),
        force: true,
      );
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

  /// 主仓名称(字典里唯一没有上级的仓)；字典没加载到时为空。
  String? get _mainWarehouseName => ref
      .read(masterNameServiceProvider)
      .warehouseHierarchy
      .where((entry) => entry.parentId == null || entry.parentId!.isEmpty)
      .map((entry) => entry.name)
      .firstOrNull;

  /// 表单字段。[editing] 为空 = 新建。内料仓与主仓的用途/车间字段只读(ADR-145)。
  List<MasterFieldDef> _fields({WarehouseDetail? editing}) {
    final l10n = AppLocalizations.of(context);
    final lineSide = editing?.lineSide ?? false;
    final isMain = editing?.isMain ?? false;
    return [
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
      // 内料仓的所属车间是它的身份(由车间内料仓页开通时定下)，这里只读。
      if (lineSide)
        const MasterFieldDef(
          key: 'workshopDepartmentName',
          label: '所属车间',
          group: '基础',
          readOnly: true,
        )
      else
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
      // ADR-145：内料仓由「车间内料仓」页开通和撤销，仓库资料只读展示，不上送。
      if (editing != null)
        MasterFieldDef(
          key: 'isLineSide',
          label: l10n.warehouseMasterLineSideLabel,
          group: '基础',
          type: MasterFieldType.select,
          readOnly: true,
          hint: l10n.warehouseMasterLineSideReadOnlyHint,
          options: [
            MasterSelectOption(
              value: 'false',
              label: l10n.warehouseMasterLineSideNo,
            ),
            MasterSelectOption(
              value: 'true',
              label: l10n.warehouseMasterLineSideYes,
            ),
          ],
        ),
      // ADR-145 单主仓：上级仓库固定是主仓，只读展示，不上送(服务端补成主仓)。
      MasterFieldDef(
        key: 'parentName',
        label: l10n.warehouseMasterParentLabel,
        group: '基础',
        readOnly: true,
        hint: isMain
            ? l10n.warehouseMasterParentSelf
            : l10n.warehouseMasterParentFixedHint,
      ),
      // ADR-145 仓库用途：不良品仓只能是子仓、不能是内料仓；有库存/还是货品所属仓库时服务端拒绝并说明原因。
      MasterFieldDef(
        key: 'defective',
        label: l10n.warehouseMasterUseColumn,
        group: '基础',
        type: MasterFieldType.select,
        required: true,
        readOnly: lineSide || isMain,
        hint: l10n.warehouseMasterUseHint,
        options: [
          MasterSelectOption(
            value: 'false',
            label: l10n.warehouseMasterUseGood,
          ),
          MasterSelectOption(
            value: 'true',
            label: l10n.warehouseMasterUseDefective,
          ),
        ],
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
  }

  Future<void> _showCreate() async {
    await ref.read(masterNameServiceProvider).ensureWarehousesLoaded();
    if (!mounted) return;
    await showMasterEditDialog(
      context: context,
      draftSpec: FormDraftCatalog.warehouse.spec(title: '新增仓库'),
      title: '新增仓库',
      fields: _fields(),
      initialValues: {
        'accountable': 'true',
        'defective': 'false',
        'parentName': _mainWarehouseName ?? '',
        'status': '使用',
      },
      readOnlyKeys: _canStatus ? null : const {'status'},
      onSubmit: _doCreate,
    );
  }

  Future<bool> _doCreate(Map<String, dynamic> body) async {
    // Preserve the actual API failure for the shared draft submission fence.
    await ref.read(warehouseRepositoryProvider).create(body);
    if (mounted) {
      context.appSuccess('仓库已创建');
      await _loadWarehouses(_pageNum);
    }
    return true;
  }

  Future<void> _showEdit(WarehouseDetail d) async {
    await ref.read(masterNameServiceProvider).ensureWarehousesLoaded();
    if (!mounted) return;
    await showMasterEditDialog(
      context: context,
      title: '编辑仓库',
      fields: _fields(editing: d),
      initialValues: {
        'name': d.name ?? '',
        'code': d.code ?? '',
        'location': d.location ?? '',
        'accountable': d.accountable ? 'true' : 'false',
        'workshopDepartmentId': d.workshopDepartmentId ?? '',
        'workshopDepartmentName': d.workshopDepartmentName ?? '',
        'isLineSide': d.lineSide ? 'true' : 'false',
        'parentName': d.isMain ? '' : (_mainWarehouseName ?? ''),
        'defective': d.defective ? 'true' : 'false',
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
    // ADR-147: 车间内料仓只由「车间内料仓」开通和撤销, 这里只读 (编辑、停用、删除都不给)。
    final lineSide = detail.lineSide;
    await showMasterDetailSheet(
      context: context,
      title: detail.name?.isNotEmpty == true
          ? detail.name!
          : (detail.code ?? '仓库详情'),
      rows: _detailRows(detail),
      canEdit: _canEdit && !lineSide,
      canDelete: _canDelete && !lineSide,
      onToggleStatus: _canStatus && !lineSide
          ? () => _toggleDetailStatus(detail)
          : null,
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

  List<MasterDetailRow> _detailRows(WarehouseDetail w) {
    final l10n = AppLocalizations.of(context);
    return [
      MasterDetailRow('编号', w.code),
      MasterDetailRow('仓库名称', w.name),
      MasterDetailRow(
        l10n.warehouseMasterParentLabel,
        w.isMain ? l10n.warehouseMasterParentSelf : _mainWarehouseName,
      ),
      MasterDetailRow(
        l10n.warehouseMasterUseColumn,
        w.defective
            ? l10n.warehouseMasterUseDefective
            : l10n.warehouseMasterUseGood,
      ),
      MasterDetailRow('位置', w.location),
      MasterDetailRow('是否核算', w.accountable ? '是' : '否'),
      MasterDetailRow(
        l10n.warehouseMasterLineSideLabel,
        w.lineSide
            ? l10n.warehouseMasterLineSideManaged
            : l10n.warehouseMasterLineSideNo,
      ),
      MasterDetailRow('备注', w.remark),
      MasterDetailRow('状态', w.status),
      MasterDetailRow('所属车间', w.workshopDepartmentName),
      MasterDetailRow('仓库负责人', _keeperLabel(w.id)),
      MasterDetailRow('旧操作员ID', w.legacyOperatorId?.toString()),
      MasterDetailRow('旧系统 ID', w.legacyId?.toString()),
    ];
  }

  /// 导出查询参数（与 _loadWarehouses 一致，不含 page/size；V717）。
  Map<String, dynamic> get _exportQuery => <String, dynamic>{
    if (_keyword.trim().isNotEmpty) 'keyword': _keyword.trim(),
    ...masterFilterQueryParams(_filters),
  };

  /// 打印预览数据：按当前筛选口径拉全量（上限 2000 行），列/格式化与页面表格一致。
  Future<UtenPrintTable> _printLoader() async {
    final result = await ref
        .read(warehouseRepositoryProvider)
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

  List<MasterColumnDef<WarehouseListItem>> get _columns {
    final l10n = AppLocalizations.of(context);
    String useLabel(WarehouseListItem w) => w.defective
        ? l10n.warehouseMasterUseDefective
        : l10n.warehouseMasterUseGood;
    return [
      MasterColumnDef(
        key: 'status',
        label: '状态',
        width: 72,
        value: (w) => w.status,
      ),
      MasterColumnDef(
        key: 'code',
        label: '编号',
        width: 110,
        value: (w) => w.code,
      ),
      MasterColumnDef(
        key: 'name',
        label: '仓库名称',
        width: 200,
        value: (w) => w.name,
        // ADR-145：主仓置顶带「主仓」标签，子仓缩进一级。
        cellBuilder: (context, w) => Padding(
          padding: EdgeInsets.only(left: w.isMain ? 0 : UtenSpacing.s16),
          child: Row(
            children: [
              Flexible(
                child: Text(
                  w.name ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (w.isMain) ...[
                const SizedBox(width: UtenSpacing.s8),
                UtenStatusBadge(
                  label: l10n.warehouseMasterMainTag,
                  type: UtenStatusBadgeType.info,
                  size: UtenStatusBadgeSize.small,
                ),
              ],
            ],
          ),
        ),
      ),
      MasterColumnDef(
        key: 'parent',
        // ADR-145 单主仓：子仓行显示主仓名，主仓显示「—」。
        label: l10n.warehouseMasterParentLabel,
        width: 140,
        value: (w) => w.parentName ?? '—',
      ),
      MasterColumnDef(
        key: 'defective',
        label: l10n.warehouseMasterUseColumn,
        width: 90,
        value: useLabel,
      ),
      MasterColumnDef(
        key: 'location',
        label: '位置',
        width: 120,
        value: (w) => w.location,
      ),
      MasterColumnDef(
        key: 'accountable',
        label: '核算',
        width: 80,
        value: (w) => w.accountable ? '是' : '否',
      ),
      // ADR-115：登记后该仓的仓库类通知只发给负责人；主仓负责人管全部子仓。
      MasterColumnDef(
        key: 'keepers',
        label: '负责人',
        width: 160,
        value: (w) => _keeperLabel(w.id),
      ),
    ];
  }

  Future<void> _refresh() async {
    await Future.wait([_loadWarehouses(1), _loadFacets(), _loadKeepers()]);
  }

  @override
  Widget build(BuildContext context) => FormDraftDialogResume(
    descriptor: FormDraftCatalog.warehouse,
    onResume: (_) => _showCreate(),
    child: _buildDraftHost(context),
  );

  Widget _buildDraftHost(BuildContext context) {
    ref.watch(currentPermissionsProvider);
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
                    columnEditingEnabled: _canEdit,
                    tableKey:
                        'features.basic_data.pages.warehouse_page.WarehousePageState._buildDraftHost.1',
                    columns: _columns,
                    items: _page?.items ?? const [],
                    // 导出/打印（V717 warehouse:export）：打印预览用本页列渲染，
                    // 导出列集服务端与表格对齐——「表格显示啥导出啥」。
                    toolbarActions: [
                      UtenPrintPreviewButton(
                        title: '仓库资料', // TODO(l10n): 补 arb
                        subtitle: '最多前 2000 行', // TODO(l10n): 补 arb
                        loader: _printLoader,
                        exportEndpoint: '/master/warehouses/export',
                        exportPermission: Perm.warehouseExport,
                        exportReport: '',
                        exportQuery: _exportQuery,
                        exportFilename: '仓库资料', // TODO(l10n): 补 arb
                        type: UtenButtonType.primary,
                        size: UtenButtonSize.large,
                      ),
                      UtenExportButton(
                        endpoint: '/master/warehouses/export',
                        requiredPermission: Perm.warehouseExport,
                        report: '',
                        queryParams: _exportQuery,
                        filename: '仓库资料', // TODO(l10n): 补 arb
                        label: '导出仓库', // TODO(l10n): 补 arb
                        type: UtenButtonType.primary,
                        size: UtenButtonSize.large,
                      ),
                    ],
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
                    paginationScope: _keyword,
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

/// 设置仓库负责人(ADR-115 / ADR-149)：多选在职员工，整组替换；说明三种角色，候选人标出工号、
/// 账号状态与同名提示。
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

  /// 显示「姓名(工号)」; 副行带部门、账号状态与同名提示(重名员工按工号核对)。
  UtenEmployeePickerItem _itemOf(WarehouseKeeper keeper) {
    final l10n = AppLocalizations.of(context);
    final notes = [
      if (keeper.departmentName?.isNotEmpty == true) keeper.departmentName!,
      if (!keeper.hasAccount) l10n.warehouseKeeperNoAccount,
      if (keeper.duplicateName) l10n.warehouseKeeperDuplicateName,
    ];
    return UtenEmployeePickerItem(
      id: keeper.employeeId,
      name: keeper.name,
      employeeCode: keeper.code,
      departmentName: notes.isEmpty ? null : notes.join(' · '),
    );
  }

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
    final l10n = AppLocalizations.of(context);
    final warnings = [
      for (final item in _selection)
        if (_known[item.id]?.warningOf(l10n) case final warning?)
          '${item.name}: $warning',
    ];
    return AlertDialog(
      title: Text(l10n.warehouseKeeperDialogTitle(widget.warehouseName)),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.warehouseKeeperRolesHint,
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
