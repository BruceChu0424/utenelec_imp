// 货品详情/编辑主体（基础资料-货品资料）：三页签（基本信息 / 组装信息 / 成本预算），
// mode 感知：create（新增）/ edit（编辑）/ view（查看）。
//
// 只以整页呈现（GoodsDetailPage，路由 /basicinfo/goods/new、/basicinfo/goods/:id）：
// - 新增货品 = create 态：基本信息可编辑（含颜色/单位内联新建），保存后同页转 edit 态，
//   组装/成本页签激活（BOM 接口要求货品 id 已存在，故两阶段）。
// - 查看：基本信息只读网格 + 编辑/删除/流水；编辑切 inline 表单。
// - 组装信息：货品 BOM 树（goods_bom_tab.dart），表格吃满全宽，层级添加组件、
//   滑窗选组件；编辑/删除/添加组件按钮挂在表格工具条，全屏表格内同样可用。
// - 成本预算：18 字段（sourceE 由 BOM 聚合只读，下游自动级联，goods_cost_tab.dart）。
// - 头部：返回键 + 货品名 + 「预览」（A4 产品配件清单，goods_bom_preview.dart）。
// - 布局：页签靠左；基本信息/成本限宽 960 居中；组装信息全宽。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/layout/uten_section_header.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../models/goods_node.dart';
import '../providers/color_unit_dict.dart';
import '../repositories/goods_repository.dart';
import 'goods_bom_preview.dart';
import 'goods_bom_tab.dart';
import 'goods_cost_tab.dart';
import 'master_detail_sheet.dart';
import 'master_edit_dialog.dart';
import 'number_unit_field.dart';
import 'packaging_picker_field.dart';
import 'uten_goods_picker.dart';

enum _GoodsDetailMode { create, edit, view }

/// 查看态详情的一个分组（标题 + 字段行），用于把扁平字段切成带小标题的区块。
class _DetailSection {
  const _DetailSection(this.title, this.rows);

  final String title;
  final List<MasterDetailRow> rows;
}

/// 货品详情/编辑主体（三页签：基本信息 / 组装信息 / 成本预算）。
/// 初始模式由 [initialDetail] 推导：null = 新增，非 null = 查看。
class GoodsDetailBody extends ConsumerStatefulWidget {
  const GoodsDetailBody({
    super.key,
    required this.initialDetail,
    required this.initialCategoryId,
    required this.initialTab,
    required this.canEdit,
    required this.onDelete,
    required this.onViewMovements,
    required this.onDataChanged,
  });

  final GoodsDetail? initialDetail;
  final String? initialCategoryId;
  final int initialTab;
  final bool canEdit;
  final VoidCallback? onDelete;
  final VoidCallback? onViewMovements;
  final VoidCallback? onDataChanged;

  @override
  ConsumerState<GoodsDetailBody> createState() => _GoodsDetailBodyState();
}

class _GoodsDetailBodyState extends ConsumerState<GoodsDetailBody> {
  late _GoodsDetailMode _mode;
  GoodsDetail? _detail;
  String? _goodsId;
  String? _categoryId;

  GlobalKey<MasterEditFormState>? _formKey;
  bool _savingBasic = false;

