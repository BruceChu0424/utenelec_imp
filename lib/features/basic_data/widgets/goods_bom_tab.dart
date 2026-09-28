// 货品详情「组装信息」页签：BOM 组件树（懒加载子级）+ 增删改（goods:edit）
// + 审计模式（goods:bom:audit，V256）。
//
// 审计模式：工具条「审计模式」按钮进入后（进行中按钮转红色「退出审计」），
// 已审行浅绿底 + 「已审」列（实心圆对勾/空心圆，点这一格即翻状态）——都只在
// 该模式出现，关闭审计模式就是普通清单视图。右键菜单也提供「标记/取消已核对
// 无误」；单击行本身始终是选中，审计模式下照样可以勾多行批量删除。
// 标记持久化在服务端（goods_bom_items.audited_at/_by），多人/跨天/换机器不丢；
// 编辑组件行内容后服务端自动清除该行的审计标记（内容变了需重新核对）。
// 「审计模式」按钮仅 goods:bom:audit 持有者可见。
//
// 工具条（2026-09-25 口径）：顶部按钮全部靠左（表头设置/全屏 + BOM学习记录/
// 预览/导出组件/导入组件/审计模式），统一高度 UtenTableToolbar.controlHeight、
// 同色（primary）、不带 icon；「已选 N 项 + 添加组件/编辑/删除」驻右下悬浮组
// （batchActionsBuilder，普通视图与全屏路由同款）。
//
// 右键（2026-09-25 统一口径）：右键 = 选中当前行 + UtenContextMenu 自绘小框
// （编辑/添加子组件/删除/审计标记），与货品资料列表同款；此前没挂菜单时右键
// 命中文本会弹框架默认的「全选/复制」工具条，看着像一整屏遮罩。
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
//
// 两个用量(ADR-129)：「设计使用数量」= goods_bom_items.qty(原「数量」，工程
// 人员维护，必填)；其后只读「真实使用数量」= 学习累计(与设计值同一计量口径，
// 没有数据或不适用显示「—」，悬停说明原因、有效批次和累计产量)。系统学出的
// 组件在身份格带「系统学习」标记；编辑它只在改了设计使用数量时才提交数量
// (改了即转为人工维护)，删除它后系统不再自动加回。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/buttons/uten_export_button.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/feedback/uten_inline_notice.dart';
import '../../../components/inputs/required_field_decoration.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../core/l10n/gen/app_localizations.dart';
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
import 'goods_bom_import_dialog.dart';
import 'master_data_table_view.dart';
import 'uten_goods_picker.dart';
import 'goods_bom_learning_panel.dart';
import 'periodic_bom_confirmation.dart';

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
    required this.learned,
  });

  final String parentGoodsId;
  final String itemId;
  final String label;

  /// true = 这条关系不是直接挂在本页货品下的(删它改的是某个子件自己的
  /// 组装清单，用到该子件的其它货品都会跟着变)。
  final bool nested;

  /// true = 系统学出的组件(删除后系统不再自动加回，确认框要说明)。
  final bool learned;
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
    this.productWeightGrams,
  });

  final String goodsId;

  /// 本货品 (产品) 货品资料里的单重折算成克 (ADR-131)；BOM 上整批领料的料
  /// 填的单个重量与它相差 20% 以上时标黄待核对。null = 没登记或单位不是重量。
  final double? productWeightGrams;
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

  /// 「审计模式」按钮可见性：goods:bom:audit 或超管（已审绿色/已审列只在该模式
  /// 下出现，只有持有权限者能改标记）。
  bool get _canAudit =>
      ref.watch(isSuperAdminProvider) ||
      ref.watch(currentPermissionsProvider).contains(Perm.goodsBomAudit);

  /// 整批领料的料 (期间边) 的单个重量要标黄待核对：服务端给了提醒，或直接挂在
  /// 本产品下、与货品资料单重相差 20% 以上 (ADR-131)。只提示，不拦截。
  bool _weightNeedsReview(_BomRow r) {
    final item = r.node.item;
    if (!item.isPeriodicEdge) return false;
    if (item.warnings.isNotEmpty) return true;
    if (r.parentGoodsId != widget.goodsId) return false;
    final grams = item.periodicUnitWeightGrams;
    return grams != null &&
        periodicGramsDeviates(grams, widget.productWeightGrams);
  }

  /// 各父件下当前看得到的期间边条数 (添加组件时判断是不是「第二种料」)。
  Map<String, int> get _periodicEdgeCountByParent {
    final counts = <String, int>{};
    for (final r in _visibleRows) {
      if (!r.node.item.isPeriodicEdge) continue;
      counts[r.parentGoodsId] = (counts[r.parentGoodsId] ?? 0) + 1;
    }
    return counts;
  }

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
          learned: item.systemLearned,
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
        existingPeriodicCount: _periodicEdgeCountByParent,
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
        // 货品资料单重只对直接挂在本产品下的行有意义 (嵌套行的父件是别的货品)。
        referenceGrams: row.parentGoodsId == widget.goodsId
            ? widget.productWeightGrams
            : null,
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
    final learnedCount = targets.where((t) => t.learned).length;
    final l10n = AppLocalizations.of(context);
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
                  // 系统学出的组件：人工删除即释放，学习不会再把它加回来。
                  if (learnedCount > 0) ...[
                    const SizedBox(height: UtenSpacing.s12),
                    UtenInlineNotice(
                      key: const Key('goods-bom-delete-learned-note'),
                      message: l10n.bomLearnedEdgeDeleteNote(learnedCount),
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

  // ---- 右键菜单（2026-09-25 统一口径：右键=选中当前行+自绘小框弹窗） ---------
  //
  // 与货品资料列表同款：MasterDataTableView 先把右键命中的行纳入选择集，再弹
  // UtenContextMenu（锚定指针、无遮罩）；菜单动作直接复用悬浮组的编辑/删除/添加。
  // 审计模式的「标记/取消已核对」也走这里（单击行不再兼任审计开关，勾选与审计
  // 两种语义从此不打架）。

  List<UtenContextMenuEntry> _rowMenuItems(_BomRow row) {
    final single = _selectedRowIds.length == 1;
    return [
      UtenMenuItem(
        label: '编辑', // TODO(l10n): 补 arb
        enabled: widget.canEdit && single,
        onTap: _editSelected,
      ),
      UtenMenuItem(
        label: '添加子组件', // TODO(l10n): 补 arb
        enabled: widget.canCreate,
        onTap: _addItem,
      ),
      UtenMenuItem(
        label: '删除', // TODO(l10n): 补 arb
        enabled: widget.canDelete && _selectedRowIds.isNotEmpty,
        destructive: true,
        onTap: _deleteSelected,
      ),
      if (_auditMode) ...[
        const UtenMenuDivider(),
        UtenMenuItem(
          label: row.node.item.audited ? '取消已核对' : '标记已核对无误', // TODO(l10n)
          onTap: () => _toggleAudited(row),
        ),
      ],
    ];
  }

  // ---- 审计标记（V256） ---------------------------------------------------
  //
  // 审计模式下单击行 = 标记/取消「已核对无误」（已审行绿色 + 「已审」列 ✓，两者都
  // 只在审计模式出现；关闭审计模式就是普通清单视图）。标记写服务端
  // goods_bom_items.audited_at/_by：多人协作、跨天核对不丢。
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
  /// 2026-09-25 口径「表格显示啥导出啥」：需求阶段/缺料处理/单价/金额四列从展示
  /// 退役（数据仍在行上，编辑弹窗/复制粘贴/成本聚合不受影响）；后端导出同列集。
  /// 「已审」列只在审计模式下出现（点该格翻已核对状态），关闭即普通清单视图。
  List<MasterColumnDef<_BomRow>> get _columns {
    final l10n = AppLocalizations.of(context);
    return [
      // 层级身份集中在首列：级联号 + 明确层级文字 + 连续树轨 + 48dp
      // 单击展开按钮。行单击只负责选中，不再让“双击整行”兼任树导航。
      // 2026-09-12 用户口径「只显示名字和组件X级」：身份格不再堆路径行与编号
      // 副标题（编号看「编号」列），副标题仅剩懒加载中的提示。
      // 系统学出的组件在格内右侧叠「系统学习」标记(ADR-129)。
      MasterColumnDef(
        key: 'treeIdentity',
        label: '层级 / 组件',
        width: 340,
        value: (r) => [
          '${r.seq} 组件 ${r.depth + 1} 级 ${r.node.item.componentName ?? ''}',
          if (r.node.item.systemLearned) l10n.bomLearnedEdge,
        ].join(' '),
        cellBuilderHandlesSemantics: true,
        // 树列吃满整行高度 + 连线跨过数据格纵向内边距，否则层级竖线会在
        // 行与行之间断开（与物料分析主表 / 级联页同一处理，2026-09-15）。
        fillsCellHeight: true,
        cellBuilder: (context, r) {
          final cell = UtenTreeTableCell(
            key: ValueKey('goods-bom-tree-cell-${r.node.item.id}'),
            toggleKey: ValueKey('goods-bom-tree-toggle-${r.node.item.id}'),
            depth: r.depth,
            guideBleed: MasterDataTableView.cellVerticalPadding,
            sequence: r.seq,
            levelLabel: '组件 ${r.depth + 1} 级',
            title:
                r.node.item.componentName ??
                r.node.item.componentCode ??
                '未命名组件',
            subtitle: r.node.loading ? '正在加载下级…' : null,
            hasChildren: r.node.item.hasChildren,
            expanded: r.node.expanded,
            onToggle: r.node.loading ? null : () => _toggle(r.node),
            ancestorContinuations: r.ancestorContinuations,
            isLastChild: r.isLastChild,
          );
          if (!r.node.item.systemLearned) return cell;
          // passthrough：树格照旧拿到整行的高度约束(层级竖线不断)，标记
          // 浮在右侧、树格让出等宽，名称省略号不被压住；不裁剪，树轨要画进
          // 上下相邻行的内边距(guideBleed)。槽宽按标记文字实测(各语言、
          // 字号档都完整显示)，再留一点与名称的间距。
          final badgeSlot =
              UtenStatusBadge.measureWidth(
                context,
                l10n.bomLearnedEdge,
                size: UtenStatusBadgeSize.small,
              ) +
              UtenSpacing.s8;
          return Stack(
            fit: StackFit.passthrough,
            clipBehavior: Clip.none,
            children: [
              Padding(
                padding: EdgeInsets.only(right: badgeSlot),
                child: cell,
              ),
              Positioned(
                right: 0,
                top: 0,
                bottom: 0,
                width: badgeSlot,
                child: Center(
                  child: UtenStatusBadge(
                    key: ValueKey('goods-bom-learned-${r.node.item.id}'),
                    label: l10n.bomLearnedEdge,
                    type: UtenStatusBadgeType.info,
                    size: UtenStatusBadgeSize.small,
                  ),
                ),
              ),
            ],
          );
        },
      ),
      // 已审列（V256）：审计标记持久在服务端，但只在做核对的人眼前出现——
      // 进「审计模式」才显示 ✓ 列（改标记要 goods:bom:audit），关闭即正常清单。
      if (_auditMode)
        MasterColumnDef(
          key: 'audited',
          label: '已审',
          width: 64,
          value: (r) => r.node.item.audited ? '已核对' : '',
          // 点这一格 = 翻「已核对无误」（2026-09-25：右键菜单之外的快捷路径）；
          // 图标弃用细体 ✓ 文本，换实心圆形对勾（已核对，绿色）/ 空心圆（未核对，
          // 待点选），年长用户隔着屏幕也认得出状态。
          cellBuilder: (context, r) => Tooltip(
            message: r.node.item.audited ? '已核对，点击取消' : '点击标记已核对',
            child: IconButton(
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              visualDensity: VisualDensity.compact,
              iconSize: 22,
              icon: Icon(
                r.node.item.audited
                    ? Icons.check_circle
                    : Icons.radio_button_unchecked,
                color: r.node.item.audited
                    ? Colors.green.shade700
                    : Theme.of(
                        context,
                      ).colorScheme.onSurfaceVariant.withValues(alpha: 0.45),
              ),
              onPressed: () => _toggleAudited(r),
            ),
          ),
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
        value: (r) => r.node.item.basisOutputQtyText,
      ),
      MasterColumnDef(
        key: 'allowPartialPackage',
        label: '尾包',
        width: 72,
        value: (r) => r.node.item.partialPackageLabel,
      ),
      // 整批领到车间内料仓的料 (颗粒等，ADR-131)：这一格是单个重量，按克显示；
      // 与货品资料单重相差 20% 以上或服务端有提醒时标黄待核对。
      MasterColumnDef(
        key: 'qty',
        label: l10n.bomDesignQty,
        width: 112,
        type: 'number',
        info: '整批领到车间内料仓的料 (颗粒等)，这一格是单个重量，按克填写和显示。',
        value: (r) => r.node.item.isPeriodicEdge
            ? _qtyText(r.node.item)
            : r.node.item.designQtyText,
        cellColor: (context, r) =>
            _weightNeedsReview(r) ? Colors.amber.withValues(alpha: 0.28) : null,
      ),
      // 真实使用数量(只读，ADR-129)：与设计使用数量同一计量口径；没有数据或
      // 不适用显示「—」，悬停说明计算按哪个数、依据几批、累计多少。
      MasterColumnDef(
        key: 'actualQty',
        label: l10n.bomActualQty,
        width: 112,
        type: 'number',
        value: (r) => r.node.item.actualQtyText,
        cellBuilder: (context, r) => Tooltip(
          message: bomActualUsageTip(
            l10n,
            r.node.item.actual,
            netUnit: r.node.item.componentUnitName,
          ),
          child: Text(r.node.item.actualQtyText),
        ),
      ),
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
    final visible = _visibleRows;
    // 勾中条数决定悬浮组「编辑」的可用性：编辑只认 1 条，删除 >=1 条即可。
    final selectedCount = _selectedRowIds.length;
    // 勾选框要不要给：三个动作(批量删除/编辑/添加组件定位)一个都没权限时不给——
    // 只读账号看到一整列勾选框却没有任何按钮可接，按准则「隐藏而非禁用」。
    // 2026-09-25 起审计模式不再关掉勾选：审计模式下也要能多选批量删除，
    // 「标记已核对」改由右键菜单触发（单击行与勾选不再打架）。
    final canActOnSelection =
        widget.canDelete || widget.canEdit || widget.canCreate;
    final selectable = canActOnSelection;
    return Stack(
      children: [
        // 统一表格（与货品资料列表同款）：Excel 表头分隔线 + 拖拽列宽 + 底部横滑条。
        Positioned.fill(
          child: MasterDataTableView<_BomRow>(
            // 按 selectable/审计模式分键，进出审计模式时整棵表重建而不是原地重排
            // （「已审」列的出现/消失会把行子树换父级，SelectionArea 的
            // SelectionKeepAlive 带着 GlobalKey 一起被搬走，同一帧里
            // 「Duplicate GlobalKeys detected」崩）。代价是切模式会丢掉列宽与
            // 滚动位置，可以接受：那本来就是一次模式切换，不是刷新。
            key: ValueKey('goods-bom-table-$selectable-$_auditMode'),
            columns: _columns,
            items: visible,
            facets: const {},
            nullCounts: const {},
            filters: const {},
            onFilterChanged: (_, _) {},
            // 多选：最前列勾选框 + 表头三态全选；「已选 N 项 + 清除」胶囊与
            // 添加组件/编辑/删除一起驻右下悬浮组（batchActionsBuilder），
            // 普通视图与全屏路由同款渲染。
            selectable: selectable,
            // _BomRow 无天然唯一 id，用复合键(见 _rowId)。
            idOf: _rowId,
            selectedIds: _selectedRowIds,
            onSelectedIdsChanged: (next) =>
                setState(() => _selectedRowIds = next),
            // _BomRow 每次 build 重建(引用变)，故按行键比较而非引用相等。
            isSelected: (row) => _selectedRowIds.contains(_rowId(row)),
            // 右键菜单：组件先选中当前行再弹自绘小框（与货品资料列表同款）。
            rowMenuBuilder: _rowMenuItems,
            // 已审行浅绿底也只在审计模式出现（与「已审」列同进退）——审计标记是
            // 核对工作态，普通视图不该有无从解释的绿色行；单击选中时表格组件
            // 自动加深加亮。
            rowColor: (r) => _auditMode && r.node.item.audited
                ? Colors.green.withValues(alpha: 0.15)
                : (_weightNeedsReview(r)
                      ? Colors.amber.withValues(alpha: 0.12)
                      : null),
            // 工具条驻左：表头设置/全屏为内建按钮，其余业务按钮走
            // toolbarLeadingActions 紧随其后（2026-09-25 口径：顶部按钮全部靠左、
            // 统一高度/同色、不带 icon——大动作在右下悬浮组）。
            toolbarLeadingActions: [
              UtenButton(
                key: const Key('goods-bom-learning'),
                height: UtenTableToolbar.controlHeight,
                // 在学习记录里重学后真实使用数量会变，本页签跟着重读。
                onPressed: () => showGoodsBomLearning(
                  context,
                  widget.goodsId,
                  onRelearned: () {
                    if (mounted) _load();
                  },
                ),
                child: Text(AppLocalizations.of(context).bomLearningTitle),
              ),
              if (widget.onPreview != null)
                UtenButton(
                  key: const ValueKey('goods-bom-preview'),
                  height: UtenTableToolbar.controlHeight,
                  onPressed: widget.onPreview,
                  child: const Text('预览'), // TODO(l10n): 补 arb
                ),
              // 导出组件（goods:export）：与「预览」弹窗里的下载Excel 同一端点
              // （整树展开的加密 xlsx），列集与本表一致。
              UtenExportButton(
                endpoint: ApiEndpoints.goodsBomExport(widget.goodsId),
                requiredPermission: Perm.goodsExport,
                report: '',
                queryParams: const {},
                height: UtenTableToolbar.controlHeight,
                icon: null,
                filename:
                    '产品配件清单_${widget.productCode ?? widget.productName ?? widget.goodsId}',
                label: '导出组件', // TODO(l10n): 补 arb
              ),
              // 导入组件（goods:bom:create，与粘贴组件同权）：格式 = 导出格式，
              // 序号列(1/2.1)表达层级，检测报告确认后再提交。
              if (widget.canCreate)
                UtenButton(
                  key: const Key('goods-bom-import'),
                  height: UtenTableToolbar.controlHeight,
                  onPressed: () => showGoodsBomImport(
                    context,
                    ref,
                    goodsId: widget.goodsId,
                    onImported: () {
                      widget.onDataChanged?.call();
                      _load();
                    },
                  ),
                  child: const Text('导入组件'), // TODO(l10n): 补 arb
                ),
              // 审计模式（V256，goods:bom:audit）：开=右键行「标记/取消已核对无误」
              // （已审行绿色 + 已审列 ✓，都只在该模式出现）；勾选与批量删除照常可用。
              if (_canAudit)
                UtenButton(
                  height: UtenTableToolbar.controlHeight,
                  // 审计进行中 = 红色「退出审计」，一眼看出当前处于特殊工作态。
                  type: _auditMode
                      ? UtenButtonType.danger
                      : UtenButtonType.primary,
                  onPressed: () => setState(() {
                    _auditMode = !_auditMode;
                    // 模式切换后「选中」的语义不再变化(都是勾选)，但切走审计时
                    // 清一下残留更干净，避免带着勾选进编辑流。
                    if (!_auditMode) _selectedRowIds = <String>{};
                  }),
                  child: Text(_auditMode ? '退出审计' : '审计模式'), // TODO(l10n)
                ),
            ],
            // 右下悬浮组：已选 N 项胶囊 + 添加组件/编辑/删除（全屏路由同款）。
            batchActionsBuilder: (context, ids) => [
              if (widget.canCreate)
                UtenButton(
                  key: const Key('goods-bom-add-component'),
                  size: UtenButtonSize.large,
                  icon: Icons.add_rounded,
                  onPressed: _addItem,
                  child: const Text('添加组件'), // TODO(l10n): 补 arb
                ),
              // 编辑只对一条生效：勾了多条时目标不明确，宁可灰掉也不替用户猜。
              if (widget.canEdit)
                UtenButton(
                  size: UtenButtonSize.large,
                  icon: Icons.edit_outlined,
                  onPressed: selectedCount == 1 ? _editSelected : null,
                  child: const Text('编辑'), // TODO(l10n): 补 arb
                ),
              // 删除：勾一条起可用，一律走批量路径(条数在确认框里报)。
              if (widget.canDelete)
                UtenButton(
                  key: const Key('goods-bom-delete-selected'),
                  type: UtenButtonType.danger,
                  size: UtenButtonSize.large,
                  icon: Icons.delete_outline,
                  onPressed: selectedCount == 0 ? null : _deleteSelected,
                  child: const Text('删除'), // TODO(l10n): 补 arb
                ),
            ],
            isLoading: _loading && _roots == null,
            error: _error,
            onRetry: _load,
            emptyMessage: '暂无组装信息，点右下「添加组件」录入', // TODO(l10n): 补 arb
          ),
        ),
        // 批量删除网络段的全屏加载遮罩(root Overlay 传送门，不占布局)。
        // 确认框已经关掉才会挂上来，否则它会盖住确认框(见 _deleteSelected)。
        if (_deleting)
          const UtenBusyOverlay(
            title: '正在删除组件',
            description: '正在把所选组件从组装清单中移除，请勿重复提交或关闭页面。',
          ),
      ],
    );
  }

  /// 数量列文本：期间边显示「X 克」(基本单位千克时 = 数量 × 1000)，
  /// 其它行照旧显示设计使用数量。
  static String _qtyText(GoodsBomItem item) {
    if (item.isPeriodicEdge) {
      final grams = item.periodicUnitWeightGrams;
      if (grams != null) return '${periodicGramsText(grams)} 克';
      // 单位不能按克换算：按基本单位显示小数 (不出现科学计数法)。
      return _plainQty(item.qty);
    }
    return item.designQtyText;
  }
}

/// 可选取 l10n：个别宿主测试没挂本地化代理，取不到时回落中文。
AppLocalizations? _bomL10n(BuildContext context) =>
    Localizations.of<AppLocalizations>(context, AppLocalizations);

/// 单个重量 (克) 输入框标签。
String _gramsLabel(BuildContext context) =>
    _bomL10n(context)?.wmUnitWeightGrams ?? '单个重量 (克)';

/// 期间边单个重量输入框标签：组件基本单位是千克/克时按克填，
/// 其它单位 (服务端不按克换算) 直接按组件基本单位填。
String _periodicWeightLabel(BuildContext context, String? unitName) {
  if (periodicGramsPerBaseUnit(unitName) != null) return _gramsLabel(context);
  final unit = unitName == null || unitName.trim().isEmpty
      ? '基本单位'
      : unitName.trim();
  return '单个重量 ($unit)';
}

/// 单个重量不在常理之内 (小于 0.1 克或大于 5000 克) 时二次确认；确认返回 true。
Future<bool> _confirmUnusualGrams(
  BuildContext context,
  List<String> lines,
) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('请核对单个重量'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final line in lines)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(line),
              ),
            const SizedBox(height: 4),
            const Text('小于 0.1 克或大于 5000 克，常见是把公斤当成克填了。'),
          ],
        ),
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('返回修改'),
        ),
        FilledButton(
          key: const Key('goods-bom-unusual-weight-confirm'),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('确定'),
        ),
      ],
    ),
  );
  return ok == true;
}

