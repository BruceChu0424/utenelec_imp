// 货品详情「组装信息」页签：BOM 组件树（懒加载子级）+ 增删改（goods:edit）
// + 审计模式（goods:bom:audit，V256）。
//
// 审计模式：工具条「审计模式」按钮进入后，单击行把该组件标记为「已核对无误」
// （再点取消），已审行浅绿底 + 「已审」列 ✓。标记持久化在服务端
// （goods_bom_items.audited_at/_by），多人/跨天/换机器不丢；编辑组件行内容后
// 服务端自动清除该行的审计标记（内容变了需重新核对）。已审绿色对所有人可见，
// 「审计模式」按钮仅 goods:bom:audit 持有者可见。
//
// 树结构：一级 = 当前货品的组件清单；组件自身有 BOM（hasChildren）可展开，
// 展开时对组件 id 再调 list 接口懒加载（对照老系统 001.jpg 的 +/- 树）。
//
// 多选批量删除(2026-09-21 用户口径「组件信息最前面加个多选框，可以多选批量
// 删除」)：表格最前列由 MasterDataTableView 自己渲染勾选框 + 表头三态全选，
// 选中集 _selectedRowIds 是本页唯一的「当前选中」真相——「编辑」只在恰好勾中
// 一条时可用，「删除」勾中一条起就是批量删除。行键用 `父货品id|关系行id` 复合
// 键：同一个子件可能同时挂在两个父件下并各自展开，光用关系行 id 会串行；复合
// 键正好也是删除要的(父货品, 关系行)二元组。审计模式例外，见下。
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
import '../../../components/buttons/uten_export_button.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../core/network/api_error.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/action_feedback.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/widgets/uten_tree_table_cell.dart';
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
  const _BomRow(
    this.node,
    this.depth,
    this.seq,
    this.parentGoodsId,
    this.ancestorContinuations,
    this.isLastChild,
  );

  final _BomNode node;
  final int depth;
  final String seq;

  /// 该 BOM 行真正所属的父货品；嵌套行不能误用页面根货品 id。
  final String parentGoodsId;
  final List<bool> ancestorContinuations;
  final bool isLastChild;
}

/// 添加组件时的父级候选项（顶层本货品 或 任一可见组件）。
class _BomParentOption {
  const _BomParentOption({required this.goodsId, required this.label});
  final String goodsId;
  final String label;
}

/// 批量删除的一条目标：一条组装关系(挂在哪个父货品下 + 关系行 id)
/// 加上确认框要用的人话标签与「是不是子件自己的明细」。
class _BomDeleteTarget {
  const _BomDeleteTarget({
    required this.parentGoodsId,
    required this.itemId,
    required this.label,
    required this.nested,
  });

  final String parentGoodsId;
  final String itemId;
  final String label;

  /// true = 这条关系不是直接挂在本页货品下的(删它改的是某个子件自己的
  /// 组装清单，用到该子件的其它货品都会跟着变)。
  final bool nested;
}

/// 「添加组件」弹窗里的选货入口(组件范围、多选)。独立成 provider，组件测试可以换成
/// 固定结果，而不必驱动整套分类树 + 分页选货面板。
final bomComponentPickerProvider =
    Provider<
      Future<List<GoodsListItem>> Function(BuildContext context, WidgetRef ref)
    >(
      (ref) =>
          (context, ref) => showUtenGoodsPickerMulti(context, ref),
    );

class GoodsBomTab extends ConsumerStatefulWidget {
  const GoodsBomTab({
    super.key,
    required this.goodsId,
    required this.canCreate,
    required this.canEdit,
    required this.canDelete,
    this.productCode,
    this.productName,
    this.onPreview,
    this.onDataChanged,
  });

  final String goodsId;
  final bool canCreate;
  final bool canEdit;
  final bool canDelete;

  /// 导出文件名用（产品配件清单_编号/名称）。
  final String? productCode;
  final String? productName;

  /// 打开 A4 产品配件清单预览（goods_bom_preview.dart）。由宿主 GoodsDetailBody
  /// 接线（要读 _detail 的型号等）；按钮渲染在表格工具条「全屏」旁（2026-09-12
  /// 从详情头部迁入，样式与全屏按钮同款）。
  final VoidCallback? onPreview;

