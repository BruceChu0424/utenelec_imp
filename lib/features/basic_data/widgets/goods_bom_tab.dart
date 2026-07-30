// 货品详情「组装信息」页签：BOM 组件树（懒加载子级）+ 增删改（goods:edit）。
//
// 树结构：一级 = 当前货品的组件清单；组件自身有 BOM（hasChildren）可展开，
// 展开时对组件 id 再调 list 接口懒加载（对照老系统 001.jpg 的 +/- 树）。
//
// 表格：复用全站统一表格组件 MasterDataTableView（与货品资料列表同款）——
// Excel 风格表头（竖线分隔 + 可拖拽拉宽拉窄）+ 表头/表体横滚同步 +
// 底部横向滚动条 + 单击行高亮。树形通过「可见节点平铺」表达：
// 首列「▶/▼」= 该行有子类（点行任意位置展开/收起，loading 显 …），
// 名称列子类缩进一格（└ 分支符，更深逐级加全角空格）；
// 工具条「编辑/删除」作用于当前选中行。
//
// 编辑：添加组件（按编号/名称搜索选择，组件编号在同一成品下唯一，后端兜底 409）、
// 编辑行（用量/单价/备注）、删除行（软删）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../models/goods_bom_item.dart';
import '../models/goods_node.dart';
import '../repositories/goods_bom_repository.dart';
import '../repositories/goods_repository.dart';
import 'master_data_table_view.dart';

/// 树节点：BOM 行 + 懒加载子级状态。
class _BomNode {
  _BomNode(this.item);

  final GoodsBomItem item;
  List<_BomNode>? children; // null = 未加载
  bool expanded = false;
  bool loading = false;
}

/// 表格行：可见节点的平铺（含深度与级联序号，供 MasterDataTableView 渲染）。
class _BomRow {
  const _BomRow(this.node, this.depth, this.seq);

  final _BomNode node;
  final int depth;
  final String seq;
}

class GoodsBomTab extends ConsumerStatefulWidget {
  const GoodsBomTab({
    super.key,
    required this.goodsId,
    required this.canEdit,
    this.onDataChanged,
  });

  final String goodsId;
  final bool canEdit;
  final VoidCallback? onDataChanged;

  @override
  ConsumerState<GoodsBomTab> createState() => _GoodsBomTabState();
}

class _GoodsBomTabState extends ConsumerState<GoodsBomTab> {
  List<_BomNode>? _roots;
  bool _loading = true;
  String? _error;

