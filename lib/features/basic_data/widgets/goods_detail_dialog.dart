// 货品详情/编辑弹窗（基础资料-货品资料）：三页签（基本信息 / 组装信息 / 成本预算），
// mode 感知：create（新增）/ edit（编辑）/ view（查看）。
//
// 替代货品行点击原来的 showMasterDetailSheet + 新增/编辑原来的 showMasterEditDialog：
// - 新增货品 = 本弹窗 create 态：基本信息可编辑（含颜色/单位内联新建），保存后同弹窗转 edit 态，
//   组装/成本页签激活（BOM 接口要求货品 id 已存在，故两阶段）。
// - 查看：基本信息只读网格 + 编辑/删除/流水；编辑切 inline 表单。
// - 组装信息：货品 BOM 树（goods_bom_tab.dart），层级添加组件、滑窗选组件、组件信息只读。
// - 成本预算：18 字段（sourceE 由 BOM 聚合只读，下游自动级联，goods_cost_tab.dart）。
// - 头部「预览」：A4 产品配件清单（goods_bom_preview.dart），仅已保存货品显示。
//
// 容器自适应：compact 底部抽屉 / medium+ 居中面板（920 宽，放 BOM 树）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../models/goods_node.dart';
import '../providers/color_unit_dict.dart';
import '../repositories/goods_repository.dart';
import 'goods_bom_preview.dart';
import 'goods_bom_tab.dart';
import 'goods_cost_tab.dart';
import 'master_detail_sheet.dart';
import 'master_edit_dialog.dart';

enum _GoodsDialogMode { create, edit, view }

/// 弹出货品详情/编辑弹窗（mode 感知）。
///
/// [detail] 为 null = 新建态（需传 [categoryId]）；非 null = 查看/编辑既有货品。
/// [onDataChanged] 在基本信息保存 / 组装成本数据变动后触发（调用方刷新列表）。
/// [initialTab]：0=基本信息，1=组装信息，2=成本预算。
Future<void> showGoodsDetailDialog({
  required BuildContext context,
  GoodsDetail? detail,
  String? categoryId,
  int initialTab = 0,
  bool canEdit = false,
  VoidCallback? onDelete,
  VoidCallback? onViewMovements,
  VoidCallback? onDataChanged,
}) {
  assert(initialTab >= 0 && initialTab < 3);
  final mode = detail == null ? _GoodsDialogMode.create : _GoodsDialogMode.view;
  final body = _GoodsDetailBody(
    initialDetail: detail,
    initialCategoryId: categoryId,
    initialTab: initialTab,
    initialMode: mode,
    canEdit: canEdit,
    onDelete: onDelete,
    onViewMovements: onViewMovements,
    onDataChanged: onDataChanged,
  );
  if (context.breakpoint.isCompact) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(UtenRadius.lg),
        ),
      ),
      builder: (_) => SizedBox(
        height: MediaQuery.of(context).size.height * 0.92,
        child: body,
      ),
    );
  }
  return showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      shape: const RoundedRectangleBorder(borderRadius: UtenRadius.xxlAll),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 920,
          maxHeight: MediaQuery.sizeOf(ctx).height * 0.9,
        ),
        child: body,
      ),
    ),
  );
}

class _GoodsDetailBody extends ConsumerStatefulWidget {
  const _GoodsDetailBody({
    required this.initialDetail,
    required this.initialCategoryId,
    required this.initialTab,
    required this.initialMode,
    required this.canEdit,
    required this.onDelete,
    required this.onViewMovements,
    required this.onDataChanged,
  });

  final GoodsDetail? initialDetail;
  final String? initialCategoryId;
  final int initialTab;
  final _GoodsDialogMode initialMode;
  final bool canEdit;
  final VoidCallback? onDelete;
  final VoidCallback? onViewMovements;
  final VoidCallback? onDataChanged;

  @override
  ConsumerState<_GoodsDetailBody> createState() => _GoodsDetailBodyState();
}

class _GoodsDetailBodyState extends ConsumerState<_GoodsDetailBody> {
  late _GoodsDialogMode _mode;
  GoodsDetail? _detail;
  String? _goodsId;
  String? _categoryId;

  GlobalKey<MasterEditFormState>? _formKey;
  bool _savingBasic = false;

  @override
  void initState() {
    super.initState();
    _mode = widget.initialMode;
    _detail = widget.initialDetail;
    _goodsId = widget.initialDetail?.id;
    _categoryId =
        widget.initialDetail?.categoryId ?? widget.initialCategoryId;
    _formKey = (_mode == _GoodsDialogMode.create ||
            _mode == _GoodsDialogMode.edit)
        ? GlobalKey<MasterEditFormState>()
        : null;
  }

