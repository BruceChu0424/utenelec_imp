// UtenClientPicker - 客户选择器（单据表头选客户用，问题 #15）
//
// 触发：函数式 showUtenClientPicker(context, ref) → 返回 ClientListItem?。
// 形态仿 showUtenGoodsPicker（左客户分类树 + 右客户列表，搜索+分页），compact 底部抽屉 /
// medium+ 右侧滑入 720 宽面板。数据来自 clientRepositoryProvider，后端 list()/search()
// 已按 client:view:all 权限点做行级过滤（仅本人客户 / 授权可看指定业务员 / 全部），
// 前端不用重复实现过滤——这正是本组件要替换掉的旧版 UtenDropdownField 平铺下拉缺的能力：
// 旧下拉走 salesMasterNameServiceProvider 的 /clients/dict（同样已过滤，但只有 id/name，
// 没有联系人/地址等客户资料，也不能按分类浏览）。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/inputs/required_field_decoration.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../models/client_node.dart';
import '../models/product_category_node.dart';
import '../repositories/client_category_repository.dart';
import '../repositories/client_repository.dart';
import 'uten_category_tree_view.dart';

/// 老库遗留的财务占位客户（非真实客户），列表/搜索一律排除——与
/// SalesMasterNameService._loadClients 的 selectable 口径一致。
bool _isStubClient(ClientListItem c) =>
    (c.code ?? '').startsWith('LEGACY-FIN-CL-');

/// 弹出客户选择器，返回所选客户；取消返回 null。
Future<ClientListItem?> showUtenClientPicker(
  BuildContext context,
  WidgetRef ref,
) async {
  List<ProductCategoryNode> tree;
  try {
    tree = await ref.read(clientCategoryRepositoryProvider).tree();
  } catch (_) {
    if (context.mounted) context.appError('客户分类加载失败，请稍后重试');
    return null;
  }
  if (!context.mounted) return null;
  final sheet = _ClientPickerSheet(tree: tree);
  if (context.breakpoint.isCompact) {
    return showModalBottomSheet<ClientListItem>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(UtenRadius.lg)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
        child: SizedBox(height: MediaQuery.sizeOf(ctx).height * 0.85, child: sheet),
      ),
    );
  }
  return showGeneralDialog<ClientListItem>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black54,
    transitionDuration: const Duration(milliseconds: 250),
    pageBuilder: (ctx, _, _) => Align(
      alignment: Alignment.centerRight,
      child: Material(
        color: Theme.of(ctx).colorScheme.surface,
        child: SizedBox(width: 720, height: double.infinity, child: sheet),
      ),
    ),
    transitionBuilder: (ctx, anim, _, child) => SlideTransition(
      position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero)
          .animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
      child: child,
    ),
  );
}

class _ClientPickerSheet extends ConsumerStatefulWidget {
  const _ClientPickerSheet({required this.tree});
  final List<ProductCategoryNode> tree;

  @override
  ConsumerState<_ClientPickerSheet> createState() => _ClientPickerSheetState();
}

