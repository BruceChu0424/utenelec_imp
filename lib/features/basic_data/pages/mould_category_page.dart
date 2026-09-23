// 模具资料分类树管理页（基础资料）
//
// 顶层壳层（树加载/统一搜索/分类 CRUD/build 骨架）复用 CategoryPageShell，
// 本页只声明文案/图标/权限/仓储钩子 + 模具领域差异：
// - 右侧明细区复用 MasterEntityDetailPane(ADR-111)，本页给 mouldRepository 分类下分页闭包；
// - 删除分类带级联预览（后代分类数/模具数红框确认），覆盖 shellDeleteNode；
// - 编辑类按钮（新增/编辑/删除）按 mould_category:edit 权限显隐；查看全员可见（路由不设守卫）；
// - 右侧用通用 MasterDataTableView（Excel 风格：搜索 + 横排 autofilter + 列对齐 + 分页）。
//
// compact：分类树作为 endDrawer；medium/expanded：左树 + 右详情。
// 文档：见 docs/数据迁移/05-模具资料-新库与迁移.md。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/inputs/uten_date_field.dart';
import '../../../components/inputs/uten_employee_picker.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/action_feedback.dart';
import '../../../shared/auth/permissions.dart';
import '../models/mould_node.dart';
import '../models/product_category_node.dart';
import '../repositories/mould_category_repository.dart';
import '../repositories/mould_repository.dart';
import '../repositories/master_status_repository.dart';
import '../widgets/category_edit_dialog.dart';
import '../widgets/category_page_shell.dart';
import '../widgets/master_data_table_view.dart';
import '../widgets/master_entity_detail_pane.dart';
import '../widgets/master_detail_sheet.dart';
import '../widgets/master_edit_dialog.dart';
import '../widgets/category_tree_search.dart';
import '../widgets/system_master_category_guard.dart';
import '../../department/models/department_node.dart';
import '../../department/widgets/uten_department_picker.dart';
import '../../employee/repositories/employee_repository.dart';
import '../../employee/widgets/department_employee_picker.dart';
import '../providers/mould_workshop_tree.dart';

class MouldCategoryPage extends ConsumerStatefulWidget {
  const MouldCategoryPage({super.key});

  @override
  ConsumerState<MouldCategoryPage> createState() => _MouldCategoryPageState();
}