  @override
  void initState() {
    super.initState();
    _mode = widget.initialDetail == null
        ? _GoodsDetailMode.create
        : _GoodsDetailMode.view;
    _detail = widget.initialDetail;
    _goodsId = widget.initialDetail?.id;
    _categoryId = widget.initialDetail?.categoryId ?? widget.initialCategoryId;
    _formKey =
        (_mode == _GoodsDetailMode.create || _mode == _GoodsDetailMode.edit)
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
      _mode = _GoodsDetailMode.edit;
      _formKey = GlobalKey<MasterEditFormState>();
    });
  }

  /// 所有主档关系以 UUID 作为表单值；legacy 仅在详情没有 UUID 时做回显兼容。
  /// 新建记录即使尚未分配 legacy_id，也必须能立即被主关系选中。
  List<MasterSelectOption> get _colorIdOptions {
    final list = ref.watch(colorDictProvider).valueOrNull ?? const [];
    return [
      for (final c in list)
        MasterSelectOption(
          value: c.id,
          label: (c.name != null && c.name!.isNotEmpty)
              ? c.name!
              : (c.code != null && c.code!.isNotEmpty ? c.code! : c.id),
        ),
    ];
  }

  List<MasterSelectOption> get _unitIdOptions {
    final list = ref.watch(unitDictProvider).valueOrNull ?? const [];
    return [
      for (final u in list)
        MasterSelectOption(
          value: u.id,
          label: (u.name != null && u.name!.isNotEmpty)
              ? u.name!
              : (u.code != null && u.code!.isNotEmpty ? u.code! : u.id),
        ),
    ];
  }

  String? _unitIdFromLegacy(int? legacyId) {
    if (legacyId == null) return null;
    final list = ref.watch(unitDictProvider).valueOrNull ?? const [];
    for (final unit in list) {
      if (unit.legacyId == legacyId) return unit.id;
    }
    return null;
  }

  Future<String?> _addColorId() async {
    final createdId = await showColorAddSheet(context, ref);
    if (!mounted) return null;
    if (createdId == null || createdId.trim().isEmpty) return null;
    try {
      await ref.read(colorDictProvider.future);
    } catch (_) {
      // The create response already supplied the authoritative UUID.
    }
    return createdId.trim();
  }

  Future<String?> _addUnitId() async {
    final createdId = await showUnitAddSheet(context, ref);
    if (!mounted) return null;
    if (createdId == null || createdId.trim().isEmpty) return null;
    try {
      await ref.read(unitDictProvider.future);
    } catch (_) {
      // Never replace a newly-created UUID with a legacy-id reverse lookup.
    }
    return createdId.trim();
  }

  List<MasterFieldDef> _goodsFields({required bool canViewDiscount}) {
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
        hint: '留空自动生成',
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
        required: true,
        type: MasterFieldType.select,
        options: kGoodsSourceTypeOptions,
        group: '基础',
      ),
      const MasterFieldDef(
        key: 'productionBomPolicy',
        label: '生产 BOM 策略',
        required: true,
        type: MasterFieldType.select,
        options: kGoodsProductionBomPolicyOptions,
        group: '基础',
      ),
      const MasterFieldDef(key: 'model', label: '型号', group: '规格'),
      const MasterFieldDef(key: 'spec', label: '规格', group: '规格'),
      const MasterFieldDef(key: 'material', label: '材质', group: '规格'),
      const MasterFieldDef(key: 'series', label: '系列', group: '规格'),
      const MasterFieldDef(key: 'stockPlace', label: '库位号', group: '规格'),
      MasterFieldDef(
        key: 'thickness',
        label: '厚度',
        type: MasterFieldType.custom,
        group: '规格',
        customBuilder: (ctx) => NumberUnitField(
          label: '厚度',
          numberKey: 'thickness',
          unitKey: 'thicknessUnitId',
          numberInitial: ctx.initialValue,
          unitInitial: _detail?.thicknessUnitId,
          unitOptions: _unitIdOptions,
          onAddUnit: _addUnitId,
          unitValueAsString: true,
          onChanged: ctx.onChanged,
        ),
      ),
      MasterFieldDef(
        key: 'mWeight',
        label: '单重',
        type: MasterFieldType.custom,
        group: '规格',
        customBuilder: (ctx) => NumberUnitField(
          label: '单重',
          numberKey: 'mWeight',
          unitKey: 'mWeightUnitId',
          numberInitial: ctx.initialValue,
          unitInitial: _detail?.mWeightUnitId,
          unitOptions: _unitIdOptions,
          onAddUnit: _addUnitId,
          unitValueAsString: true,
          onChanged: ctx.onChanged,
        ),
      ),
      MasterFieldDef(
        key: 'colorId',
        label: '主颜色',
        type: MasterFieldType.select,
        options: _colorIdOptions,
        onAddNew: _addColorId,
        group: '规格',
      ),
      const MasterFieldDef(
        key: 'price',
        label: '价格',
        type: MasterFieldType.money,
        group: '商务',
      ),
      if (canViewDiscount)
        const MasterFieldDef(
          key: 'discount',
          label: '折扣',
          type: MasterFieldType.money,
          group: '商务',
          hint: '倍率 1=原价 0.9=9折',
        ),
      MasterFieldDef(
        key: 'pack',
        label: '包装',
        type: MasterFieldType.custom,
        group: '商务',
        customBuilder: (ctx) => PackagingPickerField(
          initialValue: ctx.initialValue,
          onChanged: ctx.onChanged,
          onPick: () async {
            final g = await showUtenGoodsPicker(
              context,
              ref,
              scope: UtenGoodsPickerScope.rawMaterial,
              requireConfirm: true,
            );
            return g?.name;
          },
        ),
      ),
      MasterFieldDef(
        key: 'unitId',
        label: '单位',
        required: true,
        type: MasterFieldType.select,
        options: _unitIdOptions,
        onAddNew: _addUnitId,
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
      'productionBomPolicy': d.productionBomPolicy ?? '',
      'model': d.model ?? '',
      'spec': d.spec ?? '',
      'material': d.material ?? '',
      'series': d.series ?? '',
      'stockPlace': d.stockPlace ?? '',
      'thickness': s(d.thickness),
      'mWeight': s(d.mWeight),
      'colorId': d.colorId ?? '',
      'price': s(d.price),
      'discount': s(d.discount),
      'pack': d.pack ?? '',
      'unitId': d.unitId ?? '',
      'pieces': s(d.pieces),
    };
  }

  /// 编辑态全量回传的成本字段（后端 apply 全量覆盖，缺字段清 null）。
  Map<String, dynamic> _costFixedValues() {
    final d = _detail;
    final m = <String, dynamic>{'categoryId': _categoryId};
    if (d != null) {
      m.addAll(goodsUuidFirstReferenceBody(d));
      if (d.version != null) m['version'] = d.version;
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
    final rawBody = _formKey?.currentState?.buildBody();
    if (rawBody == null) return; // 校验失败
    final body = normalizeGoodsUuidFirstBody(rawBody);
    setState(() => _savingBasic = true);
    try {
      final repo = ref.read(goodsRepositoryProvider);
      if (_mode == _GoodsDetailMode.create) {
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
      // 编号查重 409：编号字段描红 + 显文案，保持弹窗不关让用户改。
      if (e is ApiException && e.message.contains('编号已存在')) {
        _formKey?.currentState?.setFieldError('code', e.message);
        return;
      }
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
        : (_detail?.code ??
              (_mode == _GoodsDetailMode.create ? '新增货品' : '货品详情'));
    // 成本预算 Tab 仅 goods:cost:view 持有者可见（无授权直接隐藏，非打码）。
    final canViewCost =
        ref.watch(isSuperAdminProvider) ||
        ref.watch(currentPermissionsProvider).contains(Perm.goodsCostView);
    final tabs = <Tab>[
      const Tab(text: '基本信息'),
      const Tab(text: '组装信息'),
      if (canViewCost) const Tab(text: '成本预算'),
    ];
    return SafeArea(
      child: DefaultTabController(
        length: tabs.length,
        initialIndex: widget.initialTab.clamp(0, tabs.length - 1),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _header(theme, title),
            const Divider(height: 1),
            TabBar(
              // 整页宽屏下三枚页签居中铺满会很稀疏，靠左流式排布。
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              labelColor: theme.colorScheme.primary,
              unselectedLabelColor: theme.colorScheme.onSurfaceVariant,
              indicatorColor: theme.colorScheme.primary,
              tabs: tabs,
            ),
            const Divider(height: 1),
            Flexible(
              child: TabBarView(
                children: [
                  _buildBasicTab(theme),
                  _buildBomTab(),
                  if (canViewCost) _buildCostTab(theme),
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
        UtenSpacing.s8,
        UtenSpacing.s12,
        UtenSpacing.s8,
        UtenSpacing.s8,
      ),
      child: Row(
        children: [
          // 统一返回键（pop 回来源列表页）。
          const UtenBackButton(),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(
            child: Text(
              title,
              style: theme.textTheme.titleLarge?.copyWith(
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
        ],
      ),
    );
  }

  // ---- 基本信息 Tab ----
  Widget _buildBasicTab(ThemeData theme) {
    if (_mode == _GoodsDetailMode.view) return _buildBasicView(theme);
    // Select 初值只会在 MasterEditForm 首次挂载时解析；先等字典就绪，避免 UUID
    // 因首帧 options 为空被误判成“未选择”，随后保存时把既有关系清空。
    final colors = ref.watch(colorDictProvider);
    final units = ref.watch(unitDictProvider);
    if (colors.valueOrNull == null || units.valueOrNull == null) {
      if (colors.hasError || units.hasError) {
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('颜色或单位加载失败，请重试'),
              const SizedBox(height: UtenSpacing.s12),
              UtenButton(
                icon: Icons.refresh_rounded,
                onPressed: () {
                  ref.invalidate(colorDictProvider);
                  ref.invalidate(unitDictProvider);
                },
                child: const Text('重新加载'),
              ),
            ],
          ),
        );
      }
      return const Center(child: CircularProgressIndicator());
    }
    final canEditPrice =
        ref.watch(isSuperAdminProvider) ||
        ref.watch(currentPermissionsProvider).contains(Perm.goodsPriceEdit);
    // 无 goods:discount:view 权限者：折扣字段整段不渲染（也不提交），后端保留原值。
    final canViewDiscount =
        ref.watch(isSuperAdminProvider) ||
        ref.watch(currentPermissionsProvider).contains(Perm.goodsDiscountView);
    return Column(
      children: [
        Expanded(
          // 宽屏下表单限宽居中，避免字段被拉成超长一行。
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 960),
              child: MasterEditForm(
                key: _formKey,
                fields: _goodsFields(canViewDiscount: canViewDiscount),
                initialValues: _initialValues(),
                fixedValues: _costFixedValues(),
                // 无 goods:price:edit 权限者：售价 UI 锁定（折扣字段仅可查看者才在表里，故一并锁定）。
                readOnlyKeys: canEditPrice
                    ? null
                    : (canViewDiscount
                          ? const {'price', 'discount'}
                          : const {'price'}),
              ),
            ),
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(UtenSpacing.s16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              UtenButton(
                type: UtenButtonType.secondary,
                onPressed: _savingBasic
                    ? null
                    : () => Navigator.of(context).pop(),
                child: Text(_mode == _GoodsDetailMode.create ? '取消' : '关闭'),
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
    final sections = _detailSections();
    final bodyChildren = <Widget>[];
    for (var si = 0; si < sections.length; si++) {
      final sec = sections[si];
      if (si > 0) bodyChildren.add(const SizedBox(height: UtenSpacing.s20));
      bodyChildren
        ..add(UtenSectionHeader(title: sec.title, subdued: true))
        ..add(const SizedBox(height: UtenSpacing.s12));
      final rows = sec.rows;
      for (var i = 0; i < rows.length; i += colCount) {
        final first = rows[i];
        final second = i + 1 < rows.length ? rows[i + 1] : null;
        bodyChildren.add(
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
    }
    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(UtenSpacing.s16),
            // 宽屏下只读网格限宽居中，与编辑态表单同宽（960）。
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 960),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: bodyChildren,
                ),
              ),
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
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (widget.onViewMovements != null) ...[
                  UtenButton(
                    type: UtenButtonType.tonal,
                    icon: Icons.swap_vert_rounded,
                    // 流水页压栈在本详情页之上，返回时回到本页。
                    onPressed: widget.onViewMovements,
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
                    // 页面自己确认 + 删除 + 返回（本页 context 必须活着）。
                    onPressed: widget.onDelete,
                    child: const Text('删除'),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  /// 厚度/单重的单位显示名：UUID 真源优先；仅 UUID 缺失时按 legacy_id 兼容。
  /// 新建单位通常没有 legacy_id，因此查看态不能只走 legacy 映射。
  String _unitSuffix(String? unitId, int? legacyId) {
    final normalizedId = unitId?.trim();
    final id = normalizedId != null && normalizedId.isNotEmpty
        ? normalizedId
        : _unitIdFromLegacy(legacyId);
    if (id == null) return '';
    for (final o in _unitIdOptions) {
      if (o.value == id) return o.label;
    }
    return '';
  }

  /// 查看态详情分组：沿用编辑态的基础 / 规格 / 商务分组，外加查看态专属的「库存」段。
  /// 这里只展示员工日常识别货品所需的信息；生产 BOM 策略仍是服务端权威事实并保留在编辑态，
  /// 但不在普通只读详情中重复展示。
  List<_DetailSection> _detailSections() {
    final d = _detail;
    if (d == null) return const [];
    // 无 goods:discount:view 权限者：查看态不显示折扣行（后端已置 discount=null）。
    final canViewDiscount =
        ref.watch(isSuperAdminProvider) ||
        ref.watch(currentPermissionsProvider).contains(Perm.goodsDiscountView);
    String s(Object? v) => v == null ? '' : '$v';
    String withUnit(Object? v, String? unitId, int? unitLegacyId) {
      if (v == null) return '';
      final u = _unitSuffix(unitId, unitLegacyId);
      return u.isEmpty ? '$v' : '$v $u';
    }

    return [
      _DetailSection('基础', [
        MasterDetailRow('编号', d.code),
        MasterDetailRow('货品名称', d.name),
        MasterDetailRow('简称', d.shortName),
        MasterDetailRow('状态', d.status),
        MasterDetailRow('来源', d.sourceType),
      ]),
      _DetailSection('规格', [
        MasterDetailRow('型号', d.model),
        MasterDetailRow('规格', d.spec),
        MasterDetailRow('材质', d.material),
        MasterDetailRow(
          '厚度',
          withUnit(d.thickness, d.thicknessUnitId, d.thicknessUnitLegacyId),
        ),
        MasterDetailRow(
          '单重',
          withUnit(d.mWeight, d.mWeightUnitId, d.mWeightUnitLegacyId),
        ),
        MasterDetailRow('主颜色', d.colorName),
        MasterDetailRow('系列', d.series),
        MasterDetailRow('库位号', d.stockPlace),
      ]),
      _DetailSection('商务', [
        MasterDetailRow('价格', s(d.price)),
        if (canViewDiscount)
          MasterDetailRow('折扣', d.discount == null ? '' : '${d.discount}'),
        MasterDetailRow('包装', d.pack),
        MasterDetailRow('单位', d.unitName),
        MasterDetailRow('件数', s(d.pieces)),
      ]),
      _DetailSection('库存', [
        MasterDetailRow('库存量(合计)', s(d.stockQty)),
        for (final w in d.stockByWarehouse)
          MasterDetailRow(
            '　${w.warehouseName ?? w.warehouseCode ?? '仓库'}${w.colorName != null ? '·${w.colorName}' : ''}',
            '${s(w.qty)}${d.unitName != null ? ' ${d.unitName}' : ''}',
          ),
      ]),
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
    // 宽屏下成本表单与基本信息同宽居中（960），保持三个页签视觉对齐。
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 960),
        child: GoodsCostTab(
          key: ValueKey('cost-$_goodsId'),
          detail: _detail!,
          canEdit: widget.canEdit,
          materialTotal: _detail!.sourceE,
          onSaved: () {
            _refreshDetail();
            widget.onDataChanged?.call();
          },
        ),
      ),
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