  /// 切到 edit 态（view 的「编辑」按钮 / create 保存成功后）。
  void _enterEdit(GoodsDetail? d) {
    setState(() {
      if (d != null) {
        _detail = d;
        _goodsId = d.id;
        _categoryId = d.categoryId;
      }
      _mode = _GoodsDialogMode.edit;
      _formKey = GlobalKey<MasterEditFormState>();
    });
  }

  /// 颜色/单位下拉选项（来自 provider；新建后 invalidate 自动刷新）。
  List<MasterSelectOption> get _colorOptions {
    final list = ref.watch(colorDictProvider).valueOrNull ?? const [];
    return [
      for (final c in list)
        if (c.legacyId != null)
          MasterSelectOption(
            value: c.legacyId.toString(),
            label: (c.name != null && c.name!.isNotEmpty) ? c.name! : '#${c.legacyId}',
          ),
    ];
  }

  List<MasterSelectOption> get _unitOptions {
    final list = ref.watch(unitDictProvider).valueOrNull ?? const [];
    return [
      for (final u in list)
        if (u.legacyId != null)
          MasterSelectOption(
            value: u.legacyId.toString(),
            label: (u.name != null && u.name!.isNotEmpty) ? u.name! : '#${u.legacyId}',
          ),
    ];
  }

  List<MasterFieldDef> _goodsFields() {
    return [
      const MasterFieldDef(
        key: 'name',
        label: '货品名称',
        required: true,
        group: '基础',
      ),
      const MasterFieldDef(
        key: 'code',
        label: '编号',
        readOnly: true,
        hint: '保存后自动生成',
        group: '基础',
      ),
      const MasterFieldDef(key: 'shortName', label: '简称', group: '基础'),
      const MasterFieldDef(
        key: 'status',
        label: '状态',
        type: MasterFieldType.select,
        options: kMasterStatusOptions,
        group: '基础',
      ),
      const MasterFieldDef(
        key: 'sourceType',
        label: '来源',
        type: MasterFieldType.select,
        options: kGoodsSourceTypeOptions,
        group: '基础',
      ),
      const MasterFieldDef(key: 'model', label: '型号', group: '规格'),
      const MasterFieldDef(key: 'spec', label: '规格', group: '规格'),
      const MasterFieldDef(key: 'material', label: '材质', group: '规格'),
      const MasterFieldDef(
        key: 'thickness',
        label: '厚度',
        type: MasterFieldType.money,
        group: '规格',
      ),
      const MasterFieldDef(
        key: 'mWeight',
        label: '单重',
        type: MasterFieldType.money,
        group: '规格',
      ),
      MasterFieldDef(
        key: 'colorLegacyId',
        label: '主颜色',
        type: MasterFieldType.select,
        options: _colorOptions,
        selectInteger: true,
        onAddNew: () => showColorAddSheet(context, ref),
        group: '规格',
      ),
      const MasterFieldDef(
        key: 'price',
        label: '价格',
        type: MasterFieldType.money,
        group: '商务',
      ),
      const MasterFieldDef(key: 'pack', label: '包装', group: '商务'),
      MasterFieldDef(
        key: 'unitLegacyId',
        label: '单位',
        type: MasterFieldType.select,
        options: _unitOptions,
        selectInteger: true,
        onAddNew: () => showUnitAddSheet(context, ref),
        group: '商务',
      ),
      const MasterFieldDef(
        key: 'pieces',
        label: '件数',
        type: MasterFieldType.integer,
        group: '商务',
      ),
    ];
  }

  Map<String, String> _initialValues() {
    final d = _detail;
    if (d == null) return {'status': '使用'};
    String s(Object? v) => v == null ? '' : '$v';
    return {
      'name': d.name ?? '',
      'code': d.code ?? '',
      'shortName': d.shortName ?? '',
      'status': d.status ?? '使用',
      'sourceType': d.sourceType ?? '',
      'model': d.model ?? '',
      'spec': d.spec ?? '',
      'material': d.material ?? '',
      'thickness': s(d.thickness),
      'mWeight': s(d.mWeight),
      'colorLegacyId': d.colorLegacyId == null ? '' : '${d.colorLegacyId}',
      'price': s(d.price),
      'pack': d.pack ?? '',
      'unitLegacyId': d.unitLegacyId == null ? '' : '${d.unitLegacyId}',
      'pieces': s(d.pieces),
    };
  }

