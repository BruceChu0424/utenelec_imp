// 分类主档页的右侧明细区(客户/供应商/模具/货品四页共用，ADR-111)。
//
// 四页原先各写一遍整段 _DetailPane(加载/分页/筛选/排序/打印导出/启停/删除/批量)，
// 方法同名同构、差异只在实体名与文案；批量启停/删除还在前端逐条循环调单条接口
// (选 100 条就是 200 次串行请求，失败 catch 吞掉只报「N 个跳过」)。
//
// 现在明细区只有这一份：
// - 分类信息卡(标题=名称（备注）(数量: N)) + 本地搜索 + MasterDataTableView
//   (表头筛选/排序/分页/多选)；卡上无按钮——分类增/改/删在左树行内(图标+右键
//   菜单，2026-10-19 用户口径)，系统根锁说明仍在卡上；
// - 页面特有按钮(导入货品)与预览打印/导出进表格工具条左簇（「表头设置/全屏」
//   右侧，纯文字无 icon，2026-10-19 用户口径）；
// - 右下悬浮组只挂「已选 N 项 + 添加X」（2026-10-18 用户口径：添加按钮悬浮在
//   右下角紧挨已选计数，原「X (N) + 添加X」标题行整行删除，数量移到分类卡片）；
// - 行启停走单条窄命令(PATCH /status，带列表行版本，不再先拉详情)；
// - 行删除、批量启停、批量删除走服务端批量命令(一次请求、一个事务、逐条原因)，
//   结果经 showMasterBatchOutcome 逐条展示；
// - 批量操作全部走右键菜单(多选时出批量项，与货品页同形)，工具条不再常驻
//   批量按钮（2026-10-18 用户口径：表格可右键操作，常驻批量按钮冗余）；
// - 各页只给 [MasterEntityPaneConfig]：列、仓储闭包、文案、权限，以及特有动作
//   (客户负责人/可见人、货品复制粘贴与组件信息、模具详情弹层)。
import 'package:flutter/material.dart';
import 'basic_data_l10n.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:convert';

import '../../../components/buttons/uten_button.dart';
import '../../../components/buttons/uten_export_button.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/print/uten_print_preview.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/latest_request_guard.dart';
import '../../../core/router/page_search_lifecycle.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/action_feedback.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/providers/authenticated_scope_provider.dart';
import '../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../../../shared/auth/sensitive_write.dart';
import '../../../shared/widgets/master_detail_card.dart';
import '../models/master_batch.dart';
import '../models/master_facet.dart';
import '../models/product_category_node.dart';
import '../repositories/master_batch_repository.dart';
import '../repositories/master_status_repository.dart';
import 'master_batch_feedback.dart';
import 'master_data_table_view.dart';
import 'master_inline_edit.dart';
import 'system_master_category_guard.dart';
import 'master_status_confirmation.dart';

class _PaneWriteResult<T> {
  const _PaneWriteResult(this.value, this.isCurrent, this.dialogScope);
  final T value;
  final bool Function() isCurrent;
  final Widget Function(BuildContext, Widget) dialogScope;
}

/// 明细列表的一次查询条件。[forPrint] 为打印预览全量拉取(货品页据此保持禁用品口径)。
class MasterPaneQuery {
  const MasterPaneQuery({
    required this.categoryId,
    this.page = 1,
    this.size,
    this.keyword,
    this.filters = const {},
    this.sort,
    this.order,
    this.forPrint = false,
  });

  final String? categoryId;
  final int page;
  final int? size;
  final String? keyword;
  final Map<String, String?> filters;
  final String? sort;
  final String? order;
  final bool forPrint;

  bool get hasKeyword => keyword != null && keyword!.trim().isNotEmpty;
}

/// 表头筛选桶 + 空值计数(各主档 facets 同形)。
class MasterPaneFacets {
  const MasterPaneFacets({required this.fields, required this.nullCounts});

  final Map<String, List<MasterFacetBucket>> fields;
  final Map<String, int> nullCounts;
}

/// 打印/导出按钮配置：挂上后预览打印 + 加密导出进表格工具条左簇
/// （「表头设置 / 全屏」右侧，纯文字无 icon，2026-10-19 起四页统一——
/// 原货品页放分类信息卡的 inCard 口径退役）。
class MasterPaneExport {
  const MasterPaneExport({
    required this.title,
    required this.endpoint,
    required this.permission,
    required this.label,
    this.extraQuery = const {},
    this.queryParamsOf,
    this.contactSensitiveInBody = false,
  });

  final String title;
  final String endpoint;
  final String permission;
  final String label;
  final Map<String, dynamic> extraQuery;
  final Map<String, dynamic> Function(MasterPaneQuery query)? queryParamsOf;

  /// 客户/供应商(security-19, ADR-110)：搜索关键字(会匹配手机号)与手机/电话/银行账号的筛选值
  /// 只随导出请求体的 `sensitiveFilter` 发送，不进 URL 查询串(反向代理访问日志会整行记下查询串)。
  final bool contactSensitiveInBody;
}

/// 明细区对页面暴露的操作面(页面的特有动作经它刷新列表、读选中、跑批量命令)。
abstract interface class MasterEntityPaneController<TItem, TDetail> {
  String? get categoryId;
  ProductCategoryDetail? get category;
  PagedResult<TItem>? get page;
  int get pageNum;
  Set<String> get selectedIds;
  bool get busy;

  /// 重拉当前页(以及前导分组)；[page] 为空时留在当前页。
  Future<void> reload({int? page});

  /// 当前页加载完成后滚到列表末尾，供追加/粘贴完成后的定位使用。
  void scrollToEnd();

  /// Locate an affected record using the current authoritative sort and filters.
  Future<bool> reveal(String id);

  /// 用业务操作的结果替换选择集（例如本次成功粘贴的新货品）。
  void selectIds(Iterable<String> ids);
  void clearSelection();

  /// 行操作互斥(防连点)：已有操作在跑时直接返回 null。
  Future<T?> runExclusive<T>(Future<T> Function() action);

  /// 拉详情后执行(编辑等)；对象只读时提示原因不执行。
  Future<void> withDetail(
    String id,
    Future<void> Function(TDetail detail) action,
  );

  Future<void> toggleStatus(TItem row);
  Future<void> batchSetStatus(Set<String> ids, String status);
  Future<void> batchDelete(Set<String> ids);
}

/// 一张分类主档页右侧明细区的全部差异点。
class MasterEntityPaneConfig<TItem, TDetail> {
  const MasterEntityPaneConfig({
    required this.noun,
    required this.icon,
    required this.defaultCodePrefix,
    required this.columns,
    required this.idOf,
    required this.statusOf,
    required this.labelOf,
    required this.loadCategory,
    required this.loadPage,
    required this.loadFacets,
    this.loadGlobalFacets,
    this.loadQueryFacets,
    this.loadFacetPage,
    required this.batchEntityPath,
    required this.statusResourceOf,
    required this.canCreate,
    required this.canEdit,
    required this.canDelete,
    required this.canStatus,
    this.versionOf,
    this.writableOf,
    this.readOnlyRowHint,
    this.defaultSortKey,
    this.rowColor,
    this.locatePage,
    this.columnOfFacetField = const {},
    this.filterParamOfColumn = const {},
    this.export,
    this.onCreate,
    this.onOpen,
    this.loadDetail,
    this.onEdit,
    this.detailReadOnlyHint,
    this.extraMenuItems,
    this.rowMenuOverride,
    this.backgroundMenuBuilder,
    this.extraBatchMenuItems,
    this.toolbarLeadingActions,
    this.loadLeadingGroups,
    this.inlineFields = const {},
    this.onInlineSave,
    this.inlineCreation,
    this.inlineCancelLabel,
    this.inlineDiscardNote,
    this.readStableWritePermission,
  });

