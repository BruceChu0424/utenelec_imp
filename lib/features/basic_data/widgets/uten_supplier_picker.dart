// UtenSupplierPicker - 供应商选择器（单据选商用：采购/委外表头 + 明细行级供应商）。
//
// 面板本体是泛型的 showUtenMasterPicker(与客户选择器共用一份，ADR-111)：compact
// 底部抽屉 / medium+ 右侧滑入 720 宽面板；左侧供应商分类树 + 右侧供应商列表(搜索+分页)。
// 数据请求 selectableOnly：仅「使用」状态的供应商进入分页。
// 头部带「添加供应商」（supplier:create 权限）：快捷新建入主档后自动选中该新商。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../models/supplier_node.dart';
import '../repositories/supplier_category_repository.dart';
import '../repositories/supplier_repository.dart';
import 'supplier_quick_create_sheet.dart';
import 'uten_master_picker.dart';

/// 弹出供应商选择器，返回所选供应商；取消返回 null。
Future<SupplierListItem?> showUtenSupplierPicker(
  BuildContext context,
  WidgetRef ref, {
  String title = '选择供应商',
}) {
  final suppliers = ref.read(supplierRepositoryProvider);
  final canAdd = ref
      .read(currentPermissionsProvider)
      .contains(Perm.supplierCreate);
  return showUtenMasterPicker<SupplierListItem>(
    context,
    UtenMasterPickerSpec<SupplierListItem>(
      title: title,
      noun: '供应商',
      loadTree: () => ref.read(supplierCategoryRepositoryProvider).tree(),
      loadCategoryPage: (categoryId, page, keyword) => suppliers.list(
        categoryId,
        page: page,
        keyword: keyword,
        selectableOnly: true,
      ),
      search: (query, page) =>
          suppliers.search(query, page: page, size: 100, selectableOnly: true),
      idOf: (s) => s.id,
      categoryIdOf: (s) => s.categoryId,
      labelOf: _supplierLabel,
      subtitleOf: (s) => [s.place, s.linkman, s.mobile],
      quickCreateLabel: '添加供应商',
      // 快捷新建入主档 → 刷新供应商字典(表单下拉名解析) → 面板直接选中新商。
      quickCreate: canAdd
          ? (panelContext) async {
              final created = await showSupplierQuickCreateSheet(
                panelContext,
                ref,
              );
              if (created == null) return null;
              await ref.read(masterNameServiceProvider).reloadSuppliers();
              return SupplierListItem(
                id: created.id,
                name: created.name,
                description: created.description,
                place: created.place,
                linkman: created.linkman,
                mobile: created.mobile,
              );
            }
          : null,
    ),
  );
}

String _supplierLabel(SupplierListItem s) =>
    (s.name?.isNotEmpty == true ? s.name! : (s.description ?? '—'));

/// 只读展示 + 点击打开 [showUtenSupplierPicker] 的表单字段（单据表头「供应商/委外商」用，
/// 与销售订货单「客户」ClientPickerField 同款交互）。只提交供应商 id；展示名由调用方
/// 经 [initialName] 提供（含「（已禁用）」标注等口径），程序化改值时同步显示。
class SupplierPickerField extends StatelessWidget {
  const SupplierPickerField({
    super.key,
    required this.initialId,
    required this.initialName,
    required this.onChanged,
    required this.onPick,
    this.label = '供应商',
    this.required = false,
    this.enabled = true,
    this.errorMessage,
  });

  final String? initialId;
  final String? initialName;

  /// 回写提交值（供应商 id 或 null=清除）。
  final void Function(String? id) onChanged;

  /// 打开供应商选择器（返回 SupplierListItem?；取消 null）。
  final Future<SupplierListItem?> Function() onPick;

  final String label;
  final bool required;
  final bool enabled;
  final String? errorMessage;

  @override
  Widget build(BuildContext context) => UtenMasterPickerField<SupplierListItem>(
    initialId: initialId,
    initialName: initialName,
    onChanged: onChanged,
    onPick: onPick,
    idOf: (s) => s.id,
    nameOf: (s) => s.name?.isNotEmpty == true ? s.name! : (s.description ?? ''),
    label: label,
    icon: Icons.local_shipping_outlined,
    required: required,
    enabled: enabled,
    errorMessage: errorMessage,
  );
}