class _ClientPickerSheetState extends ConsumerState<_ClientPickerSheet> {
  String? _selectedCategoryId;
  final _keywordCtl = TextEditingController();
  Timer? _debounce;
  int _page = 1;
  List<ClientListItem>? _items;
  int _totalPages = 1;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.tree.isNotEmpty) {
      _selectedCategoryId = widget.tree.first.id;
      _reload();
    }
  }

  @override
  void dispose() {
    _keywordCtl.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _onCategoryTap(ProductCategoryNode node) {
    setState(() {
      _selectedCategoryId = node.id;
      _page = 1;
    });
    _reload();
  }

  void _onKeywordChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      setState(() => _page = 1);
      _reload();
    });
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final kw = _keywordCtl.text.trim();
      final repo = ref.read(clientRepositoryProvider);
      final r = (_selectedCategoryId != null)
          ? await repo.list(
              _selectedCategoryId!,
              page: _page,
              keyword: kw.isEmpty ? null : kw,
            )
          : await repo.search(kw, page: _page);
      if (!mounted) return;
      setState(() {
        _items = r.items.where((c) => !_isStubClient(c)).toList();
        _totalPages = r.totalPages;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = '加载客户失败，请稍后重试';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final treeWidth = context.breakpoint.isCompact ? 150.0 : 240.0;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '选择客户',
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close_rounded),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: Row(
            children: [
              SizedBox(
                width: treeWidth,
                child: UtenCategoryTreeView<ProductCategoryNode>(
                  nodes: widget.tree,
                  mode: UtenCategoryTreeMode.single,
                  selectedIds: _selectedCategoryId == null
                      ? const <String>{}
                      : {_selectedCategoryId!},
                  expandOnRowTap: true,
                  searchHint: '搜索分类',
                  onToggleSelect: _onCategoryTap,
                ),
              ),
              const VerticalDivider(width: 1),
              Expanded(child: _buildRightPane(theme)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildRightPane(ThemeData theme) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            controller: _keywordCtl,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search_rounded, size: 20),
              hintText: '搜索客户（简称/编号/全称/联系人/手机）',
              isDense: true,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onChanged: _onKeywordChanged,
          ),
        ),
        Expanded(child: _buildList(theme)),
        if ((_items?.isNotEmpty ?? false) && _totalPages > 1) _buildPager(theme),
      ],
    );
  }

  Widget _buildList(ThemeData theme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.5));
    }
    if (_error != null) {
      return Center(
        child: Text(
          _error!,
          style: TextStyle(color: theme.colorScheme.error),
          textAlign: TextAlign.center,
        ),
      );
    }
    final items = _items;
    if (items == null || items.isEmpty) {
      return Center(
        child: Text(
          '未找到匹配客户',
          style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
        ),
      );
    }
    return ListView.separated(
      itemCount: items.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (ctx, i) {
        final c = items[i];
        final sub = [
          c.linkman,
          c.mobile,
          c.address,
        ].where((s) => s != null && s.isNotEmpty).join(' · ');
        return ListTile(
          title: Text(
            '${c.name ?? c.fullName ?? '—'}'
            '${c.code != null && c.code!.isNotEmpty ? '（${c.code}）' : ''}',
          ),
          subtitle: sub.isEmpty
              ? null
              : Text(sub, style: const TextStyle(fontSize: 12)),
          onTap: () => Navigator.of(context).pop(c),
        );
      },
    );
  }

  Widget _buildPager(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left_rounded),
            onPressed: _page > 1
                ? () {
                    setState(() => _page -= 1);
                    _reload();
                  }
                : null,
          ),
          Text('$_page / $_totalPages'),
          IconButton(
            icon: const Icon(Icons.chevron_right_rounded),
            onPressed: _page < _totalPages
                ? () {
                    setState(() => _page += 1);
                    _reload();
                  }
                : null,
          ),
        ],
      ),
    );
  }
}

/// 只读展示 + 点击打开 [showUtenClientPicker] 的表单字段（单据表头「客户」用，问题 #15）。
/// 只提交客户 id，展示名由本组件自行持有（同 packaging_picker_field.dart 的
/// 静态 ctx.initialValue 注释：宿主表单每次 onChanged 后都用同一份静态初值重建）。
class ClientPickerField extends StatefulWidget {
  const ClientPickerField({
    super.key,
    required this.initialId,
    required this.initialName,
    required this.onChanged,
    required this.onPick,
    this.label = '客户',
    this.required = false,
    this.errorText,
  });

  final String? initialId;
  final String? initialName;

  /// 回写提交值（客户 id 字符串或 null）。
  final void Function(String? id) onChanged;

  /// 打开客户选择器，取消返回 null。
  final Future<ClientListItem?> Function() onPick;

  final String label;
  final bool required;
  final String? errorText;

  @override
  State<ClientPickerField> createState() => _ClientPickerFieldState();
}

class _ClientPickerFieldState extends State<ClientPickerField> {
  late final TextEditingController _ctl;
  String? _id;

  @override
  void initState() {
    super.initState();
    _id = (widget.initialId == null || widget.initialId!.isEmpty)
        ? null
        : widget.initialId;
    _ctl = TextEditingController(text: widget.initialName ?? '');
  }

  @override
  void didUpdateWidget(ClientPickerField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 上游引入等场景会用新 id/name 重建本字段（表头未选客户时以上游单据客户回填）：
    // 静态初值变化时同步一次，避免仍显示旧的（空）值。
    if (widget.initialId != oldWidget.initialId ||
        widget.initialName != oldWidget.initialName) {
      _id = (widget.initialId == null || widget.initialId!.isEmpty)
          ? null
          : widget.initialId;
      _ctl.text = widget.initialName ?? '';
    }
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  void _set(ClientListItem? item) {
    setState(() {
      _id = item?.id;
      _ctl.text = item?.name ?? item?.fullName ?? '';
    });
    widget.onChanged(_id);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final requiredEmpty =
        widget.required && _id == null && widget.errorText == null;
    return TextField(
      controller: _ctl,
      readOnly: true,
      decoration: applyRequiredEmpty(
        InputDecoration(
          label: requiredLabel(
            widget.label,
            theme,
            required: widget.required,
            base: theme.inputDecorationTheme.labelStyle,
          ),
          hintText: '点击选择客户',
          errorText: widget.errorText,
          prefixIcon: const Icon(Icons.storefront_outlined),
          suffixIcon: _id != null
              ? IconButton(
                  tooltip: '清除选择',
                  icon: const Icon(Icons.clear_rounded),
                  onPressed: () => _set(null),
                )
              : Icon(
                  Icons.unfold_more_rounded,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
        ),
        theme,
        requiredEmpty: requiredEmpty,
      ),
      onTap: () async {
        final item = await widget.onPick();
        if (item != null) _set(item);
      },
    );
  }
}