class _MouldCategoryPageState extends ConsumerState<MouldCategoryPage>
    with CategoryPageShell<MouldCategoryPage> {
  @override
  String get shellTitle => '模具资料'; // TODO(l10n): 补 arb

  @override
  String get shellSearchHint => '搜索分类/模具名称或编号'; // TODO(l10n): 补 arb

  @override
  String get shellContentNoun => '模具';

  @override
  IconData get shellEmptyIcon => Icons.precision_manufacturing_outlined;

  @override
  String get shellPersistenceKey => 'basicData.mould';

  @override
  bool get shellCanCreate =>
      ref.read(currentPermissionsProvider).contains(Perm.mouldCategoryCreate);

  @override
  bool get shellCanEdit =>
      ref.read(currentPermissionsProvider).contains(Perm.mouldCategoryEdit);

  @override
  bool get shellCanDelete =>
      ref.read(currentPermissionsProvider).contains(Perm.mouldCategoryDelete);

  @override
  bool get shellCanMove =>
      ref.read(currentPermissionsProvider).contains(Perm.mouldCategoryMove);

  @override
  bool get shellCanReorder =>
      ref.read(currentPermissionsProvider).contains(Perm.mouldCategoryReorder);

  @override
  Future<List<ProductCategoryNode>> shellLoadTree() =>
      ref.read(mouldCategoryRepositoryProvider).tree();

  @override
  Future<void> shellCreateCategory(CategoryEditResult r) => ref
      .read(mouldCategoryRepositoryProvider)
      .create(
        ProductCategorySaveInput(
          name: r.name,
          remark: r.remark,
          codePrefix: r.codePrefix,
          parentId: r.parentId,
          sortOrder: r.sortOrder,
        ),
      );

  @override
  Future<void> shellUpdateCategory(String id, CategoryEditResult r) => ref
      .read(mouldCategoryRepositoryProvider)
      .update(
        id,
        ProductCategoryUpdateInput(
          name: r.name,
          codePrefix: r.codePrefix,
          remark: r.remark,
          version: r.version ?? 0,
          parentId: r.parentId,
          sortOrder: r.sortOrder,
          moveToRoot: r.moveToRoot,
        ),
      );

  @override
  Future<void> shellDeleteCategory(String id) =>
      ref.read(mouldCategoryRepositoryProvider).delete(id);

  @override
  Future<CategoryPrefixPreview> shellPrefixPreview(
    String id,
    String prefix,
    String? parentId,
  ) => ref
      .read(mouldCategoryRepositoryProvider)
      .prefixPreview(id, prefix, parentId: parentId);

  @override
  Future<Set<String>?> shellContentCategoryIds(
    String q,
    bool Function() isCurrent,
  ) async {
    final repository = ref.read(mouldRepositoryProvider);
    return collectPagedHierarchyCategoryIds<MouldListItem>(
      loadPage: (page) => repository.search(q, page: page, size: 100),
      categoryIdOf: (item) => item.categoryId,
      isCurrent: isCurrent,
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => shellReload());
  }

  /// 分类创建/编辑保存后：除了树（shellReload 已做），还要重挂右栏详情面板——
  /// 否则分类卡片仍显示旧名称/前缀，且前缀变更后模具编号已变、列表也需重拉。
  int _detailEpoch = 0;

  @override
  void shellAfterCategorySaved() => setState(() => _detailEpoch++);

  // ---- 级联删除（预览后代分类数/模具数，红框确认） -------------------------

  @override
  Future<void> shellDeleteNode(ProductCategoryNode node) async {
    if (isSystemUncategorizedCategory(systemManaged: node.systemManaged)) {
      context.appInfo(systemUncategorizedCategoryProtectionMessage);
      return;
    }
    // 先拉子树规模预览（后代分类数 + 模具数），用于红色确认框提示级联影响（问题 #7）。
    MouldCategoryDeletePreview? preview;
    try {
      preview = await ref
          .read(mouldCategoryRepositoryProvider)
          .deletePreview(node.id);
    } catch (_) {
      preview = null; // 预览失败不阻塞：退回无计数的通用确认。
    }
    if (!mounted) return;

    final hasCascade =
        preview != null &&
        (preview.descendantCount > 0 || preview.mouldCount > 0);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: UtenColors.error),
            SizedBox(width: UtenSpacing.s8),
            Text('删除分类'), // TODO(l10n): 补 arb
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('确定删除分类「${node.name}」吗？'), // TODO(l10n): 补 arb
            if (hasCascade) ...[
              const SizedBox(height: UtenSpacing.s12),
              Container(
                padding: const EdgeInsets.all(UtenSpacing.s12),
                decoration: BoxDecoration(
                  color: UtenColors.error.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: UtenColors.error.withValues(alpha: 0.45),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (preview!.descendantCount > 0)
                      Text(
                        '• ${preview.descendantCount} 个子分类',
                      ), // TODO(l10n): 补 arb
                    if (preview.mouldCount > 0)
                      Text('• ${preview.mouldCount} 个模具'), // TODO(l10n): 补 arb
                    const SizedBox(height: UtenSpacing.s4),
                    const Text(
                      '以上将随该分类一并删除，且不可恢复。', // TODO(l10n): 补 arb
                      style: TextStyle(color: UtenColors.error),
                    ),
                  ],
                ),
              ),
            ],
          ],
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
    final deleted = await guardShellAction(
      () async {
        await ref.read(mouldCategoryRepositoryProvider).delete(node.id);
      },
      success: '分类已删除', // TODO(l10n): 补 arb
      errorFallback: '删除失败，请稍后重试', // TODO(l10n): 补 arb
    );
    if (!deleted || !mounted) return;
    shellAfterCategoryDeleted(node.id);
    await shellReload();
  }

  @override
  Widget build(BuildContext context) {
    return buildShell(
      context,
      detailPaneBuilder: (selected) =>
          MasterEntityDetailPane<MouldListItem, MouldDetail>(
            key: ValueKey('dp-${selected.id}-$_detailEpoch'),
            config: _paneConfig(),
            categoryId: selected.id,
            canEditCategory: shellCanEdit,
            canAddCategory: shellCanCreate,
            canDeleteCategory: shellCanDelete,
            externalKeyword: shellTreeSearchKeyword,
            onAddChild: () => shellShowCreateDialog(parent: selected),
            onEditCategory: (detail) => shellShowEditDialog(detail),
            onDeleteCategory: () => shellDeleteNode(selected),
          ),
    );
  }

  bool get _canStatusMaster =>
      ref.read(currentPermissionsProvider).contains(Perm.mouldStatus);

  /// 模具明细区配置：列、仓储闭包、权限；新建/编辑带车间树，单击行开详情弹层。
  MasterEntityPaneConfig<MouldListItem, MouldDetail> _paneConfig() {
    final perms = ref.read(currentPermissionsProvider);
    final moulds = ref.read(mouldRepositoryProvider);
    return MasterEntityPaneConfig<MouldListItem, MouldDetail>(
      noun: '模具', // TODO(l10n): 补 arb
      icon: Icons.precision_manufacturing_outlined,
      defaultCodePrefix: 'MJ',
      keyPrefix: 'mould',
      searchHint: '搜索模具(名称/编号/位置/备注)', // TODO(l10n): 补 arb
      columns: _mouldColumns,
      idOf: (m) => m.id,
      statusOf: (m) => m.status,
      labelOf: (m) => m.name?.isNotEmpty == true ? m.name! : (m.code ?? '该模具'),
      loadCategory: (id) =>
          ref.read(mouldCategoryRepositoryProvider).detail(id),
      loadPage: (q) => moulds.list(
        q.categoryId,
        page: q.page,
        size: q.size ?? 20,
        keyword: q.keyword,
        filters: q.filters,
      ),
      loadFacets: (id) async {
        final f = await moulds.facets(id);
        return MasterPaneFacets(fields: f.fields, nullCounts: f.nullCounts);
      },
      batchEntityPath: ApiEndpoints.moulds,
      statusResourceOf: ApiEndpoints.mould,
      canCreate: perms.contains(Perm.mouldCreate),
      canEdit: perms.contains(Perm.mouldEdit),
      canDelete: perms.contains(Perm.mouldDelete),
      canStatus: perms.contains(Perm.mouldStatus),
      onCreate: _showMouldCreate,
      onOpen: (pane, m) => _showMouldDetail(pane, m.id),
      loadDetail: moulds.detail,
      onEdit: _showMouldEdit,
    );
  }

  /// 模具主档可编辑字段（与后端 MouldSaveRequest 对齐）。
  ///
  /// custom 字段（制造年月/车间/保管人）经 [MasterFieldDef.customBuilder] 嵌入
  /// UtenDateField / UtenDepartmentPicker / DepartmentEmployeePickerField（右滑入滑窗）。
  /// 闭包捕获 [iv](初值 map)与 [ref]，故为实例方法而非 static const。
  ///
  /// [workshop] 由调用方（_showMouldCreate/_showMouldEdit）提前 await 拿到，避免在这里
  /// 用 .read 读到还没 resolve 的 FutureProvider（autoDispose 首次打开必是 loading，
  /// .valueOrNull 永远 null，车间选择器会静默退化成全公司组织树——问题 #5 根因之一）。
  List<MasterFieldDef> _buildMouldFields(
    Map<String, String> iv,
    MouldWorkshopTree workshop,
  ) {
    return [
      const MasterFieldDef(
        key: 'name',
        label: '名称',
        required: true,
        group: '基础',
      ),
      const MasterFieldDef(
        key: 'code',
        label: '编号',
        group: '基础',
        hint: '留空自动生成',
      ),
      // 分类：只读显示外面选中分类名（添加模具即在当前分类下）；categoryId 走 fixedValues。
      const MasterFieldDef(
        key: 'categoryName',
        label: '分类',
        group: '基础',
        readOnly: true,
        hint: '当前分类',
      ),
      const MasterFieldDef(key: 'mnumber', label: '备用编号', group: '基础'),
      const MasterFieldDef(
        key: 'status',
        label: '状态',
        type: MasterFieldType.select,
        options: kMasterStatusOptions,
        required: true,
        group: '基础',
      ),
      const MasterFieldDef(key: 'qty', label: '数量', group: '制造'),
      const MasterFieldDef(
        key: 'tqty',
        label: '总数量',
        type: MasterFieldType.money,
        group: '制造',
      ),
      // 制造年月：日期选择窗（UtenDateField）；存 yyyy-MM-dd，兼容老库「2018年7月」初值。
      MasterFieldDef(
        key: 'mstatus',
        label: '制造年月',
        type: MasterFieldType.custom,
        group: '制造',
        customBuilder: (ctx) => UtenDateField(
          label: '制造年月',
          value: _parseMstatus(ctx.initialValue),
          onChanged: (date) => ctx.onChanged(_formatYmd(date)),
        ),
      ),
      // 车间：部门选择滑窗（仅制造与研发管理中心子树，默认只展开生产部，需点确定才生效，
      // 问题 #5）；落 departmentId，后端按 id 解析 place 文本。
      MasterFieldDef(
        key: 'departmentId',
        label: '车间',
        type: MasterFieldType.custom,
        group: '制造',
        customBuilder: (ctx) {
          final id = ctx.initialValue;
          return UtenDepartmentPicker(
            mode: UtenDepartmentPickerMode.single,
            label: '车间',
            hint: '选择生产车间',
            selectablePredicate: isBusinessDepartmentNode,
            treeOverride: workshop.tree.isEmpty ? null : workshop.tree,
            expandOnRowTap: true,
            initiallyExpandedIds: workshop.prodDeptId == null
                ? const {}
                : {workshop.prodDeptId!},
            initialSelection: (id == null || id.isEmpty)
                ? const []
                : [
                    DeptSelection(
                      id: id,
                      name: iv['departmentName'] ?? '',
                      fullPath: '',
                      level: '',
                    ),
                  ],
            onChanged: (sel) =>
                ctx.onChanged(sel.isEmpty ? null : sel.first.id),
          );
        },
      ),
      // 保管人：先选部门（未展开的分类树）再挑人，也可跨部门搜姓名/工号（问题 #6）；
      // 落 keeperId，后端按 id 解析 keeper 文本。
      MasterFieldDef(
        key: 'keeperId',
        label: '保管人',
        type: MasterFieldType.custom,
        group: '制造',
        customBuilder: (ctx) {
          final id = ctx.initialValue;
          return DepartmentEmployeePickerField(
            label: '保管人',
            hint: '请选择保管人',
            initialId: id,
            initialName: iv['keeperName'],
            initialLoader: (employeeId) async {
              final employee = await ref
                  .read(employeeRepositoryProvider)
                  .getById(employeeId);
              return UtenEmployeePickerItem(
                id: employee.id,
                name: employee.fullName ?? '',
                employeeCode: employee.code,
                departmentName: employee.departmentName,
              );
            },
            onChanged: ctx.onChanged,
            onPick: () =>
                showUtenDepartmentEmployeePicker(context, ref, title: '选择保管人'),
          );
        },
      ),
      const MasterFieldDef(key: 'remark', label: '备注', group: '其他'),
    ];
  }

  /// 解析制造年月初值：「2018-07-01」(ISO) / 「2018年7月」(老库中文) → DateTime；失败 null。
  DateTime? _parseMstatus(String? s) {
    if (s == null || s.isEmpty) return null;
    final iso = RegExp(r'^(\d{4})-(\d{1,2})(?:-(\d{1,2}))?$').firstMatch(s);
    if (iso != null) {
      return DateTime(
        int.parse(iso.group(1)!),
        int.parse(iso.group(2)!),
        int.parse(iso.group(3) ?? '1'),
      );
    }
    final cn = RegExp(r'(\d{4})\s*年\s*(\d{1,2})\s*月?').firstMatch(s);
    if (cn != null) {
      return DateTime(int.parse(cn.group(1)!), int.parse(cn.group(2)!));
    }
    return null;
  }

  /// DateTime → yyyy-MM-dd（提交/存储格式）。
  String _formatYmd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  // ---- 模具 新建/编辑/详情弹层 ---------------------------------------------

  /// 车间树需要先 await（FutureProvider 首次读永远是 loading，同步 .read 会拿到 null，
  /// 见 [_buildMouldFields] 上的注释），失败兜底空树（picker 退回全公司组织树，不阻断填表）。
  Future<MouldWorkshopTree> _loadWorkshopTree() async {
    try {
      return await ref.read(mouldWorkshopTreeProvider.future);
    } catch (_) {
      return const MouldWorkshopTree(tree: [], prodDeptId: null);
    }
  }

  Future<void> _showMouldCreate(
    MasterEntityPaneController<MouldListItem, MouldDetail> pane,
  ) async {
    final workshop = await _loadWorkshopTree();
    if (!mounted) return;
    final iv = {'status': '使用', 'categoryName': pane.category?.name ?? ''};
    showMasterEditDialog(
      context: context,
      title: '新增模具', // TODO(l10n): 补 arb
      fields: _buildMouldFields(iv, workshop),
      initialValues: iv,
      fixedValues: {'categoryId': pane.categoryId},
      readOnlyKeys: _canStatusMaster ? null : const {'status'},
      onSubmit: (body) => _saveMould(pane, null, body),
    );
  }

  Future<void> _showMouldEdit(
    MasterEntityPaneController<MouldListItem, MouldDetail> pane,
    MouldDetail d,
  ) async {
    final workshop = await _loadWorkshopTree();
    if (!mounted) return;
    final iv = {
      'name': d.name ?? '',
      'code': d.code ?? '',
      'categoryName': d.categoryName ?? '',
      'mnumber': d.mnumber ?? '',
      'qty': d.qty ?? '',
      'tqty': d.tqty?.toString() ?? '',
      'mstatus': d.mstatus ?? '',
      'status': d.status ?? '',
      'departmentId': d.departmentId ?? '',
      'departmentName': d.departmentName ?? '',
      'keeperId': d.keeperId ?? '',
      'keeperName': d.keeperName ?? '',
      'remark': d.remark ?? '',
    };
    showMasterEditDialog(
      context: context,
      title: '编辑模具', // TODO(l10n): 补 arb
      fields: _buildMouldFields(iv, workshop),
      initialValues: iv,
      fixedValues: {'categoryId': d.categoryId ?? pane.categoryId},
      readOnlyKeys: _canStatusMaster ? null : const {'status'},
      onSubmit: (body) => _saveMould(pane, d.id, body),
    );
  }

  /// 新建([id] 为空)或编辑保存；成功后重拉明细区当前页。
  Future<bool> _saveMould(
    MasterEntityPaneController<MouldListItem, MouldDetail> pane,
    String? id,
    Map<String, dynamic> body,
  ) async {
    final repository = ref.read(mouldRepositoryProvider);
    final ok = await context.guardRun(
      () => id == null ? repository.create(body) : repository.update(id, body),
      success: id == null ? '模具已创建' : '模具已更新', // TODO(l10n): 补 arb
      errorFallback: id == null
          ? '创建失败，请稍后重试'
          : '更新失败，请稍后重试', // TODO(l10n): 补 arb
    );
    if (ok) await pane.reload();
    return ok;
  }

  /// 点模具行：拉详情弹框展示核心字段。独立 [_detailLoading] 防连点(多个对话框路由
  /// 交错 push/pop 会触发 element 生命周期断言)；loading 用 root navigator 关闭，
  /// 防 go_router 嵌套 navigator 误把当前页 pop 掉。
  bool _detailLoading = false;

  Future<void> _showMouldDetail(
    MasterEntityPaneController<MouldListItem, MouldDetail> pane,
    String id,
  ) async {
    if (_detailLoading) return;
    _detailLoading = true;
    final nav = Navigator.of(context, rootNavigator: true);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const Center(child: CircularProgressIndicator()),
    );
    MouldDetail? d;
    try {
      d = await ref.read(mouldRepositoryProvider).detail(id);
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('加载模具详情失败'); // TODO(l10n): 补 arb
    }
    nav.pop(); // 关 loading
    if (!mounted || d == null) {
      _detailLoading = false;
      return;
    }
    final detail = d;
    final perms = ref.read(currentPermissionsProvider);
    await showMasterDetailSheet(
      context: context,
      title: detail.name?.isNotEmpty == true
          ? detail.name!
          : (detail.code ?? '模具详情'),
      rows: _mouldDetailRows(detail),
      canEdit: perms.contains(Perm.mouldEdit),
      canDelete: perms.contains(Perm.mouldDelete),
      onToggleStatus: _canStatusMaster
          ? () async {
              final next = detail.status == '使用' ? '禁用' : '使用';
              final ok = await context.guardRun(
                () => ref
                    .read(masterStatusRepositoryProvider)
                    .change(
                      resourcePath: ApiEndpoints.mould(detail.id),
                      status: next,
                    ),
                success: next == '禁用' ? '已停用' : '已启用',
              );
              if (ok && mounted) await pane.reload();
            }
          : null,
      statusActionLabel: detail.status == '使用' ? '停用' : '启用',
      onEdit: () => _showMouldEdit(pane, detail),
      onDelete: () => pane.batchDelete({detail.id}),
    );
    if (mounted) _detailLoading = false;
  }

  List<MasterDetailRow> _mouldDetailRows(MouldDetail d) => [
    MasterDetailRow('编号', d.code), // TODO(l10n): 补 arb
    MasterDetailRow('名称', d.name), // TODO(l10n): 补 arb
    MasterDetailRow('备用编号', d.mnumber), // TODO(l10n): 补 arb
    MasterDetailRow('数量', d.qty), // TODO(l10n): 补 arb
    MasterDetailRow('总数量', d.tqty?.toStringAsFixed(2)), // TODO(l10n): 补 arb
    MasterDetailRow('状态', d.status), // TODO(l10n): 补 arb
    MasterDetailRow('车间', d.place), // TODO(l10n): 补 arb
    MasterDetailRow('保管人', d.keeper), // TODO(l10n): 补 arb
    MasterDetailRow('制造年月', d.mstatus), // TODO(l10n): 补 arb
    MasterDetailRow('分类', d.categoryName), // TODO(l10n): 补 arb
    MasterDetailRow('备注', d.remark), // TODO(l10n): 补 arb
    MasterDetailRow('旧系统 ID', d.legacyId?.toString()), // TODO(l10n): 补 arb
  ];

  // ---- 模具列定义（表格列头 + 单元格取值 + 筛选键） ---------------------

  /// 模具表格列：[MasterColumnDef.label]=列头、[MasterColumnDef.width]=固定列宽、
  /// [MasterColumnDef.value]=单元格取值；key 与后端 query 参数名一一对齐（autofilter）。
  ///
  /// 列顺序按产品定义的 10 列。其中：
  /// - 有数据列（key 与后端 query/facet 字段对齐）：模具编号/模具名称/存放位置/制造日期/备注/状态。
  /// - 无数据列（表无对应字段；模数/套数语义与 qty/tqty 不符按需求当无数据处理）：
  ///   模数/套数/模具类型/制造商——单元格取 null（表格显"—"），不进 FACET_COLUMNS 白名单
  ///   （下拉只显示"所有"），后端忽略其 query 参数。
  static final _mouldColumns = <MasterColumnDef<MouldListItem>>[
    MasterColumnDef(
      key: 'code',
      label: '模具编号',
      width: 120,
      value: (m) => m.code,
    ),
    MasterColumnDef(
      key: 'name',
      label: '模具名称',
      width: 180,
      value: (m) => m.name,
    ),
    MasterColumnDef(
      key: 'cavities',
      label: '模数',
      width: 80,
      value: (_) => null,
    ),
    MasterColumnDef(key: 'sets', label: '套数', width: 80, value: (_) => null),
    MasterColumnDef(
      key: 'mouldType',
      label: '模具类型',
      width: 120,
      value: (_) => null,
    ),
    MasterColumnDef(
      key: 'place',
      label: '存放位置',
      width: 140,
      value: (m) => m.place,
    ),
    MasterColumnDef(
      key: 'manufacturer',
      label: '制造商',
      width: 140,
      value: (_) => null,
    ),
    MasterColumnDef(
      key: 'mstatus',
      label: '制造日期',
      width: 110,
      value: (m) => m.mstatus,
    ),
    MasterColumnDef(
      key: 'remark',
      label: '备注',
      width: 200,
      value: (m) => m.remark,
    ),
    MasterColumnDef(
      key: 'status',
      label: '状态',
      width: 80,
      value: (m) => m.status,
    ),
  ];
}
