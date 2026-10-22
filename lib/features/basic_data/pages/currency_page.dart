// 币种资料管理页（基础资料 · 扁平主档，无分类树）。
//
// 与颜色/单位同级扁平字典（编号/名称/参考汇率/状态）。复刻 color_page：
// 搜索栏 + MasterDataTableView + 右下角添加 + showMasterEditDialog/DetailSheet。
// 查看全员可见（路由不设守卫），编辑按 currency:edit 显隐。
import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'dart:async';

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
import '../../../core/network/authenticated_request_scope.dart';
import '../../../core/network/latest_request_guard.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/action_feedback.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../../../shared/models/paged_result.dart';
import '../models/currency_node.dart';
import '../models/master_facet.dart';
import '../models/master_batch.dart';
import '../repositories/currency_repository.dart';
import '../repositories/master_status_repository.dart';
import '../widgets/master_data_table_view.dart';
import '../widgets/master_inline_edit.dart';
import '../widgets/master_inline_page_mixin.dart';
import '../widgets/master_operation_history_panel.dart';
import '../widgets/master_detail_sheet.dart';
import '../widgets/master_edit_dialog.dart';
import '../widgets/master_edit_owner.dart';
import '../widgets/master_status_confirmation.dart';
import '../widgets/master_batch_feedback.dart';

class CurrencyPage extends ConsumerStatefulWidget {
  const CurrencyPage({super.key});

  @override
  ConsumerState<CurrencyPage> createState() => _CurrencyPageState();
}

