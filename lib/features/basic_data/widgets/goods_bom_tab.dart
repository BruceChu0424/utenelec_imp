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
// 添加组件（2026-08-01）：仿部门添加——选中某组件行再点「添加组件」默认作为该组件的
// 子组件，弹窗内可选「顶层」或任一可见组件作为父级（POST 到对应 goods 的 BOM）。
// 组件经右侧滑窗 showUtenGoodsPicker(scope: component) 选择（原材料/半成品/辅料/OEM 系列），
// 选完组件信息（编号/型号/规格/单位/颜色/材质/单价/来源）自动回填只读，仅用量/备注可改。
// CRUD 后保留展开状态（_expandedIds），让刚加的子组件立即可见。
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
import 'master_data_table_view.dart';
import 'uten_goods_picker.dart';

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
  const _BomRow(this.node, this.depth, this.seq, this.parentGoodsId);

  final _BomNode node;
  final int depth;
  final String seq;

  /// 该 BOM 行真正所属的父货品；嵌套行不能误用页面根货品 id。
  final String parentGoodsId;
}

/// 添加组件时的父级候选项（顶层本货品 或 任一可见组件）。
class _BomParentOption {
  const _BomParentOption({required this.goodsId, required this.label});
  final String goodsId;
  final String label;
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

class _GoodsBomTabState extends ConsumerState<GoodsBomTab>
    with AutomaticKeepAliveClientMixin {
  List<_BomNode>? _roots;
  bool _loading = true;
  String? _error;

  /// 当前点选行（工具条 编辑/删除 的作用对象；表格内同步高亮）。
  _BomRow? _selected;

  /// 当前展开的组件 goodsId 集合：CRUD 重载后据此恢复展开，让新加的子组件可见。
  final Set<String> _expandedIds = {};

  @override
  bool get wantKeepAlive => true;

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
      final roots = items.map(_BomNode.new).toList();
      // 恢复之前展开的子树（CRUD 后树不塌，新加的子组件立即可见）。
      await _restoreExpansion(roots);
      if (!mounted) return;
      setState(() {
        _roots = roots;
        _loading = false;
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

  /// 按 _expandedIds 递归恢复展开的子树（深度上限保护，防脏数据）。
  Future<void> _restoreExpansion(List<_BomNode> nodes, [int depth = 0]) async {
    if (depth > 10) return;
    for (final n in nodes) {
      if (_expandedIds.contains(n.item.componentGoodsId) &&
          n.item.hasChildren) {
        try {
          final items = await ref
              .read(goodsBomRepositoryProvider)
              .list(n.item.componentGoodsId);
          n.children = items.map(_BomNode.new).toList();
          n.expanded = true;
          await _restoreExpansion(n.children!, depth + 1);
        } catch (_) {
          // 单个子树恢复失败不阻断整体。
        }
      }
    }
  }

  /// 可见节点平铺：根 → （展开的）子级递归，级联序号 1 / 1.1 / 1.1.2。
  List<_BomRow> get _visibleRows {
    final rows = <_BomRow>[];
    void walk(
      List<_BomNode> nodes,
      int depth,
      String prefix,
      String parentGoodsId,
    ) {
      for (var i = 0; i < nodes.length; i++) {
        final seq = prefix.isEmpty ? '${i + 1}' : '$prefix.${i + 1}';
        final n = nodes[i];
        rows.add(_BomRow(n, depth, seq, parentGoodsId));
        if (n.expanded && n.children != null) {
          walk(n.children!, depth + 1, seq, n.item.componentGoodsId);
        }
      }
    }

    walk(_roots ?? const <_BomNode>[], 0, '', widget.goodsId);
    return rows;
  }

  Future<void> _toggle(_BomNode node) async {
    final id = node.item.componentGoodsId;
    if (!node.item.hasChildren) return;
    if (node.expanded) {
      setState(() {
        node.expanded = false;
        _expandedIds.remove(id);
      });
      return;
    }
    if (node.children != null) {
      setState(() {
        node.expanded = true;
        _expandedIds.add(id);
      });
      return;
    }
    setState(() => node.loading = true);
    try {
      final items = await ref.read(goodsBomRepositoryProvider).list(id);
      if (!mounted) return;
      setState(() {
        node.children = items.map(_BomNode.new).toList();
        node.expanded = true;
        node.loading = false;
        _expandedIds.add(id);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => node.loading = false);
      context.appError('加载子级组件失败'); // TODO(l10n): 补 arb
    }
  }

  /// 行点击：选中（工具条 编辑/删除 生效）；有子级的行同时展开/收起。
  void _onRowTap(_BomRow row) {
    setState(() => _selected = row);
    if (row.node.item.hasChildren) _toggle(row.node);
  }

  // ---- 增删改 -------------------------------------------------------------
  //
  // 添加组件：选中某组件行 → 默认作为该组件的子组件；未选中 → 顶层。弹窗内父级可选。
  // 保存 POST 到所选父级 goods 的 BOM（/master/goods/{parentGoodsId}/bom）。

  Future<void> _addItem() async {
    final candidates = <_BomParentOption>[
      _BomParentOption(goodsId: widget.goodsId, label: '顶层（本货品）'),
      for (final r in _visibleRows)
        _BomParentOption(
          goodsId: r.node.item.componentGoodsId,
          label:
              '${'　' * (r.depth + 1)}└ ${r.node.item.componentName ?? r.node.item.componentCode ?? ''}',
        ),
    ];
    final defaultParent =
        _selected?.node.item.componentGoodsId ?? widget.goodsId;
    final result = await showDialog<_AddResult>(
      context: context,
      builder: (_) => _BomItemAddDialog(
        parentCandidates: candidates,
        defaultParentGoodsId: defaultParent,
      ),
    );
    if (result?.saved == true) {
      // 加为某组件的子组件：确保该父级展开，重载后子组件可见。
      if (result!.parentGoodsId != widget.goodsId) {
        _expandedIds.add(result.parentGoodsId);
      }
      widget.onDataChanged?.call();
      await _load();
    }
  }

  Future<void> _editSelected() async {
    final row = _selected;
    if (row == null) return;
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _BomItemEditDialog(
        parentGoodsId: row.parentGoodsId,
        editing: row.node.item,
      ),
    );
    if (saved == true) {
      widget.onDataChanged?.call();
      await _load();
    }
  }

  Future<void> _deleteSelected() async {
    final row = _selected;
    if (row == null) return;
    final item = row.node.item;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除组件'), // TODO(l10n): 补 arb
        content: Text(
          '确定把「${item.componentName ?? item.componentCode ?? '该组件'}」从组装清单中删除吗？', // TODO(l10n): 补 arb
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
    try {
      await ref
          .read(goodsBomRepositoryProvider)
          .delete(row.parentGoodsId, item.id);
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
      key: 'source',
      label: '来源',
      width: 64,
      value: (r) => r.node.item.componentSourceType,
    ),
    MasterColumnDef(
      key: 'controlStage',
      label: '需求阶段',
      width: 112,
      value: (r) => r.node.item.controlStage.label,
    ),
    MasterColumnDef(
      key: 'consumptionBasis',
      label: '计量方式',
      width: 92,
      value: (r) => r.node.item.consumptionBasis.label,
    ),
    MasterColumnDef(
      key: 'basisOutputQty',
      label: '基准产量',
      width: 88,
      type: 'number',
      value: (r) => _num(r.node.item.basisOutputQty),
    ),
    MasterColumnDef(
      key: 'allowPartialPackage',
      label: '尾包',
      width: 72,
      value: (r) =>
          r.node.item.consumptionBasis == BomConsumptionBasis.perPackage
          ? (r.node.item.allowPartialPackage ? '允许' : '整包')
          : '—',
    ),
    MasterColumnDef(
      key: 'hardGate',
      label: '缺料处理',
      width: 88,
      value: (r) => r.node.item.hardGate ? '阻止进入' : '只提醒',
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
    super.build(context); // AutomaticKeepAliveClientMixin
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
                            : '共 ${roots.length} 个组件（▶ = 含子类，点行展开；选中组件后再添加默认为其子组件）'), // TODO(l10n): 补 arb
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
            // _BomRow 每次 build 重建（引用变），故按组件行 id 比较而非引用相等。
            isSelected: (row) =>
                _selected != null &&
                row.node.item.id == _selected!.node.item.id,
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

/// 添加组件弹窗的返回：是否保存 + 实际写入的父级 goodsId（供父级恢复展开）。
class _AddResult {
  const _AddResult({required this.saved, required this.parentGoodsId});
  final bool saved;
  final String parentGoodsId;
}

/// 添加组件对话框（多选批量）：选父级 + 右滑窗勾选多个组件（component scope）+ 每个用量，
/// 一次添加多个组件到同一层级。组件属性只读、用量可改、单价取自组件。
class _BomItemAddDialog extends ConsumerStatefulWidget {
  const _BomItemAddDialog({
    required this.parentCandidates,
    required this.defaultParentGoodsId,
  });

  final List<_BomParentOption> parentCandidates;
  final String defaultParentGoodsId;

  @override
  ConsumerState<_BomItemAddDialog> createState() => _BomItemAddDialogState();
}

class _PickedComponent {
  _PickedComponent(this.goods, this.qtyCtl);
  final GoodsListItem goods;
  final TextEditingController qtyCtl;
}

class _BomItemAddDialogState extends ConsumerState<_BomItemAddDialog> {
  late String _parentGoodsId;
  final List<_PickedComponent> _picked = [];
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _parentGoodsId = widget.defaultParentGoodsId;
  }

  @override
  void dispose() {
    for (final p in _picked) {
      p.qtyCtl.dispose();
    }
    super.dispose();
  }

  Future<void> _pickComponents() async {
    final list = await showUtenGoodsPickerMulti(context, ref);
    if (list.isEmpty) return;
    setState(() {
      for (final g in list) {
        if (_picked.any((p) => p.goods.id == g.id)) continue; // 去重
        _picked.add(_PickedComponent(g, TextEditingController(text: '1')));
      }
      _error = null;
    });
  }

  Future<void> _save() async {
    if (_picked.isEmpty) {
      setState(() => _error = '请先选择组件货品'); // TODO(l10n): 补 arb
      return;
    }
    final bodies = <Map<String, dynamic>>[];
    for (final p in _picked) {
      final raw = p.qtyCtl.text.trim();
      final qty = raw.isEmpty ? 1.0 : double.tryParse(raw);
      if (qty == null || qty <= 0) {
        setState(
          () => _error = '「${p.goods.name ?? p.goods.code}」数量必须大于 0',
        ); // TODO(l10n)
        return;
      }
      bodies.add({
        'componentGoodsId': p.goods.id,
        'qty': qty,
        'price': p.goods.price,
      });
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final repo = ref.read(goodsBomRepositoryProvider);
    final errors = <String>{};
    var ok = 0;
    try {
      for (final body in bodies) {
        try {
          await repo.create(_parentGoodsId, body);
          ok++;
        } on ApiException catch (e) {
          errors.add(e.message); // 组件重复/环路（409）等后端友好报错
        }
      }
      if (!mounted) return;
      if (ok > 0) {
        context.appSuccess(
          '已添加 $ok 个组件${errors.isNotEmpty ? '，${errors.length} 个跳过' : ''}',
        );
        Navigator.of(
          context,
        ).pop(_AddResult(saved: true, parentGoodsId: _parentGoodsId));
      } else {
        setState(() {
          _saving = false;
          _error = errors.isEmpty ? '保存失败' : errors.join('；');
        });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = '保存失败，请稍后重试';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Dialog(
      shape: const RoundedRectangleBorder(borderRadius: UtenRadius.xxlAll),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 640),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _dialogHeader(context, theme, '添加组件'),
              const Divider(height: 1),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(UtenSpacing.s16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '添加位置', // TODO(l10n): 补 arb
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: UtenSpacing.s4),
                      DropdownButtonFormField<String>(
                        initialValue: _parentGoodsId,
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        items: [
                          for (final p in widget.parentCandidates)
                            DropdownMenuItem<String>(
                              value: p.goodsId,
                              child: Text(
                                p.label,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: (v) {
                          if (v != null) setState(() => _parentGoodsId = v);
                        },
                      ),
                      const SizedBox(height: UtenSpacing.s12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            '已选组件 ${_picked.length}', // TODO(l10n)
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          TextButton.icon(
                            onPressed: _pickComponents,
                            icon: const Icon(Icons.add_rounded, size: 18),
                            label: const Text('选择组件'), // TODO(l10n)
                          ),
                        ],
                      ),
                      if (_picked.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            vertical: UtenSpacing.s8,
                          ),
                          child: Text(
                            '点「选择组件」批量勾选原材料/半成品/辅料/OEM 系列',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        )
                      else
                        for (final p in _picked)
                          Padding(
                            padding: const EdgeInsets.only(
                              bottom: UtenSpacing.s8,
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '${p.goods.code ?? ''}  ${p.goods.name ?? ''}',
                                        style: theme.textTheme.bodyMedium
                                            ?.copyWith(
                                              fontWeight: FontWeight.w600,
                                            ),
                                      ),
                                      Text(
                                        [
                                              p.goods.spec,
                                              p.goods.material,
                                              p.goods.sourceType,
                                            ]
                                            .where(
                                              (s) => s != null && s.isNotEmpty,
                                            )
                                            .join(' · '),
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(
                                              color: theme
                                                  .colorScheme
                                                  .onSurfaceVariant,
                                            ),
                                      ),
                                    ],
                                  ),
                                ),
                                SizedBox(
                                  width: 84,
                                  child: TextField(
                                    controller: p.qtyCtl,
                                    keyboardType:
                                        const TextInputType.numberWithOptions(
                                          decimal: true,
                                        ),
                                    decoration: const InputDecoration(
                                      labelText: '数量',
                                      border: OutlineInputBorder(),
                                      isDense: true,
                                    ),
                                  ),
                                ),
                                IconButton(
                                  icon: const Icon(
                                    Icons.close_rounded,
                                    size: 18,
                                  ),
                                  onPressed: () => setState(() {
                                    p.qtyCtl.dispose();
                                    _picked.remove(p);
                                  }),
                                ),
                              ],
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
              _dialogActions(
                theme,
                onCancel: () => Navigator.of(context).pop(),
                onSave: _save,
                saving: _saving,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 编辑组件对话框（单条）：组件与父级锁定（换组件/换父级走删除+新增），
/// 用量、生产管控和备注可改。
class _BomItemEditDialog extends ConsumerStatefulWidget {
  const _BomItemEditDialog({
    required this.parentGoodsId,
    required this.editing,
  });

  final String parentGoodsId;
  final GoodsBomItem editing;

  @override
  ConsumerState<_BomItemEditDialog> createState() => _BomItemEditDialogState();
}

class _BomItemEditDialogState extends ConsumerState<_BomItemEditDialog> {
  final _qtyCtl = TextEditingController();
  final _summaryCtl = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final e = widget.editing;
    _qtyCtl.text = e.qty?.toString() ?? '';
    _summaryCtl.text = e.summary ?? '';
  }

  @override
  void dispose() {
    _qtyCtl.dispose();
    _summaryCtl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final qty = double.tryParse(_qtyCtl.text.trim());
    if (qty == null || qty <= 0) {
      setState(() => _error = '「数量」必须是大于 0 的数字'); // TODO(l10n): 补 arb
      return;
    }
    final e = widget.editing;
    final body = <String, dynamic>{
      'componentGoodsId': e.componentGoodsId,
      'qty': qty,
      'price': e.price,
      // 编辑数量/备注时必须保留迁移来的行级颜色覆盖。
      'colorLegacyId': e.colorLegacyId,
      'summary': _summaryCtl.text.trim().isEmpty
          ? null
          : _summaryCtl.text.trim(),
    };
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref
          .read(goodsBomRepositoryProvider)
          .update(widget.parentGoodsId, e.id, body);
      if (!mounted) return;
      context.appSuccess('组件已更新'); // TODO(l10n): 补 arb
      Navigator.of(context).pop(true);
    } on ApiException catch (ex) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = ex.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = '保存失败，请稍后重试';
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
              _dialogHeader(context, theme, '编辑组件'),
              const Divider(height: 1),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(UtenSpacing.s16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 组件信息卡（只读）：编号/名称/型号/规格/单位/颜色/材质/来源
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(UtenSpacing.s12),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primaryContainer,
                          borderRadius: UtenRadius.mdAll,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${e.componentCode ?? ''}  ${e.componentName ?? ''}',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Wrap(
                              spacing: UtenSpacing.s12,
                              runSpacing: 2,
                              children: [
                                _kv(theme, '型号', e.componentModel),
                                _kv(theme, '规格', e.componentSpec),
                                _kv(theme, '材质', e.componentMaterial),
                                _kv(theme, '单位', e.componentUnitName),
                                _kv(theme, '颜色', e.componentColorName),
                                _kv(theme, '来源', e.componentSourceType),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: UtenSpacing.s12),
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
                                labelText: '数量',
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                            ),
                          ),
                          const SizedBox(width: UtenSpacing.s12),
                          Expanded(
                            child: InputDecorator(
                              decoration: const InputDecoration(
                                labelText: '单价（取自组件）',
                                border: OutlineInputBorder(),
                                isDense: true,
                                filled: true,
                              ),
                              child: Text(
                                e.price == null ? '' : e.price.toString(),
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: UtenSpacing.s12),
                      TextField(
                        controller: _summaryCtl,
                        decoration: const InputDecoration(
                          labelText: '备注',
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
              _dialogActions(
                theme,
                onCancel: () => Navigator.of(context).pop(),
                onSave: _save,
                saving: _saving,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// —— 弹窗公共片段 ——

Widget _dialogHeader(BuildContext context, ThemeData theme, String title) {
  return Padding(
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
            title,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    ),
  );
}

Widget _dialogActions(
  ThemeData theme, {
  required VoidCallback onCancel,
  required VoidCallback onSave,
  required bool saving,
}) {
  return Padding(
    padding: const EdgeInsets.all(UtenSpacing.s16),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        UtenButton(
          type: UtenButtonType.secondary,
          onPressed: onCancel,
          child: const Text('取消'),
        ),
        const SizedBox(width: UtenSpacing.s12),
        UtenButton(
          icon: Icons.save_outlined,
          isLoading: saving,
          onPressed: onSave,
          child: const Text('保存'),
        ),
      ],
    ),
  );
}

Widget _kv(ThemeData theme, String label, String? value) {
  final has = value != null && value.isNotEmpty;
  return Text.rich(
    TextSpan(
      children: [
        TextSpan(
          text: '$label：',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        TextSpan(text: has ? value : '—'),
      ],
    ),
  );
}