  /// 编辑态全量回传的成本字段（后端 apply 全量覆盖，缺字段清 null）。
  Map<String, dynamic> _costFixedValues() {
    final d = _detail;
    final m = <String, dynamic>{'categoryId': _categoryId};
    if (d != null) {
      m
        ..['sourceE'] = d.sourceE
        ..['machiningE'] = d.machiningE
        ..['incidentalE'] = d.incidentalE
        ..['lacquerE'] = d.lacquerE
        ..['platingE'] = d.platingE
        ..['casingE'] = d.casingE
        ..['polishE'] = d.polishE
        ..['total'] = d.total
        ..['workRate'] = d.workRate
        ..['workE'] = d.workE
        ..['lostRate'] = d.lostRate
        ..['lostE'] = d.lostE
        ..['rentRate'] = d.rentRate
        ..['rentE'] = d.rentE
        ..['makeRate'] = d.makeRate
        ..['makeE'] = d.makeE
        ..['cTotal'] = d.cTotal
        ..['gTotal'] = d.gTotal;
    }
    return m;
  }

  Future<void> _saveBasic() async {
    final body = _formKey?.currentState?.buildBody();
    if (body == null) return; // 校验失败
    setState(() => _savingBasic = true);
    try {
      final repo = ref.read(goodsRepositoryProvider);
      if (_mode == _GoodsDialogMode.create) {
        final created = await repo.create(body);
        if (!mounted) return;
        context.appSuccess('货品已创建，可继续维护组装信息与成本');
        _enterEdit(created);
        widget.onDataChanged?.call();
      } else {
        await repo.update(_goodsId!, body);
        if (!mounted) return;
        // 刷新 detail（成本/sourceE 可能他处变动），保留表单编辑态。
        final fresh = await repo.detail(_goodsId!);
        if (!mounted) return;
        setState(() => _detail = fresh);
        context.appSuccess('已保存');
        widget.onDataChanged?.call();
      }
    } catch (e) {
      if (!mounted) return;
      context.appApiError(e);
    } finally {
      if (mounted) setState(() => _savingBasic = false);
    }
  }