  /// 面向人的实体名(客户/供应商/模具/货品)。
  final String noun;
  final IconData icon;
  final String defaultCodePrefix;
  final List<MasterColumnDef<TItem>> columns;
  final Map<String, MasterInlineField<TItem>> inlineFields;
  final MasterInlineCreateConfig Function(
    MasterEntityPaneController<TItem, TDetail> pane,
  )?
  inlineCreation;
  final String? inlineCancelLabel;
  final String? inlineDiscardNote;
  final String? readStableWritePermission;
  final Future<void> Function(
    String id,
    Map<String, dynamic> patch,
    TItem originalRow,
  )?
  onInlineSave;
  final String Function(TItem row) idOf;
  final String? Function(TItem row) statusOf;
  final String Function(TItem row) labelOf;
  final int? Function(TItem row)? versionOf;

  /// 对象级写权限(客户)；为空表示行都可写。
  final bool Function(TItem row)? writableOf;
  final String Function(TItem row)? readOnlyRowHint;

  final Future<ProductCategoryDetail> Function(String categoryId) loadCategory;
  final Future<PagedResult<TItem>> Function(MasterPaneQuery query) loadPage;
  final Future<MasterPaneFacets> Function(String categoryId) loadFacets;
  final Future<MasterPaneFacets> Function()? loadGlobalFacets;
  final Future<MasterPaneFacets> Function(MasterPaneQuery query)?
  loadQueryFacets;
  final Future<MasterFacetPage> Function(
    MasterPaneQuery query,
    String field,
    String search,
    int page,
  )?
  loadFacetPage;

  /// 主档集合路径(ApiEndpoints.clients 等)，批量命令拼 /batch-status、/batch-delete。
  final String batchEntityPath;

  /// 单条资源路径(ApiEndpoints.client(id) 等)，行启停拼 /status。
  final String Function(String id) statusResourceOf;

  final bool canCreate;
  final bool canEdit;
  final bool canDelete;
  final bool canStatus;
  final String? defaultSortKey;
  final Color? Function(TItem item)? rowColor;
  final Future<int?> Function(MasterPaneQuery query, String id)? locatePage;

  /// 服务端 facet 字段 → 表格列 key(如 empId → ownerEmployeeName)。
  final Map<String, String> columnOfFacetField;

  /// 表格列 key → 服务端筛选参数名(如 ownerEmployeeName → ownerEmployeeId)。
  final Map<String, String> filterParamOfColumn;
  final MasterPaneExport? export;

  final Future<void> Function(MasterEntityPaneController<TItem, TDetail> pane)?
  onCreate;
  final Future<void> Function(
    MasterEntityPaneController<TItem, TDetail> pane,
    TItem row,
  )?
  onOpen;
  final Future<TDetail> Function(String id)? loadDetail;
  final Future<void> Function(
    MasterEntityPaneController<TItem, TDetail> pane,
    TDetail detail,
  )?
  onEdit;
  final String? Function(TDetail detail)? detailReadOnlyHint;

  /// 默认行菜单里插在「编辑」与「删除」之间的特有动作。
  final List<UtenContextMenuEntry> Function(
    MasterEntityPaneController<TItem, TDetail> pane,
    TItem row,
  )?
  extraMenuItems;

  /// 整个行菜单由页面接管(货品页：复制/粘贴/组件信息与多选菜单)。
  final List<UtenContextMenuEntry> Function(
    MasterEntityPaneController<TItem, TDetail> pane,
    TItem row,
  )?
  rowMenuOverride;

  /// 不依赖货品/客户等数据行的列表操作，空分类仍可使用（例如粘贴货品）。
  final List<UtenContextMenuEntry> Function(
    MasterEntityPaneController<TItem, TDetail> pane,
  )?
  backgroundMenuBuilder;

  /// 多选右键批量菜单里的页面特有条目（客户：批量设负责人/可见人），
  /// 排在默认批量启停/删除之后。批量操作只走右键菜单，不再常驻工具条按钮。
  final List<UtenContextMenuEntry> Function(
    MasterEntityPaneController<TItem, TDetail> pane,
    Set<String> ids,
  )?
  extraBatchMenuItems;

  /// 表格工具条左簇的页面特有按钮（货品页：导入货品），排在预览打印/导出之前，
  /// 与「表头设置 / 全屏」同一簇同一形态（纯文字无 icon）。
  final List<Widget> Function(MasterEntityPaneController<TItem, TDetail> pane)?
  toolbarLeadingActions;

  /// 表头下前导分组(货品页：禁用货品 / 不明货品)，随列表一起重拉。
  final Future<List<MasterDataGroup<TItem>>> Function(
    MasterPaneQuery query,
    ProductCategoryDetail category,
  )?
  loadLeadingGroups;
}

class MasterEntityDetailPane<TItem, TDetail> extends ConsumerStatefulWidget {
  const MasterEntityDetailPane({
    super.key,
    required this.config,
    required this.categoryId,
    required this.externalKeyword,
    this.externalSearchPending = false,
  });

  final MasterEntityPaneConfig<TItem, TDetail> config;
  final String? categoryId;

  /// 顶部树搜索命中内容时传入的过滤词：采纳为本地列表搜索词，右侧只显示搜索结果。
  final String? externalKeyword;

  /// Invalidates old reads immediately while the shared search debounces.
  final bool externalSearchPending;

  @override
  ConsumerState<MasterEntityDetailPane<TItem, TDetail>> createState() =>
      _MasterEntityDetailPaneState<TItem, TDetail>();
}

