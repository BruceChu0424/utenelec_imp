// 仓库资料管理页(基础资料)。
//
// 主档形态(ADR-145)：全公司只有一个主仓(编号 001)，只作汇总、负责人范围和导航；其余仓都是
// 它的直属子仓。左侧仓库目录、右侧信息卡与即时库存；「上级仓库」只读、固定是主仓(新建不传，服务端补)；
// 「仓库用途」(良品仓/不良品仓)可筛选可编辑；内料仓由「车间内料仓」页开通，这里只读。
// 停用/删除被拒时原样展示服务端原因(还有库存/还是货品所属仓库/未结预留/主仓等)。
// accountable(bool) 用 select 使用/不使用(提交 'true'/'false' 字符串，Jackson 自动转 Boolean)。
// 查看全员可见，编辑按 warehouse:edit。
//
// 仓库负责人(仓管员, ADR-115 / ADR-149)：列表「负责人」列 + 详情「设置负责人」。负责关系决定
// 谁看、谁收仓库任务(服务端唯一判定)：登记在主仓上 = 仓库主管(看全部、可挑任一仓)；登记在子仓上
// = 只看、只收自己负责的仓；没登记负责人的仓交主管，没登记的同事也看得到。
import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'package:flutter/material.dart';
import '../widgets/master_operation_history_panel.dart';
import '../../../shared/drafts/form_draft_dialog_resume.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_refresh_button.dart';
import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/buttons/uten_app_bar_action_button.dart';
import '../../../components/buttons/uten_export_button.dart';
import '../../../components/inputs/uten_employee_multi_picker.dart';
import '../../../components/inputs/uten_employee_picker.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/print/uten_print_preview.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../components/layout/uten_split_view.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/latest_request_guard.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/action_feedback.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/auth/sensitive_write.dart';
import '../../../shared/models/uten_tree_node.dart';
import '../../../shared/search/keyword_search.dart';
import '../../../shared/widgets/master_detail_card.dart';
import '../../../shared/widgets/uten_hierarchy_node_actions.dart';
import '../../../shared/widgets/uten_hierarchy_detail_menu.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../shared/widgets/uten_hierarchy_search_header.dart';
import '../models/master_facet.dart';
import '../models/master_batch.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../models/warehouse_node.dart';
import '../repositories/warehouse_keeper_repository.dart';
import '../repositories/warehouse_repository.dart';
import '../repositories/master_status_repository.dart';
import '../repositories/master_identifier_repository.dart';
import '../repositories/master_batch_repository.dart';
import '../widgets/master_batch_feedback.dart';
import '../widgets/master_data_table_view.dart';
import '../widgets/master_edit_dialog.dart';
import '../widgets/master_status_confirmation.dart';
import '../widgets/master_inline_edit.dart';
import '../widgets/master_inline_page_mixin.dart';
import '../widgets/master_read_only_fields.dart';
import '../widgets/uten_category_tree_view.dart';
import '../widgets/warehouse_inventory_panel.dart';

class WarehousePage extends ConsumerStatefulWidget {
  const WarehousePage({super.key});

  @override
  ConsumerState<WarehousePage> createState() => _WarehousePageState();
}

