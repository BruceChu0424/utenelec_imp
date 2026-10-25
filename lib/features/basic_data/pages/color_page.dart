// 颜色资料管理页（基础资料 · 扁平主档，无分类树）。
//
// 与货品/模具/客户/供应商同级，但颜色是扁平字典（编号/名称/状态/备注），
// 故无左树 + 右详情布局，直接：AppBar + 搜索栏 + 全屏主档表格；添加并入右下角悬浮组。
// 复用 MasterDataTableView（搜索/autofilter/分页）+ showMasterEditDialog +
// showMasterDetailSheet，CRUD/详情/并发防护流程与货品 _DetailPane 一致。
// 查看全员可见（路由不设守卫），编辑按 color:edit 权限显隐。
// 文档：见 docs/03-页面/基础资料页.md。
import 'dart:async';

import 'package:flutter/material.dart';
import '../../../shared/drafts/form_draft_dialog_resume.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_refresh_button.dart';
import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/buttons/uten_export_button.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/feedback/uten_dialog.dart';
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
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/action_feedback.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../../../shared/models/paged_result.dart';
import '../models/color_node.dart';
import '../models/master_facet.dart';
import '../models/master_batch.dart';
import '../repositories/color_repository.dart';
import '../repositories/master_batch_repository.dart';
import '../widgets/master_batch_feedback.dart';
import '../widgets/master_data_table_view.dart';
import '../widgets/master_inline_edit.dart';
import '../widgets/master_inline_page_mixin.dart';
import '../widgets/master_operation_history_panel.dart';
import '../widgets/master_detail_sheet.dart';
import '../widgets/master_edit_dialog.dart';
import '../widgets/master_edit_owner.dart';
import '../widgets/master_status_confirmation.dart';

class ColorPage extends ConsumerStatefulWidget {
  const ColorPage({super.key});

  @override
  ConsumerState<ColorPage> createState() => _ColorPageState();
}