class _CurrencyPageState extends ConsumerState<CurrencyPage>
    with MasterInlinePageMixin<CurrencyPage, CurrencyListItem> {
  @override
  String get inlineEntityType => 'currencies';
  @override
  bool get inlineCanEdit => _canEdit;
  @override
  bool get inlineReadReady => !_loading && _error == null;
  @override
  String inlineIdOf(CurrencyListItem row) => row.id;
  @override
  Future<void> inlineReload() => _loadCurrencies(_pageNum);
  @override
  Future<void> inlineReloadAfterBoundary() => _refresh();
  @override
  void inlineClearView() {
    _page = null;
    _facets = null;
    _error = null;
    _selectedCurrencyIds = {};
    _invalidateOperations();
  }

  @override
  Map<String, MasterInlineField<CurrencyListItem>> get inlineFields => {
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
        enabledOf: (row) => !row.baseCurrency,
      ),
    'exchangeRate': MasterInlineField(
      key: 'exchangeRate',
      read: (row) => row.exchangeRateText ?? row.exchangeRate,
      type: MasterFieldType.money,
      enabledOf: (row) => !row.baseCurrency,
      validate: (value) =>
          value != null && (num.tryParse(value.toString()) ?? 0) <= 0
          ? '汇率必须大于 0'
          : null,
    ),
  };
  PagedResult<CurrencyListItem>? _page;
  Set<String> _selectedCurrencyIds = {};
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

  int _pageNum = 1;
  bool _loading = false;
  String? _error;
  final _loadRequests = LatestRequestGuard();

  Map<String, String?> _filters = {};
  String _keyword = '';
  CurrencyFacets? _facets;
  bool _detailLoading = false;

  // 列排序态（金额/数量/日期列）：null = 默认顺序（code ASC）。
  String? _sortKey;
  bool _sortAsc = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadCurrencies(1);
      _loadFacets();
    });
  }

  bool get _canCreate =>
      ref.read(currentPermissionsProvider).contains(Perm.currencyCreate);

  bool get _canEdit =>
      ref.read(currentPermissionsProvider).contains(Perm.currencyEdit);

  bool get _canDelete =>
      ref.read(currentPermissionsProvider).contains(Perm.currencyDelete);

  bool get _canStatus =>
      ref.read(currentPermissionsProvider).contains(Perm.currencyStatus);

  Future<void> _loadCurrencies(int page) async {
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
          .read(currencyRepositoryProvider)
          .list(
            page: page,
            keyword: _keyword.trim().isEmpty ? null : _keyword,
            filters: _filters,
            sort: _sortKey,
            order: _sortKey == null ? null : (_sortAsc ? 'asc' : 'desc'),
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
        _error = '加载币种列表失败';
        _loading = false;
      });
    }
  }

  Future<void> _loadFacets() async {
    final inlineReadBoundary = ref.read(sensitiveReadBoundaryProvider);
    try {
      final f = await ref.read(currencyRepositoryProvider).facets();
      if (!mounted || !inlineAcceptsRead(inlineReadBoundary)) return;
      setState(() => _facets = f);
    } catch (_) {
      // Facets are optional; the primary list remains usable.
    }
  }

  void _onFilterChanged(String key, String? value) {
    setState(() {
      _invalidateOperations();
      _selectedCurrencyIds = {};
      final next = Map<String, String?>.from(_filters);
      if (value == null) {
        next.remove(key);
      } else {
        next[key] = value;
      }
      _filters = next;
    });
    _loadCurrencies(1);
  }

  void _onKeywordChanged(String kw) {
    setState(() {
      _invalidateOperations();
      _selectedCurrencyIds = {};
      _keyword = kw;
    });
    _loadCurrencies(1);
  }

  void _onSortChange(String? column, bool ascending) {
    setState(() {
      _invalidateOperations();
      _sortKey = column;
      _sortAsc = ascending;
    });
    _loadCurrencies(1); // 排序变化回第 1 页重载
  }

  List<MasterFieldDef> _fields([String? entityId]) => [
    const MasterFieldDef(
      key: 'name',
      label: '币种名称',
      required: true,
      group: '基础',
    ),
    MasterFieldDef(
      key: 'code',
      label: '币种编号',
      group: '基础',
      identifierDomain: 'CURRENCY',
      identifierId: entityId,
      hint: '留空自动生成；已有编号可修改，旧编号不会被复用',
    ),
    const MasterFieldDef(
      key: 'exchangeRate',
      label: '参考汇率',
      group: '基础',
      type: MasterFieldType.money,
      hint: '如 7.2',
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

  Future<void> _showCreate() async {
    if (!_canCreate || _rowOpBusy) return;
    final owner = _operationOwner(Perm.currencyCreate);
    try {
      if (!await owner.bindRequests() || !mounted) return;
      await showMasterEditDialog(
        context: context,
        draftSpec: FormDraftCatalog.currency.spec(title: '新增币种'),
        title: '新增币种',
        fields: _fields(),
        initialValues: const {'status': '使用'},
        readOnlyKeys: _canStatus ? null : const {'status'},
        submissionOwner: owner,
        onSubmit: (body) async {
          await ref.read(currencyRepositoryProvider).create(body);
          return true;
        },
        onAccepted: () {
          if (!owner.isCurrent) return;
          context.appSuccess('币种已创建');
          unawaited(_loadCurrencies(_pageNum));
        },
      );
    } finally {
      _releaseOwner(owner);
    }
  }

  Future<void> _showEdit(
    CurrencyDetail d, {
    MasterEditOwner? openingOwner,
  }) async {
    if (!_canEdit || _rowOpBusy || inlineEdit.active) return;
    final owner = openingOwner ?? _operationOwner(Perm.currencyEdit);
    try {
      if (openingOwner == null && !await owner.bindRequests()) return;
      if (!mounted || !owner.isCurrent) return;
      await showMasterEditDialog(
        context: context,
        title: '编辑币种',
        fields: _fields(d.id),
        initialValues: {
          'name': d.name ?? '',
          'code': d.code ?? '',
          'exchangeRate': d.exchangeRate?.toString() ?? '',
          'status': d.status ?? '',
        },
        readOnlyKeys: {
          if (!_canStatus || d.baseCurrency) 'status',
          if (d.baseCurrency) 'exchangeRate',
        },
        submissionOwner: owner,
        onSubmit: (body) async {
          await ref.read(currencyRepositoryProvider).update(d.id, body);
          return true;
        },
        onAccepted: () {
          if (!owner.isCurrent) return;
          context.appSuccess('币种已更新');
          unawaited(_loadCurrencies(_pageNum));
        },
      );
    } finally {
      if (openingOwner == null) _releaseOwner(owner);
    }
  }

  Future<void> _toggleDetailStatus(CurrencyDetail d) async {
    if (d.baseCurrency) return;
    await _currencyBatch({d.id}, status: d.status == '使用' ? '禁用' : '使用');
  }

  Future<void> _delete(CurrencyDetail d) async {
    if (d.baseCurrency) return;
    await _currencyBatch({d.id});
  }

  Future<void> _showDetail(String id) async {
    if (_detailLoading) return;
    final owner = _operationOwner(Perm.currencyView, write: false);
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
        () => ref.read(currencyRepositoryProvider).detail(id),
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
            : (detail.code ?? '币种详情'),
        rows: _detailRows(detail),
        historyEntityType: 'currencies',
        historyRecordId: detail.id,
        onHistoryChanged: () => _loadCurrencies(_pageNum),
        dialogScopeBuilder: owner.ownDialog,
        isCurrent: () => owner.isCurrent,
        canEdit: _canEdit,
        canDelete: _canDelete && !detail.baseCurrency,
        onToggleStatus: _canStatus && !detail.baseCurrency
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
        context.appError('加载币种详情失败');
      }
    } finally {
      owner.closeRoute(loadingRoute);
      _releaseOwner(owner);
    }
  }

  List<MasterDetailRow> _detailRows(CurrencyDetail c) => [
    MasterDetailRow('币种名称', c.name),
    MasterDetailRow('编号', c.code),
    MasterDetailRow('参考汇率', c.exchangeRate?.toStringAsFixed(4)),
    MasterDetailRow('状态', c.status),
    MasterDetailRow('本位币权威', c.baseCurrency ? '是（受保护，不可改动）' : '否'),
    MasterDetailRow('旧系统 ID', c.legacyId?.toString()),
  ];

  bool get _currencyActionsReady =>
      !_rowOpBusy &&
      !inlineEdit.active &&
      !inlineEdit.preparing &&
      inlineReadReady;

  String? _currencyLabel(String id) {
    for (final currency in _page?.items ?? const <CurrencyListItem>[]) {
      if (currency.id == id) {
        return currency.name?.isNotEmpty == true
            ? currency.name
            : currency.code;
      }
    }
    return null;
  }

  Future<void> _editCurrencyRow(CurrencyListItem row) async {
    if (!_currencyActionsReady || !_canEdit) return;
    final owner = _operationOwner(Perm.currencyEdit);
    _setOperationBusy(owner, true);
    var editorOpened = false;
    try {
      if (!await owner.bindRequests()) return;
      final detail = await owner.run(
        () => ref.read(currencyRepositoryProvider).detail(row.id),
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
      if (mounted && owner.isCurrent) context.appError('加载币种详情失败');
    } finally {
      if (!editorOpened) _releaseOwner(owner);
    }
  }

  List<UtenContextMenuEntry> _currencyMenuItems(CurrencyListItem row) {
    final selected = Set<String>.unmodifiable(_selectedCurrencyIds);
    if (selected.length > 1 && selected.contains(row.id)) {
      return [
        if (_canStatus) ...[
          UtenMenuItem(
            label: '批量停用(${selected.length})',
            icon: Icons.pause_circle_outline_rounded,
            destructive: true,
            enabled: _currencyActionsReady,
            onTap: () => _currencyBatch(selected, status: '禁用'),
          ),
          UtenMenuItem(
            label: '批量启用(${selected.length})',
            icon: Icons.play_circle_outline_rounded,
            enabled: _currencyActionsReady,
            onTap: () => _currencyBatch(selected, status: '使用'),
          ),
        ],
        if (_canDelete)
          UtenMenuItem(
            label: '批量删除(${selected.length})',
            icon: Icons.delete_outline_rounded,
            destructive: true,
            enabled: _currencyActionsReady,
            onTap: () => _currencyBatch(selected),
          ),
      ];
    }
    return [
      UtenMenuItem(
        label: '查看详情',
        icon: Icons.open_in_new_rounded,
        enabled: _currencyActionsReady,
        onTap: () => _showDetail(row.id),
      ),
      if (_canEdit)
        UtenMenuItem(
          label: '编辑币种',
          icon: Icons.edit_outlined,
          enabled: _currencyActionsReady,
          onTap: () => _editCurrencyRow(row),
        ),
      if (row.baseCurrency)
        UtenMenuItem(
          label: '本位币不可停用或删除',
          icon: Icons.lock_outline_rounded,
          enabled: false,
          onTap: () {},
        ),
      if (_canStatus && !row.baseCurrency)
        UtenMenuItem(
          label: row.status == '禁用' ? '启用币种' : '停用币种',
          icon: row.status == '禁用'
              ? Icons.play_circle_outline_rounded
              : Icons.pause_circle_outline_rounded,
          destructive: row.status != '禁用',
          enabled: _currencyActionsReady,
          onTap: () => _currencyBatch({
            row.id,
          }, status: row.status == '禁用' ? '使用' : '禁用'),
        ),
      if (_canDelete && !row.baseCurrency)
        UtenMenuItem(
          label: '删除币种',
          icon: Icons.delete_outline_rounded,
          destructive: true,
          enabled: _currencyActionsReady,
          onTap: () => _currencyBatch({row.id}),
        ),
    ];
  }

  Future<void> _currencyBatch(Set<String> selected, {String? status}) async {
    bool allowed() => status == null ? _canDelete : _canStatus;
    if (!_currencyActionsReady || !allowed() || selected.isEmpty) return;
    final ids = Set<String>.unmodifiable(selected);
    final labels = {for (final id in ids) id: _currencyLabel(id)};
    final owner = _operationOwner(
      status == null ? Perm.currencyDelete : Perm.currencyStatus,
    );
    final action = status == null
        ? '删除'
        : status == '禁用'
        ? '停用'
        : '启用';
    try {
      if (!await owner.bindRequests() || !mounted) return;
      final confirmed = status == null
          ? await UtenDialog.show(
              context,
              title: ids.length == 1 ? '删除币种' : '批量删除币种',
              content: Builder(
                builder: (ctx) => owner.ownDialog(
                  ctx,
                  Text(
                    ids.length == 1
                        ? '确定删除「${labels[ids.first] ?? '该币种'}」吗？'
                        : '确定删除选中的 ${ids.length} 个币种吗？被引用的币种会保留并显示原因。',
                  ),
                ),
              ),
              confirmLabel: '删除',
              danger: true,
            )
          : await confirmMasterStatusChange(
              context,
              disabling: status == '禁用',
              label: ids.length == 1 ? (labels[ids.first] ?? '该币种') : '选中的币种',
              count: ids.length,
              dialogScopeBuilder: owner.ownDialog,
            );
      if (confirmed != true || !owner.isCurrent || !_currencyActionsReady) {
        return;
      }
      _setOperationBusy(owner, true);
      final results = <MasterBatchItemResult>[];
      for (final id in ids) {
        if (!owner.isCurrent) return;
        String? label = labels[id];
        try {
          final current = await owner.run(
            () => ref.read(currencyRepositoryProvider).detail(id),
          );
          label = current.name ?? current.code ?? label;
          if (current.baseCurrency) {
            results.add(
              MasterBatchItemResult(
                id: id,
                ok: false,
                label: label,
                reason: '本位币不可停用或删除',
              ),
            );
            continue;
          }
          if (!owner.isCurrent) return;
          if (status == null) {
            await owner.run(
              () => ref.read(currencyRepositoryProvider).delete(id),
            );
          } else if (current.status != status) {
            await owner.run(
              () => ref
                  .read(masterStatusRepositoryProvider)
                  .change(
                    resourcePath: ApiEndpoints.currency(id),
                    status: status,
                  ),
            );
          }
          results.add(MasterBatchItemResult(id: id, ok: true, label: label));
        } on ApiException catch (error) {
          if (!owner.isCurrent) return;
          if (isSessionBoundaryError(error)) rethrow;
          results.add(
            MasterBatchItemResult(
              id: id,
              ok: false,
              label: label,
              reason: error.message,
            ),
          );
        }
      }
      if (!mounted || !owner.isCurrent) return;
      final result = MasterBatchResult(
        succeeded: results.where((row) => row.ok).length,
        failed: results.where((row) => !row.ok).length,
        results: results,
      );
      _setOperationBusy(owner, false);
      setState(
        () => _selectedCurrencyIds = {
          for (final row in result.results)
            if (!row.ok && _selectedCurrencyIds.contains(row.id)) row.id,
        },
      );
      await showMasterBatchOutcome(
        context,
        result,
        action: action,
        noun: '币种',
        labelOf: (id) => labels[id],
        dialogScopeBuilder: owner.ownDialog,
      );
      if (!owner.isCurrent) return;
      await Future.wait([_loadCurrencies(_pageNum), _loadFacets()]);
      if (owner.isCurrent && _page?.items.isEmpty == true && _page!.page > 1) {
        await _loadCurrencies(_page!.page - 1);
      }
    } on ApiException catch (e) {
      if (mounted && owner.isCurrent) context.appError(e.message);
    } catch (_) {
      if (mounted && owner.isCurrent) context.appError('$action失败，请稍后重试');
    } finally {
      _releaseOwner(owner);
    }
  }

  List<Widget> _currencyFloatingActions(
    BuildContext context,
    Set<String> ids,
  ) => [
    MasterInlineEditActions<CurrencyListItem>(
      controller: inlineEdit,
      canEdit: _canEdit && inlineReadReady && !_rowOpBusy,
      onSave: saveInline,
      embedded: true,
      additionalActions: [
        if (ids.isNotEmpty && _canStatus) ...[
          UtenButton(
            type: UtenButtonType.danger,
            size: UtenButtonSize.large,
            onPressed: _currencyActionsReady
                ? () => _currencyBatch(ids, status: '禁用')
                : null,
            child: const Text('停用选中'),
          ),
          UtenButton(
            type: UtenButtonType.tonal,
            size: UtenButtonSize.large,
            onPressed: _currencyActionsReady
                ? () => _currencyBatch(ids, status: '使用')
                : null,
            child: const Text('启用选中'),
          ),
        ],
        if (ids.isNotEmpty && _canDelete)
          UtenButton(
            type: UtenButtonType.danger,
            size: UtenButtonSize.large,
            onPressed: _currencyActionsReady ? () => _currencyBatch(ids) : null,
            child: const Text('删除选中'),
          ),
        if (_canCreate)
          UtenButton(
            size: UtenButtonSize.large,
            icon: Icons.add_rounded,
            onPressed: _rowOpBusy ? null : () => inlineNavigate(_showCreate),
            child: const Text('添加币种'),
          ),
      ],
    ),
  ];

  static final _columns = <MasterColumnDef<CurrencyListItem>>[
    MasterColumnDef(
      key: 'status',
      label: '状态',
      width: 72,
      value: (c) => c.status,
    ),
    MasterColumnDef(key: 'code', label: '编号', width: 120, value: (c) => c.code),
    MasterColumnDef(
      key: 'name',
      label: '币种名称',
      width: 200,
      value: (c) => c.name,
    ),
    MasterColumnDef(
      key: 'exchangeRate',
      label: '参考汇率',
      width: 140,
      type: 'money',
      sortable: true,
      value: (c) => c.exchangeRate?.toStringAsFixed(4),
    ),
  ];

  Future<void> _refresh() async {
    _invalidateOperations();
    await Future.wait([_loadCurrencies(1), _loadFacets()]);
  }

  /// 导出查询参数（与 _loadCurrencies 一致，不含 page/size）。
  Map<String, dynamic> get _exportQuery => <String, dynamic>{
    if (_keyword.trim().isNotEmpty) 'keyword': _keyword.trim(),
    ...masterFilterQueryParams(_filters),
    if (_sortKey != null) 'sort': _sortKey,
    if (_sortKey != null) 'order': _sortAsc ? 'asc' : 'desc',
  };

  /// 打印预览数据：按当前筛选口径拉全量（上限 2000 行），列/格式化与页面表格一致。
  Future<UtenPrintTable> _printLoader() async {
    final result = await ref
        .read(currencyRepositoryProvider)
        .list(
          size: 2000,
          keyword: _keyword.trim().isEmpty ? null : _keyword,
          filters: _filters,
          sort: _sortKey,
          order: _sortKey == null ? null : (_sortAsc ? 'asc' : 'desc'),
        );
    return UtenPrintTable(
      columnKeys: [for (final c in _columns) c.key],
      rowIds: [for (final a in result.items) a.id],
      headers: [for (final c in _columns) c.label],
      rows: [
        for (final a in result.items)
          [for (final c in _columns) c.value(a) ?? ''],
      ],
    );
  }

  @override
  Widget build(BuildContext context) => FormDraftDialogResume(
    descriptor: FormDraftCatalog.currency,
    onResume: (_) => _showCreate(),
    child: _buildDraftHost(context),
  );

  Widget _buildDraftHost(BuildContext context) {
    ref.watch(currentPermissionsProvider);
    return inlineGuard(
      Scaffold(
        appBar: UtenAppBar(
          title: '币种资料',
          leading: UtenBackButton(
            onPressed: () => inlineNavigate(
              () => backTo(context, defaultPath: RouteName.basicinfo),
            ),
          ),
          actions: [
            MasterOperationHistoryActions(
              entityType: 'currencies',
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
                          hint: '搜索币种(名称/编号)',
                          initialValue: _keyword,
                          onChanged: (value) =>
                              inlineNavigate(() => _onKeywordChanged(value)),
                        ),
                      ),
                      Expanded(
                        child: MasterDataTableView<CurrencyListItem>(
                          bottomContentPadding: (_canCreate || _canEdit)
                              ? UtenFloatingActionGroup.scrollClearance
                              : 0,
                          columnEditingEnabled: _canEdit,
                          tableKey:
                              'features.basic_data.pages.currency_page.CurrencyPageState._buildDraftHost.1',
                          columns: inlineColumns(_columns),
                          requiredLeadingColumnKeys: const [
                            'code',
                            'name',
                            'status',
                          ],
                          items: _page?.items ?? const [],
                          selectable: true,
                          idOf: (currency) =>
                              currency.baseCurrency ? null : currency.id,
                          selectedIds: _selectedCurrencyIds,
                          onSelectedIdsChanged: (ids) {
                            if (!_rowOpBusy) {
                              setState(() => _selectedCurrencyIds = ids);
                            }
                          },
                          batchActionsBuilder: _currencyFloatingActions,
                          rowMenuBuilder: inlineEdit.active
                              ? null
                              : _currencyMenuItems,
                          // 导出/打印进左簇（2026-10-18 用户口径）：与「表头设置 / 全屏」同排靠左，
                          // 工具条右侧留给分页；按钮纯文字无 icon（工具条无 icon 口径）。
                          toolbarLeadingActions: [
                            UtenPrintPreviewButton(
                              title: '币种资料',
                              subtitle: '最多前 2000 行',
                              loader: _printLoader,
                              exportEndpoint: '/master/currencies/export',
                              exportPermission: Perm.currencyExport,
                              exportReport: '',
                              exportQuery: _exportQuery,
                              exportFilename: '币种资料',
                              type: UtenButtonType.primary,
                              size: UtenButtonSize.large,
                              icon: null,
                            ),
                            UtenExportButton(
                              endpoint: '/master/currencies/export',
                              requiredPermission: Perm.currencyExport,
                              report: '',
                              queryParams: _exportQuery,
                              filename: '币种资料',
                              label: '导出币种',
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
                              : (c) => _showDetail(c.id),
                          sortColumn: _sortKey,
                          sortAscending: _sortAsc,
                          onSortChange: (key, ascending) => inlineNavigate(
                            () => _onSortChange(key, ascending),
                          ),
                          isLoading: _loading && _page == null,
                          loadingMore: _loading && _page != null,
                          error: _error,
                          onRetry: () => _loadCurrencies(_pageNum),
                          emptyMessage: '暂无币种',
                          currentPage: _page?.page ?? 1,
                          totalPages: _page?.totalPages ?? 1,
                          paginationScope: _keyword,
                          onPageChange: (p) =>
                              inlineNavigate(() => _loadCurrencies(p)),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (_rowOpBusy) const UtenBusyOverlay(title: '正在处理币种'),
          ],
        ),
      ),
    );
  }
}
