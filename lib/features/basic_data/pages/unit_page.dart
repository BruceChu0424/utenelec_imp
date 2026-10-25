// 基本单位资料管理页（基础资料 · 扁平主档，无分类树）。
//
// 与货品/模具/客户/供应商/颜色同级，扁平字典（编号/名称/状态 3 字段）：
// AppBar + 搜索栏 + 全屏主档表格；添加统一在右下角悬浮。复用 MasterDataTableView +
// showMasterEditDialog + showMasterDetailSheet，CRUD/详情/并发防护流程与货品 _DetailPane 一致。
// 查看全员可见（路由不设守卫），编辑按 unit:edit 权限显隐。
// 文档：见 docs/03-页面/基础资料页.md。
import 'dart:async';

import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'package:flutter/material.dart';
import '../../../shared/drafts/form_draft_dialog_resume.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_refresh_button.dart';
import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/buttons/uten_export_button.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/print/uten_print_preview.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/latest_request_guard.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/action_feedback.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../../../shared/models/paged_result.dart';
import '../models/master_facet.dart';
import '../models/unit_node.dart';
import '../models/master_batch.dart';
import '../repositories/master_batch_repository.dart';
import '../repositories/unit_repository.dart';
import '../widgets/master_data_table_view.dart';
import '../widgets/master_inline_edit.dart';
import '../widgets/master_inline_page_mixin.dart';
import '../widgets/master_operation_history_panel.dart';
import '../widgets/master_detail_sheet.dart';
import '../widgets/master_edit_dialog.dart';
import '../widgets/master_edit_owner.dart';
import '../widgets/master_status_confirmation.dart';
import '../widgets/master_batch_feedback.dart';

class UnitPage extends ConsumerStatefulWidget {
  const UnitPage({super.key});

  @override
  ConsumerState<UnitPage> createState() => _UnitPageState();
}