  final VoidCallback? onDataChanged;

  @override
  ConsumerState<GoodsBomTab> createState() => _GoodsBomTabState();
}

class _GoodsBomTabState extends ConsumerState<GoodsBomTab>
    with AutomaticKeepAliveClientMixin {
  List<_BomNode>? _roots;
  bool _loading = true;
  String? _error;

  /// 当前勾选的行键集合(复合键 `父货品id|关系行id`，见 [_rowId])。
  ///
  /// 本页「当前选中」的唯一真相：多选态由表格最前列勾选框写入，审计模式的单击
  /// 单选也写这里。不再另留一个 _selected 字段，否则两份真相一旦错位，批量删除
  /// 删的就不是用户勾的那几条。
  Set<String> _selectedRowIds = <String>{};

  /// 批量删除的网络段进行中(只包住网络调用本身，确认框弹出时必须是 false)。
  bool _deleting = false;

  /// 当前展开的组件 goodsId 集合：CRUD 重载后据此恢复展开，让新加的子组件可见。
  final Set<String> _expandedIds = {};

  /// 审计模式（V256）：点行把该组件标记为「已核对无误」（绿色），再点取消。
  /// 标记持久化在服务端，多人/跨天/换机器都保留；编辑行内容后服务端自动清除。
  bool _auditMode = false;

  /// 审计标记请求防并发（连点同一行导致标记状态来回翻转）。
  bool _auditBusy = false;

  /// 「审计模式」按钮可见性：goods:bom:audit 或超管（已审绿色对所有人可见，
  /// 只有持有权限者能改标记）。
  bool get _canAudit =>
      ref.watch(isSuperAdminProvider) ||
      ref.watch(currentPermissionsProvider).contains(Perm.goodsBomAudit);

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
        // 重载会重建全部行/节点对象，但勾选集用的是业务复合键而非对象引用，
        // 所以审计标记、编辑保存后的重载不会平白丢掉用户的勾选；真正已经不在
        // 树里的行(刚被删掉的、父级子树没恢复展开的)在这里一并剪掉，
        // 避免编辑/删除去指一个已经不存在的 id。
        _pruneSelection();
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
  ///
  /// `ancestorContinuations` 按 [UtenTreeTableCell] 的硬契约累积：长度恒等于
  /// depth、`[i]` = 深度 i 的祖先后面还有没有兄弟。这里的展开是懒加载的
  /// （`hasChildren` 是服务端事实，不能从扁平行推），所以保留本地 walk；
  /// 同口径的通用推导见 `utenTreeProjection`。
  List<_BomRow> get _visibleRows {
    final rows = <_BomRow>[];
    void walk(
      List<_BomNode> nodes,
      int depth,
      String prefix,
      String parentGoodsId,
      List<bool> ancestorContinuations,
    ) {
      for (var i = 0; i < nodes.length; i++) {
        final seq = prefix.isEmpty ? '${i + 1}' : '$prefix.${i + 1}';
        final n = nodes[i];
        final isLastChild = i == nodes.length - 1;
        rows.add(
          _BomRow(
            n,
            depth,
            seq,
            parentGoodsId,
            List.unmodifiable(ancestorContinuations),
            isLastChild,
          ),
        );
        if (n.expanded && n.children != null) {
          walk(n.children!, depth + 1, seq, n.item.componentGoodsId, [
            ...ancestorContinuations,
            !isLastChild,
          ]);
        }
      }
    }

    walk(_roots ?? const <_BomNode>[], 0, '', widget.goodsId, const []);
    return rows;
  }

  /// 行键：`父货品id|关系行id`。
  ///
  /// _BomRow 没有天然唯一 id——同一个子件可能同时挂在两个父件下并各自展开，
  /// 此时两行的 node.item.id 一模一样。复合键把「挂在谁下面」也算进身份，同时
  /// 正好就是删除动作需要的(父货品, 关系行)二元组。一条关系在树里出现两次时
  /// 两处会一起勾上，这是**正确**的：删的本来就是同一条关系。
  static String _rowId(_BomRow r) => '${r.parentGoodsId}|${r.node.item.id}';

  /// 把已经看不见的行从勾选集里剪掉。
  ///
  /// 「看到的勾选 = 提交的内容」：勾了子级行再把父级折叠起来，该行从表里消失、
  /// id 却还留在集合里——「已选 N 项」数得对，用户却一条都看不见，点批量删除就会
  /// 删掉屏幕上根本没有的组件。宁可丢掉这几条勾选，也不能删用户看不见的东西。
  /// 必须在改完 _roots / 展开状态之后调用(它按新的可见行重算)。
  void _pruneSelection() {
    if (_selectedRowIds.isEmpty) return;
    final visible = <String>{for (final r in _visibleRows) _rowId(r)};
    _selectedRowIds = _selectedRowIds.intersection(visible);
  }

  /// 恰好勾中一条时的那一行(编辑、以及「添加组件」的默认父级都只认单条)。
  /// 勾了 0 条或多条一律返回 null——多选时目标不明确，宁可灰掉按钮也不替用户猜。
  _BomRow? get _singleSelectedRow {
    if (_selectedRowIds.length != 1) return null;
    final id = _selectedRowIds.first;
    for (final r in _visibleRows) {
      if (_rowId(r) == id) return r;
    }
    return null;
  }

  /// 勾选集 → 批量删除目标(按行键去重，一条关系只提交一次)。
  List<_BomDeleteTarget> get _selectedTargets {
    final rows = _visibleRows;
    // 父件名字典：某行的 componentGoodsId 就是它作为下一层父件时的 parentGoodsId。
    // 确认框要能说出「这条挂在谁下面」——只列组件名的话，用户看不出自己动的是哪个
    // 共用子件的清单，而那恰好是这个警告想拦住的误删。
    final parentNames = <String, String>{};
    for (final r in rows) {
      final item = r.node.item;
      final label = item.componentName?.trim().isNotEmpty == true
          ? item.componentName!.trim()
          : item.componentCode?.trim();
      if (label != null && label.isNotEmpty) {
        parentNames.putIfAbsent(item.componentGoodsId, () => label);
      }
    }
    final byRowId = <String, _BomDeleteTarget>{};
    for (final r in rows) {
      final id = _rowId(r);
      if (!_selectedRowIds.contains(id)) continue;
      final item = r.node.item;
      final name = item.componentName?.trim();
      final code = item.componentCode?.trim();
      // 级联号打头，让人在确认框里能和表里的行一一对上；名称在前编号在后。
      final identity = [
        if (name != null && name.isNotEmpty) name,
        if (code != null && code.isNotEmpty) code,
      ].join(' ');
      final display = identity.isEmpty ? '未命名组件' : identity;
      // 不是直接挂在本货品下 = 删的是某个子件自己的组装明细，影响面不止
      // 当前货品，确认框要为此单独出警告。
      final nested = r.parentGoodsId != widget.goodsId;
      final parentName = nested ? parentNames[r.parentGoodsId] : null;
      byRowId.putIfAbsent(
        id,
        () => _BomDeleteTarget(
          parentGoodsId: r.parentGoodsId,
          itemId: item.id,
          label: parentName == null
              ? '${r.seq} $display'
              : '${r.seq} $display — 挂在「$parentName」下',
          nested: nested,
        ),
      );
    }
    return byRowId.values.toList();
  }

  Future<void> _toggle(_BomNode node) async {
    final id = node.item.componentGoodsId;
    if (!node.item.hasChildren) return;
    if (node.expanded) {
      setState(() {
        node.expanded = false;
        _expandedIds.remove(id);
        // 整棵子树的行随折叠消失，它们的勾选跟着剪掉(见 _pruneSelection)。
        _pruneSelection();
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

  // ---- 增删改 -------------------------------------------------------------
  //
  // 添加组件：选中某组件行 → 默认作为该组件的子组件；未选中 → 顶层。弹窗内父级可选。
  // 保存 POST 到所选父级 goods 的 BOM（/master/goods/{parentGoodsId}/bom）。

  Future<void> _addItem() async {
    final candidates = <_BomParentOption>[
      _BomParentOption(goodsId: widget.goodsId, label: '顶层(本货品)'),
      for (final r in _visibleRows)
        _BomParentOption(
          goodsId: r.node.item.componentGoodsId,
          label:
              '${r.seq} · 层级 ${r.depth + 1} · '
              '${r.node.item.componentName ?? r.node.item.componentCode ?? ''}',
        ),
    ];
    // 只勾一条时默认加在它下面；勾了 0 条或多条都回落顶层(多选时「加在谁下面」
    // 没有唯一答案，弹窗里再让用户自己选)。
    final defaultParent =
        _singleSelectedRow?.node.item.componentGoodsId ?? widget.goodsId;
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
    final row = _singleSelectedRow;
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

  /// 批量删除勾中的组件(勾中一条也走这条路，删除动作只有一个实现)。
  ///
  /// 确认框弹出前不能有任何 busy 态：UtenBusyOverlay 是挂 root Overlay 的裸
  /// entry，Navigator 每次 rearrange 都把它重新抬到最顶，会盖住之后弹出的对话框
  /// 并让它点不动(全站铁律)。所以遮罩只包住确认之后的纯网络段，且 finally 必清。
  Future<void> _deleteSelected() async {
    final targets = _selectedTargets;
    if (targets.isEmpty) return;
    final nestedCount = targets.where((t) => t.nested).length;
    // 清单太长会把确认框撑成一屏文字，前 10 条足够让人认出自己勾了什么。
    final shown = targets.take(10).toList();
    final rest = targets.length - shown.length;
    // TODO(l10n): 本弹窗文案待进 arb。
    final dialogTitle = targets.length == 1
        ? '删除组件'
        : '删除 ${targets.length} 个组件';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return AlertDialog(
          title: Text(dialogTitle),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('确定把下面 ${targets.length} 个组件从组装清单里删掉吗？'),
                  // 跨层级警告：删子级行改的是那个子件自己的组装清单，影响面
                  // 不止眼前这个货品。真实踩过的坑，所以单独出大字警告。
                  if (nestedCount > 0) ...[
                    const SizedBox(height: UtenSpacing.s12),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(UtenSpacing.s12),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.errorContainer,
                        borderRadius: UtenRadius.mdAll,
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.warning_amber_rounded,
                            size: 20,
                            color: theme.colorScheme.onErrorContainer,
                          ),
                          const SizedBox(width: UtenSpacing.s8),
                          Expanded(
                            child: Text(
                              '注意：其中 $nestedCount 个不是直接装在本货品上的，'
                              '删掉改的是那个子件自己的组装清单。'
                              '以后凡是用到该子件的货品，做出来都会跟着少这几样料，不只是眼前这个货品。',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onErrorContainer,
                                fontWeight: FontWeight.w600,
                                height: 1.45,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: UtenSpacing.s12),
                  for (final t in shown)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Text(
                        '· ${t.label}',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  if (rest > 0)
                    Text(
                      '还有 $rest 条未列出',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
          ),
          actionsAlignment: MainAxisAlignment.center,
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'), // TODO(l10n): 补 arb
            ),
            FilledButton(
              key: const Key('goods-bom-batch-delete-confirm'),
              style: FilledButton.styleFrom(backgroundColor: UtenColors.error),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除'), // TODO(l10n): 补 arb
            ),
          ],
        );
      },
    );
    if (ok != true) return;
    if (!mounted) return;

    // 勾选可能横跨树的多层：服务端按本货品的组装树核对每一行(ADR-111)，
    // 一次请求、一个事务，要么全删要么一条不删——不再按父货品分组逐组提交。
    if (targets.length > _batchDeleteLimit) {
      context.appError(
        '一次最多删除 $_batchDeleteLimit 个组件，请分几次勾选', // TODO(l10n): 补 arb
      );
      return;
    }
    setState(() => _deleting = true);
    int? deleted;
    try {
      deleted = await context.guardAction(
        () => ref.read(goodsBomRepositoryProvider).deleteMany(widget.goodsId, [
          for (final t in targets) t.itemId,
        ]),
        errorFallback: '删除失败，请稍后重试', // TODO(l10n): 补 arb
      );
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
    if (!mounted) return;
    if (deleted != null) {
      context.appSuccess('已删除 $deleted 个组件'); // TODO(l10n): 补 arb
      widget.onDataChanged?.call();
    }
    // 失败也重载：树可能已被别人改过，重载顺带把删掉的行从勾选集剪掉。
    await _load();
  }

  /// 单次批量删除请求的条数上限(与服务端 itemIds 上限一致)。
  static const int _batchDeleteLimit = 500;

  // ---- 审计标记（V256） ---------------------------------------------------
  //
  // 审计模式下单击行 = 标记/取消「已核对无误」（已审行绿色 + 「已审」列 ✓）。
  // 标记写服务端 goods_bom_items.audited_at/_by：多人协作、跨天核对不丢。
  // 双击仍展开/收起子级（第一击已翻面标记属预期，展开后子组件才可逐行审）。

  Future<void> _toggleAudited(_BomRow row) async {
    if (_auditBusy) return;
    _auditBusy = true;
    final item = row.node.item;
    try {
      await ref
          .read(goodsBomRepositoryProvider)
          .setAudited(row.parentGoodsId, item.id, !item.audited);
      if (!mounted) return;
      await _load(); // 重载保留展开状态（_expandedIds），新标记即刻显色
    } on ApiException catch (e) {
      if (!mounted) return;
      context.appError(e.message);
    } catch (_) {
      if (!mounted) return;
      context.appError('审计标记失败，请稍后重试'); // TODO(l10n): 补 arb
    } finally {
      _auditBusy = false;
    }
  }

  // ---- 渲染 ---------------------------------------------------------------

  /// 表格列（与 MasterDataTableView 对齐：key 仅标识用，本页不接筛选/排序）。
  /// 售价可见性（goods:price:view，V570）：无授权者「单价/金额」两列整列移除
  ///（服务端 BOM 行 price/total 已同步置 null）。
  List<MasterColumnDef<_BomRow>> get _columns {
    final canViewPrice =
        ref.watch(isSuperAdminProvider) ||
        ref.watch(currentPermissionsProvider).contains(Perm.goodsPriceView) ||
        ref.watch(currentPermissionsProvider).contains(Perm.goodsPriceEdit);
    return [
      // 层级身份集中在首列：级联号 + 明确层级文字 + 连续树轨 + 48dp
      // 单击展开按钮。行单击只负责选中，不再让“双击整行”兼任树导航。
      // 2026-09-12 用户口径「只显示名字和组件X级」：身份格不再堆路径行与编号
      // 副标题（编号看「编号」列），副标题仅剩懒加载中的提示。
      MasterColumnDef(
        key: 'treeIdentity',
        label: '层级 / 组件',
        width: 320,
        value: (r) =>
            '${r.seq} 组件 ${r.depth + 1} 级 '
            '${r.node.item.componentName ?? ''}',
        cellBuilderHandlesSemantics: true,
        // 树列吃满整行高度 + 连线跨过数据格纵向内边距，否则层级竖线会在
        // 行与行之间断开（与物料分析主表 / 级联页同一处理，2026-09-15）。
        fillsCellHeight: true,
        cellBuilder: (context, r) => UtenTreeTableCell(
          key: ValueKey('goods-bom-tree-cell-${r.node.item.id}'),
          toggleKey: ValueKey('goods-bom-tree-toggle-${r.node.item.id}'),
          depth: r.depth,
          guideBleed: MasterDataTableView.cellVerticalPadding,
          sequence: r.seq,
          levelLabel: '组件 ${r.depth + 1} 级',
          title:
              r.node.item.componentName ?? r.node.item.componentCode ?? '未命名组件',
          subtitle: r.node.loading ? '正在加载下级…' : null,
          hasChildren: r.node.item.hasChildren,
          expanded: r.node.expanded,
          onToggle: r.node.loading ? null : () => _toggle(r.node),
          ancestorContinuations: r.ancestorContinuations,
          isLastChild: r.isLastChild,
        ),
      ),
      // 已审列（V256）：审计标记为服务端持久数据，对所有人可见（✓ + 行变绿）；
      // 改标记要 goods:bom:audit，进「审计模式」点行翻面。
      MasterColumnDef(
        key: 'audited',
        label: '已审',
        width: 56,
        value: (r) => r.node.item.audited ? '✓' : '',
      ),
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
      if (canViewPrice) ...[
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
      ],
      MasterColumnDef(
        key: 'summary',
        label: '备注',
        width: 120,
        value: (r) => r.node.item.summary,
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAliveClientMixin
    final roots = _roots ?? const <_BomNode>[];
    final visible = _visibleRows;
    final auditedCount = visible.where((r) => r.node.item.audited).length;
    // 勾中条数决定工具条两个按钮的可用性：编辑只认 1 条，删除 >=1 条即可。
    final selectedCount = _selectedRowIds.length;
    // 勾选框要不要给：审计模式下单击行是「翻已核对」，与勾选打架，一律关掉；
    // 三个动作(批量删除/编辑/添加组件定位)一个都没权限时也关掉——只读账号看到
    // 一整列勾选框却没有任何按钮可接，勾了等于白勾，按准则「隐藏而非禁用」。
    final canActOnSelection =
        widget.canDelete || widget.canEdit || widget.canCreate;
    final selectable = !_auditMode && canActOnSelection;
    // 说明条只讲这个账号真能做的事：没有删除权还写着「可勾多行一起删除」，
    // 等于教用户去点一个不存在的按钮。
    // TODO(l10n): 本段提示待进 arb。
    final hints = <String>[
      '层级列箭头可展开',
      if (selectable && widget.canDelete) '最前面的方框可勾多行一起删除',
      if (selectable && widget.canEdit) '只勾一行时「编辑」可用',
      if (selectable && widget.canCreate) '只勾一行时「添加组件」默认加在它下面',
    ];
    return Column(
      children: [
        // 批量删除网络段的全屏加载遮罩(root Overlay 传送门，不占布局)。
        // 确认框已经关掉才会挂上来，否则它会盖住确认框(见 _deleteSelected)。
        if (_deleting)
          const UtenBusyOverlay(
            title: '正在删除组件',
            description: '正在把所选组件从组装清单中移除，请勿重复提交或关闭页面。',
          ),
        // 说明条：组件数 / 操作提示；审计模式下显示核对进度。
        // 编辑/删除/添加组件/审计模式按钮已挪进表格工具条
        // （toolbarActions），全屏表格路由里也带同一组按钮与逻辑。
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
                      : _auditMode
                      ? '审计模式：点击行标记/取消「已核对无误」(已审 $auditedCount/${visible.length}；编辑组件后需重新核对)' // TODO(l10n)
                      : (roots.isEmpty
                            ? '该货品暂无组装信息'
                            : '共 ${roots.length} 个顶层组件(${hints.join('；')})'),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: _auditMode
                        ? Colors.green.shade700
                        : Theme.of(context).colorScheme.onSurfaceVariant,
                    fontWeight: _auditMode ? FontWeight.w600 : null,
                  ),
                ),
              ),
            ],
          ),
        ),
        // 统一表格（与货品资料列表同款）：Excel 表头分隔线 + 拖拽列宽 + 底部横滑条。
        Expanded(
          child: MasterDataTableView<_BomRow>(
            // 按 selectable 分键，进出审计模式时整棵表重建而不是原地重排。
            // 勾选列的出现/消失会把行子树换一个父级，SelectionArea 的
            // SelectionKeepAlive 带着 GlobalKey 一起被搬走，于是同一帧里
            // 「Duplicate GlobalKeys detected」+ 释放时 null check 崩(widget 树
            // finalize 阶段)。代价是切模式会丢掉列宽与滚动位置，可以接受：那本来
            // 就是一次模式切换，不是刷新。
            key: ValueKey('goods-bom-table-$selectable'),
            columns: _columns,
            items: visible,
            facets: const {},
            nullCounts: const {},
            filters: const {},
            onFilterChanged: (_, _) {},
            // 多选：最前列勾选框 + 表头三态全选，工具条驻「已选 N 项 + 清除」。
            // **审计模式下必须关掉**——那时单击行的语义是翻「已核对无误」，与
            // 「单击切换勾选」直接打架；审计模式因此退回原来的单选点击。
            // 只读账号(三个动作都没权限)同样不给勾选框，见 [canActOnSelection]。
            selectable: selectable,
            // _BomRow 无天然唯一 id，用复合键(见 _rowId)。
            idOf: _rowId,
            selectedIds: _selectedRowIds,
            onSelectedIdsChanged: (next) =>
                setState(() => _selectedRowIds = next),
            // 下面两个回调只在审计模式(selectable=false)生效：多选态下表格会
            // 忽略它们(master_data_table_view.dart 的硬契约)。两种模式都写同一个
            // _selectedRowIds，页面里不存在第二份「当前选中」。
            onSelectionChanged: (row) {
              setState(() => _selectedRowIds = {_rowId(row)});
              if (_auditMode) _toggleAudited(row);
            },
            // _BomRow 每次 build 重建(引用变)，故按行键比较而非引用相等。
            isSelected: (row) => _selectedRowIds.contains(_rowId(row)),
            // 已审行浅绿底（审计标记持久在服务端，对所有人可见）；
            // 单击选中时表格组件自动加深加亮。
            rowColor: (r) => r.node.item.audited
                ? Colors.green.withValues(alpha: 0.15)
                : null,
            // 编辑/删除/添加组件：挂进表格工具条——普通态显示在「全屏」按钮旁，
            // 进全屏后由全屏路由同位置渲染，按钮逻辑（本 State 的增删改方法）
            // 与选中态（didUpdateWidget → _fsTick 驱动全屏重建）全部生效。
            // 「预览」（A4 产品配件清单）2026-09-12 从详情头部迁入：走
            // toolbarLeadingActions 紧挨「全屏」按钮，样式同款（48 高、primary），
            // 全屏路由与空态工具条同位置渲染。
            toolbarLeadingActions: [
              if (widget.onPreview != null)
                UtenButton(
                  key: const ValueKey('goods-bom-preview'),
                  size: UtenButtonSize.large,
                  height: UtenTableToolbar.controlHeight,
                  icon: Icons.preview_outlined,
                  onPressed: widget.onPreview,
                  child: const Text('预览'), // TODO(l10n): 补 arb
                ),
            ],
            toolbarActions: [
              // 页面主动作置于业务工具条最前：持有独立 goods:bom:create 即显示，
              // 不依赖 goods:edit，窄屏换行时也不会被次要导出/编辑动作挤到末尾。
              if (widget.canCreate)
                UtenButton(
                  key: const Key('goods-bom-add-component'),
                  size: UtenButtonSize.large,
                  icon: Icons.add_rounded,
                  onPressed: _addItem,
                  child: const Text('添加组件'), // TODO(l10n): 补 arb
                ),
              // 导出组件（goods:export）：与「预览」弹窗里的下载Excel 同一端点
              // （整树展开的加密 xlsx），此处是组装信息页签的直接入口。
              UtenExportButton(
                endpoint: ApiEndpoints.goodsBomExport(widget.goodsId),
                requiredPermission: Perm.goodsExport,
                report: '',
                queryParams: const {},
                filename:
                    '产品配件清单_${widget.productCode ?? widget.productName ?? widget.goodsId}',
                label: '导出组件', // TODO(l10n): 补 arb
                size: UtenButtonSize.large,
              ),
              // 编辑只对一条生效：勾了多条时目标不明确，宁可灰掉也不替用户猜。
              if (widget.canEdit)
                UtenButton(
                  type: UtenButtonType.secondary,
                  size: UtenButtonSize.large,
                  icon: Icons.edit_outlined,
                  onPressed: selectedCount == 1 ? _editSelected : null,
                  child: const Text('编辑'), // TODO(l10n): 补 arb
                ),
              // 删除：勾一条起可用，一律走批量路径(条数在确认框里报)。
              // 按钮文字不带条数——已选数由工具条的「已选 N 项」胶囊负责。
              if (widget.canDelete)
                UtenButton(
                  key: const Key('goods-bom-delete-selected'),
                  type: UtenButtonType.danger,
                  size: UtenButtonSize.large,
                  icon: Icons.delete_outline,
                  onPressed: selectedCount == 0 ? null : _deleteSelected,
                  child: const Text('删除'), // TODO(l10n): 补 arb
                ),
              // 审计模式（V256，goods:bom:audit）：开=点行标记/取消「已核对无误」
              // （已审行绿色）。与编辑权限解耦——质检可以只有审计权没有编辑权。
              if (_canAudit)
                UtenButton(
                  type: _auditMode
                      ? UtenButtonType.primary
                      : UtenButtonType.tonal,
                  size: UtenButtonSize.large,
                  icon: Icons.fact_check_outlined,
                  onPressed: () => setState(() {
                    _auditMode = !_auditMode;
                    // 两种模式的「选中」语义不同(勾选集 vs 单选高亮)，切换时
                    // 不清空就会留下看不见的残留勾选：退出审计后一点「删除」，
                    // 删的是用户压根没勾过的行。
                    _selectedRowIds = <String>{};
                  }),
                  child: Text(_auditMode ? '退出审计' : '审计模式'), // TODO(l10n)
                ),
            ],
            isLoading: _loading && _roots == null,
            error: _error,
            onRetry: _load,
            emptyMessage: '暂无组装信息，点上方「添加组件」录入', // TODO(l10n): 补 arb
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
///
/// 保存走服务端「追加组件」原子命令(ADR-111，与粘贴组件同一个接口)：一次请求、一个事务，
/// 任何一行不合格(重复、成环、组件停用……)一条都不写，逐行原因留在弹窗里给用户改，
/// 不再逐个新建、失败的只报「N 个跳过」。
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

  /// 服务端逐行给出的不合格原因(「第几行 哪个组件：为什么」)。
  List<String> _problems = const [];

  /// 单次追加的组件上限(与服务端粘贴命令的行数上限一致)。
  static const int _maxLines = 200;

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
    final list = await ref.read(bomComponentPickerProvider)(context, ref);
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
    if (_picked.length > _maxLines) {
      setState(() => _error = '一次最多添加 $_maxLines 个组件，请分几次添加'); // TODO(l10n)
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
      _problems = const [];
    });
    try {
      final result = await ref
          .read(goodsBomRepositoryProvider)
          .paste(
            mode: BomPasteMode.append,
            targets: [BomPasteTarget(_parentGoodsId)],
            items: bodies,
          );
      if (!mounted) return;
      context.appSuccess('已添加 ${result.added} 个组件'); // TODO(l10n): 补 arb
      Navigator.of(
        context,
      ).pop(_AddResult(saved: true, parentGoodsId: _parentGoodsId));
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e.message.isNotEmpty ? e.message : '添加失败'; // TODO(l10n)
        _problems = [
          for (final f in e.fieldErrors ?? const <ApiFieldError>[])
            f.field.isEmpty ? f.message : '${f.field}：${f.message}',
        ];
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = '添加失败，请稍后重试'; // TODO(l10n): 补 arb
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
              // 批量添加组件网络段的全屏加载遮罩（root Overlay 传送门，不占布局）。
              if (_saving)
                const UtenBusyOverlay(
                  title: '正在添加 BOM 组件',
                  description: '正在一次写入全部组件关系，请勿重复提交或关闭弹窗。',
                ),
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
                      UtenDropdownField(
                        dense: true,
                        value: _parentGoodsId,
                        allowClear: false,
                        items: [
                          for (final p in widget.parentCandidates)
                            UtenDropdownItem(value: p.goodsId, label: p.label),
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
                          key: const Key('goods-bom-add-error'),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.error,
                          ),
                        ),
                        for (final problem in _problems)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              '· $problem',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.error,
                              ),
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
      // 实时关联只回传 UUID；历史 legacy 快照缺少 UUID 时不解析、不覆盖。
      if (e.colorId != null) 'colorId': e.colorId,
      if (e.defaultSupplierId != null) 'defaultSupplierId': e.defaultSupplierId,
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
                                labelText: '单价(取自组件)',
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