class _WarehousePageState extends ConsumerState<WarehousePage>
    with MasterInlinePageMixin<WarehousePage, WarehouseDetail> {
  @override
  String get inlineEntityType => 'warehouses';
  @override
  bool get inlineCanEdit => _canEdit;
  @override
  bool get inlineReadReady =>
      !_loading &&
      !_detailLoading &&
      !_tableBatchBusy &&
      _error == null &&
      _warehouses != null;
  @override
  String inlineIdOf(WarehouseDetail row) => row.id;
  @override
  Future<void> inlineReload() => _refresh();
  @override
  void inlineClearView() {
    _loadRequests.begin();
    _detailRequests.begin();
    _warehouses = null;
    _selectedId = null;
    _selectedDetail = null;
    _keeperNames = const {};
    _error = null;
    _detailError = null;
    _loading = false;
    _detailLoading = false;
    _selectedWarehouseIds = {};
    _tableBatchBusy = false;
    _tableBatchWriting = false;
    _tableBatchEpoch++;
    _closeTableBatchDialogs();
  }

  Object? _inlineValue(WarehouseDetail row, String key) => switch (key) {
    'name' => row.name,
    'code' => row.code,
    'location' => row.location,
    'remark' => row.remark,
    'accountable' => row.accountable,
    'workshopDepartmentId' => row.workshopDepartmentId,
    'workshopDepartmentName' => row.workshopDepartmentName,
    'isLineSide' => row.lineSide,
    'parentName' => row.isMain ? '' : _mainWarehouseName,
    'defective' => row.defective,
    'status' => row.status,
    _ => null,
  };

  @override
  Map<String, MasterInlineField<WarehouseDetail>> get inlineFields {
    return {
      for (final field in _fields())
        if (!field.readOnly && (field.key != 'status' || _canStatus))
          field.key: MasterInlineField(
            key: field.key,
            read: (row) => _inlineValue(row, field.key),
            type: field.type,
            required: field.required,
            options: field.options,
            customBuilder: field.customBuilder,
            asyncValidate: field.key == 'code'
                ? (id, value) => ref
                      .read(masterIdentifierRepositoryProvider)
                      .check(
                        'warehouses',
                        value?.toString() ?? '',
                        entityId: id,
                      )
                : null,
            editableOf: (row) =>
                !row.lineSide &&
                !(row.isMain &&
                    const {'code', 'status', 'defective'}.contains(field.key)),
          ),
    };
  }

  @override
  Future<void> saveInline(String id, Map<String, dynamic> patch) async {
    final changes = <String, dynamic>{};
    for (final entry in patch.entries) {
      if (const {'accountable', 'defective'}.contains(entry.key)) {
        final value = entry.value;
        if (value is! bool && value != 'true' && value != 'false') {
          throw StateError(
            masterEditText(
              context,
              '请选择有效的仓库选项',
              'Select a valid warehouse option',
              '올바른 창고 옵션을 선택하세요',
            ),
          );
        }
        changes[entry.key] = value == true || value == 'true';
      } else {
        changes[entry.key] = entry.value;
      }
    }
    await super.saveInline(id, changes);
  }

  List<WarehouseListItem>? _warehouses;
  bool _loading = false;
  String? _error;
  final _loadRequests = LatestRequestGuard();

  Map<String, String?> _filters = {};
  String _keyword = '';
  bool _detailLoading = false;
  String? _selectedId;
  WarehouseDetail? _selectedDetail;
  String? _detailError;
  final _detailRequests = LatestRequestGuard();
  bool _directoryActionBusy = false;
  bool _tableView = false;
  bool _tableBatchBusy = false;
  bool _tableBatchWriting = false;
  int _tableBatchEpoch = 0;
  final Set<ModalRoute<dynamic>> _tableBatchDialogs = {};
  Set<String> _selectedWarehouseIds = {};

  /// 仓库 id → 负责人姓名(ADR-115)；加载失败时列显示「—」不挡列表。
  Map<String, List<String>> _keeperNames = const {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadWarehouses();
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

  Future<void> _loadWarehouses() async {
    final boundary = ref.read(sensitiveReadBoundaryProvider);
    final generation = _loadRequests.begin();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await ref.read(warehouseRepositoryProvider).dict();
      if (!inlineAcceptsRead(boundary) ||
          !_loadRequests.isCurrent(generation)) {
        return;
      }
      setState(() {
        _warehouses = result;
        final selectable = {
          for (final row in result)
            if (!row.isMain && !row.lineSide) row.id,
        };
        _selectedWarehouseIds = _selectedWarehouseIds.intersection(selectable);
        _loading = false;
        if (_selectedId != null && !result.any((w) => w.id == _selectedId)) {
          _detailRequests.begin();
          _selectedId = null;
          _selectedDetail = null;
          _detailError = null;
          _detailLoading = false;
        }
      });
    } on ApiException catch (e) {
      if (!inlineAcceptsRead(boundary) ||
          !_loadRequests.isCurrent(generation)) {
        return;
      }
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!inlineAcceptsRead(boundary) ||
          !_loadRequests.isCurrent(generation)) {
        return;
      }
      setState(() {
        _error = '加载仓库列表失败';
        _loading = false;
      });
    }
  }

  Future<void> _loadKeepers() async {
    final boundary = ref.read(sensitiveReadBoundaryProvider);
    try {
      final assignments = await ref
          .read(warehouseKeeperRepositoryProvider)
          .assignments();
      if (!inlineAcceptsRead(boundary)) return;
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
    if (!_canEdit) return;
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
    if (!mounted || !_canEdit) return;
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

  // 目录筛选同时用于打印与导出的服务端查询参数。
  void _onFilterChanged(String key, String? value) {
    setState(() {
      _selectedWarehouseIds = {};
      final next = Map<String, String?>.from(_filters);
      if (value == null) {
        next.remove(key);
      } else {
        next[key] = value;
      }
      _filters = next;
    });
  }

  void _onKeywordChanged(String kw) {
    setState(() {
      _keyword = kw;
      _selectedWarehouseIds = {};
    });
  }

  /// 主仓名称(字典里唯一没有上级的仓)；字典没加载到时为空。
  String? get _mainWarehouseName =>
      _warehouses
          ?.where((warehouse) => warehouse.isMain)
          .map((warehouse) => warehouse.name)
          .whereType<String>()
          .firstOrNull ??
      ref
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
      MasterFieldDef(
        key: 'code',
        label: '仓库编号',
        group: '基础',
        readOnly: lineSide || isMain,
        identifierDomain: 'WAREHOUSE',
        identifierId: editing?.id,
        hint: '留空自动生成；已有编号可修改，旧编号不会被复用',
      ),
      const MasterFieldDef(
        key: 'location',
        label: '仓库位置',
        group: '基础',
        hint: '如 总仓库/轨道仓',
      ),
      MasterFieldDef(
        key: 'remark',
        label: l10n.employeeTransferFieldRemark,
        group: '基础',
      ),
      const MasterFieldDef(
        key: 'accountable',
        label: '是否核算',
        group: '基础',
        type: MasterFieldType.select,
        required: true,
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
      MasterFieldDef(
        key: 'status',
        label: '状态',
        type: MasterFieldType.select,
        options: kMasterStatusOptions,
        required: true,
        readOnly: isMain,
        group: '基础',
      ),
    ];
  }

  Future<void> _showCreate() async {
    if (!_canCreate) return;
    if (!await inlineEdit.confirmLeave(context) || !mounted) return;
    await ref.read(masterNameServiceProvider).ensureWarehousesLoaded();
    if (!mounted || !_canCreate) return;
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
      await _loadWarehouses();
    }
    return true;
  }

  @override
  MasterInlineCreateConfig get inlineCreation => MasterInlineCreateConfig(
    namespace: 'warehouses',
    fields: _fields()
        .where(
          (field) => !field.readOnly && (field.key != 'status' || _canStatus),
        )
        .toList(),
    defaults: const {
      'accountable': 'true',
      'defective': 'false',
      'status': '使用',
    },
    canCreate: _canCreate,
    onCreate: (_, values) async {
      await ref.read(warehouseRepositoryProvider).create({
        'status': '使用',
        ...values,
        'accountable':
            values['accountable'] == null ||
            values['accountable'] == true ||
            values['accountable'] == 'true',
        'defective':
            values['defective'] == true || values['defective'] == 'true',
      });
    },
  );

  Future<void> _showEdit(WarehouseDetail detail) async {
    if (!_canEdit || detail.lineSide || _selectedId != detail.id) return;
    await inlineEdit.prepareToBegin();
  }

  Future<void> _toggleDetailStatus(WarehouseDetail d) async {
    if (!_canStatus || d.lineSide || d.isMain) return;
    final next = d.status == '使用' ? '禁用' : '使用';
    if (!await confirmMasterStatusChange(
          context,
          disabling: next == '禁用',
          label: d.name ?? d.code ?? '该仓库',
        ) ||
        !mounted) {
      return;
    }
    final ok = await context.guardRun(
      () => ref
          .read(masterStatusRepositoryProvider)
          .change(resourcePath: ApiEndpoints.warehouse(d.id), status: next),
      success: next == '禁用' ? '已停用' : '已启用',
      errorFallback: '状态变更失败，请稍后重试',
    );
    if (ok && mounted) {
      await _loadWarehouses();
      if (mounted && _selectedId == d.id) await _showDetail(d.id);
    }
  }

  Future<void> _delete(WarehouseDetail d) async {
    if (!_canDelete || d.lineSide || d.isMain) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => UtenAlertDialog(
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
    if (!mounted || !_canDelete) return;
    final deleted = await context.guardRun(
      () async {
        await ref.read(warehouseRepositoryProvider).delete(d.id);
      },
      success: '仓库已删除', // TODO(l10n): 补 arb
      errorFallback: '删除失败，请稍后重试', // TODO(l10n): 补 arb
    );
    if (!deleted || !mounted) return;
    await _loadWarehouses();
  }

  Future<void> _showDetail(String id) async {
    final boundary = ref.read(sensitiveReadBoundaryProvider);
    final generation = _detailRequests.begin();
    setState(() {
      _selectedId = id;
      _selectedDetail = null;
      _detailLoading = true;
      _detailError = null;
    });
    try {
      final detail = await ref.read(warehouseRepositoryProvider).detail(id);
      if (!inlineAcceptsRead(boundary) ||
          !_detailRequests.isCurrent(generation)) {
        return;
      }
      setState(() {
        _selectedDetail = detail;
        _detailLoading = false;
      });
    } on ApiException catch (e) {
      if (!inlineAcceptsRead(boundary) ||
          !_detailRequests.isCurrent(generation)) {
        return;
      }
      setState(() {
        _detailError = e.message;
        _detailLoading = false;
      });
    } catch (_) {
      if (!inlineAcceptsRead(boundary) ||
          !_detailRequests.isCurrent(generation)) {
        return;
      }
      setState(() {
        _detailError = AppLocalizations.of(
          context,
        ).warehouseMasterDetailsLoadFailed;
        _detailLoading = false;
      });
    }
  }

  String? _displayField(WarehouseDetail row, MasterFieldDef field) {
    if (field.key == 'parentName' && row.isMain) {
      return AppLocalizations.of(context).warehouseMasterParentSelf;
    }
    if (field.key == 'workshopDepartmentId') {
      return row.workshopDepartmentName;
    }
    final value = _inlineValue(row, field.key)?.toString();
    for (final option in field.options ?? <MasterSelectOption>[]) {
      if (option.value == value) return option.label;
    }
    return value?.isNotEmpty == true ? value : null;
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
    final selectedId = _selectedId;
    await Future.wait([_loadWarehouses(), _loadKeepers()]);
    if (mounted && selectedId != null && _selectedId == selectedId) {
      await _showDetail(selectedId);
    }
  }

  List<_WarehouseTreeNode> get _directoryNodes {
    final items = _warehouses ?? const <WarehouseListItem>[];
    final ids = {for (final item in items) item.id};
    List<_WarehouseTreeNode> childrenOf(String? parent) => [
      for (final item in items)
        if (parent == null
            ? item.parentId == null || !ids.contains(item.parentId)
            : item.parentId == parent)
          _WarehouseTreeNode(item, childrenOf(item.id)),
    ];
    return childrenOf(null);
  }

  Set<String>? get _visibleDirectoryIds {
    if (_keyword.trim().isEmpty && _filters.isEmpty) return null;
    final visible = <String>{};
    final byId = {
      for (final item in _warehouses ?? <WarehouseListItem>[]) item.id: item,
    };
    for (final item in byId.values) {
      if (!matchesKeywordSearch([item.name, item.code], _keyword)) continue;
      if (_filters['defective'] case final use?) {
        if (item.defective.toString() != use) continue;
      }
      if (_filters['status'] case final status?) {
        if (item.status != status) continue;
      }
      WarehouseListItem? ancestor = item;
      while (ancestor != null && visible.add(ancestor.id)) {
        ancestor = byId[ancestor.parentId];
      }
    }
    return visible;
  }

  Future<void> _directoryAction(
    WarehouseListItem warehouse,
    Future<void> Function(WarehouseDetail detail) action, {
    bool keepInlineDrafts = false,
  }) async {
    if (_directoryActionBusy) return;
    if (inlineEdit.busy || inlineEdit.preparing) return;
    if (!keepInlineDrafts &&
        (!await inlineEdit.confirmLeave(context) || !mounted)) {
      return;
    }
    _directoryActionBusy = true;
    try {
      await _showDetail(warehouse.id);
      final detail = _selectedDetail;
      if (mounted && _selectedId == warehouse.id && detail != null) {
        await action(detail);
      }
    } finally {
      _directoryActionBusy = false;
    }
  }

  final _directoryOperationsCache = <String, UtenHierarchyNodeOperations>{};
  List<WarehouseListItem>? _directoryOperationsSource;

  UtenHierarchyNodeOperations _directoryOperations(_WarehouseTreeNode node) {
    if (!identical(_directoryOperationsSource, _warehouses)) {
      _directoryOperationsSource = _warehouses;
      _directoryOperationsCache.clear();
    }
    final key =
        '${Localizations.localeOf(context)}|$_canCreate|$_canEdit|'
        '$_canDelete|$_canStatus|${node.id}';
    return _directoryOperationsCache.putIfAbsent(
      key,
      () => _buildDirectoryOperations(node),
    );
  }

  UtenHierarchyNodeOperations _buildDirectoryOperations(
    _WarehouseTreeNode node,
  ) {
    final l10n = AppLocalizations.of(context);
    final warehouse = node.warehouse;
    return UtenHierarchyNodeOperations(
      add: _canCreate && !warehouse.lineSide
          ? UtenHierarchyNodeOperation(
              buttonKey: ValueKey('warehouse-node-add-${node.id}'),
              label: warehouse.isMain
                  ? l10n.warehouseMasterAddChild
                  : l10n.warehouseMasterAddPeer,
              icon: Icons.add_outlined,
              onInvoke: _showCreate,
            )
          : null,
      edit: _canEdit && !warehouse.lineSide
          ? UtenHierarchyNodeOperation(
              buttonKey: ValueKey('warehouse-node-edit-${node.id}'),
              label: l10n.warehouseMasterEdit,
              icon: Icons.edit_outlined,
              onInvoke: () => _directoryAction(
                warehouse,
                _showEdit,
                keepInlineDrafts: true,
              ),
            )
          : null,
      delete: _canDelete && !warehouse.lineSide && !warehouse.isMain
          ? UtenHierarchyNodeOperation(
              buttonKey: ValueKey('warehouse-node-delete-${node.id}'),
              label: l10n.warehouseMasterDelete,
              icon: Icons.delete_outline,
              destructive: true,
              onInvoke: () => _directoryAction(warehouse, _delete),
            )
          : null,
      extra: [
        if (_canEdit)
          UtenHierarchyNodeOperation(
            label: l10n.warehouseMasterSetKeepers,
            icon: Icons.manage_accounts_outlined,
            onInvoke: () => _directoryAction(warehouse, _editKeepers),
          ),
        if (_canStatus && !warehouse.lineSide && !warehouse.isMain)
          UtenHierarchyNodeOperation(
            label: warehouse.status == '使用'
                ? l10n.warehouseMasterDisable
                : l10n.warehouseMasterEnable,
            icon: Icons.power_settings_new,
            destructive: warehouse.status == '使用',
            onInvoke: () => _directoryAction(warehouse, _toggleDetailStatus),
          ),
      ],
    );
  }

  List<UtenContextMenuEntry> _directoryMenu(_WarehouseTreeNode node) {
    final operations = _directoryOperations(node).menuEntries;
    return [
      ...operations,
      if (operations.isNotEmpty) const UtenMenuDivider(),
      ...utenHierarchyCopyEntries(context, name: node.name),
    ];
  }

  List<UtenContextMenuEntry> _detailDirectoryMenu(String id) {
    _WarehouseTreeNode? find(List<_WarehouseTreeNode> nodes) {
      for (final node in nodes) {
        if (node.id == id) return node;
        final child = find(node.children);
        if (child != null) return child;
      }
      return null;
    }

    final node = find(_directoryNodes);
    return node == null ? const [] : _directoryMenu(node);
  }

  Widget _directoryHeader(BuildContext context, {bool showCreate = true}) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.only(
        top: UtenSpacing.s12,
        bottom: UtenSpacing.s8,
      ),
      child: Column(
        children: [
          UtenHierarchySearchHeader(
            search: UtenSearchBar(
              key: const Key('warehouse-directory-search'),
              hint: l10n.warehouseMasterSearchHint,
              initialValue: _keyword,
              onChanged: (value) =>
                  inlineNavigate(() => _onKeywordChanged(value)),
            ),
            trailing: showCreate && _canCreate
                ? IconButton.filledTonal(
                    key: const Key('warehouse-add'),
                    tooltip: l10n.warehouseMasterAdd,
                    style: IconButton.styleFrom(
                      shape: const RoundedRectangleBorder(
                        borderRadius: UtenRadius.controlAll,
                      ),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    padding: EdgeInsets.zero,
                    onPressed: _showCreate,
                    icon: const Icon(Icons.add_outlined),
                  )
                : null,
          ),
          const SizedBox(height: UtenSpacing.s8),
          Row(
            children: [
              Expanded(
                child: UtenDropdownField(
                  key: const Key('warehouse-directory-use-filter'),
                  label: l10n.warehouseMasterUseColumn,
                  value: _filters['defective'],
                  items: [
                    UtenDropdownItem(label: l10n.visitorFilterAll),
                    UtenDropdownItem(
                      value: 'false',
                      label: l10n.warehouseMasterUseGood,
                    ),
                    UtenDropdownItem(
                      value: 'true',
                      label: l10n.warehouseMasterUseDefective,
                    ),
                  ],
                  onChanged: (value) => inlineNavigate(
                    () => _onFilterChanged('defective', value),
                  ),
                ),
              ),
              const SizedBox(width: UtenSpacing.s8),
              Expanded(
                child: UtenDropdownField(
                  label: l10n.warehouseMasterStatusLabel,
                  value: _filters['status'],
                  items: [
                    UtenDropdownItem(label: l10n.visitorFilterAll),
                    for (final option in kMasterStatusOptions)
                      UtenDropdownItem(
                        value: option.value,
                        label: option.label,
                      ),
                  ],
                  onChanged: (value) =>
                      inlineNavigate(() => _onFilterChanged('status', value)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _directory(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (_loading && _warehouses == null) {
      return Column(
        children: [
          _directoryHeader(context),
          const Expanded(child: Center(child: CircularProgressIndicator())),
        ],
      );
    }
    if (_error != null) {
      return Column(
        children: [
          _directoryHeader(context),
          Expanded(
            child: UtenEmpty.error(
              message: _error,
              actionLabel: l10n.commonRetry,
              onAction: _loadWarehouses,
            ),
          ),
        ],
      );
    }
    return UtenCategoryTreeView<_WarehouseTreeNode>(
      key: const Key('warehouse-directory-tree'),
      nodes: _directoryNodes,
      showSearch: false,
      sortByCode: false,
      flatLevelColors: true,
      expandOnRowTap: true,
      initiallyExpandDepth: 2,
      header: _directoryHeader(context),
      selectedIds: {?_selectedId},
      visibleFilterIds: _visibleDirectoryIds,
      externalSearchQuery: _keyword,
      emptySearchText: l10n.commonNoData,
      onNodeTap: (node) {
        if (!inlineEdit.busy && !inlineEdit.preparing) _showDetail(node.id);
      },
      trailingBuilder: (node) =>
          UtenHierarchyNodeActions(operations: _directoryOperations(node)),
      rowMenuBuilder: _directoryMenu,
    );
  }

  List<WarehouseDetail> get _warehouseTableRows {
    final visible = _visibleDirectoryIds;
    return [
      for (final row in _warehouses ?? const <WarehouseListItem>[])
        if (visible == null || visible.contains(row.id))
          WarehouseDetail.fromListItem(row),
    ];
  }

  Future<void> _switchWarehouseView() async {
    if (_tableBatchBusy || inlineEdit.busy || inlineEdit.preparing) return;
    if (!await inlineEdit.confirmLeave(context) || !mounted) return;
    inlineEdit.cancel();
    setState(() {
      _tableView = !_tableView;
      _selectedWarehouseIds = {};
    });
  }

  void _closeTableBatchDialogs() {
    final routes = _tableBatchDialogs.toList();
    _tableBatchDialogs.clear();
    for (final route in routes) {
      if (route.isActive) route.navigator?.removeRoute(route);
    }
  }

  Widget _ownTableBatchDialog(
    BuildContext dialogContext,
    Widget dialog,
    int epoch,
  ) {
    _tableBatchDialogs.removeWhere((route) => !route.isActive);
    final route = ModalRoute.of(dialogContext);
    if (route is PopupRoute<dynamic>) _tableBatchDialogs.add(route);
    return Consumer(
      builder: (context, ref, _) {
        ref.watch(sensitiveReadBoundaryProvider);
        return mounted && epoch == _tableBatchEpoch
            ? dialog
            : const SizedBox.shrink();
      },
    );
  }

  @override
  void dispose() {
    final routes = _tableBatchDialogs.toList();
    _tableBatchDialogs.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final route in routes) {
        if (route.isActive) route.navigator?.removeRoute(route);
      }
    });
    super.dispose();
  }

  Future<bool> _confirmWarehouseDeletion(int epoch, int count) async =>
      await showDialog<bool>(
        context: context,
        builder: (dialogContext) => _ownTableBatchDialog(
          dialogContext,
          UtenAlertDialog(
            title: const UtenDialogHeading(
              title: Text('批量删除仓库'),
              danger: true,
              icon: Icons.delete_outline_rounded,
            ),
            content: Text('确定删除选中的 $count 个仓库吗？仍有库存、货品归属或业务引用的仓库会保留，并逐项显示原因。'),
            actions: [
              UtenButton(
                type: UtenButtonType.ghost,
                onPressed: () {
                  if (dialogContext.mounted) {
                    Navigator.pop(dialogContext, false);
                  }
                },
                child: const Text('取消'),
              ),
              UtenButton(
                type: UtenButtonType.danger,
                onPressed: () {
                  if (dialogContext.mounted && epoch == _tableBatchEpoch) {
                    Navigator.pop(dialogContext, true);
                  }
                },
                child: const Text('删除'),
              ),
            ],
          ),
          epoch,
        ),
      ) ==
      true;

  Future<void> _batchWarehouses(Set<String> ids, {String? status}) async {
    final deleting = status == null;
    if (_tableBatchBusy ||
        inlineEdit.active ||
        !inlineReadReady ||
        ids.isEmpty ||
        !(deleting ? _canDelete : _canStatus)) {
      return;
    }
    final epoch = ++_tableBatchEpoch;
    final targets = Set<String>.unmodifiable(ids);
    final labels = {
      for (final row in _warehouses ?? const <WarehouseListItem>[])
        row.id: row.name ?? row.code ?? row.id,
    };
    bool current() =>
        mounted &&
        epoch == _tableBatchEpoch &&
        _tableView &&
        !_loading &&
        _error == null &&
        _warehouses != null &&
        (deleting ? _canDelete : _canStatus);
    setState(() => _tableBatchBusy = true);
    try {
      final result = await runSensitiveWrite<MasterBatchResult?>(
        ref,
        isCurrent: current,
        write: () async {
          final confirmed = deleting
              ? await _confirmWarehouseDeletion(epoch, targets.length)
              : await confirmMasterStatusChange(
                  context,
                  disabling: status == '禁用',
                  label: '选中的仓库',
                  count: targets.length,
                  dialogScopeBuilder: (dialogContext, dialog) =>
                      _ownTableBatchDialog(dialogContext, dialog, epoch),
                );
          if (confirmed != true || !current()) return null;
          setState(() => _tableBatchWriting = true);
          final repository = ref.read(masterBatchRepositoryProvider);
          final items = [for (final id in targets) MasterBatchItem(id)];
          return deleting
              ? repository.delete(
                  entityPath: ApiEndpoints.warehouses,
                  items: items,
                )
              : repository.changeStatus(
                  entityPath: ApiEndpoints.warehouses,
                  status: status,
                  items: items,
                );
        },
      );
      if (!mounted || !current() || result == null) return;
      setState(() {
        _tableBatchWriting = false;
        _selectedWarehouseIds = _selectedWarehouseIds.difference({
          for (final row in result.results)
            if (row.ok) row.id,
        });
      });
      await showMasterBatchOutcome(
        context,
        result,
        action: deleting
            ? '删除'
            : status == '禁用'
            ? '停用'
            : '启用',
        noun: '仓库',
        labelOf: (id) => labels[id],
        dialogScopeBuilder: (dialogContext, dialog) =>
            _ownTableBatchDialog(dialogContext, dialog, epoch),
      );
      if (current()) await _refresh();
    } on ApiException catch (error) {
      if (mounted && current()) {
        context.appError(error.message, fieldErrors: error.fieldErrors);
      }
    } catch (_) {
      if (mounted && current()) context.appError('仓库批量操作失败，请刷新后重试');
    } finally {
      if (mounted && epoch == _tableBatchEpoch) {
        setState(() {
          _tableBatchBusy = false;
          _tableBatchWriting = false;
        });
      }
    }
  }

  List<Widget> _warehouseTableActions(BuildContext context, Set<String> ids) =>
      [
        MasterInlineEditActions<WarehouseDetail>(
          controller: inlineEdit,
          canEdit: inlineCanEdit && inlineReadReady && !_tableBatchBusy,
          canCreate: _canCreate && inlineReadReady && !_tableBatchBusy,
          onSave: saveInline,
          embedded: true,
          additionalActions: [
            if (_canCreate)
              UtenButton(
                size: UtenButtonSize.large,
                onPressed: _tableBatchBusy ? null : _showCreate,
                child: const Text('添加仓库'),
              ),
          ],
        ),
        if (!inlineEdit.active && ids.isNotEmpty) ...[
          if (_canStatus) ...[
            UtenButton(
              type: UtenButtonType.secondary,
              size: UtenButtonSize.large,
              onPressed: _tableBatchBusy
                  ? null
                  : () => _batchWarehouses(ids, status: '使用'),
              child: const Text('批量启用'),
            ),
            UtenButton(
              type: UtenButtonType.danger,
              size: UtenButtonSize.large,
              onPressed: _tableBatchBusy
                  ? null
                  : () => _batchWarehouses(ids, status: '禁用'),
              child: const Text('批量停用'),
            ),
          ],
          if (_canDelete)
            UtenButton(
              type: UtenButtonType.danger,
              size: UtenButtonSize.large,
              onPressed: _tableBatchBusy ? null : () => _batchWarehouses(ids),
              child: const Text('批量删除'),
            ),
        ],
      ];

  Widget _warehouseTable(BuildContext context) => UtenContentContainer.wide(
    child: Stack(
      children: [
        AbsorbPointer(
          absorbing: _tableBatchBusy,
          child: Column(
            children: [
              _directoryHeader(context, showCreate: false),
              Expanded(
                child: MasterDataTableView<WarehouseDetail>(
                  appendRowsSource: inlineAppendRowsSource,
                  key: const Key('warehouse-master-table'),
                  tableKey: 'master.warehouses',
                  requiredLeadingColumnKeys: const ['code', 'name', 'status'],
                  columns: inlineColumns([
                    for (final field in _fields())
                      MasterColumnDef(
                        key: field.key,
                        label: field.label,
                        width: 180,
                        value: (row) => _displayField(row, field),
                      ),
                  ]),
                  items: _warehouseTableRows,
                  selectable: true,
                  idOf: (row) => row.isMain || row.lineSide ? null : row.id,
                  rowKeyOf: (row) => row.id,
                  selectedIds: _selectedWarehouseIds,
                  onSelectedIdsChanged: (ids) =>
                      setState(() => _selectedWarehouseIds = ids),
                  batchActionsBuilder: _warehouseTableActions,
                  facets: const {},
                  nullCounts: const {},
                  filters: const {},
                  onFilterChanged: (_, _) {},
                  onRowTap: inlineEdit.active
                      ? null
                      : (row) async {
                          setState(() {
                            _tableView = false;
                            _selectedWarehouseIds = {};
                          });
                          await _showDetail(row.id);
                        },
                  isLoading: _loading,
                  error: _error,
                  onRetry: _loadWarehouses,
                  emptyMessage: '暂无符合筛选的仓库',
                  toolbarLeadingActions: const [Text('主仓与车间内料仓不可批量启停或删除')],
                ),
              ),
            ],
          ),
        ),
        if (_tableBatchWriting) const UtenBusyOverlay(title: '正在处理仓库资料'),
      ],
    ),
  );

  Widget _detailPane(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (_selectedId == null) {
      return UtenEmpty(
        icon: Icons.warehouse_outlined,
        message: l10n.warehouseMasterSelectHint,
      );
    }
    if (_detailLoading) return const Center(child: CircularProgressIndicator());
    if (_detailError != null) {
      return UtenEmpty.error(
        message: _detailError,
        actionLabel: l10n.commonRetry,
        onAction: () => _showDetail(_selectedId!),
      );
    }
    final detail = _selectedDetail;
    if (detail == null) return const SizedBox.shrink();
    final name = detail.name?.isNotEmpty == true
        ? detail.name!
        : (detail.code ?? l10n.warehouseMasterTitle);
    final remark = detail.remark?.trim();
    final fields = _fields(editing: detail);
    return Padding(
      key: ValueKey('warehouse-master-detail-${detail.id}'),
      padding: EdgeInsets.symmetric(
        horizontal: context.breakpoint.isCompact ? 0 : UtenSpacing.s16,
      ),
      child: UtenCollapsingHeaderScrollView(
        key: ValueKey(detail.id),
        collapsingHeader: Padding(
          padding: const EdgeInsets.only(
            top: UtenSpacing.s16,
            bottom: UtenSpacing.s12,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              UtenHierarchyDetailMenu(
                entriesBuilder: () => _detailDirectoryMenu(detail.id),
                child: MasterDetailCard(
                  key: const Key('warehouse-master-summary'),
                  title: remark == null || remark.isEmpty
                      ? name
                      : '$name ($remark)',
                  subtitle: [
                    if (detail.isMain) l10n.warehouseMasterParentSelf,
                    if (detail.lineSide) l10n.warehouseMasterLineSideManaged,
                  ].join('\n'),
                  icon: Icons.warehouse_outlined,
                  stats: [MasterDetailStat('仓库负责人', _keeperLabel(detail.id))],
                  canEdit: false,
                ),
              ),
              const SizedBox(height: UtenSpacing.s16),
              if (inlineEdit.active && !detail.lineSide)
                MasterInlineRecordEditor<WarehouseDetail>(
                  preferenceNamespace: inlineEntityType,
                  key: ValueKey('warehouse-inline-editor-${detail.id}'),
                  controller: inlineEdit,
                  row: detail,
                  idOf: inlineIdOf,
                  fields: inlineFields,
                  columns: [
                    for (final field in fields)
                      MasterColumnDef(
                        key: field.key,
                        label: field.label,
                        width: 180,
                        value: (row) => _displayField(row, field),
                      ),
                  ],
                )
              else
                MasterReadOnlyFields(
                  key: ValueKey('warehouse-read-only-fields-${detail.id}'),
                  fields: fields,
                  valueOf: (field) => _displayField(detail, field),
                  showGroupHeaders: false,
                ),
            ],
          ),
        ),
        body: WarehouseInventoryPanel(
          warehouse: detail,
          navigationEnabled: !inlineEdit.active,
          primary: true,
          bottomContentPadding: _canCreate || _canEdit
              ? UtenFloatingActionGroup.scrollClearance
              : 0,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => FormDraftDialogResume(
    descriptor: FormDraftCatalog.warehouse,
    onResume: (_) => _showCreate(),
    child: _buildDraftHost(context),
  );

  Widget _buildDraftHost(BuildContext context) {
    ref.watch(currentPermissionsProvider);
    final l10n = AppLocalizations.of(context);
    final selected = _warehouses
        ?.where((warehouse) => warehouse.id == _selectedId)
        .firstOrNull;
    return inlineGuard(
      Scaffold(
        appBar: UtenAppBar(
          title: l10n.warehouseMasterTitle,
          leading: UtenBackButton(
            onPressed: () {
              if (_tableBatchBusy) return;
              inlineNavigate(
                () => backTo(context, defaultPath: RouteName.basicinfo),
              );
            },
          ),
          actions: [
            UtenAppBarActionButton(
              label: _tableView ? '详情视图' : '表格视图',
              onPressed: _tableBatchBusy ? null : _switchWarehouseView,
            ),
            AbsorbPointer(
              absorbing: _tableBatchBusy,
              child: Opacity(
                opacity: _tableBatchBusy ? 0.5 : 1,
                child: MasterOperationHistoryActions(
                  entityType: 'warehouses',
                  recordId: _tableView ? null : _selectedId,
                  onChanged: _refresh,
                ),
              ),
            ),
            UtenPrintPreviewButton(
              enabled: !inlineEdit.active && !_tableBatchBusy,
              title: l10n.warehouseMasterTitle,
              loader: _printLoader,
              exportEndpoint: '/master/warehouses/export',
              exportPermission: Perm.warehouseExport,
              exportReport: '',
              exportQuery: _exportQuery,
              exportFilename: l10n.warehouseMasterTitle,
              icon: null,
            ),
            UtenExportButton(
              enabled: !inlineEdit.active && !_tableBatchBusy,
              endpoint: '/master/warehouses/export',
              requiredPermission: Perm.warehouseExport,
              report: '',
              queryParams: _exportQuery,
              filename: l10n.warehouseMasterTitle,
              icon: null,
            ),
            UtenRefreshButton(
              busy: _loading || _detailLoading || _tableBatchBusy,
              tooltip: l10n.commonRefresh,
              onRefresh: () async {
                if (!_tableBatchBusy) await inlineNavigate(_refresh);
              },
            ),
          ],
        ),
        floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
        floatingActionButtonAnimator: FloatingActionButtonAnimator.noAnimation,
        floatingActionButton: _tableView
            ? null
            : MasterInlineEditActions<WarehouseDetail>(
                controller: inlineEdit,
                canEdit:
                    inlineCanEdit &&
                    inlineReadReady &&
                    (_selectedDetail?.lineSide == false || inlineEdit.active),
                onSave: saveInline,
                additionalActions: [
                  if (_canCreate)
                    UtenButton(
                      size: UtenButtonSize.large,
                      icon: Icons.add_rounded,
                      onPressed: _showCreate,
                      child: Text(l10n.warehouseMasterAdd),
                    ),
                ],
              ),
        body: PopScope(
          canPop: !_tableBatchBusy,
          child: SafeArea(
            child: SelectionArea(
              child: _tableView
                  ? _warehouseTable(context)
                  : UtenSplitView(
                      persistenceKey: 'basicData.warehouse',
                      minTwoPaneWidth: 840,
                      leadingNoun: l10n.warehouseMasterWarehouseLabel,
                      selectedLeadingKey: _selectedId,
                      selectedLeadingLabel: selected?.name,
                      compactHeader: _directoryHeader(context),
                      leading: _directory(context),
                      trailing: _detailPane(context),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class _WarehouseTreeNode extends UtenTreeNode<_WarehouseTreeNode> {
  _WarehouseTreeNode(this.warehouse, this.children);
  final WarehouseListItem warehouse;
  @override
  String get id => warehouse.id;
  @override
  String get name => warehouse.name ?? warehouse.code ?? id;
  @override
  String get code => warehouse.code ?? '';
  @override
  final List<_WarehouseTreeNode> children;
  @override
  bool get hasChildren => children.isNotEmpty;
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
        hintText: '所属车间',
        info: '只可选择生产部直属车间。',
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
      if (!keeper.hasAccount) l10n.warehouseKeeperNoAccount,
      if (keeper.duplicateName) l10n.warehouseKeeperDuplicateName,
    ];
    return UtenEmployeePickerItem(
      id: keeper.employeeId,
      name: keeper.name,
      employeeCode: keeper.code,
      departmentId: keeper.departmentId,
      departmentName: keeper.departmentName,
      accountStatus: keeper.accountStatus,
      employmentStatus: keeper.employmentStatus,
      subtitle: notes.isEmpty ? null : notes.join(' · '),
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
    return UtenAlertDialog(
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