class _MasterEntityDetailPaneState<TItem, TDetail>
    extends ConsumerState<MasterEntityDetailPane<TItem, TDetail>>
    implements MasterEntityPaneController<TItem, TDetail> {
  final _tableRows = MasterDataTableRowsController<TItem>();
  final _inlineEdit = MasterInlineEditController<TItem>();
  bool _inlineModeActive = false;
  ProviderSubscription<SensitiveReadBoundary>? _inlineIdentitySubscription;
  final _categoryRequests = LatestRequestGuard();
  final _listRequests = LatestRequestGuard();
  final _groupRequests = LatestRequestGuard();
  final _facetRequests = LatestRequestGuard();

  ProductCategoryDetail? _category;
  bool _loading = true;
  bool _retainingReadShell = false;
  int _queryVersion = 0;
  // Typing invalidates commands immediately, but the displayed page window
  // changes only when a replacement query is actually committed.
  int _tableQueryVersion = 0;
  String? _error;

  PagedResult<TItem>? _page;
  int _pageNum = 1;
  bool _listLoading = false;
  bool _displayedQueryStale = false;
  String? _listError;
  List<MasterDataGroup<TItem>> _groups = const [];

  Map<String, String?> _filters = {};
  String _keyword = '';
  MasterPaneFacets? _facets;
  String? _sortKey;
  bool _sortAsc = true;
  Set<String> _selectedIds = {};
  bool _busy = false;
  bool _lifecycleWriting = false;
  int _writeEpoch = 0;
  final Set<PopupRoute<dynamic>> _writeDialogs = {};
  late final _writeLifecycle = PageSearchLifecycle(
    onLeave: _invalidateWrites,
    onReturn: () {},
  );
  int _scrollToEndRequest = 0;
  String? _revealItemId;
  int _revealRequest = 0;

  /// 折叠滚动外层控制器：滚到底请求时联动收起分类卡（见
  /// [_revealOuterScrollToEnd]）。
  final ScrollController _outerScroll = ScrollController();

  MasterEntityPaneConfig<TItem, TDetail> get _c => widget.config;

  bool get _queryPending =>
      widget.externalSearchPending || _displayedQueryStale;

  @override
  void initState() {
    super.initState();
    _inlineEdit.addListener(_inlineChanged);
    _inlineIdentitySubscription = ref.listenManual(
      sensitiveReadBoundaryProvider,
      (previous, next) {
        if (!mounted || previous == next) return;
        _invalidateWrites();
        final retainShell =
            !_loading &&
            _error == null &&
            (widget.categoryId == null || _category != null) &&
            canRetainMasterReadShell(
              previous,
              next,
              writeOnlyPermission: _c.readStableWritePermission,
            );
        _inlineEdit.cancel();
        _categoryRequests.begin();
        _listRequests.begin();
        _groupRequests.begin();
        _facetRequests.begin();
        setState(() {
          // Clear every old DTO/window even when only presentation survives.
          _queryVersion++;
          _tableQueryVersion++;
          _category = null;
          _page = null;
          _groups = const [];
          _facets = null;
          _selectedIds = {};
          _error = null;
          _listError = null;
          _listLoading = true;
          _retainingReadShell = retainShell;
          _loading = !retainShell;
        });
        // Let the host rebuild repository closures for the new API/identity
        // before starting replacement reads. The old requests are fenced above.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && ref.read(sensitiveReadBoundaryProvider) == next) {
            _load(retainReadShell: retainShell);
          }
        });
      },
    );
    _sortKey = _c.defaultSortKey;
    _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _writeLifecycle.attach(context);
  }

  @override
  void dispose() {
    _writeLifecycle.dispose();
    _invalidateWrites();
    _inlineIdentitySubscription?.close();
    _inlineEdit.removeListener(_inlineChanged);
    _inlineEdit.dispose();
    _outerScroll.dispose();
    super.dispose();
  }

  void _inlineChanged() {
    if (_inlineModeActive == _inlineEdit.active) return;
    _inlineModeActive = _inlineEdit.active;
    if (mounted) setState(() {});
  }

  Future<void> _saveInlineRow(String id, Map<String, dynamic> patch) async {
    if (_listError != null) {
      throw StateError('已完成的行已保存；列表刷新失败，请先重新加载后再保存其余修改');
    }
    final save = _c.onInlineSave;
    final baseline = _inlineEdit.baselineOf(id);
    if (!_c.canEdit || save == null || baseline == null) {
      throw StateError('当前资料不可编辑，请刷新后重试');
    }
    await runSensitiveWrite(
      ref,
      isCurrent: () => mounted && _c.canEdit && _listError == null,
      write: () => save(id, patch, baseline),
    );
    // This callback is awaited before the controller advances to another row.
    // Refresh each completed row's server version, including partial success.
    if (mounted) {
      await reload();
      if (mounted && _listError != null) {
        setState(() {
          _listError = '修改已保存，但列表刷新失败。请重新加载后继续编辑，不要重复保存。\n$_listError';
        });
      }
    }
  }

  void _configureInlineCreation() {
    final builder = _c.inlineCreation;
    final categoryId = widget.categoryId;
    final config = builder == null || widget.categoryId == null
        ? null
        : builder(this);
    _inlineEdit.configureCreation(
      config == null
          ? null
          : MasterInlineCreateConfig(
              namespace: config.namespace,
              fields: config.fields,
              defaults: config.defaults,
              emptyRows: config.emptyRows,
              columnFields: config.columnFields,
              canCreate: _c.canCreate && config.canCreate,
              onCreate: (key, values) async {
                if (!_c.canCreate ||
                    _listError != null ||
                    categoryId == null ||
                    widget.categoryId != categoryId) {
                  throw ApiException('FORBIDDEN', '当前分类或新增权限已变化，请刷新后重试');
                }
                await runSensitiveWrite(
                  ref,
                  isCurrent: () =>
                      mounted &&
                      _c.canCreate &&
                      widget.categoryId == categoryId &&
                      _listError == null,
                  write: () => config.onCreate(key, values),
                );
              },
              afterSave: () async {
                if (!mounted || widget.categoryId != categoryId) return;
                await config.afterSave?.call();
                await reload();
                if (mounted && _listError != null) {
                  throw StateError(
                    'Confirmed creation refresh did not restore the readable list',
                  );
                }
              },
            ),
    );
  }

  @override
  void didUpdateWidget(MasterEntityDetailPane<TItem, TDetail> old) {
    super.didUpdateWidget(old);
    if (widget.externalSearchPending) {
      _invalidateWrites();
      _queryVersion++;
      _categoryRequests.begin();
      _listRequests.begin();
      _groupRequests.begin();
      _facetRequests.begin();
      // Keep the last rendered rows mounted while the replacement query
      // debounces. The pane blocks all interaction with that stale snapshot.
      _displayedQueryStale = _page != null;
      _listLoading = false;
      _selectedIds = {};
      _listError = null;
      return;
    }
    if (old.categoryId != widget.categoryId ||
        (old.externalSearchPending &&
            widget.categoryId != null &&
            _category == null)) {
      _load();
      return;
    }
    if (old.externalKeyword != widget.externalKeyword ||
        old.externalSearchPending) {
      _queryVersion++;
      _tableQueryVersion++;
      setState(() {
        _loading = false;
        _displayedQueryStale = _page != null;
        _groups = const [];
        _facets = null;
        _filters = {};
        _sortKey = _c.defaultSortKey;
        _sortAsc = true;
        _selectedIds = {};
        _keyword = widget.externalKeyword ?? '';
      });
      reload(page: 1);
      if (old.externalSearchPending && _c.loadQueryFacets == null) {
        _loadFacets();
      }
    }
  }

  // ---- MasterEntityPaneController ----------------------------------------

  @override
  String? get categoryId => widget.categoryId;

  @override
  ProductCategoryDetail? get category => _category;

  @override
  PagedResult<TItem>? get page => _page;

  @override
  int get pageNum => _pageNum;

  @override
  Set<String> get selectedIds => _selectedIds;

  @override
  bool get busy => _busy || _queryPending || _inlineEdit.active;

  @override
  void scrollToEnd() {
    if (!mounted ||
        _listLoading ||
        _listError != null ||
        (_page?.items.isEmpty ?? true)) {
      return;
    }
    setState(() => _scrollToEndRequest++);
    _revealOuterScrollToEnd();
  }

  @override
  Future<bool> reveal(String id) async {
    final locator = _c.locatePage;
    if (locator == null || busy) return false;
    final queryVersion = _queryVersion;
    final targetPage = await runExclusive(
      () => context.guardLoad(
        () => locator(_query(size: _page?.size ?? 20), id),
        errorFallback: '定位资料失败，请刷新后重试',
      ),
    );
    if (!mounted || queryVersion != _queryVersion || targetPage == null) {
      return false;
    }
    await reload(page: targetPage);
    if (!mounted ||
        queryVersion != _queryVersion ||
        !(_page?.items.any((item) => _c.idOf(item) == id) ?? false)) {
      return false;
    }
    setState(() {
      _revealItemId = id;
      _revealRequest++;
    });
    return true;
  }

  /// 滚到底时把折叠页外层（分类信息卡）一并推到底：表体内层由表格自行跳到底，
  /// 但外层不收起时表体底缘仍在窗下、末行看不全。原底部翻页条曾在布局上垫高
  /// 底缘隐式兜住这一点，2026-10-18 分页上移工具条后退役，改为显式联动。
  void _revealOuterScrollToEnd([int attempt = 0]) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || attempt >= 8) return;
      if (!_outerScroll.hasClients ||
          !_outerScroll.position.hasContentDimensions) {
        _revealOuterScrollToEnd(attempt + 1);
        return;
      }
      final position = _outerScroll.position;
      final target = position.maxScrollExtent;
      if (target > 0 && position.pixels < target) {
        position.jumpTo(target);
        // 卡片收起会改表体高度（表格内层随后自跳到底），下一帧复核收敛。
        _revealOuterScrollToEnd(attempt + 1);
      }
    });
  }

  @override
  void selectIds(Iterable<String> ids) {
    if (!mounted || _queryPending) return;
    setState(() => _selectedIds = Set<String>.of(ids));
  }

  @override
  void clearSelection() => selectIds(const []);

  @override
  Future<void> reload({int? page}) async {
    if (!mounted || widget.externalSearchPending) return;
    await Future.wait([
      _loadList(page ?? _pageNum),
      _loadGroups(),
      if (_c.loadQueryFacets != null) _loadFacets(),
    ]);
    // 删空当前页时回退上一页，避免列表空白。
    final current = _page;
    if (mounted &&
        current != null &&
        current.items.isEmpty &&
        current.page > 1) {
      await _loadList(current.page - 1);
    }
  }

  @override
  Future<T?> runExclusive<T>(Future<T> Function() action) async {
    if (_busy || _queryPending || _inlineEdit.active) return null;
    setState(() => _busy = true);
    try {
      return await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Future<void> withDetail(
    String id,
    Future<void> Function(TDetail detail) action,
  ) async {
    final version = _queryVersion;
    final loader = _c.loadDetail;
    if (loader == null) return;
    final detail = await runExclusive(
      () => context.guardLoad(
        () => loader(id),
        errorFallback: '加载${_c.noun}详情失败', // TODO(l10n): 补 arb
      ),
    );
    if (detail == null ||
        !mounted ||
        _queryPending ||
        version != _queryVersion) {
      return;
    }
    final hint = _c.detailReadOnlyHint?.call(detail);
    if (hint != null) {
      context.appInfo(hint);
      return;
    }
    await action(detail);
  }

  @override
  Future<void> toggleStatus(TItem row) async {
    if (!_c.canStatus) return;
    if (!_rowWritable(row)) {
      context.appInfo(_c.readOnlyRowHint?.call(row) ?? '该${_c.noun}为只读');
      return;
    }
    final next = _c.statusOf(row) == '使用' ? '禁用' : '使用';
    final path = _c.statusResourceOf(_c.idOf(row));
    final version = _c.versionOf?.call(row);
    final label = _c.labelOf(row);
    final noun = _c.noun;
    final result = await _writeCommand<bool>(
      canWrite: () => _c.canStatus && _rowWritable(row),
      confirm: (scope) => confirmMasterStatusChange(
        context,
        disabling: next == '禁用',
        label: label,
        dialogScopeBuilder: scope,
      ),
      write: () async {
        await ref
            .read(masterStatusRepositoryProvider)
            .change(resourcePath: path, status: next, version: version);
        return true;
      },
    );
    if (result == null || !mounted || !result.isCurrent()) return;
    context.appSuccess(next == '禁用' ? '$noun已禁用' : '$noun已启用');
    await reload();
  }

  @override
  Future<void> batchSetStatus(Set<String> ids, String status) async {
    if (!_c.canStatus || ids.isEmpty) return;
    final targets = Set<String>.unmodifiable(ids);
    final items = List<MasterBatchItem>.unmodifiable(_batchItems(targets));
    final labels = {for (final id in targets) id: _labelOf(id)};
    final path = _c.batchEntityPath;
    final noun = _c.noun;
    final result = await _writeCommand<MasterBatchResult>(
      canWrite: () => _c.canStatus && _targetsWritable(targets),
      confirm: (scope) => confirmMasterStatusChange(
        context,
        disabling: status == '禁用',
        label: noun,
        count: targets.length,
        dialogScopeBuilder: scope,
      ),
      write: () => ref
          .read(masterBatchRepositoryProvider)
          .changeStatus(entityPath: path, status: status, items: items),
    );
    if (result == null || !mounted || !result.isCurrent()) return;
    await _afterBatch(result, status == '禁用' ? '禁用' : '启用', noun, labels);
  }

  @override
  Future<void> batchDelete(Set<String> ids) async {
    if (!_c.canDelete || ids.isEmpty) return;
    final targets = Set<String>.unmodifiable(ids);
    final items = List<MasterBatchItem>.unmodifiable(_batchItems(targets));
    final labels = {for (final id in targets) id: _labelOf(id)};
    final path = _c.batchEntityPath;
    final noun = _c.noun;
    final single = targets.length == 1 ? labels[targets.single] : null;
    final result = await _writeCommand<MasterBatchResult>(
      canWrite: () => _c.canDelete && _targetsWritable(targets),
      confirm: (scope) async =>
          await showDialog<bool>(
            context: context,
            builder: (dialogContext) => scope(
              dialogContext,
              UtenAlertDialog(
                title: Text(single != null ? '删除$noun' : '批量删除$noun'),
                content: Text(
                  single != null
                      ? '确定删除「$single」吗？'
                      : '确定删除选中的 ${targets.length} 个$noun吗？还在被单据、库存或其它资料使用的会逐条说明原因并保留。',
                ),
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
                      if (dialogContext.mounted) {
                        Navigator.pop(dialogContext, true);
                      }
                    },
                    child: const Text('删除'),
                  ),
                ],
              ),
            ),
          ) ==
          true,
      write: () => ref
          .read(masterBatchRepositoryProvider)
          .delete(entityPath: path, items: items),
    );
    if (result == null || !mounted || !result.isCurrent()) return;
    await _afterBatch(result, '删除', noun, labels);
  }

  Future<void> _afterBatch(
    _PaneWriteResult<MasterBatchResult> command,
    String action,
    String noun,
    Map<String, String?> labels,
  ) async {
    if (!command.isCurrent()) return;
    final result = command.value;
    // 成功的从勾选里剪掉，失败的留着方便用户处理后重试。
    setState(() {
      _selectedIds = {
        for (final r in result.results)
          if (!r.ok && _selectedIds.contains(r.id)) r.id,
      };
    });
    await showMasterBatchOutcome(
      context,
      result,
      action: action,
      noun: noun,
      labelOf: (id) => labels[id],
      dialogScopeBuilder: command.dialogScope,
    );
    if (mounted && command.isCurrent()) await reload();
  }

  bool _targetsWritable(Set<String> ids) {
    if (_c.writableOf == null) return true;
    final rows = _rowsById();
    return ids.every(
      (id) => rows.containsKey(id) && _rowWritable(rows[id] as TItem),
    );
  }

  void _invalidateWrites() {
    _writeEpoch++;
    final wasWriting = _lifecycleWriting;
    _lifecycleWriting = false;
    final routes = _writeDialogs.toList();
    _writeDialogs.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final route in routes) {
        if (route.isActive) route.navigator?.removeRoute(route);
      }
      if (mounted && wasWriting) setState(() {});
    });
  }

  Future<_PaneWriteResult<R>?> _writeCommand<R>({
    required bool Function() canWrite,
    required Future<bool> Function(Widget Function(BuildContext, Widget))
    confirm,
    required Future<R> Function() write,
  }) async {
    if (_busy ||
        _queryPending ||
        _inlineEdit.active ||
        _loading ||
        _listLoading ||
        _listError != null ||
        !canWrite()) {
      return null;
    }
    final epoch = ++_writeEpoch;
    final query = _queryVersion;
    final owner = ref.read(sensitiveReadBoundaryProvider);
    final path = _c.batchEntityPath;
    bool current() =>
        mounted &&
        epoch == _writeEpoch &&
        query == _queryVersion &&
        owner == ref.read(sensitiveReadBoundaryProvider) &&
        path == _c.batchEntityPath &&
        !_queryPending &&
        !_loading &&
        !_listLoading &&
        _listError == null &&
        canWrite();
    Widget scope(BuildContext context, Widget child) {
      final route = ModalRoute.of(context);
      if (route is PopupRoute<dynamic>) _writeDialogs.add(route);
      return Consumer(
        builder: (_, ref, _) {
          ref.watch(sensitiveReadBoundaryProvider);
          return current() ? child : const SizedBox.shrink();
        },
      );
    }

    final value = await runExclusive<R?>(() async {
      try {
        return await runSensitiveWrite<R?>(
          ref,
          isCurrent: current,
          write: () async {
            if (!await confirm(scope) || !current()) return null;
            setState(() => _lifecycleWriting = true);
            return await write();
          },
        );
      } catch (error) {
        if (mounted && current()) context.appApiError(error);
        return null;
      } finally {
        if (mounted && epoch == _writeEpoch) {
          setState(() => _lifecycleWriting = false);
        }
      }
    });
    return value == null || !current()
        ? null
        : _PaneWriteResult(value, current, scope);
  }

  List<MasterBatchItem> _batchItems(Set<String> ids) {
    final byId = _rowsById();
    return [
      for (final id in ids)
        MasterBatchItem(
          id,
          byId[id] == null ? null : _c.versionOf?.call(byId[id] as TItem),
        ),
    ];
  }

  Map<String, TItem> _rowsById() => {
    for (final row in _tableRows.items) _c.idOf(row): row,
    for (final group in _groups)
      for (final row in group.items) _c.idOf(row): row,
  };

  String? _labelOf(String id) {
    final row = _rowsById()[id];
    return row == null ? null : _c.labelOf(row);
  }

  bool _rowWritable(TItem row) => _c.writableOf?.call(row) ?? true;

  // ---- 加载 -------------------------------------------------------------

  Future<void> _load({bool retainReadShell = false}) async {
    _invalidateWrites();
    _queryVersion++;
    _tableQueryVersion++;
    if (widget.externalSearchPending) return;
    final generation = _categoryRequests.begin();
    // Category-dependent reads from the prior category must stop publishing
    // immediately, even while the new category detail is still loading.
    _listRequests.begin();
    _groupRequests.begin();
    _facetRequests.begin();
    setState(() {
      _loading = !retainReadShell;
      _retainingReadShell = retainReadShell;
      _displayedQueryStale = false;
      _error = null;
      // 切换分类：分页、筛选、facet、排序、特殊分组、勾选全部重置；
      // 树搜索的关键词随分类切换一并带入(搜索定位时右侧只显示搜索结果)。
      _page = null;
      _pageNum = 1;
      _listError = null;
      _groups = const [];
      _filters = {};
      _keyword = widget.externalKeyword ?? '';
      _facets = null;
      _sortKey = _c.defaultSortKey;
      _sortAsc = true;
      _selectedIds = {};
    });
    // 详情/列表/筛选桶/前导分组四路并行（2026-10-19 用户口径「数据加载后端
    // 并行」）：后三路只依赖 categoryId，不等分类详情先回来——首屏数据 = 最慢
    // 一路，而非「详情→列表」两跳串行。列表/桶/分组失败各自内部消化
    // （_listError / 静默降级），外层 catch 仍只由详情失败触达整 pane 错误态。
    final categoryId = widget.categoryId;
    Future<void> loadDetail() async {
      if (categoryId == null) {
        if (mounted && _categoryRequests.isCurrent(generation)) {
          setState(() {
            _loading = false;
            _retainingReadShell = false;
          });
        }
        return;
      }
      final category = await _c.loadCategory(categoryId);
      if (!mounted || !_categoryRequests.isCurrent(generation)) return;
      setState(() {
        _category = category;
        _loading = false;
        _retainingReadShell = false;
      });
      // 前导分组要读分类详情（systemManaged、把 detail 交给 loader），只能跟在
      // 详情之后拉；四路并行时 _category 尚为 null，首屏分组会被整体跳过。
      await _loadGroups();
    }

    try {
      await Future.wait([loadDetail(), _loadList(1), _loadFacets()]);
    } on ApiException catch (e) {
      if (!mounted || !_categoryRequests.isCurrent(generation)) return;
      setState(() {
        _error = e.message;
        _loading = false;
        _retainingReadShell = false;
      });
    } catch (_) {
      if (!mounted || !_categoryRequests.isCurrent(generation)) return;
      setState(() {
        _error = '加载分类详情失败'; // TODO(l10n): 补 arb
        _loading = false;
        _retainingReadShell = false;
      });
    }
  }

  MasterPaneQuery _query({int page = 1, int? size, bool forPrint = false}) =>
      MasterPaneQuery(
        categoryId: widget.categoryId,
        page: page,
        size: size,
        keyword: _keyword.trim().isEmpty ? null : _keyword,
        filters: _filters,
        sort: _sortKey,
        order: _sortKey == null ? null : (_sortAsc ? 'asc' : 'desc'),
        forPrint: forPrint,
      );

  Future<void> _loadList(int page) async {
    if (widget.externalSearchPending) return;
    _invalidateWrites();
    final generation = _listRequests.begin();
    setState(() {
      _listLoading = true;
      _listError = null;
      _pageNum = page;
    });
    try {
      final result = await _c.loadPage(_query(page: page));
      if (!mounted || !_listRequests.isCurrent(generation)) return;
      setState(() {
        _page = result;
        _displayedQueryStale = false;
      });
    } on ApiException catch (e) {
      if (!mounted || !_listRequests.isCurrent(generation)) return;
      setState(() {
        if (_displayedQueryStale) _page = null;
        _displayedQueryStale = false;
        _listError = e.message;
      });
    } catch (_) {
      if (!mounted || !_listRequests.isCurrent(generation)) return;
      setState(() {
        if (_displayedQueryStale) _page = null;
        _displayedQueryStale = false;
        _listError = '加载${_c.noun}列表失败'; // TODO(l10n): 补 arb
      });
    } finally {
      if (mounted && _listRequests.isCurrent(generation)) {
        setState(() => _listLoading = false);
      }
    }
  }

  /// 表头筛选下拉选项。失败不阻塞列表，静默降级为空下拉。
  Future<void> _loadFacets() async {
    if (widget.externalSearchPending) return;
    final categoryId = widget.categoryId;
    if (_c.loadQueryFacets == null &&
        categoryId == null &&
        _c.loadGlobalFacets == null) {
      return;
    }
    final generation = _facetRequests.begin();
    try {
      final facets = await (_c.loadQueryFacets != null
          ? _c.loadQueryFacets!(_query())
          : categoryId == null
          ? _c.loadGlobalFacets!()
          : _c.loadFacets(categoryId));
      if (mounted && _facetRequests.isCurrent(generation)) {
        setState(() => _facets = facets);
      }
    } catch (_) {
      // Facets are optional; the primary list remains usable.
    }
  }

  /// 前导分组是辅助视图：失败静默，不影响主表。
  Future<void> _loadGroups() async {
    if (widget.externalSearchPending) return;
    final loader = _c.loadLeadingGroups;
    final category = _category;
    if (loader == null || category == null) return;
    final generation = _groupRequests.begin();
    try {
      final groups = await loader(_query(), category);
      if (!mounted || !_groupRequests.isCurrent(generation)) return;
      setState(() => _groups = groups);
    } catch (_) {
      // 辅助视图失败静默。
    }
  }

  void _onFilterChanged(String column, String? value) async {
    if (_queryPending) return;
    if (!await _inlineEdit.confirmLeave(context) || !mounted) return;
    _queryVersion++;
    _tableQueryVersion++;
    final searching = column.startsWith('search.');
    final field = searching ? column.substring(7) : column;
    final mapped = _c.filterParamOfColumn[field] ?? field;
    final param = searching ? 'search.$mapped' : mapped;
    setState(() {
      final next = Map<String, String?>.from(_filters);
      if (value == null) {
        next.remove(param); // 选「所有」= 不筛
      } else {
        next[param] = value; // 具体值 或 kMasterFilterNullValue(空值)
      }
      _filters = next;
    });
    reload(page: 1);
  }

  void _onSortChange(String? column, bool ascending) async {
    if (_queryPending) return;
    if (!await _inlineEdit.confirmLeave(context) || !mounted) return;
    _queryVersion++;
    _tableQueryVersion++;
    setState(() {
      _sortKey = column;
      _sortAsc = ascending;
    });
    reload(page: 1);
  }

  Map<String, List<MasterFacetBucket>> get _columnFacets => {
    for (final e in (_facets?.fields ?? const {}).entries)
      (_c.columnOfFacetField[e.key] ?? e.key): e.value,
  };

  Map<String, int> get _columnNullCounts => {
    for (final e in (_facets?.nullCounts ?? const {}).entries)
      (_c.columnOfFacetField[e.key] ?? e.key): e.value,
  };

  Map<String, String?> get _columnFilters {
    final columnOfParam = {
      for (final e in _c.filterParamOfColumn.entries) e.value: e.key,
    };
    return {
      for (final e in _filters.entries)
        (e.key.startsWith('search.')
            ? 'search.${columnOfParam[e.key.substring(7)] ?? e.key.substring(7)}'
            : (columnOfParam[e.key] ?? e.key)): e
            .value,
    };
  }

  bool get _contactSensitiveInBody =>
      _c.export?.contactSensitiveInBody ?? false;

  Map<String, dynamic> get _exportQuery => <String, dynamic>{
    if (widget.categoryId != null) 'categoryId': widget.categoryId,
    ...?_c.export?.extraQuery,
    ...?_c.export?.queryParamsOf?.call(_query()),
    if (!_contactSensitiveInBody && _keyword.trim().isNotEmpty)
      'keyword': _keyword.trim(),
    ...masterFilterQueryParams(_filters),
    if (_sortKey != null) 'sort': _sortKey,
    if (_sortKey != null) 'order': _sortAsc ? 'asc' : 'desc',
  };

  /// 导出请求体里的敏感检索值(仅 [MasterPaneExport.contactSensitiveInBody])：
  /// 搜索关键字与手机/电话/银行账号筛选值只走请求体，不进 URL。
  Map<String, dynamic> get _exportBody {
    if (!_contactSensitiveInBody) return const {};
    final sensitive = contactSensitiveFilterBody(_filters, keyword: _keyword);
    return sensitive.isEmpty ? const {} : {'sensitiveFilter': sensitive};
  }

  /// 打印预览：按当前分类/筛选口径拉全量(上限 2000 行)，列/格式化与表格一致。
  Future<UtenPrintTable> _printLoader() async {
    if (_queryPending) throw StateError('查询条件已变化，请重新预览');
    final version = _queryVersion;
    final result = await _c.loadPage(_query(size: 2000, forPrint: true));
    if (!mounted || version != _queryVersion || _queryPending) {
      throw StateError('查询条件已变化，请重新预览');
    }
    return UtenPrintTable(
      columnKeys: [for (final c in _c.columns) c.key],
      rowIds: [for (final row in result.items) _c.idOf(row)],
      headers: [for (final c in _c.columns) c.label],
      rows: [
        for (final row in result.items)
          [for (final c in _c.columns) c.value(row) ?? ''],
      ],
    );
  }

  /// 预览打印/导出（表格工具条左簇款）：primary/large 纯文字、无 icon——与
  /// 「表头设置 / 全屏」同一形态（2026-10-08 工具条无 icon 口径 + 2026-10-19
  /// 四页统一进工具条，卡内带 icon 的旧款随 inCard 退役）。
  List<Widget> _exportButtons() {
    final export = _c.export;
    if (export == null) return const [];
    return [
      UtenPrintPreviewButton(
        enabled: !_queryPending && !_loading && !_listLoading,
        title: export.title,
        subtitle: '最多前 2000 行', // TODO(l10n): 补 arb
        loader: _printLoader,
        exportEndpoint: export.endpoint,
        exportPermission: export.permission,
        exportReport: '',
        exportQuery: _exportQuery,
        exportBody: _exportBody,
        exportFilename: export.title,
        type: UtenButtonType.primary,
        size: UtenButtonSize.large,
      ),
      UtenExportButton(
        enabled: !_queryPending && !_loading && !_listLoading,
        prepareExport: () async {
          final version = _queryVersion;
          return UtenExportSelection(
            stillCurrent: () =>
                mounted && version == _queryVersion && !_queryPending,
          );
        },
        endpoint: export.endpoint,
        requiredPermission: export.permission,
        report: '',
        queryParams: _exportQuery,
        bodyParams: _exportBody,
        filename: export.title,
        label: export.label,
        type: UtenButtonType.primary,
        size: UtenButtonSize.large,
      ),
    ];
  }

  // ---- 行菜单 + 批量 ------------------------------------------------------

  List<UtenContextMenuEntry> _currentQueryMenu(
    List<UtenContextMenuEntry> entries,
  ) {
    final version = _queryVersion;
    return [
      for (final entry in entries)
        if (entry is UtenMenuItem)
          UtenMenuItem(
            label: entry.label,
            icon: entry.icon,
            enabled: entry.enabled,
            destructive: entry.destructive,
            preserveSelectionAfterAction: entry.preserveSelectionAfterAction,
            onTap: () async {
              if (!mounted || _queryPending || version != _queryVersion) {
                return;
              }
              await entry.onTap();
            },
          )
        else
          entry,
    ];
  }

  List<UtenContextMenuEntry> _menuItems(TItem row) {
    final override = _c.rowMenuOverride;
    if (override != null) return override(this, row);
    // 多选时右键已勾选的行 → 批量菜单（作用于整个选中集）；单行/未勾选行 →
    // 单行菜单。表格保证右键未勾选行时选择集先替换为该行，不会走错分支。
    final selected = _selectedIds;
    if (selected.length > 1 && selected.contains(_c.idOf(row))) {
      return _batchMenuItems(selected);
    }
    final inUse = _c.statusOf(row) == '使用';
    final writable = _rowWritable(row);
    return [
      if (_c.onOpen != null) ...[
        UtenMenuItem(
          label: '查看详情', // TODO(l10n): 补 arb
          icon: Icons.open_in_new_rounded,
          onTap: () => _c.onOpen!(this, row),
        ),
        const UtenMenuDivider(),
      ],
      UtenMenuItem(
        label: inUse ? '禁用${_c.noun}' : '启用${_c.noun}', // TODO(l10n): 补 arb
        icon: inUse
            ? Icons.pause_circle_outline_rounded
            : Icons.play_circle_outline_rounded,
        enabled: _c.canStatus && writable,
        destructive: inUse,
        onTap: () => toggleStatus(row),
      ),
      if (_c.onEdit != null)
        UtenMenuItem(
          label: '编辑${_c.noun}', // TODO(l10n): 补 arb
          icon: Icons.edit_outlined,
          enabled: _c.canEdit && writable,
          onTap: () =>
              withDetail(_c.idOf(row), (detail) => _c.onEdit!(this, detail)),
        ),
      ...?_c.extraMenuItems?.call(this, row),
      UtenMenuItem(
        label: '删除${_c.noun}', // TODO(l10n): 补 arb
        icon: Icons.delete_outline_rounded,
        destructive: true,
        enabled: _c.canDelete && writable,
        onTap: () => batchDelete({_c.idOf(row)}),
      ),
    ];
  }

  /// 多选批量菜单（2026-10-18 用户口径：批量操作走右键菜单，与货品页同形；
  /// 工具条不再常驻批量按钮）。只读行混选时批量启停/删除灰置。
  List<UtenContextMenuEntry> _batchMenuItems(Set<String> ids) {
    final n = ids.length;
    final byId = _rowsById();
    final allWritable =
        _c.writableOf == null ||
        ids.every(
          (id) => byId[id] != null && _c.writableOf!(byId[id] as TItem),
        );
    final idle = busy || !allWritable;
    return [
      if (_c.canStatus) ...[
        UtenMenuItem(
          label: '批量禁用($n)', // TODO(l10n): 补 arb
          icon: Icons.pause_circle_outline_rounded,
          enabled: !idle,
          onTap: () => batchSetStatus(ids, '禁用'),
        ),
        UtenMenuItem(
          label: '批量启用($n)', // TODO(l10n): 补 arb
          icon: Icons.play_circle_outline_rounded,
          enabled: !idle,
          onTap: () => batchSetStatus(ids, '使用'),
        ),
      ],
      if (_c.canDelete)
        UtenMenuItem(
          label: '批量删除($n)', // TODO(l10n): 补 arb
          icon: Icons.delete_outline_rounded,
          destructive: true,
          enabled: !idle,
          onTap: () => batchDelete(ids),
        ),
      ...?_c.extraBatchMenuItems?.call(this, ids),
    ];
  }

  /// 右下悬浮组：只挂「添加X」（已选胶囊由表格恒置首位）。
  /// 批量操作在右键菜单(多选时出批量项)；全局搜索态(categoryId 为空)不提供新增。
  List<Widget> _batchActions(BuildContext context, Set<String> ids) {
    final additional = <Widget>[
      if (widget.categoryId != null && _c.canCreate && _c.onCreate != null)
        UtenButton(
          key: const ValueKey('master-add-entity'),
          size: UtenButtonSize.large,
          icon: Icons.add_rounded,
          onPressed: _busy ? null : () => _c.onCreate!(this),
          child: Text('添加${_c.noun}'), // TODO(l10n): 补 arb
        ),
    ];
    final canCreate =
        widget.categoryId != null && _c.canCreate && _c.inlineCreation != null;
    if ((_c.onInlineSave == null || _c.inlineFields.isEmpty) && !canCreate) {
      return additional;
    }
    return [
      MasterInlineEditActions<TItem>(
        controller: _inlineEdit,
        canEdit: _c.canEdit && !_busy && !_listLoading && _listError == null,
        canCreate: canCreate && !_busy && !_listLoading && _listError == null,
        onSave: _saveInlineRow,
        cancelLabel: _c.inlineCancelLabel,
        discardNote: _c.inlineDiscardNote,
        additionalActions: additional,
        embedded: true,
      ),
    ];
  }

  // ---- build -------------------------------------------------------------

  /// 分类卡片标题：名称（备注）——与左侧分类列表同形；列表加载完成后缀上
  /// (数量: N)。数量为当前列表口径（本地搜索/筛选时随之变化，与原标题行
  /// 「X (N)」同一语义）。
  String _categoryCardTitle(ProductCategoryDetail d) {
    final remark = d.remark?.trim();
    final label = (remark == null || remark.isEmpty)
        ? d.name
        : '${d.name}（$remark）';
    final page = _page;
    return page == null ? label : '$label (数量: ${page.total})';
  }

  @override
  Widget build(BuildContext context) {
    _configureInlineCreation();
    final theme = Theme.of(context);
    if (_loading || (widget.externalSearchPending && _page == null)) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return UtenEmpty.error(
        message: _error,
        actionLabel: '重试', // TODO(l10n): 补 arb
        onAction: _load,
      );
    }
    final d = _category;
    if (d == null && widget.categoryId != null && !_retainingReadShell) {
      return Center(
        child: Text(
          '未选择分类', // TODO(l10n): 补 arb
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    final isSystemRoot = isSystemUncategorizedCategory(
      systemManaged: d?.systemManaged ?? false,
    );
    // compact：容器 gutter 已提供水平留白；medium+：明细区自带水平内边距。
    final hPad = context.breakpoint.isCompact ? 0.0 : UtenSpacing.s16;
    final content = Padding(
      padding: EdgeInsets.symmetric(horizontal: hPad),
      child: UtenCollapsingHeaderScrollView(
        controller: _outerScroll,
        // 滚走区：分类信息卡——上滑即收起、腾出表格空间。卡片只留标题/副标题与
        // 系统根锁说明（2026-10-19 用户口径：分类增/改/删移到左树行内图标 +
        // 右键菜单，导入/导出/预览打印进表格工具条，卡上不再有按钮）。
        collapsingHeader: d == null
            ? const SizedBox.shrink()
            : Padding(
                padding: const EdgeInsets.fromLTRB(
                  0,
                  UtenSpacing.s16,
                  0,
                  UtenSpacing.s12,
                ),
                child: MasterDetailCard(
                  // 标题与左侧分类列表同形（名称（备注）），数量缀尾
                  // （2026-10-18 用户口径：原「X (N) + 添加X」标题行删除，
                  // 备注与数量都收进分类卡片；数量取当前列表口径）。
                  title: _categoryCardTitle(d),
                  icon: _c.icon,
                  subtitle:
                      '编号前缀 ${d.effectivePrefix ?? _c.defaultCodePrefix}${d.codePrefix == null ? '(继承)' : ''} · 层级 L${d.level}',
                  // 卡片只留标题 + 说明：层级/父级/子项数左侧分类树里都能看出。
                  stats: const [],
                  canEdit: false,
                  secondaryActions: [
                    if (isSystemRoot)
                      const SystemMasterCategoryProtectionNotice(),
                  ],
                ),
              ),
        // body：表格(内滚)。本地搜索框已退役（2026-10-18 用户口径：右侧明细区
        // 不再放搜索框——顶部全局搜索已覆盖分类+名称+编号检索，且支持「搜索范围：
        // 所选分类」）；数量进分类卡片标题，添加X悬浮右下角紧挨已选计数（见
        // [_batchActions]）。
        body: Column(
          children: [
            // primary:true → 表体参与「卡片折叠 → 表格内滚」联动。
            Expanded(
              child: MasterDataTableView<TItem>(
                appendRowsSource: _inlineEdit.appendRowsSource,
                temporaryLeadingColumnKeys: _inlineEdit.requiredColumnKeys(
                  columns: _c.columns,
                  fields: _c.canEdit ? _c.inlineFields : const {},
                ),
                columnEditingEnabled: _c.canEdit,
                rowsController: _tableRows,
                paginationRevision: _page,
                paginationScope: (
                  widget.categoryId,
                  _keyword,
                  _tableQueryVersion,
                ),
                tableKey:
                    'features.basic_data.widgets.master_entity_detail_pane.MasterEntityDetailPaneState.build.1',
                primary: true,
                scrollToEndRequest: _scrollToEndRequest,
                revealItemId: _revealItemId,
                revealRequest: _revealRequest,
                columns: _inlineEdit.columns(
                  preferenceNamespace: _c.batchEntityPath,
                  columns: _c.columns,
                  idOf: _c.idOf,
                  fields: _c.canEdit ? _c.inlineFields : const {},
                  enabled: !_listLoading && _listError == null,
                  writableOf: _c.writableOf,
                ),
                items: _page?.items ?? <TItem>[],
                // 多选：最前列勾选框 + 表头三态全选；选中非空时工具条出批量操作区。
                selectable: true,
                idOf: _c.idOf,
                selectedIds: _selectedIds,
                onSelectedIdsChanged: (s) {
                  if (!_queryPending) setState(() => _selectedIds = s);
                },
                batchActionsBuilder: _batchActions,
                rowMenuBuilder: (row) => _queryPending || _inlineEdit.active
                    ? const []
                    : _currentQueryMenu(_menuItems(row)),
                backgroundMenuBuilder:
                    widget.categoryId == null ||
                        _c.backgroundMenuBuilder == null
                    ? null
                    : () => _queryPending || _inlineEdit.active
                          ? const []
                          : _currentQueryMenu(_c.backgroundMenuBuilder!(this)),
                // 页面特有按钮（导入货品）+ 预览打印/导出进左簇（2026-10-19
                // 用户口径：与「表头设置 / 全屏」同簇、紧随其后，纯文字无 icon，
                // 工具条右侧留给分页）。
                toolbarLeadingActions: () {
                  final leading = [
                    if (!_inlineEdit.active)
                      ...?_c.toolbarLeadingActions?.call(this),
                    ..._exportButtons(),
                  ];
                  return leading.isEmpty ? null : leading;
                }(),
                leadingGroups: _groups,
                facets: _columnFacets,
                facetSearchScope: (
                  ref.watch(authenticatedScopeProvider),
                  widget.categoryId,
                  _keyword,
                  widget.externalKeyword,
                  _queryVersion,
                  _queryPending,
                  jsonEncode(_filters),
                ),
                loadFacetPage: _queryPending || _c.loadFacetPage == null
                    ? null
                    : (column, search, page) => _c.loadFacetPage!(
                        _query(),
                        _c.filterParamOfColumn[column] ?? column,
                        search,
                        page,
                      ),
                nullCounts: _columnNullCounts,
                filters: _columnFilters,
                serverColumnSearch: true,
                onFilterChanged: _onFilterChanged,
                // 行底色按状态（ADR-169 收编）：使用=蓝档淡底（裸 Colors.lightBlue
                // 收编进语义档）/ 禁用=灰档淡底（停用归中性终态，原浅红把「停用」
                // 当异常——基础资料主档停用不是错误，文本仍按 DocStatusBadge 不上色）。
                rowColor:
                    _c.rowColor ??
                    (row) => switch (_c.statusOf(row)) {
                      '使用' => UtenColors.info.withValues(alpha: 0.13),
                      '禁用' => UtenColors.statusNeutral.withValues(alpha: 0.10),
                      _ => null,
                    },
                onRowTap: _c.onOpen == null || _inlineEdit.active
                    ? null
                    : (row) {
                        if (!_queryPending) _c.onOpen!(this, row);
                      },
                sortColumn: _sortKey,
                sortAscending: _sortAsc,
                onSortChange: _onSortChange,
                isLoading: _listLoading && _page == null,
                loadingMore: _listLoading && _page != null,
                error: _listError,
                onRetry: () => reload(),
                emptyMessage: widget.categoryId == null
                    ? '未找到匹配${_c.noun}'
                    : '该分类暂无${_c.noun}', // TODO(l10n): 补 arb
                currentPage: _page?.page ?? 1,
                totalPages: _page?.totalPages ?? 1,
                onPageChange: (p) async {
                  if (!await _inlineEdit.confirmLeave(context) || !mounted) {
                    return;
                  }
                  await reload(page: p);
                },
              ),
            ),
          ],
        ),
      ),
    );
    return MasterInlineEditGuard<TItem>(
      controller: _inlineEdit,
      authorityKey: (
        ref.watch(sensitiveReadBoundaryProvider),
        _c.canEdit,
        jsonEncode(_c.inlineFields.keys.toList()..sort()),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          ExcludeFocus(
            excluding: _queryPending,
            child: AbsorbPointer(
              absorbing: _queryPending,
              child: ExcludeSemantics(excluding: _queryPending, child: content),
            ),
          ),
          if (_queryPending)
            Positioned.fill(
              child: ColoredBox(
                key: const ValueKey('master-query-pending'),
                color: theme.colorScheme.surface.withValues(alpha: 0.45),
                child: Align(
                  alignment: Alignment.topCenter,
                  child: Semantics(
                    liveRegion: true,
                    label: basicDataL10n(context).masterSearchUpdating,
                    child: MediaQuery.disableAnimationsOf(context)
                        ? SizedBox(
                            width: double.infinity,
                            height: 2,
                            child: ColoredBox(color: theme.colorScheme.primary),
                          )
                        : const LinearProgressIndicator(minHeight: 2),
                  ),
                ),
              ),
            ),
          if (_lifecycleWriting)
            const UtenBusyOverlay(
              title: '正在处理资料',
              semanticsKey: Key('master-pane-lifecycle-writing'),
            ),
        ],
      ),
    );
  }
}