/// 一行「单个重量不太对」的确认文案。
String _unusualLine(BuildContext context, String name, double grams) {
  final text = periodicGramsText(grams);
  final sentence =
      _bomL10n(context)?.wmUnusualWeightConfirm(text) ??
      '单个重量 $text 克看起来不太对, 确定吗?';
  return name.isEmpty ? sentence : '「$name」$sentence';
}

/// 同一产品要挂第二种整批领料的料时确认 (双色 / 双料)；确认返回 true。
Future<bool> _confirmSecondPeriodicMaterial(BuildContext context) async {
  final message =
      _bomL10n(context)?.wmSecondMaterialConfirm ??
      '这个产品要同时用两种料吗 (双色 / 双料)? 如果只是换料, 请改原来那一行';
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('再加一种料'),
      content: SizedBox(width: 420, child: Text(message)),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('返回修改'),
        ),
        FilledButton(
          key: const Key('goods-bom-second-material-confirm'),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('确定，同时用两种料'),
        ),
      ],
    ),
  );
  return ok == true;
}

/// BOM 用量 (最多 5 位小数) 的输入框 / 表格文本：去掉补齐的 0，不出现科学计数法。
String _plainQty(double? v) {
  if (v == null) return '';
  final fixed = v.toStringAsFixed(5);
  return fixed
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
}