class _ColorPageState extends ConsumerState<ColorPage>
    with MasterInlinePageMixin<ColorPage, ColorListItem> {
  @override
  String get inlineEntityType => 'colors';
  @override
  bool get inlineCanEdit => _canEdit;
  @override
  bool get inlineReadReady => !_loading && _error == null;
  @override
  String inlineIdOf(ColorListItem row) => row.id;
  @override
  Future<void> inlineReload() => _loadColors(_pageNum);
  @override
  Future<void> inlineReloadAfterBoundary() => _refresh();
  @override
  void inlineClearView() {
    _page = null;
    _facets = null;
    _error = null;
    _selectedColorIds = {};
    _invalidateOperations();
  }

  @override
  Map<String, MasterInlineField<ColorListItem>> get inlineFields => {
    'name': MasterInlineField(
      key: 'name',
      read: (row) => row.name,
      required: true,
    ),
    'remark': MasterInlineField(key: 'remark', read: (row) => row.remark),
    if (_canStatus)
      'status': MasterInlineField(
        key: 'status',
        read: (row) => row.status,
        type: MasterFieldType.select,
        options: kMasterStatusOptions,
        required: true,
      ),
  };
  PagedResult<ColorListItem>? _page;
  int _pageNum = 1;
  bool _loading = false;
  String? _error;
  final _loadRequests = LatestRequestGuard();

  Map<String, String?> _filters = {};
  String _keyword = '';
  ColorFacets? _facets;

  /// 详情弹窗加载中（防并发）。与 [_loading]（分页列表加载）是两回事。
  bool _detailLoading = false;

  /// 多选选中集（业务 id，跨页保留；批量禁用/删除用）。
  Set<String> _selectedColorIds = {};

  /// 行操作进行中（启停/删除等）防并发。
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
      _loadColors(1);
      _loadFacets();
    });
  }

  bool get _canCreate =>
      ref.read(currentPermissionsProvider).contains(Perm.colorCreate);

  bool get _canEdit =>
      ref.read(currentPermissionsProvider).contains(Perm.colorEdit);

  bool get _canDelete =>
      ref.read(currentPermissionsProvider).contains(Perm.colorDelete);

  bool get _canStatus =>
      ref.read(currentPermissionsProvider).contains(Perm.colorStatus);

  // ---- 分页 -------------------------------------------------------------

  Future<void> _loadColors(int page) async {
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
          .read(colorRepositoryProvider)
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
        _error = '加载颜色列表失败'; // TODO(l10n): 补 arb
        _loading = false;
      });
    }
  }

  /// 拉字段 facet（筛选栏下拉选项）。失败静默降级为空下拉，不阻塞列表。
  Future<void> _loadFacets() async {
    final inlineReadBoundary = ref.read(sensitiveReadBoundaryProvider);
    try {
      final f = await ref.read(colorRepositoryProvider).facets();
      if (!mounted || !inlineAcceptsRead(inlineReadBoundary)) return;
      setState(() => _facets = f);
    } catch (_) {
      // Facets are optional; the primary list remains usable.
    }
  }

  void _onFilterChanged(String key, String? value) {
    setState(() {
      _invalidateOperations();
      _selectedColorIds = {};
      final next = Map<String, String?>.from(_filters);
      if (value == null) {
        next.remove(key);
      } else {
        next[key] = value;
      }
      _filters = next;
    });
    _loadColors(1);
  }

  void _onKeywordChanged(String kw) {
    setState(() {
      _invalidateOperations();
      _selectedColorIds = {};
      _keyword = kw;
    });
    _loadColors(1);
  }

  // ---- 新建/编辑/删除 ---------------------------------------------------

  @override
  MasterInlineCreateConfig get inlineCreation => MasterInlineCreateConfig(
    namespace: 'colors',
    fields: _colorFields()
        .where((field) => field.key != 'status' || _canStatus)
        .toList(),
    defaults: const {'status': '使用'},
    canCreate: _canCreate,
    onCreate: (_, values) async {
      await ref.read(colorRepositoryProvider).create({
        'status': '使用',
        ...values,
      });
    },
  );

  List<MasterFieldDef> _colorFields([String? entityId]) => [
    MasterFieldDef(
      key: 'code',
      label: '颜色编号',
      group: '基础',
      hint: '留空自动生成',
      identifierDomain: 'COLOR',
      identifierId: entityId,
    ),
    const MasterFieldDef(
      key: 'name',
      label: '颜色名称',
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
    const MasterFieldDef(key: 'remark', label: '备注', group: '基础'),
  ];

  Future<void> _showCreate() async {
    if (!_canCreate || _rowOpBusy) return;
    final owner = _operationOwner(Perm.colorCreate);
    try {
      if (!await owner.bindRequests() || !mounted) return;
      await showMasterEditDialog(
        context: context,
        draftSpec: FormDraftCatalog.color.spec(title: '新增颜色'),
        title: '新增颜色', // TODO(l10n): 补 arb
        fields: _colorFields(),
        initialValues: const {'status': '使用'},
        readOnlyKeys: _canStatus ? null : const {'status'},
        submissionOwner: owner,
        onSubmit: (body) async {
          await ref.read(colorRepositoryProvider).create(body);
          return true;
        },
        onAccepted: () {
          if (!owner.isCurrent) return;
          context.appSuccess('颜色已创建');
          unawaited(_loadColors(_pageNum));
        },
      );
    } finally {
      _releaseOwner(owner);
    }
  }

  Future<void> _showEdit(ColorDetail d, {MasterEditOwner? openingOwner}) async {
    if (!_canEdit || _rowOpBusy || inlineEdit.active) return;
    final owner = openingOwner ?? _operationOwner(Perm.colorEdit);
    try {
      if (openingOwner == null && !await owner.bindRequests()) return;
      if (!mounted || !owner.isCurrent) return;
      await showMasterEditDialog(
        context: context,
        title: '编辑颜色', // TODO(l10n): 补 arb
        fields: _colorFields(d.id),
        initialValues: {
          'name': d.name ?? '',
          'code': d.code ?? '',
          'status': d.status ?? '',
          'remark': d.remark ?? '',
        },
        readOnlyKeys: _canStatus ? null : const {'status'},
        submissionOwner: owner,
        onSubmit: (body) async {
          await ref.read(colorRepositoryProvider).update(d.id, body);
          return true;
        },
        onAccepted: () {
          if (!owner.isCurrent) return;
          context.appSuccess('颜色已更新');
          unawaited(_loadColors(_pageNum));
        },
      );
    } finally {
      if (openingOwner == null) _releaseOwner(owner);
    }
  }

  Future<void> _toggleDetailStatus(ColorDetail d) =>
      _batchSetColorStatus({d.id}, d.status == '使用' ? '禁用' : '使用');

  Future<void> _delete(ColorDetail d) => _batchDeleteColors({d.id});

  /// 读取、加载框与详情操作始终属于打开时的身份和查询范围。
  Future<void> _showDetail(String id) async {
    if (_detailLoading) return;
    final owner = _operationOwner(Perm.colorView, write: false);
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
        () => ref.read(colorRepositoryProvider).detail(id),
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
            : (detail.code ?? '颜色详情'),
        rows: _detailRows(detail),
        historyEntityType: 'colors',
        historyRecordId: detail.id,
        onHistoryChanged: () => _loadColors(_pageNum),
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
        context.appError('加载颜色详情失败');
      }
    } finally {
      owner.closeRoute(loadingRoute);
      _releaseOwner(owner);
    }
  }

  List<MasterDetailRow> _detailRows(ColorDetail c) => [
    MasterDetailRow('编号', c.code), // TODO(l10n): 补 arb
    MasterDetailRow('颜色名称', c.name), // TODO(l10n): 补 arb
    MasterDetailRow('状态', c.status), // TODO(l10n): 补 arb
    MasterDetailRow('备注', c.remark),
    MasterDetailRow('旧系统 ID', c.legacyId?.toString()), // TODO(l10n): 补 arb
  ];

  // ---- 行菜单（右击/长按）+ 多选批量 --------------------------------------

  Future<void> _toggleColorStatus(ColorListItem c) =>
      _batchSetColorStatus({c.id}, c.status == '使用' ? '禁用' : '使用');

  Future<void> _editColorRow(ColorListItem row) async {
    if (_rowOpBusy || inlineEdit.active || !inlineReadReady || !_canEdit) {
      return;
    }
    final owner = _operationOwner(Perm.colorEdit);
    _setOperationBusy(owner, true);
    var editorOpened = false;
    try {
      if (!await owner.bindRequests()) return;
      final detail = await owner.run(
        () => ref.read(colorRepositoryProvider).detail(row.id),
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
      if (mounted && owner.isCurrent) context.appError('加载颜色详情失败');
    } finally {
      if (!editorOpened) _releaseOwner(owner);
    }
  }

  /// 行菜单条目（右击/长按弹出）。可用性按权限 + 行状态实时决定。
  /// 多选时右键已勾选的行 → 批量菜单（作用于整个选中集），与主档分类页同形
  /// （2026-10-18 用户口径：批量走右键菜单，工具条不再常驻批量按钮）。
  List<UtenContextMenuEntry> _colorMenuItems(ColorListItem c) {
    final selected = _selectedColorIds;
    if (selected.length > 1 && selected.contains(c.id)) {
      final n = selected.length;
      final idle = _rowOpBusy;
      return [
        UtenMenuItem(
          label: '批量禁用($n)', // TODO(l10n): 补 arb
          icon: Icons.pause_circle_outline_rounded,
          destructive: true,
          enabled: _canStatus && !idle,
          onTap: () => _batchSetColorStatus(selected, '禁用'),
        ),
        UtenMenuItem(
          label: '批量启用($n)', // TODO(l10n): 补 arb
          icon: Icons.play_circle_outline_rounded,
          enabled: _canStatus && !idle,
          onTap: () => _batchSetColorStatus(selected, '使用'),
        ),
        UtenMenuItem(
          label: '批量删除($n)', // TODO(l10n): 补 arb
          icon: Icons.delete_outline_rounded,
          destructive: true,
          enabled: _canDelete && !idle,
          onTap: () => _batchDeleteColors(selected),
        ),
      ];
    }
    final inUse = c.status == '使用';
    return [
      UtenMenuItem(
        label: '查看详情',
        icon: Icons.open_in_new_rounded,
        onTap: () => _showDetail(c.id),
      ),
      const UtenMenuDivider(),
      UtenMenuItem(
        label: inUse ? '禁用颜色' : '启用颜色',
        icon: inUse
            ? Icons.pause_circle_outline_rounded
            : Icons.play_circle_outline_rounded,
        enabled: _canStatus,
        destructive: inUse,
        onTap: () => _toggleColorStatus(c),
      ),
      UtenMenuItem(
        label: '编辑颜色',
        icon: Icons.edit_outlined,
        enabled: _canEdit,
        onTap: () => _editColorRow(c),
      ),
      UtenMenuItem(
        label: '删除颜色',
        icon: Icons.delete_outline_rounded,
        destructive: true,
        enabled: _canDelete,
        onTap: () => _batchDeleteColors({c.id}),
      ),
    ];
  }

  /// 批量启停(ADR-111)：一次请求、一个事务，服务端逐条回原因(原本就是目标状态的不动)。
  Future<void> _batchSetColorStatus(Set<String> ids, String status) async {
    if (_rowOpBusy ||
        inlineEdit.active ||
        !inlineReadReady ||
        !_canStatus ||
        ids.isEmpty) {
      return;
    }
    final targets = Set<String>.unmodifiable(ids);
    final labels = {for (final id in targets) id: _labelOf(id)};
    final owner = _operationOwner(Perm.colorStatus);
    try {
      if (!await owner.bindRequests() || !mounted) return;
      final confirmed = await confirmMasterStatusChange(
        context,
        disabling: status == '禁用',
        label: targets.length == 1 ? (labels[targets.first] ?? '该颜色') : '选中的颜色',
        count: targets.length,
        dialogScopeBuilder: owner.ownDialog,
      );
      if (!confirmed || !owner.isCurrent || _rowOpBusy || !inlineReadReady) {
        return;
      }
      await _runColorBatch(
        owner,
        () => ref
            .read(masterBatchRepositoryProvider)
            .changeStatus(
              entityPath: ApiEndpoints.colors,
              status: status,
              items: [for (final id in targets) MasterBatchItem(id)],
            ),
        action: status == '禁用' ? '禁用' : '启用',
        labels: labels,
      );
    } finally {
      _releaseOwner(owner);
    }
  }

  /// 批量删除(ADR-111)：一次请求；还被货品、组装清单、单据、库存用着的颜色逐条说明原因并保留。
  Future<void> _batchDeleteColors(Set<String> ids) async {
    if (_rowOpBusy ||
        inlineEdit.active ||
        !inlineReadReady ||
        !_canDelete ||
        ids.isEmpty) {
      return;
    }
    final targets = Set<String>.unmodifiable(ids);
    final labels = {for (final id in targets) id: _labelOf(id)};
    final owner = _operationOwner(Perm.colorDelete);
    try {
      if (!await owner.bindRequests() || !mounted) return;
      final ok = await UtenDialog.show(
        context,
        title: ids.length == 1 ? '删除颜色' : '批量删除颜色', // TODO(l10n): 补 arb
        content: Builder(
          builder: (ctx) => owner.ownDialog(
            ctx,
            Text(
              ids.length == 1
                  ? '确定删除「${labels[targets.first] ?? '该颜色'}」吗？'
                  : '确定删除选中的 ${ids.length} 个颜色吗？还在被货品或单据使用的会逐条说明原因并保留。', // TODO(l10n): 补 arb
            ),
          ),
        ),
        confirmLabel: '删除', // TODO(l10n): 补 arb
        danger: true,
      );
      if (ok != true || !owner.isCurrent || _rowOpBusy || !inlineReadReady) {
        return;
      }
      await _runColorBatch(
        owner,
        () => ref
            .read(masterBatchRepositoryProvider)
            .delete(
              entityPath: ApiEndpoints.colors,
              items: [for (final id in targets) MasterBatchItem(id)],
            ),
        action: '删除',
        labels: labels,
      );
    } finally {
      _releaseOwner(owner);
    }
  }

  Future<void> _runColorBatch(
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
      setState(() {
        _selectedColorIds = {
          for (final r in result.results)
            if (!r.ok && _selectedColorIds.contains(r.id)) r.id,
        };
      });
      await showMasterBatchOutcome(
        context,
        result,
        action: action,
        noun: '颜色',
        labelOf: (id) => labels[id],
        dialogScopeBuilder: owner.ownDialog,
      );
      if (!owner.isCurrent) return;
      await _loadColors(_pageNum);
      if (owner.isCurrent &&
          _page != null &&
          _page!.items.isEmpty &&
          _page!.page > 1) {
        await _loadColors(_page!.page - 1);
      }
    } on ApiException catch (e) {
      if (mounted && owner.isCurrent) context.appError(e.message);
    } catch (_) {
      if (mounted && owner.isCurrent) context.appError('$action失败，请稍后重试');
    } finally {
      _setOperationBusy(owner, false);
    }
  }

  String? _labelOf(String id) {
    for (final c in _page?.items ?? const <ColorListItem>[]) {
      if (c.id == id) return c.name?.isNotEmpty == true ? c.name : c.code;
    }
    return null;
  }

  // ---- 列定义 -----------------------------------------------------------

  static final _columns = <MasterColumnDef<ColorListItem>>[
    MasterColumnDef(key: 'code', label: '编号', width: 120, value: (c) => c.code),
    MasterColumnDef(
      key: 'name',
      label: '颜色名称',
      width: 220,
      value: (c) => c.name,
    ),
    MasterColumnDef(
      key: 'status',
      label: '状态',
      width: 72,
      value: (c) => c.status,
    ),
    MasterColumnDef(
      key: 'remark',
      label: '备注',
      width: 260,
      value: (c) => c.remark,
    ),
  ];

  Future<void> _refresh() async {
    _invalidateOperations();
    await Future.wait([_loadColors(1), _loadFacets()]);
  }

  List<Widget> _colorFloatingActions(BuildContext context, Set<String> ids) => [
    MasterInlineEditActions<ColorListItem>(
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
            onPressed: !inlineEdit.active && !_rowOpBusy
                ? () => _batchSetColorStatus(ids, '禁用')
                : null,
            child: const Text('停用选中'),
          ),
          UtenButton(
            type: UtenButtonType.tonal,
            size: UtenButtonSize.large,
            onPressed: !inlineEdit.active && !_rowOpBusy
                ? () => _batchSetColorStatus(ids, '使用')
                : null,
            child: const Text('启用选中'),
          ),
        ],
        if (ids.isNotEmpty && _canDelete)
          UtenButton(
            type: UtenButtonType.danger,
            size: UtenButtonSize.large,
            onPressed: !inlineEdit.active && !_rowOpBusy
                ? () => _batchDeleteColors(ids)
                : null,
            child: const Text('删除选中'),
          ),
        if (_canCreate)
          UtenButton(
            size: UtenButtonSize.large,
            icon: Icons.add_rounded,
            onPressed: _rowOpBusy ? null : () => inlineNavigate(_showCreate),
            child: const Text('添加颜色'),
          ),
      ],
    ),
  ];

  /// 导出查询参数（与 _loadColors 一致，不含 page/size；V717）。
  Map<String, dynamic> get _exportQuery => <String, dynamic>{
    if (_keyword.trim().isNotEmpty) 'keyword': _keyword.trim(),
    ...masterFilterQueryParams(_filters),
  };

  /// 打印预览数据：按当前筛选口径拉全量（上限 2000 行），列/格式化与页面表格一致。
  Future<UtenPrintTable> _printLoader() async {
    final result = await ref
        .read(colorRepositoryProvider)
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

  @override
  Widget build(BuildContext context) => FormDraftDialogResume(
    descriptor: FormDraftCatalog.color,
    onResume: (_) => _showCreate(),
    child: _buildDraftHost(context),
  );

  Widget _buildDraftHost(BuildContext context) {
    ref.watch(currentPermissionsProvider);
    return inlineGuard(
      Scaffold(
        appBar: UtenAppBar(
          title: '颜色资料', // TODO(l10n): 补 arb
          leading: UtenBackButton(
            onPressed: () => inlineNavigate(
              () => backTo(context, defaultPath: RouteName.basicinfo),
            ),
          ),
          actions: [
            MasterOperationHistoryActions(
              entityType: 'colors',
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
                          hint: '搜索颜色(名称/编号)', // TODO(l10n): 补 arb
                          initialValue: _keyword,
                          onChanged: (value) =>
                              inlineNavigate(() => _onKeywordChanged(value)),
                        ),
                      ),
                      Expanded(
                        child: MasterDataTableView<ColorListItem>(
                          appendRowsSource: inlineAppendRowsSource,
                          bottomContentPadding: (_canCreate || _canEdit)
                              ? UtenFloatingActionGroup.scrollClearance
                              : 0,
                          columnEditingEnabled: _canEdit,
                          tableKey:
                              'features.basic_data.pages.color_page.ColorPageState._buildDraftHost.1',
                          columns: inlineColumns(_columns),
                          requiredLeadingColumnKeys: const [
                            'code',
                            'name',
                            'status',
                          ],
                          items: _page?.items ?? const [],
                          // 导出/打印（V717 color:export）：打印预览用本页列渲染，
                          // 导出列集服务端与表格对齐——「表格显示啥导出啥」。
                          // 导出/打印进左簇（2026-10-18 用户口径）：与「表头设置 / 全屏」同排靠左，
                          // 工具条右侧留给分页；按钮纯文字无 icon（工具条无 icon 口径）。
                          toolbarLeadingActions: [
                            UtenPrintPreviewButton(
                              title: '颜色资料', // TODO(l10n): 补 arb
                              subtitle: '最多前 2000 行', // TODO(l10n): 补 arb
                              loader: _printLoader,
                              exportEndpoint: '/master/colors/export',
                              exportPermission: Perm.colorExport,
                              exportReport: '',
                              exportQuery: _exportQuery,
                              exportFilename: '颜色资料', // TODO(l10n): 补 arb
                              type: UtenButtonType.primary,
                              size: UtenButtonSize.large,
                              icon: null,
                            ),
                            UtenExportButton(
                              endpoint: '/master/colors/export',
                              requiredPermission: Perm.colorExport,
                              report: '',
                              queryParams: _exportQuery,
                              filename: '颜色资料', // TODO(l10n): 补 arb
                              label: '导出颜色', // TODO(l10n): 补 arb
                              type: UtenButtonType.primary,
                              size: UtenButtonSize.large,
                              icon: null,
                            ),
                          ],
                          // 多选保留勾选状态；批量启停和删除由右键菜单提供。
                          selectable: true,
                          idOf: (c) => c.id,
                          selectedIds: _selectedColorIds,
                          onSelectedIdsChanged: (s) =>
                              setState(() => _selectedColorIds = s),
                          batchActionsBuilder: _colorFloatingActions,
                          // 行菜单（右击/长按）：查看/启用/禁用/编辑/删除。
                          rowMenuBuilder: inlineEdit.active
                              ? null
                              : _colorMenuItems,
                          facets: _facets?.fields ?? const {},
                          nullCounts: _facets?.nullCounts ?? const {},
                          filters: _filters,
                          onFilterChanged: (key, value) => inlineNavigate(
                            () => _onFilterChanged(key, value),
                          ),
                          // 行底色按状态（ADR-169 收编）：使用=蓝档淡底（裸色收编）/
                          // 禁用=灰档淡底（停用归中性终态，原浅红把「停用」当异常）。
                          rowColor: (c) => switch (c.status) {
                            '使用' => UtenColors.info.withValues(alpha: 0.13),
                            '禁用' => UtenColors.statusNeutral.withValues(
                              alpha: 0.10,
                            ),
                            _ => null,
                          },
                          onRowTap: inlineEdit.active
                              ? null
                              : (c) => _showDetail(c.id),
                          isLoading: _loading && _page == null,
                          loadingMore: _loading && _page != null,
                          error: _error,
                          onRetry: () => _loadColors(_pageNum),
                          emptyMessage: '暂无颜色', // TODO(l10n): 补 arb
                          currentPage: _page?.page ?? 1,
                          totalPages: _page?.totalPages ?? 1,
                          paginationScope: _keyword,
                          onPageChange: (p) =>
                              inlineNavigate(() => _loadColors(p)),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (_rowOpBusy) const UtenBusyOverlay(title: '正在处理颜色'),
          ],
        ),
      ),
    );
  }
}