  Future<void> _refreshDetail() async {
    if (_goodsId == null) return;
    try {
      final fresh = await ref.read(goodsRepositoryProvider).detail(_goodsId!);
      if (!mounted) return;
      setState(() => _detail = fresh);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = _detail?.name?.isNotEmpty == true
        ? _detail!.name!
        : (_detail?.code ?? (_mode == _GoodsDialogMode.create ? '新增货品' : '货品详情'));
    return SafeArea(
      child: DefaultTabController(
        length: 3,
        initialIndex: widget.initialTab,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _header(theme, title),
            const Divider(height: 1),
            TabBar(
              labelColor: theme.colorScheme.primary,
              unselectedLabelColor: theme.colorScheme.onSurfaceVariant,
              indicatorColor: theme.colorScheme.primary,
              tabs: const [
                Tab(text: '基本信息'),
                Tab(text: '组装信息'),
                Tab(text: '成本预算'),
              ],
            ),
            const Divider(height: 1),
            Flexible(
              child: TabBarView(
                children: [
                  _buildBasicTab(theme),
                  _buildBomTab(),
                  _buildCostTab(theme),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header(ThemeData theme, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UtenSpacing.s16,
        UtenSpacing.s12,
        UtenSpacing.s8,
        UtenSpacing.s8,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (_goodsId != null)
            UtenButton(
              type: UtenButtonType.tonal,
              size: UtenButtonSize.small,
              icon: Icons.preview_outlined,
              onPressed: () => showGoodsBomPreview(
                context: context,
                goodsId: _goodsId!,
                productName: _detail?.name,
                productModel: _detail?.model,
                productCode: _detail?.code,
              ),
              child: const Text('预览'),
            ),
          IconButton(
            icon: const Icon(Icons.close_rounded),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  // ---- 基本信息 Tab ----
  Widget _buildBasicTab(ThemeData theme) {
    if (_mode == _GoodsDialogMode.view) return _buildBasicView(theme);
    return Column(
      children: [
        Expanded(
          child: MasterEditForm(
            key: _formKey,
            fields: _goodsFields(),
            initialValues: _initialValues(),
            fixedValues: _costFixedValues(),
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(UtenSpacing.s16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              UtenButton(
                type: UtenButtonType.secondary,
                onPressed: _savingBasic
                    ? null
                    : () => Navigator.of(context).pop(),
                child: Text(
                    _mode == _GoodsDialogMode.create ? '取消' : '关闭'),
              ),
              const SizedBox(width: UtenSpacing.s12),
              UtenButton(
                icon: Icons.save_outlined,
                isLoading: _savingBasic,
                onPressed: _saveBasic,
                child: const Text('保存'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 查看态：只读字段网格 + 流水/编辑/删除。
  Widget _buildBasicView(ThemeData theme) {
    final twoColumn = !context.breakpoint.isCompact;
    final colCount = twoColumn ? 2 : 1;
    final rows = _detailRows();
    final gridRows = <Widget>[];
    for (var i = 0; i < rows.length; i += colCount) {
      final first = rows[i];
      final second = i + 1 < rows.length ? rows[i + 1] : null;
      gridRows.add(
        Padding(
          padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _cell(theme, first)),
              if (colCount > 1) ...[
                const SizedBox(width: UtenSpacing.s8),
                Expanded(
                  child: second != null
                      ? _cell(theme, second)
                      : const SizedBox.shrink(),
                ),
              ],
            ],
          ),
        ),
      );
    }
    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(UtenSpacing.s16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: gridRows,
            ),
          ),
        ),
        if (widget.onViewMovements != null ||
            (widget.canEdit) ||
            widget.onDelete != null) ...[
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(UtenSpacing.s16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.onViewMovements != null) ...[
                  UtenButton(
                    type: UtenButtonType.tonal,
                    icon: Icons.swap_vert_rounded,
                    onPressed: () {
                      Navigator.of(context).pop();
                      widget.onViewMovements!();
                    },
                    child: const Text('出入库流水'),
                  ),
                  const SizedBox(width: UtenSpacing.s8),
                ],
                if (widget.canEdit) ...[
                  UtenButton(
                    type: UtenButtonType.secondary,
                    icon: Icons.edit_outlined,
                    onPressed: () => _enterEdit(null),
                    child: const Text('编辑'),
                  ),
                  const SizedBox(width: UtenSpacing.s8),
                ],
                if (widget.canEdit && widget.onDelete != null)
                  UtenButton(
                    type: UtenButtonType.danger,
                    icon: Icons.delete_outline,
                    onPressed: () {
                      Navigator.of(context).pop();
                      widget.onDelete!();
                    },
                    child: const Text('删除'),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  List<MasterDetailRow> _detailRows() {
    final d = _detail;
    if (d == null) return const [];
    String s(Object? v) => v == null ? '' : '$v';
    return [
      MasterDetailRow('编号', d.code),
      MasterDetailRow('货品名称', d.name),
      MasterDetailRow('简称', d.shortName),
      MasterDetailRow('状态', d.status),
      MasterDetailRow('来源', d.sourceType),
      MasterDetailRow('型号', d.model),
      MasterDetailRow('规格', d.spec),
      MasterDetailRow('材质', d.material),
      MasterDetailRow('厚度', s(d.thickness)),
      MasterDetailRow('单重', s(d.mWeight)),
      MasterDetailRow('主颜色', d.colorName),
      MasterDetailRow('单位', d.unitName),
      MasterDetailRow('价格', s(d.price)),
      MasterDetailRow('包装', d.pack),
      MasterDetailRow('件数', s(d.pieces)),
    ];
  }

  Widget _cell(ThemeData theme, MasterDetailRow r) {
    final hasValue = r.value != null && r.value!.isNotEmpty;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s12,
        vertical: UtenSpacing.s8,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: UtenRadius.mdAll,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            r.label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            hasValue ? r.value! : '—',
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  // ---- 组装信息 Tab ----
  Widget _buildBomTab() {
    if (_goodsId == null) {
      return _emptyTab('请先在「基本信息」保存货品后维护组装信息');
    }
    return GoodsBomTab(
      key: ValueKey('bom-$_goodsId'),
      goodsId: _goodsId!,
      canEdit: widget.canEdit,
      onDataChanged: () {
        // BOM 变动后刷新 detail（sourceE 已被后端聚合），同步成本 Tab 与外层列表。
        _refreshDetail();
        widget.onDataChanged?.call();
      },
    );
  }

  // ---- 成本预算 Tab ----
  Widget _buildCostTab(ThemeData theme) {
    if (_detail == null) {
      return _emptyTab('请先在「基本信息」保存货品后维护成本预算');
    }
    return GoodsCostTab(
      key: ValueKey('cost-$_goodsId'),
      detail: _detail!,
      canEdit: widget.canEdit,
      materialTotal: _detail!.sourceE,
      onSaved: () {
        _refreshDetail();
        widget.onDataChanged?.call();
      },
    );
  }

  Widget _emptyTab(String msg) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s24),
        child: Text(
          msg,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}
