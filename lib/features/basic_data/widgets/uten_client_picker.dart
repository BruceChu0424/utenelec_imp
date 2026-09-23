// UtenClientPicker - 客户选择器（单据表头选客户用，问题 #15）
//
// 触发：函数式 showUtenClientPicker(context, ref) → 返回 ClientListItem?。
// 面板本体是泛型的 showUtenMasterPicker(左客户分类树 + 右客户列表，搜索+分页，
// 与供应商选择器共用一份，ADR-111)，本文件只给客户的仓储闭包与文案。数据来自
// clientRepositoryProvider，后端 list()/search() 已按 client:view:all 权限点做行级过滤
// (仅本人客户 / 授权可看指定业务员 / 全部)，前端不重复实现过滤。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/client_node.dart';
import '../repositories/client_category_repository.dart';
import '../repositories/client_repository.dart';
import 'uten_master_picker.dart';

/// 弹出客户选择器，返回所选客户；取消返回 null。
/// 列表始终请求 selectableOnly：只有「使用」状态的真实客户可选。
Future<ClientListItem?> showUtenClientPicker(
  BuildContext context,
  WidgetRef ref,
) {
  final clients = ref.read(clientRepositoryProvider);
  return showUtenMasterPicker<ClientListItem>(
    context,
    UtenMasterPickerSpec<ClientListItem>(
      title: '选择客户',
      noun: '客户',
      searchKey: const Key('uten-client-picker-search'),
      loadTree: () => ref.read(clientCategoryRepositoryProvider).tree(),
      loadCategoryPage: (categoryId, page, keyword) => clients.list(
        categoryId,
        page: page,
        keyword: keyword,
        selectableOnly: true,
      ),
      search: (query, page) =>
          clients.search(query, page: page, size: 100, selectableOnly: true),
      idOf: (c) => c.id,
      categoryIdOf: (c) => c.categoryId,
      labelOf: clientPickerLabel,
      subtitleOf: (c) => [c.linkman, c.mobile, c.address],
    ),
  );
}

/// 选择面板里的客户显示名：简称(编码)。
String clientPickerLabel(ClientListItem c) =>
    '${c.name ?? c.fullName ?? '—'}'
    '${c.code != null && c.code!.isNotEmpty ? '(${c.code})' : ''}';

/// 只读展示 + 点击打开 [showUtenClientPicker] 的表单字段（单据表头「客户」用，问题 #15）。
/// 只提交客户 id，展示名由字段自行持有。
class ClientPickerField extends StatelessWidget {
  const ClientPickerField({
    super.key,
    required this.initialId,
    required this.initialName,
    required this.onChanged,
    required this.onPick,
    this.label = '客户',
    this.required = false,
    this.errorMessage,
  });

  final String? initialId;
  final String? initialName;

  /// 回写提交值（客户 id 字符串或 null）。
  final void Function(String? id) onChanged;

  /// 打开客户选择器，取消返回 null。
  final Future<ClientListItem?> Function() onPick;

  final String label;
  final bool required;
  final String? errorMessage;

  @override
  Widget build(BuildContext context) => UtenMasterPickerField<ClientListItem>(
    initialId: initialId,
    initialName: initialName,
    onChanged: onChanged,
    onPick: onPick,
    idOf: (c) => c.id,
    nameOf: (c) => c.name ?? c.fullName ?? '',
    label: label,
    hint: '点击选择客户',
    icon: Icons.storefront_outlined,
    required: required,
    errorMessage: errorMessage,
  );
}