class _UnitPageState extends ConsumerState<UnitPage>
    with MasterInlinePageMixin<UnitPage, UnitListItem> {
  @override
  String get inlineEntityType => 'units';
  @override
  bool get inlineCanEdit => _canEdit;
  @override
  bool get inlineReadReady => !_loading && _error == null;
  @override
  String inlineIdOf(UnitListItem row) => row.id;
  @override
  Future<void> inlineReload() => _loadUnits(_pageNum);
  @override
  Future<void> inlineReloadAfterBoundary() => _refresh();
  @override
  void inlineClearView() {
    _page = null;
    _facets = null;
    _error = null;
    _selectedUnitIds = {};
    _invalidateOperations();
  }

  @override
  Map<String, MasterInlineField<UnitListItem>> get inlineFields => {
    'name': MasterInlineField(
      key: 'name',
      read: (row) => row.name,
      required: true,
    ),
    if (_canStatus)
      'status': MasterInlineField(
        key: 'status',
        read: (row) => row.status,
        type: MasterFieldType.select,
        options: kMasterStatusOptions,
        required: true,
      ),
  };
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
  Set<String> _selectedUnitIds = {};
  bool _rowOpBusy = false;
  int _queryEpoch = 0;
  final _operationOwners = <MasterEditOwner>{};
  MasterEditOwner? _busyOwner;
  MasterEditOwner? _detailOwner;

  MasterEditOwner _operationOwner(String permission, {bool write = true}) {
    final epoch = _queryEpoch;
    final owner = MasterEditOwner(
      context,
      ref,
      permissions: {permission},
      requireWrite: write,
      isCurrent: () => mounted && epoch == _queryEpoch && !inlineEdit.active,
    );
    _operationOwners.add(owner);
    owner.addListener(() {
      if (mounted && !owner.isCurrent) {
        _setOperationBusy(owner, false);
        if (identical(_detailOwner, owner)) {
          _detailOwner = null;
          _detailLoading = false;
        }
      }
    });
    return owner;
  }

  void _setOperationBusy(MasterEditOwner owner, bool busy) {
    if (!mounted || (!busy && !identical(_busyOwner, owner))) return;
    setState(() {
      _busyOwner = busy ? owner : null;
      _rowOpBusy = busy;
    });
  }

  void _invalidateOperations() {
    _queryEpoch++;
    for (final owner in _operationOwners.toList()) {
      owner.invalidate();
    }
    _busyOwner = null;
    _detailOwner = null;
    _rowOpBusy = false;
    _detailLoading = false;
  }

  void _releaseOwner(MasterEditOwner owner) {
    _setOperationBusy(owner, false);
    if (identical(_detailOwner, owner)) {
      _detailOwner = null;
      _detailLoading = false;
    }
    _operationOwners.remove(owner);
    owner.dispose();
  }

  @override
  void dispose() {
    for (final owner in _operationOwners) {
      owner.dispose();
    }
    super.dispose();
  }

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
    if (page != _pageNum) _invalidateOperations();
    final inlineReadBoundary = ref.read(sensitiveReadBoundaryProvider);
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
      if (!mounted ||
          !inlineAcceptsRead(inlineReadBoundary) ||
          !_loadRequests.isCurrent(generation)) {
        return;
      }
      setState(() {
        _page = result;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted ||
          !inlineAcceptsRead(inlineReadBoundary) ||
          !_loadRequests.isCurrent(generation)) {
        return;
      }
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted ||
          !inlineAcceptsRead(inlineReadBoundary) ||
          !_loadRequests.isCurrent(generation)) {
        return;
      }
      setState(() {
        _error = '加载单位列表失败'; // TODO(l10n): 补 arb
        _loading = false;
      });
    }
  }

  /// 拉字段 facet（筛选栏下拉选项）。失败静默降级为空下拉，不阻塞列表。
  Future<void> _loadFacets() async {
    final inlineReadBoundary = ref.read(sensitiveReadBoundaryProvider);
    try {
      final f = await ref.read(unitRepositoryProvider).facets();
      if (!mounted || !inlineAcceptsRead(inlineReadBoundary)) return;
      setState(() => _facets = f);
    } catch (_) {
      // Facets are optional; the primary list remains usable.
    }
  }

  void _onFilterChanged(String key, String? value) {
    setState(() {
      _invalidateOperations();
      _selectedUnitIds = {};
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

  void _onKeywordChanged(String kw) {
    setState(() {
      _invalidateOperations();
      _selectedUnitIds = {};
      _keyword = kw;
    });
    _loadUnits(1);
  }

  // ---- 新建/编辑/删除 ---------------------------------------------------

  List<MasterFieldDef> _unitFields([String? entityId]) => [
    MasterFieldDef(
      key: 'code',
      label: '单位编号',
      group: '基础',
      hint: '留空自动生成',
      identifierDomain: 'UNIT',
      identifierId: entityId,
    ),
    const MasterFieldDef(
      key: 'name',
      label: '单位名称',
      required: true,
      group: '基础',
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

  @override
  MasterInlineCreateConfig get inlineCreation => MasterInlineCreateConfig(
    namespace: 'units',
    fields: _unitFields()
        .where((field) => field.key != 'status' || _canStatus)
        .toList(),
    defaults: const {'status': '使用'},
    canCreate: _canCreate,
    onCreate: (_, values) async {
      await ref.read(unitRepositoryProvider).create({
        'status': '使用',
        ...values,
      });
    },
  );

  Future<void> _showCreate() async {
    if (!_canCreate || _rowOpBusy) return;
    final owner = _operationOwner(Perm.unitCreate);
    try {
      if (!await owner.bindRequests() || !mounted) return;
      await showMasterEditDialog(
        context: context,
        draftSpec: FormDraftCatalog.unit.spec(title: '新增单位'),
        title: '新增单位', // TODO(l10n): 补 arb
        fields: _unitFields(),
        initialValues: const {'status': '使用'},
        readOnlyKeys: _canStatus ? null : const {'status'},
        submissionOwner: owner,
        onSubmit: (body) async {
          await ref.read(unitRepositoryProvider).create(body);
          return true;
        },
        onAccepted: () {
          if (!owner.isCurrent) return;
          context.appSuccess('单位已创建');
          unawaited(_loadUnits(_pageNum));
        },
      );
    } finally {
      _releaseOwner(owner);
    }
  }

  Future<void> _showEdit(UnitDetail d, {MasterEditOwner? openingOwner}) async {
    if (!_canEdit || _rowOpBusy || inlineEdit.active) return;
    final owner = openingOwner ?? _operationOwner(Perm.unitEdit);
    try {
      if (openingOwner == null && !await owner.bindRequests()) return;
      if (!mounted || !owner.isCurrent) return;
      await showMasterEditDialog(
        context: context,
        title: '编辑单位', // TODO(l10n): 补 arb
        fields: _unitFields(d.id),
        initialValues: {
          'name': d.name ?? '',
          'code': d.code ?? '',
          'status': d.status ?? '',
        },
        readOnlyKeys: _canStatus ? null : const {'status'},
        submissionOwner: owner,
        onSubmit: (body) async {
          await ref.read(unitRepositoryProvider).update(d.id, body);
          return true;
        },
        onAccepted: () {
          if (!owner.isCurrent) return;
          context.appSuccess('单位已更新');
          unawaited(_loadUnits(_pageNum));
        },
      );
    } finally {
      if (openingOwner == null) _releaseOwner(owner);
    }
  }

  Future<void> _toggleDetailStatus(UnitDetail d) async {
    await _batchSetUnitStatus({d.id}, d.status == '使用' ? '禁用' : '使用');
  }

  Future<void> _delete(UnitDetail d) => _batchDeleteUnits({d.id});

  /// 读取、加载框与详情操作始终属于打开时的身份和查询范围。
  Future<void> _showDetail(String id) async {
    if (_detailLoading) return;
    final owner = _operationOwner(Perm.unitView, write: false);
    _detailOwner = owner;
    _detailLoading = true;
    ModalRoute<dynamic>? loadingRoute;
    try {
      if (!await owner.bindRequests() || !mounted) return;
      final route = DialogRoute<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) {
          return owner.ownDialog(
            ctx,
            const Center(child: CircularProgressIndicator()),
          );
        },
      );
      loadingRoute = route;
      owner.trackRoute(route);
      unawaited(Navigator.of(context, rootNavigator: true).push(route));
      final detail = await owner.run(
        () => ref.read(unitRepositoryProvider).detail(id),
      );
      final wasLoadingCurrent = loadingRoute.isCurrent;
      owner.closeRoute(loadingRoute);
      if (!wasLoadingCurrent ||
          !mounted ||
          !owner.isCurrent ||
          ModalRoute.of(context)?.isCurrent != true) {
        return;
      }
      await showMasterDetailSheet(
        context: context,
        title: detail.name?.isNotEmpty == true
            ? detail.name!
            : (detail.code ?? '单位详情'),
        rows: _detailRows(detail),
        historyEntityType: 'units',
        historyRecordId: detail.id,
        onHistoryChanged: () => _loadUnits(_pageNum),
        dialogScopeBuilder: owner.ownDialog,
        isCurrent: () => owner.isCurrent,
        canEdit: _canEdit,
        canDelete: _canDelete,
        onToggleStatus: _canStatus
            ? () {
                if (owner.isCurrent) _toggleDetailStatus(detail);
              }
            : null,
        statusActionLabel: detail.status == '使用' ? '停用' : '启用',
        onEdit: () {
          if (owner.isCurrent) _showEdit(detail);
        },
        onDelete: () {
          if (owner.isCurrent) _delete(detail);
        },
      );
    } on ApiException catch (e) {
      final wasLoadingCurrent = loadingRoute?.isCurrent == true;
      owner.closeRoute(loadingRoute);
      if (wasLoadingCurrent &&
          mounted &&
          owner.isCurrent &&
          ModalRoute.of(context)?.isCurrent == true) {
        context.appError(e.message);
      }
    } catch (_) {
      final wasLoadingCurrent = loadingRoute?.isCurrent == true;
      owner.closeRoute(loadingRoute);
      if (wasLoadingCurrent &&
          mounted &&
          owner.isCurrent &&
          ModalRoute.of(context)?.isCurrent == true) {
        context.appError('加载单位详情失败');
      }
    } finally {
      owner.closeRoute(loadingRoute);
      _releaseOwner(owner);
    }
  }

  List<MasterDetailRow> _detailRows(UnitDetail u) => [
    MasterDetailRow('编号', u.code), // TODO(l10n): 补 arb
    MasterDetailRow('单位名称', u.name), // TODO(l10n): 补 arb
    MasterDetailRow('状态', u.status), // TODO(l10n): 补 arb
  ];

  bool get _unitActionsReady =>
      !_rowOpBusy &&
      !inlineEdit.active &&
      !inlineEdit.preparing &&
      inlineReadReady;

  String? _unitLabel(String id) {
    for (final unit in _page?.items ?? const <UnitListItem>[]) {
      if (unit.id == id) {
        return unit.name?.isNotEmpty == true ? unit.name : unit.code;
      }
    }
    return null;
  }

  Future<void> _editUnitRow(UnitListItem unit) async {
    if (!_unitActionsReady || !_canEdit) return;
    final owner = _operationOwner(Perm.unitEdit);
    _setOperationBusy(owner, true);
    var editorOpened = false;
    try {
      if (!await owner.bindRequests()) return;
      final detail = await owner.run(
        () => ref.read(unitRepositoryProvider).detail(unit.id),
      );
      _setOperationBusy(owner, false);
      if (owner.isCurrent) {
        editorOpened = true;
        unawaited(
          _showEdit(
            detail,
            openingOwner: owner,
          ).whenComplete(() => _releaseOwner(owner)),
        );
      }
    } on ApiException catch (e) {
      if (mounted && owner.isCurrent) context.appError(e.message);
    } catch (_) {
      if (mounted && owner.isCurrent) context.appError('加载单位详情失败');
    } finally {
      if (!editorOpened) _releaseOwner(owner);
    }
  }

  List<UtenContextMenuEntry> _unitMenuItems(UnitListItem unit) {
    final selected = Set<String>.unmodifiable(_selectedUnitIds);
    final multiple = selected.length > 1 && selected.contains(unit.id);
    if (multiple) {
      return [
        if (_canStatus) ...[
          UtenMenuItem(
            label: '批量停用(${selected.length})',
            icon: Icons.pause_circle_outline_rounded,
            destructive: true,
            enabled: _unitActionsReady,
            onTap: () => _batchSetUnitStatus(selected, '禁用'),
          ),
          UtenMenuItem(
            label: '批量启用(${selected.length})',
            icon: Icons.play_circle_outline_rounded,
            enabled: _unitActionsReady,
            onTap: () => _batchSetUnitStatus(selected, '使用'),
          ),
        ],
        if (_canDelete)
          UtenMenuItem(
            label: '批量删除(${selected.length})',
            icon: Icons.delete_outline_rounded,
            destructive: true,
            enabled: _unitActionsReady,
            onTap: () => _batchDeleteUnits(selected),
          ),
      ];
    }
    return [
      UtenMenuItem(
        label: '查看详情',
        icon: Icons.open_in_new_rounded,
        enabled: _unitActionsReady,
        onTap: () => _showDetail(unit.id),
      ),
      if (_canEdit)
        UtenMenuItem(
          label: '编辑单位',
          icon: Icons.edit_outlined,
          enabled: _unitActionsReady,
          onTap: () => _editUnitRow(unit),
        ),
      if (_canStatus)
        UtenMenuItem(
          label: unit.status == '禁用' ? '启用单位' : '停用单位',
          icon: unit.status == '禁用'
              ? Icons.play_circle_outline_rounded
              : Icons.pause_circle_outline_rounded,
          destructive: unit.status != '禁用',
          enabled: _unitActionsReady,
          onTap: () =>
              _batchSetUnitStatus({unit.id}, unit.status == '禁用' ? '使用' : '禁用'),
        ),
      if (_canDelete)
        UtenMenuItem(
          label: '删除单位',
          icon: Icons.delete_outline_rounded,
          destructive: true,
          enabled: _unitActionsReady,
          onTap: () => _batchDeleteUnits({unit.id}),
        ),
    ];
  }

  Future<void> _batchSetUnitStatus(Set<String> selected, String status) async {
    if (!_unitActionsReady || !_canStatus || selected.isEmpty) return;
    final ids = Set<String>.unmodifiable(selected);
    final labels = {for (final id in ids) id: _unitLabel(id)};
    final owner = _operationOwner(Perm.unitStatus);
    try {
      if (!await owner.bindRequests() || !mounted) return;
      final confirmed = await confirmMasterStatusChange(
        context,
        disabling: status == '禁用',
        label: ids.length == 1 ? (labels[ids.first] ?? '该单位') : '选中的单位',
        count: ids.length,
        dialogScopeBuilder: owner.ownDialog,
      );
      if (!confirmed || !owner.isCurrent || !_unitActionsReady) return;
      await _runUnitBatch(
        owner,
        () => ref
            .read(masterBatchRepositoryProvider)
            .changeStatus(
              entityPath: ApiEndpoints.units,
              status: status,
              items: [for (final id in ids) MasterBatchItem(id)],
            ),
        action: status == '禁用' ? '停用' : '启用',
        labels: labels,
      );
    } finally {
      _releaseOwner(owner);
    }
  }

  Future<void> _batchDeleteUnits(Set<String> selected) async {
    if (!_unitActionsReady || !_canDelete || selected.isEmpty) return;
    final ids = Set<String>.unmodifiable(selected);
    final labels = {for (final id in ids) id: _unitLabel(id)};
    final owner = _operationOwner(Perm.unitDelete);
    try {
      if (!await owner.bindRequests() || !mounted) return;
      final confirmed = await UtenDialog.show(
        context,
        title: ids.length == 1 ? '删除单位' : '批量删除单位',
        content: Builder(
          builder: (ctx) => owner.ownDialog(
            ctx,
            Text(
              ids.length == 1
                  ? '确定删除「${labels[ids.first] ?? '该单位'}」吗？'
                  : '确定删除选中的 ${ids.length} 个单位吗？被货品或单据引用的单位将保留并显示原因。',
            ),
          ),
        ),
        confirmLabel: '删除',
        danger: true,
      );
      if (confirmed != true || !owner.isCurrent || !_unitActionsReady) return;
      await _runUnitBatch(
        owner,
        () => ref
            .read(masterBatchRepositoryProvider)
            .delete(
              entityPath: ApiEndpoints.units,
              items: [for (final id in ids) MasterBatchItem(id)],
            ),
        action: '删除',
        labels: labels,
      );
    } finally {
      _releaseOwner(owner);
    }
  }

  Future<void> _runUnitBatch(
    MasterEditOwner owner,
    Future<MasterBatchResult> Function() command, {
    required String action,
    required Map<String, String?> labels,
  }) async {
    _setOperationBusy(owner, true);
    try {
      final result = await owner.run(command);
      _setOperationBusy(owner, false);
      if (!mounted || !owner.isCurrent) return;
      setState(
        () => _selectedUnitIds = {
          for (final row in result.results)
            if (!row.ok && _selectedUnitIds.contains(row.id)) row.id,
        },
      );
      await showMasterBatchOutcome(
        context,
        result,
        action: action,
        noun: '单位',
        labelOf: (id) => labels[id],
        dialogScopeBuilder: owner.ownDialog,
      );
      if (!owner.isCurrent) return;
      await Future.wait([_loadUnits(_pageNum), _loadFacets()]);
      if (owner.isCurrent && _page?.items.isEmpty == true && _page!.page > 1) {
        await _loadUnits(_page!.page - 1);
      }
    } on ApiException catch (e) {
      if (mounted && owner.isCurrent) context.appError(e.message);
    } catch (_) {
      if (mounted && owner.isCurrent) context.appError('$action失败，请稍后重试');
    } finally {
      _setOperationBusy(owner, false);
    }
  }

  List<Widget> _unitFloatingActions(BuildContext context, Set<String> ids) => [
    MasterInlineEditActions<UnitListItem>(
      controller: inlineEdit,
      canEdit: _canEdit && inlineReadReady && !_rowOpBusy,
      canCreate: _canCreate && inlineReadReady && !_rowOpBusy,
      onSave: saveInline,
      embedded: true,
      additionalActions: [
        if (ids.isNotEmpty && _canStatus) ...[
          UtenButton(
            type: UtenButtonType.danger,
            size: UtenButtonSize.large,
            onPressed: _unitActionsReady
                ? () => _batchSetUnitStatus(ids, '禁用')
                : null,
            child: const Text('停用选中'),
          ),
          UtenButton(
            type: UtenButtonType.tonal,
            size: UtenButtonSize.large,
            onPressed: _unitActionsReady
                ? () => _batchSetUnitStatus(ids, '使用')
                : null,
            child: const Text('启用选中'),
          ),
        ],
        if (ids.isNotEmpty && _canDelete)
          UtenButton(
            type: UtenButtonType.danger,
            size: UtenButtonSize.large,
            onPressed: _unitActionsReady ? () => _batchDeleteUnits(ids) : null,
            child: const Text('删除选中'),
          ),
        if (_canCreate)
          UtenButton(
            size: UtenButtonSize.large,
            icon: Icons.add_rounded,
            onPressed: _rowOpBusy ? null : () => inlineNavigate(_showCreate),
            child: const Text('添加单位'),
          ),
      ],
    ),
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
      width: 72,
      value: (u) => u.status,
    ),
  ];

  Future<void> _refresh() async {
    _invalidateOperations();
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
    return inlineGuard(
      Scaffold(
        appBar: UtenAppBar(
          title: '基本单位', // TODO(l10n): 补 arb
          leading: UtenBackButton(
            onPressed: () => inlineNavigate(
              () => backTo(context, defaultPath: RouteName.basicinfo),
            ),
          ),
          actions: [
            MasterOperationHistoryActions(
              entityType: 'units',
              onChanged: _refresh,
            ),
            UtenRefreshButton(
              busy: _loading,
              onRefresh: () => inlineNavigate(_refresh),
            ),
          ],
        ),
        body: Stack(
          children: [
            SafeArea(
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
                        child: UtenSearchBar(
                          hint: '搜索单位(名称/编号)', // TODO(l10n): 补 arb
                          initialValue: _keyword,
                          onChanged: (value) =>
                              inlineNavigate(() => _onKeywordChanged(value)),
                        ),
                      ),
                      Expanded(
                        child: MasterDataTableView<UnitListItem>(
                          appendRowsSource: inlineAppendRowsSource,
                          bottomContentPadding: (_canCreate || _canEdit)
                              ? UtenFloatingActionGroup.scrollClearance
                              : 0,
                          columnEditingEnabled: _canEdit,
                          tableKey:
                              'features.basic_data.pages.unit_page.UnitPageState._buildDraftHost.1',
                          columns: inlineColumns(_columns),
                          requiredLeadingColumnKeys: const [
                            'code',
                            'name',
                            'status',
                          ],
                          items: _page?.items ?? const [],
                          selectable: true,
                          idOf: (unit) => unit.id,
                          selectedIds: _selectedUnitIds,
                          onSelectedIdsChanged: (ids) {
                            if (!_rowOpBusy) {
                              setState(() => _selectedUnitIds = ids);
                            }
                          },
                          batchActionsBuilder: _unitFloatingActions,
                          rowMenuBuilder: inlineEdit.active
                              ? null
                              : _unitMenuItems,
                          // 导出/打印（V717 unit:export）：打印预览用本页列渲染，
                          // 导出列集服务端与表格对齐——「表格显示啥导出啥」。
                          // 导出/打印进左簇（2026-10-18 用户口径）：与「表头设置 / 全屏」同排靠左，
                          // 工具条右侧留给分页；按钮纯文字无 icon（工具条无 icon 口径）。
                          toolbarLeadingActions: [
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
                              icon: null,
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
                              icon: null,
                            ),
                          ],
                          facets: _facets?.fields ?? const {},
                          nullCounts: _facets?.nullCounts ?? const {},
                          filters: _filters,
                          onFilterChanged: (key, value) => inlineNavigate(
                            () => _onFilterChanged(key, value),
                          ),
                          onRowTap: inlineEdit.active
                              ? null
                              : (u) => _showDetail(u.id),
                          isLoading: _loading && _page == null,
                          loadingMore: _loading && _page != null,
                          error: _error,
                          onRetry: () => _loadUnits(_pageNum),
                          emptyMessage: '暂无单位', // TODO(l10n): 补 arb
                          currentPage: _page?.page ?? 1,
                          totalPages: _page?.totalPages ?? 1,
                          paginationScope: _keyword,
                          onPageChange: (p) =>
                              inlineNavigate(() => _loadUnits(p)),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (_rowOpBusy) const UtenBusyOverlay(title: '正在处理单位'),
          ],
        ),
      ),
    );
  }
}