  /// 当前点选行（工具条 编辑/删除 的作用对象；表格内同步高亮）。
  GoodsBomItem? _selected;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = await ref
          .read(goodsBomRepositoryProvider)
          .list(widget.goodsId);
      if (!mounted) return;
      setState(() {
        _roots = items.map(_BomNode.new).toList();
        _loading = false;
        _selected = null;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = '加载组装信息失败'; // TODO(l10n): 补 arb
        _loading = false;
      });
    }
  }

  /// 可见节点平铺：根 → （展开的）子级递归，级联序号 1 / 1.1 / 1.1.2。
  List<_BomRow> get _visibleRows {
    final rows = <_BomRow>[];
    void walk(List<_BomNode> nodes, int depth, String prefix) {
      for (var i = 0; i < nodes.length; i++) {
        final seq = prefix.isEmpty ? '${i + 1}' : '$prefix.${i + 1}';
        final n = nodes[i];
        rows.add(_BomRow(n, depth, seq));
        if (n.expanded && n.children != null) {
          walk(n.children!, depth + 1, seq);
        }
      }
    }

    walk(_roots ?? const <_BomNode>[], 0, '');
    return rows;
  }

  Future<void> _toggle(_BomNode node) async {
    if (!node.item.hasChildren) return;
    if (node.expanded) {
      setState(() => node.expanded = false);
      return;
    }
    if (node.children != null) {
      setState(() => node.expanded = true);
      return;
    }
    setState(() => node.loading = true);
    try {
      final items = await ref
          .read(goodsBomRepositoryProvider)
          .list(node.item.componentGoodsId);
      if (!mounted) return;
      setState(() {
        node.children = items.map(_BomNode.new).toList();
        node.expanded = true;
        node.loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => node.loading = false);
      context.appError('加载子级组件失败'); // TODO(l10n): 补 arb
    }
  }

  /// 行点击：选中（工具条 编辑/删除 生效）；有子级的行同时展开/收起。
  void _onRowTap(_BomRow row) {
    setState(() => _selected = row.node.item);
    if (row.node.item.hasChildren) _toggle(row.node);
  }

  // ---- 增删改 -------------------------------------------------------------

  Future<void> _addItem() async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _BomItemEditDialog(goodsId: widget.goodsId),
    );
    if (saved == true) {
      widget.onDataChanged?.call();
      await _load();
    }
  }

  Future<void> _editSelected() async {
    final item = _selected;
    if (item == null) return;
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) =>
          _BomItemEditDialog(goodsId: widget.goodsId, editing: item),
    );
    if (saved == true) {
      widget.onDataChanged?.call();
      await _load();
    }
  }

  Future<void> _deleteSelected() async {
    final item = _selected;
    if (item == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除组件'), // TODO(l10n): 补 arb
        content: Text(
          '确定把「${item.componentName ?? item.componentCode ?? '该组件'}」从组装清单中删除吗？', // TODO(l10n): 补 arb
        ),
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
    try {
      await ref
          .read(goodsBomRepositoryProvider)
          .delete(widget.goodsId, item.id);
      if (!mounted) return;
      context.appSuccess('组件已删除'); // TODO(l10n): 补 arb
      widget.onDataChanged?.call();
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      context.appError(e.message);
    } catch (_) {
      if (!mounted) return;
      context.appError('删除失败，请稍后重试'); // TODO(l10n): 补 arb
    }
  }

  // ---- 渲染 ---------------------------------------------------------------

  /// 表格列（与 MasterDataTableView 对齐：key 仅标识用，本页不接筛选/排序）。
  static final _columns = <MasterColumnDef<_BomRow>>[
    // 展开标识列：有子类的行显 ▶（未展开）/ ▼（已展开），点行任意位置即展开/收起——
    // 没有标识用户无从得知该行可下钻（对照老系统 001.jpg 的 +/- 方块）。
    MasterColumnDef(
      key: 'expand',
      label: '',
      width: 48,
      value: (r) {
        final n = r.node;
        if (!n.item.hasChildren) return '';
        if (n.loading) return '…';
        return n.expanded ? '▼' : '▶';
      },
    ),
    MasterColumnDef(key: 'seq', label: '序号', width: 72, value: (r) => r.seq),
    MasterColumnDef(
      key: 'code',
      label: '编号',
      width: 110,
      value: (r) => r.node.item.componentCode,
    ),
    MasterColumnDef(
      key: 'model',
      label: '型号',
      width: 120,
      value: (r) => r.node.item.componentModel,
    ),
    MasterColumnDef(
      key: 'name',
      label: '货品名称',
      width: 220,
      // 树形缩进：一级顶格；子类退一格 + └ 分支符，孙类退两格，逐级递进
      // （每层一个全角空格，层级深浅直接看缩进就知道）。
      value: (r) {
        final name = r.node.item.componentName ?? '';
        if (r.depth == 0) return name;
        return '${'　' * r.depth}└ $name';
      },
    ),
    MasterColumnDef(
      key: 'spec',
      label: '规格',
      width: 170,
      value: (r) => r.node.item.componentSpec,
    ),
    MasterColumnDef(
      key: 'unit',
      label: '单位',
      width: 56,
      value: (r) => r.node.item.componentUnitName,
    ),
    MasterColumnDef(
      key: 'color',
      label: '颜色',
      width: 80,
      value: (r) => r.node.item.componentColorName,
    ),
    MasterColumnDef(
      key: 'qty',
      label: '数量',
      width: 72,
      type: 'number',
      value: (r) => _num(r.node.item.qty),
    ),
    MasterColumnDef(
      key: 'price',
      label: '单价',
      width: 90,
      type: 'money',
      value: (r) => _money(r.node.item.price),
    ),
    MasterColumnDef(
      key: 'total',
      label: '金额',
      width: 90,
      type: 'money',
      value: (r) => _money(r.node.item.total),
    ),
    MasterColumnDef(
      key: 'summary',
      label: '备注',
      width: 120,
      value: (r) => r.node.item.summary,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final roots = _roots ?? const <_BomNode>[];
    return Column(
      children: [
        // 工具条：说明 + 编辑/删除（作用于选中行）+ 添加组件
        Padding(
          padding: const EdgeInsets.fromLTRB(
            UtenSpacing.s16,
            UtenSpacing.s12,
            UtenSpacing.s16,
            UtenSpacing.s8,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _loading
                      ? '加载中…'
                      : (roots.isEmpty
                            ? '该货品暂无组装信息'
                            : '共 ${roots.length} 个组件（▶ = 含子类，点行展开）'), // TODO(l10n): 补 arb
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              if (widget.canEdit) ...[
                UtenButton(
                  type: UtenButtonType.secondary,
                  size: UtenButtonSize.small,
                  icon: Icons.edit_outlined,
                  onPressed: _selected == null ? null : _editSelected,
                  child: const Text('编辑'), // TODO(l10n): 补 arb
                ),
                const SizedBox(width: UtenSpacing.s8),
                UtenButton(
                  type: UtenButtonType.secondary,
                  size: UtenButtonSize.small,
                  icon: Icons.delete_outline,
                  onPressed: _selected == null ? null : _deleteSelected,
                  child: const Text('删除'), // TODO(l10n): 补 arb
                ),
                const SizedBox(width: UtenSpacing.s8),
                UtenButton(
                  type: UtenButtonType.tonal,
                  size: UtenButtonSize.small,
                  icon: Icons.add_rounded,
                  onPressed: _addItem,
                  child: const Text('添加组件'), // TODO(l10n): 补 arb
                ),
              ],
            ],
          ),
        ),
        // 统一表格（与货品资料列表同款）：Excel 表头分隔线 + 拖拽列宽 + 底部横滑条。
        Expanded(
          child: MasterDataTableView<_BomRow>(
            columns: _columns,
            items: _visibleRows,
            facets: const {},
            nullCounts: const {},
            filters: const {},
            onFilterChanged: (_, _) {},
            onRowTap: _onRowTap,
            isLoading: _loading && _roots == null,
            error: _error,
            onRetry: _load,
            emptyMessage: '暂无组装信息，点右上角「添加组件」录入', // TODO(l10n): 补 arb
          ),
        ),
      ],
    );
  }

  static String _num(double? v) =>
      v == null ? '' : (v == v.roundToDouble() ? v.toStringAsFixed(0) : '$v');

  static String _money(double? v) => v == null ? '' : v.toStringAsFixed(2);
}

