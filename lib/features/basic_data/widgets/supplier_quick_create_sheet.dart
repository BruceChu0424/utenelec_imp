// 供应商快捷新建弹窗（单据表单内联新增，如采购订货单表头供应商下拉的「添加供应商」）。
//
// 范式同颜色/单位内联新建（color_unit_dict.dart → showNameAddSheet），但供应商资料
// 字段多且必须归属分类（后端 SupplierSaveRequest.categoryId 必填），名称单项弹窗不够用，
// 故复用主档编辑弹窗 showMasterEditDialog：名称/分类/手机必填，其余常用联系/财务字段可选，
// 状态固定「使用」（默认启用态建商，无需 supplier:status 权限，与基础资料页一致）。
//
// 保存成功返回新建 SupplierDetail（后端回含 id/编号/分类）；取消/失败返回 null。
// 调用方刷新供应商字典（MasterNameService.reloadSuppliers）后把 id 写入选中值，
// 即「保存后默认选中该供应商」。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/inputs/required_field_decoration.dart';
import '../../../core/theme/uten_tokens.dart';
import '../models/product_category_node.dart';
import '../models/supplier_node.dart';
import '../repositories/supplier_category_repository.dart';
import '../repositories/supplier_repository.dart';
import 'master_edit_dialog.dart';

/// 单据表单内联新建供应商：弹主档编辑表单 → POST /master/suppliers → 返回新建详情。
Future<SupplierDetail?> showSupplierQuickCreateSheet(
  BuildContext context,
  WidgetRef ref,
) {
  SupplierDetail? created;
  return showMasterEditDialog(
    context: context,
    title: '添加供应商',
    fields: [
      const MasterFieldDef(
        key: 'name',
        label: '名称',
        required: true,
        group: '基础',
      ),
      MasterFieldDef(
        key: 'categoryId',
        label: '分类',
        required: true,
        group: '基础',
        customBuilder: (ctx) =>
            _SupplierCategoryPickerField(onChanged: ctx.onChanged),
      ),
      const MasterFieldDef(
        key: 'code',
        label: '编号',
        group: '基础',
        hint: '留空按分类前缀自动生成',
      ),
      const MasterFieldDef(key: 'description', label: '描述/全称', group: '基础'),
      const MasterFieldDef(key: 'place', label: '地区', group: '联系'),
      const MasterFieldDef(key: 'linkman', label: '联系人', group: '联系'),
      const MasterFieldDef(
        key: 'mobile',
        label: '手机',
        required: true,
        group: '联系',
      ),
      const MasterFieldDef(key: 'phone', label: '电话', group: '联系'),
      const MasterFieldDef(key: 'address', label: '地址', group: '联系'),
      const MasterFieldDef(
        key: 'tday',
        label: '结算天数',
        type: MasterFieldType.integer,
        group: '财务',
      ),
      const MasterFieldDef(key: 'bank', label: '开户行', group: '财务'),
      const MasterFieldDef(key: 'bankAccount', label: '银行账号', group: '财务'),
      const MasterFieldDef(key: 'taxId', label: '税号', group: '财务'),
      const MasterFieldDef(key: 'remark', label: '备注', group: '其他'),
    ],
    // 新建即启用：状态不进表单固定「使用」（后端仅对非「使用」状态要求 supplier:status）。
    fixedValues: const {'status': '使用'},
    onSubmit: (body) async {
      created = await ref.read(supplierRepositoryProvider).create(body);
      return true;
    },
  ).then((_) => created);
}

/// 供应商分类树选择字段（quick-create 弹窗用）：点开底部抽屉按层级缩进选一个分类，
/// 选中值经 [onChanged]（MasterFieldContext 回调）回写，buildBody 校验必填。
class _SupplierCategoryPickerField extends ConsumerStatefulWidget {
  const _SupplierCategoryPickerField({required this.onChanged});

  final ValueChanged<dynamic> onChanged;

  @override
  ConsumerState<_SupplierCategoryPickerField> createState() =>
      _SupplierCategoryPickerFieldState();
}

class _SupplierCategoryPickerFieldState
    extends ConsumerState<_SupplierCategoryPickerField> {
  List<ProductCategoryNode>? _tree;
  String? _error;
  String? _selectedName;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final tree = await ref.read(supplierCategoryRepositoryProvider).tree();
      if (!mounted) return;
      setState(() {
        _tree = tree;
        _error = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = '分类加载失败，点击重试');
    }
  }

  /// 树拍平成 (节点, 层级) 列表，保持前序（父在前、子紧随），供抽屉列表按层级缩进。
  List<(ProductCategoryNode, int)> _flatten(List<ProductCategoryNode> nodes) {
    final out = <(ProductCategoryNode, int)>[];
    void walk(List<ProductCategoryNode> list, int depth) {
      for (final n in list) {
        out.add((n, depth));
        walk(n.children, depth + 1);
      }
    }

    walk(nodes, 0);
    return out;
  }

  Future<void> _pick() async {
    if (_tree == null) {
      await _load();
      if (!mounted || _tree == null) return;
    }
    final flattened = _flatten(_tree!);
    final node = await showModalBottomSheet<ProductCategoryNode>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(UtenRadius.lg),
        ),
      ),
      builder: (sheetCtx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        builder: (_, scrollCtl) => ListView.builder(
          controller: scrollCtl,
          itemCount: flattened.length,
          itemBuilder: (_, i) {
            final (node, depth) = flattened[i];
            return ListTile(
              dense: true,
              contentPadding: EdgeInsets.only(
                left: UtenSpacing.s16 + depth * UtenSpacing.s16,
                right: UtenSpacing.s16,
              ),
              leading: Icon(
                depth == 0
                    ? Icons.folder_outlined
                    : Icons.subdirectory_arrow_right_rounded,
                size: 18,
              ),
              title: Text(node.name),
              onTap: () => Navigator.of(sheetCtx).pop(node),
            );
          },
        ),
      ),
    );
    if (node == null) return;
    setState(() => _selectedName = node.name);
    widget.onChanged(node.id);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final empty = _selectedName == null || _selectedName!.isEmpty;
    final showRed = empty && _error == null;
    return InkWell(
      onTap: _pick,
      child: InputDecorator(
        decoration: applyRequiredEmpty(
          InputDecoration(
            label: requiredLabel(
              '分类',
              theme,
              required: true,
              base: theme.inputDecorationTheme.labelStyle,
            ),
            suffixIcon: const Icon(Icons.arrow_drop_down_rounded, size: 20),
          ),
          theme,
          requiredEmpty: showRed,
        ),
        child: Text(
          _error ?? (empty ? '请选择分类' : _selectedName!),
          style: TextStyle(
            color: empty
                ? theme.colorScheme.onSurfaceVariant
                : theme.colorScheme.onSurface,
          ),
        ),
      ),
    );
  }
}