/// 期间边的单个重量 (克) → BOM 数量 (基本单位, 5 位小数)。只在组件单位是千克/克时调用。
double _gramsToQty(double grams, double gramsPerUnit) =>
    double.parse((grams / gramsPerUnit).toStringAsFixed(5));

/// 期间边一行的请求体：组件单位能按克换算时按克提交 unitWeightGrams (服务端换成基本单位存)，
/// 不能换算时 [entered] 就是基本单位的用量，只提交 qty。形状字段不提交 (服务端固定)。
Map<String, dynamic> _periodicEdgeBody(
  String componentGoodsId,
  double entered,
  String? unitName,
) {
  final factor = periodicGramsPerBaseUnit(unitName);
  if (factor == null) {
    return {'componentGoodsId': componentGoodsId, 'qty': entered};
  }
  return {
    'componentGoodsId': componentGoodsId,
    'qty': _gramsToQty(entered, factor),
    'unitWeightGrams': entered,
  };
}

/// 期间边输入值对应的克数 (不能换算为 null，此时不在页面判断异常单重，交服务端)。
double? _enteredGrams(double entered, String? unitName) =>
    periodicGramsPerBaseUnit(unitName) == null ? null : entered;

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
    this.existingPeriodicCount = const {},
  });

  final List<_BomParentOption> parentCandidates;
  final String defaultParentGoodsId;

  /// 各父件下已有的整批领料的料条数 (看得到的部分)：再加一种要确认 (双色 / 双料)。
  final Map<String, int> existingPeriodicCount;

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
        // 整批领料的料 (颗粒等) 填单个重量 (克)，没有合理默认值，留空让人填。
        _picked.add(
          _PickedComponent(
            g,
            TextEditingController(text: g.isPeriodicIssue ? '' : '1'),
          ),
        );
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
    final l10n = AppLocalizations.of(context);
    final bodies = <Map<String, dynamic>>[];
    final periodicBodies = <Map<String, dynamic>>[];
    final unusual = <String>[];
    for (final p in _picked) {
      final raw = p.qtyCtl.text.trim();
      final name = p.goods.name ?? p.goods.code ?? '';
      if (p.goods.isPeriodicIssue) {
        // ADR-131 期间边：辅料 / 记车间费用的料不写进 BOM (按主料用量分摊)。
        final basis = p.goods.periodicCostBasis;
        if (basis != null && basis != GoodsPeriodicCostBasis.own) {
          setState(() => _error = '「$name」是辅料或记车间费用的料，不写进 BOM，按当期主料用量分到各产品');
          return;
        }
        final entered = double.tryParse(raw);
        if (entered == null || entered <= 0) {
          final label = _periodicWeightLabel(context, p.goods.unitName);
          setState(() => _error = '「$name」$label必须大于 0');
          return;
        }
        final grams = _enteredGrams(entered, p.goods.unitName);
        if (grams != null && periodicGramsUnusual(grams)) {
          unusual.add(_unusualLine(context, name, grams));
        }
        final body = <String, dynamic>{
          ..._periodicEdgeBody(p.goods.id, entered, p.goods.unitName),
          'price': p.goods.price,
        };
        bodies.add(body);
        periodicBodies.add(body);
        continue;
      }
      // 设计使用数量必填：清空了就报错，不再静默按 1。
      final error = _designQtyError(l10n, raw);
      if (error != null) {
        setState(() => _error = '「$name」$error');
        return;
      }
      bodies.add({
        'componentGoodsId': p.goods.id,
        'qty': double.parse(p.qtyCtl.text.trim()),
        'price': p.goods.price,
      });
    }
    // 单个重量异常 (小于 0.1 克或大于 5000 克) 二次确认；确认框弹出时不能有遮罩。
    if (unusual.isNotEmpty) {
      final ok = await _confirmUnusualGrams(context, unusual);
      if (!ok || !mounted) return;
      for (final body in periodicBodies) {
        body[periodicConfirmUnusualWeight] = true;
      }
    }
    // 同一产品第二种整批领料的料 (双色 / 双料) 要确认，换料应改原来那一行。
    final existing = widget.existingPeriodicCount[_parentGoodsId] ?? 0;
    if (periodicBodies.isNotEmpty && existing + periodicBodies.length >= 2) {
      if (!mounted) return;
      final ok = await _confirmSecondPeriodicMaterial(context);
      if (!ok || !mounted) return;
      for (final body in periodicBodies) {
        body[periodicConfirmSecondMaterial] = true;
      }
    }
    setState(() {
      _saving = true;
      _error = null;
      _problems = const [];
    });
    try {
      final repo = ref.read(goodsBomRepositoryProvider);
      BomPasteResult result;
      while (true) {
        try {
          result = await repo.paste(
            mode: BomPasteMode.append,
            targets: [BomPasteTarget(_parentGoodsId)],
            items: bodies,
          );
          break;
        } on ApiException catch (e) {
          // 服务端还要人确认 (异常单重 / 同一产品第二种料)：撤遮罩、问完带上确认重发。
          final confirmations = periodicConfirmationsOf(e);
          if (confirmations == null || !mounted) rethrow;
          setState(() => _saving = false);
          await WidgetsBinding.instance.endOfFrame;
          if (!mounted) return;
          final confirmed = await askPeriodicConfirmations(
            context,
            confirmations,
          );
          if (confirmed == null || !mounted) return;
          applyPeriodicConfirmations(periodicBodies, confirmed);
          setState(() => _saving = true);
        }
      }
      if (!mounted) return;
      // 服务端的提醒 (如与货品资料单重相差 20% 以上) 只提示、不拦截。
      if (result.warnings.isNotEmpty) {
        context.appWarning(
          '已添加 ${result.added} 个组件；请核对：${result.warnings.join('；')}',
        );
      } else {
        context.appSuccess('已添加 ${result.added} 个组件'); // TODO(l10n): 补 arb
      }
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
                                  width: 132,
                                  child: p.goods.isPeriodicIssue
                                      ? TextField(
                                          key: ValueKey(
                                            'goods-bom-add-qty-${p.goods.id}',
                                          ),
                                          controller: p.qtyCtl,
                                          keyboardType:
                                              const TextInputType.numberWithOptions(
                                                decimal: true,
                                              ),
                                          // 整批领料的料 (ADR-131)：按克填单个重量。
                                          decoration: InputDecoration(
                                            labelText: _periodicWeightLabel(
                                              context,
                                              p.goods.unitName,
                                            ),
                                            border: const OutlineInputBorder(),
                                            isDense: true,
                                          ),
                                        )
                                      : _DesignQtyField(
                                          key: Key(
                                            'goods-bom-add-qty-${p.goods.id}',
                                          ),
                                          controller: p.qtyCtl,
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
/// 设计使用数量和备注可改。
///
/// 设计使用数量只在用户真改了时才提交(ADR-129)：系统学出的组件只改备注时
/// 仍由系统维护；改了数量即转为人工维护(真实使用数量照常累计)，弹窗顶部
/// 黄色提示先说清楚。
class _BomItemEditDialog extends ConsumerStatefulWidget {
  const _BomItemEditDialog({
    required this.parentGoodsId,
    required this.editing,
    this.referenceGrams,
  });

  final String parentGoodsId;
  final GoodsBomItem editing;

  /// 父件 (产品) 货品资料单重折算的克数；期间边单重与它相差 20% 以上时提醒核对。
  final double? referenceGrams;

  @override
  ConsumerState<_BomItemEditDialog> createState() => _BomItemEditDialogState();
}

class _BomItemEditDialogState extends ConsumerState<_BomItemEditDialog> {
  final _qtyCtl = TextEditingController();
  final _summaryCtl = TextEditingController();
  bool _saving = false;
  String? _error;

  /// 打开时的设计使用数量文本：保存时与它比较，判断用户是否改了数量。
  late final String _initialQtyText;

  @override
  void initState() {
    super.initState();
    final e = widget.editing;
    if (e.isPeriodicEdge) {
      // 期间边按克输入显示 (ADR-131)；组件单位不能按克换算时按基本单位显示。
      final grams = e.periodicUnitWeightGrams;
      _qtyCtl.text = grams != null
          ? periodicGramsText(grams)
          : _plainQty(e.qty);
      _initialQtyText = _qtyCtl.text;
      _qtyCtl.addListener(_onGramsChanged);
    } else {
      _initialQtyText = e.designQtyText;
      _qtyCtl.text = _initialQtyText;
    }
    _summaryCtl.text = e.summary ?? '';
  }

  void _onGramsChanged() {
    if (mounted) setState(() {});
  }

  /// 输入的单个重量与货品资料单重相差 20% 以上 (只提醒，不拦截)。
  bool get _gramsDeviate {
    final entered = double.tryParse(_qtyCtl.text.trim());
    if (entered == null) return false;
    final grams = _enteredGrams(entered, widget.editing.componentUnitName);
    return grams != null && periodicGramsDeviates(grams, widget.referenceGrams);
  }

  @override
  void dispose() {
    _qtyCtl.dispose();
    _summaryCtl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final e = widget.editing;
    final raw = _qtyCtl.text.trim();
    final entered = double.tryParse(raw);
    if (e.isPeriodicEdge) {
      if (entered == null || entered <= 0) {
        final label = _periodicWeightLabel(context, e.componentUnitName);
        setState(() => _error = '「$label」必须是大于 0 的数字'); // TODO(l10n): 补 arb
        return;
      }
    } else {
      // 只有改了才提交数量：不改就不碰服务端的设计使用数量(学习组件不被接管)。
      final qtyChanged = raw != _initialQtyText;
      if (qtyChanged) {
        final error = _designQtyError(AppLocalizations.of(context), raw);
        if (error != null) {
          setState(() => _error = error);
          return;
        }
      }
    }
    var confirmUnusual = false;
    final grams = e.isPeriodicEdge
        ? _enteredGrams(entered!, e.componentUnitName)
        : null;
    if (grams != null && periodicGramsUnusual(grams)) {
      final ok = await _confirmUnusualGrams(context, [
        _unusualLine(context, '', grams),
      ]);
      if (!ok || !mounted) return;
      confirmUnusual = true;
    }
    final body = <String, dynamic>{
      // 期间边按克提交 (服务端换成基本单位存，形状固定为开工前、按每件、不设齐套门槛)。
      if (e.isPeriodicEdge)
        ..._periodicEdgeBody(e.componentGoodsId, entered!, e.componentUnitName)
      else ...{
        'componentGoodsId': e.componentGoodsId,
        if (raw != _initialQtyText) 'qty': double.parse(raw),
      },
      if (confirmUnusual) periodicConfirmUnusualWeight: true, 'price': e.price,
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
      final repo = ref.read(goodsBomRepositoryProvider);
      GoodsBomItem updated;
      while (true) {
        try {
          updated = await repo.update(widget.parentGoodsId, e.id, body);
          break;
        } on ApiException catch (ex) {
          // 服务端还要人确认 (异常单重 / 同一产品第二种料)：问完带上确认重发。
          final confirmations = periodicConfirmationsOf(ex);
          if (confirmations == null || !mounted) rethrow;
          setState(() => _saving = false);
          await WidgetsBinding.instance.endOfFrame;
          if (!mounted) return;
          final confirmed = await askPeriodicConfirmations(
            context,
            confirmations,
          );
          if (confirmed == null || !mounted) return;
          applyPeriodicConfirmations([body], confirmed);
          setState(() => _saving = true);
        }
      }
      if (!mounted) return;
      // 服务端的提醒 (如与货品资料单重相差 20% 以上) 只提示、不拦截。
      if (updated.warnings.isNotEmpty) {
        context.appWarning('组件已更新；请核对：${updated.warnings.join('；')}');
      } else {
        context.appSuccess('组件已更新'); // TODO(l10n): 补 arb
      }
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
                      if (e.systemLearned) ...[
                        const SizedBox(height: UtenSpacing.s12),
                        UtenInlineNotice(
                          key: const Key('goods-bom-edit-learned-hint'),
                          level: UtenInlineNoticeLevel.warning,
                          message: AppLocalizations.of(
                            context,
                          ).bomLearnedEdgeEditHint,
                        ),
                      ],
                      const SizedBox(height: UtenSpacing.s12),
                      Row(
                        children: [
                          Expanded(
                            child: e.isPeriodicEdge
                                ? TextField(
                                    key: const Key('goods-bom-edit-qty'),
                                    controller: _qtyCtl,
                                    keyboardType:
                                        const TextInputType.numberWithOptions(
                                          decimal: true,
                                        ),
                                    decoration: InputDecoration(
                                      labelText: _periodicWeightLabel(
                                        context,
                                        e.componentUnitName,
                                      ),
                                      border: const OutlineInputBorder(),
                                      isDense: true,
                                    ),
                                  )
                                : _DesignQtyField(
                                    key: const Key('goods-bom-edit-qty'),
                                    controller: _qtyCtl,
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
                      // 期间边 (ADR-131)：形状由系统固定，只读说明；单重偏差标黄提醒。
                      if (e.isPeriodicEdge) ...[
                        const SizedBox(height: UtenSpacing.s8),
                        Text(
                          '整批领到车间内料仓的料：只填单个重量 (克，不含水口)；'
                          '管控阶段固定为开工前、按每件计量、不设齐套门槛。',
                          key: const Key('goods-bom-periodic-readonly-note'),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        if (_gramsDeviate)
                          Container(
                            key: const Key('goods-bom-weight-deviation'),
                            margin: const EdgeInsets.only(top: UtenSpacing.s8),
                            padding: const EdgeInsets.all(UtenSpacing.s8),
                            decoration: BoxDecoration(
                              color: Colors.amber.withValues(alpha: 0.25),
                              borderRadius: BorderRadius.circular(
                                UtenRadius.control,
                              ),
                            ),
                            child: Text(
                              '与货品资料单重 '
                              '${periodicGramsText(widget.referenceGrams!)} 克'
                              '相差 20% 以上，请核对是不是填错了。',
                              style: theme.textTheme.bodySmall,
                            ),
                          ),
                      ],
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

/// 设计使用数量输入框(添加/编辑两个弹窗共用)：必填，空时红框 + 红 *。
class _DesignQtyField extends StatelessWidget {
  const _DesignQtyField({super.key, required this.controller});

  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    final label = AppLocalizations.of(context).bomDesignQty;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final theme = Theme.of(context);
        return TextField(
          controller: controller,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: UtenInputDecoration(
            applyRequiredEmpty(
              InputDecoration(
                label: requiredLabel(
                  label,
                  theme,
                  required: true,
                  base: theme.inputDecorationTheme.labelStyle,
                ),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              theme,
              requiredEmpty: controller.text.trim().isEmpty,
            ),
          ),
        );
      },
    );
  }
}

/// 设计使用数量校验(两个弹窗共用)：空 → 请填写；不是大于 0 的有限数字 →
/// 报错；合法返回 null。
String? _designQtyError(AppLocalizations l10n, String raw) {
  final text = raw.trim();
  if (text.isEmpty) return l10n.bomDesignQtyRequired;
  final value = double.tryParse(text);
  return value == null || !value.isFinite || value <= 0
      ? l10n.bomDesignQtyInvalid
      : null;
}

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