/// 添加 / 编辑组件对话框：组件搜索选择 + 用量/单价/备注。
class _BomItemEditDialog extends ConsumerStatefulWidget {
  const _BomItemEditDialog({required this.goodsId, this.editing});

  final String goodsId;
  final GoodsBomItem? editing;

  @override
  ConsumerState<_BomItemEditDialog> createState() => _BomItemEditDialogState();
}

class _BomItemEditDialogState extends ConsumerState<_BomItemEditDialog> {
  final _searchCtl = TextEditingController();
  final _qtyCtl = TextEditingController();
  final _priceCtl = TextEditingController();
  final _summaryCtl = TextEditingController();

  GoodsListItem? _selected; // 选中的组件货品
  List<GoodsListItem> _results = const [];
  bool _searching = false;
  bool _saving = false;
  String? _error;

  bool get _isEdit => widget.editing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.editing;
    if (e != null) {
      _qtyCtl.text = e.qty?.toString() ?? '';
      _priceCtl.text = e.price?.toString() ?? '';
      _summaryCtl.text = e.summary ?? '';
      // 编辑态：组件锁定展示（换组件走 删除+新增，避免误改关联编号）。
    }
  }

  @override
  void dispose() {
    _searchCtl.dispose();
    _qtyCtl.dispose();
    _priceCtl.dispose();
    _summaryCtl.dispose();
    super.dispose();
  }

  Future<void> _search(String kw) async {
    setState(() => _searching = true);
    try {
      final page = await ref.read(goodsRepositoryProvider).search(kw);
      if (!mounted) return;
      setState(() {
        _results = page.items;
        _searching = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _results = const [];
        _searching = false;
      });
    }
  }

  Future<void> _save() async {
    final qty = double.tryParse(_qtyCtl.text.trim());
    if (_qtyCtl.text.trim().isNotEmpty && qty == null) {
      setState(() => _error = '「数量」需为数字'); // TODO(l10n): 补 arb
      return;
    }
    final price = double.tryParse(_priceCtl.text.trim());
    if (_priceCtl.text.trim().isNotEmpty && price == null) {
      setState(() => _error = '「单价」需为数字'); // TODO(l10n): 补 arb
      return;
    }
    if (!_isEdit && _selected == null) {
      setState(() => _error = '请先搜索并选择组件货品'); // TODO(l10n): 补 arb
      return;
    }
    final body = <String, dynamic>{
      'componentGoodsId': _isEdit
          ? widget.editing!.componentGoodsId
          : _selected!.id,
      'qty': qty ?? 1,
      'price': price,
      'summary': _summaryCtl.text.trim().isEmpty
          ? null
          : _summaryCtl.text.trim(),
    };
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final repo = ref.read(goodsBomRepositoryProvider);
      if (_isEdit) {
        await repo.update(widget.goodsId, widget.editing!.id, body);
      } else {
        await repo.create(widget.goodsId, body);
      }
      if (!mounted) return;
      context.appSuccess(_isEdit ? '组件已更新' : '组件已添加'); // TODO(l10n): 补 arb
      Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e.message; // 组件重复（409）等后端友好报错直接展示
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = '保存失败，请稍后重试'; // TODO(l10n): 补 arb
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final e = widget.editing;
    return Dialog(
      shape: const RoundedRectangleBorder(borderRadius: UtenRadius.xxlAll),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 600),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  UtenSpacing.s16,
                  UtenSpacing.s12,
                  UtenSpacing.s8,
                  UtenSpacing.s12,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _isEdit ? '编辑组件' : '添加组件', // TODO(l10n): 补 arb
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () => Navigator.of(context).pop(false),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(UtenSpacing.s16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_isEdit) ...[
                        // 编辑态：组件锁定（编号关联稳定，换组件请删除后重加）
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(UtenSpacing.s12),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainerHigh,
                            borderRadius: UtenRadius.mdAll,
                          ),
                          child: Text(
                            '${e!.componentCode ?? ''}  ${e.componentName ?? ''}',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ] else ...[
                        TextField(
                          controller: _searchCtl,
                          decoration: InputDecoration(
                            labelText: '搜索组件（编号/名称/型号/规格）', // TODO(l10n): 补 arb
                            border: const OutlineInputBorder(),
                            isDense: true,
                            suffixIcon: _searching
                                ? const Padding(
                                    padding: EdgeInsets.all(10),
                                    child: SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    ),
                                  )
                                : const Icon(Icons.search_rounded),
                          ),
                          onChanged: _search,
                        ),
                        const SizedBox(height: UtenSpacing.s8),
                        if (_selected != null)
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(UtenSpacing.s12),
                            margin: const EdgeInsets.only(
                              bottom: UtenSpacing.s8,
                            ),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primaryContainer,
                              borderRadius: UtenRadius.mdAll,
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    '已选：${_selected!.code ?? ''}  ${_selected!.name ?? ''}',
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                InkWell(
                                  onTap: () => setState(() => _selected = null),
                                  child: Icon(
                                    Icons.close_rounded,
                                    size: 18,
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          )
                        else if (_results.isNotEmpty)
                          Container(
                            constraints: const BoxConstraints(maxHeight: 220),
                            decoration: BoxDecoration(
                              border: Border.all(
                                color: theme.colorScheme.outlineVariant,
                              ),
                              borderRadius: UtenRadius.mdAll,
                            ),
                            child: ListView.builder(
                              shrinkWrap: true,
                              itemCount: _results.length,
                              itemBuilder: (_, i) {
                                final g = _results[i];
                                return ListTile(
                                  dense: true,
                                  title: Text(
                                    '${g.code ?? ''}  ${g.name ?? ''}',
                                    style: theme.textTheme.bodyMedium,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  subtitle: Text(
                                    [g.model, g.spec]
                                        .where((s) => s != null && s.isNotEmpty)
                                        .join(' · '),
                                    style: theme.textTheme.bodySmall,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  onTap: () => setState(() => _selected = g),
                                );
                              },
                            ),
                          ),
                        const SizedBox(height: UtenSpacing.s12),
                      ],
                      const SizedBox(height: UtenSpacing.s4),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _qtyCtl,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                    decimal: true,
                                  ),
                              decoration: const InputDecoration(
                                labelText: '数量', // TODO(l10n): 补 arb
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                            ),
                          ),
                          const SizedBox(width: UtenSpacing.s12),
                          Expanded(
                            child: TextField(
                              controller: _priceCtl,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                    decimal: true,
                                  ),
                              decoration: const InputDecoration(
                                labelText: '单价', // TODO(l10n): 补 arb
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: UtenSpacing.s12),
                      TextField(
                        controller: _summaryCtl,
                        decoration: const InputDecoration(
                          labelText: '备注（如 外购 / 外加工）', // TODO(l10n): 补 arb
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: UtenSpacing.s8),
                        Text(
                          _error!,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.error,
                          ),
                        ),
                      ],
                    ],
                  ),
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
                      onPressed: () => Navigator.of(context).pop(false),
                      child: const Text('取消'), // TODO(l10n): 补 arb
                    ),
                    const SizedBox(width: UtenSpacing.s12),
                    UtenButton(
                      icon: Icons.save_outlined,
                      isLoading: _saving,
                      onPressed: _save,
                      child: const Text('保存'), // TODO(l10n): 补 arb
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
