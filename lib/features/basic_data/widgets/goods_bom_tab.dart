// 货品详情「组装信息」：默认只读；编辑模式中的每次操作进入会话草稿。
// 退出编辑时选择保存或丢弃，保存前预览共用组件的影响并一次提交全部变更。
// 右下固定选择摘要、编辑模式和审计模式；写入口同时检查模式、会话及细分权限。
// 行右键自动选中未选中的行，已选中的行保留多选，支持批量复制与跨货品粘贴。
// 审计模式独立于结构编辑，已核对标记持久化在服务端，修改结构后需重新核对。
//
// 树结构：一级 = 当前货品的组件清单；组件自身有 BOM（hasChildren）可展开，
// 展开时对组件 id 再调 list 接口懒加载（对照老系统 001.jpg 的 +/- 树）。
//
// 多选批量删除(2026-09-21 用户口径「组件信息最前面加个多选框，可以多选批量
// 删除」)：表格最前列由 MasterDataTableView 自己渲染勾选框 + 表头三态全选，
// 选中集 _selectedRowIds 是本页唯一的「当前选中」真相——「编辑」只在恰好勾中
// 一条时可用，「删除」勾中一条起就是批量删除。行键用 `父货品id|关系行id` 复合
// 键：同一个子件可能同时挂在两个父件下并各自展开，光用关系行 id 会串行；复合
// 键正好也是删除和审计标记要的(父货品, 关系行)二元组。
//
// 表格：复用全站统一表格组件 MasterDataTableView（与货品资料列表同款）——
// Excel 风格表头（竖线分隔 + 可拖拽拉宽拉窄）+ 表头/表体横滚同步 +
// 底部横向滚动条 + 单击行高亮。树形通过「可见节点平铺」表达：
// 首列「▶/▼」= 该行有子类（点行任意位置展开/收起，loading 显 …），
// 名称列子类缩进一格（└ 分支符，更深逐级加全角空格）；
// 编辑模式逐格录入关系字段；名称格输入查找并选择真实货品。型号、规格、材质和
// 来源在具备该组件主档修改权限时同格编辑，和关系变更一起预览、原子保存。
// 右键或双击层级区域仍可打开单行数量/备注浮窗，删除作用于当前多选集合。
//
// 添加组件（2026-08-01）：仿部门添加——选中某组件行再点「添加组件」默认作为该组件的
// 子组件，弹窗内可选「顶层」或任一可见组件作为父级（POST 到对应 goods 的 BOM）。
// 组件经右侧滑窗 showUtenGoodsPicker(scope: component) 选择（原材料/半成品/辅料/OEM 系列），
// 选完组件信息自动回填；编号、库存、学习实耗只读，颜色保持关系级覆盖语义。
// CRUD 后保留展开状态（_expandedIds），让刚加的子组件立即可见。
//
// 两个用量(ADR-129)：「设计使用数量」= goods_bom_items.qty(原「数量」，工程
// 人员维护，必填)；其后只读「真实使用数量」= 学习累计(与设计值同一计量口径，
// 没有数据或不适用显示「—」，悬停说明原因、有效批次和累计产量)。系统学出的
// 组件在身份格带「系统学习」标记；编辑它只在改了设计使用数量时才提交数量
// (改了即转为人工维护)，删除它后系统不再自动加回。
import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'package:uten_imp/components/feedback/uten_floating_window.dart';
import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/buttons/uten_export_button.dart';
import '../../../components/buttons/uten_tree_expansion_button.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/data_display/uten_table_row_drag.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/feedback/uten_inline_notice.dart';
import '../../../components/inputs/required_field_decoration.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/inputs/uten_inline_edit_cell.dart';
import '../../../components/inputs/uten_reference_picker_field.dart';
import '../../../components/inputs/uten_picker_icon_button.dart';
import '../../../components/inputs/uten_table_cell_spec.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_error.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/action_feedback.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/formatters/quantity_display.dart';
import '../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../../../shared/widgets/uten_tree_table_cell.dart';
import '../models/goods_bom_item.dart';
import '../models/goods_node.dart';
import '../providers/goods_clipboard.dart';
import '../providers/color_unit_dict.dart';
import 'master_edit_dialog.dart' show kGoodsSourceTypeOptions;
import 'master_inline_edit.dart' show masterEditText;
import '../repositories/goods_bom_repository.dart';
import '../repositories/goods_bom_edit_repository.dart';
import 'goods_bom_import_dialog.dart';
import 'master_data_table_view.dart';
import '../../../components/data_display/uten_status_cell_color.dart';
import 'uten_goods_picker.dart';
import 'goods_bom_learning_panel.dart';
import 'periodic_bom_confirmation.dart';
import 'bom_component_picker.dart';
import 'bom_component_quantity_field.dart';

export 'bom_component_picker.dart'
    show
        bomComponentPickerProvider,
        bomComponentSuggestionsProvider,
        bomComponentSinglePickerProvider;

/// 树节点：BOM 行 + 懒加载子级状态。
class _BomNode {
  _BomNode(this.item);

  GoodsBomItem item;
  List<_BomNode>? children; // null = 未加载
  bool expanded = false;
  bool loading = false;
}

/// One repository/authority/read generation owns these actual list slots.
/// Retirement drops unsent reads; sent reads still release their own slot.
class _BomReadScope {
  final _waiting = Queue<Completer<bool>>();
  int _active = 0;
  bool _retired = false;

  Future<List<GoodsBomItem>> run(
    Future<List<GoodsBomItem>> Function() read,
  ) async {
    if (_retired) return const [];
    if (_active < 4) {
      _active++;
    } else {
      final ready = Completer<bool>();
      _waiting.add(ready);
      if (!await ready.future) return const [];
    }
    if (_retired) {
      _release();
      return const [];
    }
    try {
      return await read();
    } finally {
      _release();
    }
  }

  void _release() {
    if (!_retired && _waiting.isNotEmpty) {
      // Transfer the reservation before waking its owner; a fresh call cannot
      // steal the released slot and temporarily exceed the four-read limit.
      _waiting.removeFirst().complete(true);
    } else {
      _active--;
    }
  }

  void retire() {
    if (_retired) return;
    _retired = true;
    while (_waiting.isNotEmpty) {
      _waiting.removeFirst().complete(false);
    }
  }
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
    this.occurrenceKey,
  );

  final _BomNode node;
  final int depth;
  final String seq;

  /// 该 BOM 行真正所属的父货品；嵌套行不能误用页面根货品 id。
  final String parentGoodsId;
  final List<bool> ancestorContinuations;
  final bool isLastChild;

  /// 同一关系可在多条展开路径出现；显示身份与批量操作的关系身份分开。
  final String occurrenceKey;

  bool get isPlaceholder => node.item.id.startsWith('__new-child:');
}

class _BomInlineValues {
  _BomInlineValues(this.item, this.parentGoodsId)
    : colorId = item.colorId,
      colorLabel = item.componentColorName,
      consumption = item.consumptionBasis,
      partial = item.allowPartialPackage;
  final _text = <String, TextEditingController>{};
  TextEditingController get qty => _controller('qty');
  TextEditingController get basis => _controller('basisOutputQty');
  TextEditingController get summary => _controller('summary');
  String textFor(String field) =>
      _text[field]?.text ??
      switch (field) {
        'qty' =>
          item.isPeriodicEdge
              ? _plainQty(item.periodicUnitWeightGrams ?? item.qty)
              : item.designQtyText,
        'basisOutputQty' => formatBomQty(item.basisOutputQty),
        _ => item.summary ?? '',
      };
  TextEditingController _controller(String field) => _text.putIfAbsent(
    field,
    () => TextEditingController(text: textFor(field)),
  );
  final GoodsBomItem item;
  final String parentGoodsId;
  BomConsumptionBasis consumption;
  bool partial;
  String? colorId;
  String? colorLabel;
  final Set<String> changed = {};
  void dispose() {
    for (final controller in _text.values) {
      controller.dispose();
    }
  }
}

class _BomMasterValues {
  _BomMasterValues(this.snapshot)
    : base = Map<String, dynamic>.of(snapshot),
      sourceType = snapshot['sourceType'] as String?;
  final Map<String, dynamic> snapshot;
  final Map<String, dynamic> base;
  final text = <String, TextEditingController>{};
  String textFor(String field) =>
      text[field]?.text ?? snapshot[field] as String? ?? '';
  TextEditingController controllerFor(String field) => text.putIfAbsent(
    field,
    () => TextEditingController(text: textFor(field)),
  );
  String? sourceType;
  final Set<String> changed = {};
  void dispose() {
    for (final controller in text.values) {
      controller.dispose();
    }
  }
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

enum _BomEditExitAction { continueEditing, discard, save }

// Native fields retain their own selection. Their labels and decorations must
// not also register as table text while rows move or an edit session closes.
Widget _bomTableInput({required Widget child}) =>
    SelectionContainer.disabled(child: UtenTableCellInputTheme(child: child));

/// 「添加组件」弹窗里的选货入口(组件范围、多选)。独立成 provider，组件测试可以换成
/// 固定结果，而不必驱动整套分类树 + 分页选货面板。
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
    this.onEditModeChanged,
    this.onInteractionChanged,
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
  final ValueChanged<bool>? onEditModeChanged;

  /// A pending snapshot, draft, write or confirmation must finish before the
  /// host can replay operation history against the same canonical assembly.
  final ValueChanged<bool>? onInteractionChanged;

  @override
  ConsumerState<GoodsBomTab> createState() => GoodsBomTabState();
}

class GoodsBomTabState extends ConsumerState<GoodsBomTab>
    with AutomaticKeepAliveClientMixin, WidgetsBindingObserver {
  List<_BomNode>? _roots;
  bool _loading = true;
  String? _error;
  int _loadRevision = 0;
  bool _expandingAll = false;
  int _treeExpansionRevision = 0;
  bool _expandingPeers = false;
  int _peerExpansionRevision = 0;
  final _peerLoadingNodes = <_BomNode>{};
  final _singleLoadingNodes = <_BomNode, int>{};
  final _pendingBomReads =
      Map<
        GoodsBomRepository,
        Map<
          (String, int, int, SensitiveReadBoundary),
          Future<List<GoodsBomItem>>
        >
      >.identity();
  final _bomReadSnapshots =
      Map<
        GoodsBomRepository,
        Map<(String, int, int, SensitiveReadBoundary), List<GoodsBomItem>>
      >.identity();
  final _bomReadScopes =
      Map<
        GoodsBomRepository,
        Map<(int, SensitiveReadBoundary), _BomReadScope>
      >.identity();
  bool? _wasActive;

  bool _editMode = false;
  bool _enteringEdit = false;
  bool _finishingEdit = false;
  bool _switchingMode = false;
  bool _checkingChanges = false;
  int _modeRevision = 0;
  bool _pasting = false;
  bool _choosingComponent = false;
  bool _flushingInline = false;
  SensitiveReadBoundary? _editBoundary;
  GoodsBomEditDraft? _draft;
  GoodsBomEditDraft? _pendingDraft;
  List<_BomRow>? _visibleRowsCache;
  int _modalInteractions = 0;
  bool _reportedInteraction = false;
  bool _interactionReportScheduled = false;
  ProviderSubscription<SensitiveReadBoundary>? _boundarySubscription;
  final Map<String, _BomInlineValues> _inlineValues = {};
  final Map<String, TextEditingController> _componentInputs = {};
  final Set<String> _childAppendParents = {};
  final Map<String, _BomMasterValues> _masterValues = {};
  AsyncValue<GoodsBomLearningSummary>? _editingLearning;
  late final _editableAppendRows = [
    for (var index = 0; index < 3; index++)
      MasterTableAppendRow(
        key: ValueKey('goods-bom-new-row-$index'),
        cellBuilder: (context, key) => key != 'treeIdentity'
            ? const SizedBox.shrink()
            : _componentLookup('new:$index', parentGoodsId: widget.goodsId),
      ),
  ];
  List<MasterColumnDef<_BomRow>>? _columnsCache;
  Object? _columnsCacheScope;

  void _clearTableEditors() {
    _flushingInline = false;
    _editingLearning = null;
    for (final values in _masterValues.values) {
      values.dispose();
    }
    _masterValues.clear();
    for (final value in _inlineValues.values) {
      value.dispose();
    }
    for (final controller in _componentInputs.values) {
      controller.dispose();
    }
    _inlineValues.clear();
    _componentInputs.clear();
    _childAppendParents.clear();
  }

  _BomInlineValues _valuesFor(_BomRow row) => _inlineValues.putIfAbsent(
    _rowId(row),
    () => _BomInlineValues(row.node.item, row.parentGoodsId),
  );

  Future<bool> _flushInlineEdits({bool requireLookupSelection = false}) async {
    final draft = _draft;
    if (draft == null || !_canEdit || _flushingInline) return false;
    // A lost receipt must be resolved using the exact reviewed command. It
    // cannot accept new mutations before that outcome has been established.
    if (draft.isCommitRecoveryPending) return true;
    final revision = _modeRevision;
    bool current() =>
        mounted &&
        _canEdit &&
        identical(draft, _draft) &&
        revision == _modeRevision;
    if (requireLookupSelection &&
        _componentInputs.entries.any(
          (entry) =>
              !entry.key.startsWith('row:') &&
              entry.value.text.trim().isNotEmpty,
        )) {
      context.appWarning(_l10n.bomChooseComponent);
      return false;
    }
    final updates =
        <(String, GoodsBomItem, Map<String, dynamic>, _BomInlineValues)>[];
    for (final entry in _inlineValues.entries) {
      final values = entry.value;
      if (values.changed.isEmpty) continue;
      final item = values.item;
      final body = <String, dynamic>{};
      if (values.changed.contains('qty')) {
        final error = _designQtyError(_l10n, values.qty.text);
        if (error != null) {
          context.appWarning(error);
          return false;
        }
        final entered = double.parse(values.qty.text.trim());
        if (item.isPeriodicEdge) {
          body.addAll(
            _periodicEdgeBody(
              item.componentGoodsId,
              entered,
              item.componentUnitName,
            ),
          );
        } else {
          body['qty'] = entered;
        }
      }
      if (values.changed.contains('basisOutputQty')) {
        final parsed = double.tryParse(values.basis.text.trim());
        if (parsed == null || !parsed.isFinite || parsed <= 0) {
          context.appWarning(_l10n.bomDesignQtyInvalid);
          return false;
        }
        body['basisOutputQty'] = parsed;
      }
      if (values.changed.contains('consumptionBasis')) {
        body['consumptionBasis'] = values.consumption.code;
      }
      if (values.changed.contains('allowPartialPackage')) {
        body['allowPartialPackage'] = values.partial;
      }
      if (values.changed.contains('summary')) {
        body['summary'] = values.summary.text.trim();
      }
      if (values.changed.contains('colorId')) {
        body['colorId'] = values.colorId;
        if (values.colorId == null) body['colorLegacyId'] = 0;
      }
      updates.add((values.parentGoodsId, item, body, values));
    }
    final masterUpdates = <(String, Map<String, dynamic>, _BomMasterValues)>[];
    for (final entry in _masterValues.entries) {
      final values = entry.value;
      if (values.changed.isEmpty) continue;
      if (!_hasPermission(Perm.goodsEdit)) {
        context.appWarning(_l10n.bomEditPermissionChanged);
        return false;
      }
      final changes = <String, dynamic>{};
      for (final key in values.changed) {
        changes[key] = key == 'sourceType'
            ? values.sourceType
            : values.text[key]!.text.trim();
      }
      masterUpdates.add((entry.key, changes, values));
    }
    if (updates.isEmpty && masterUpdates.isEmpty) return current();
    setState(() => _flushingInline = true);
    try {
      for (final (parent, item, body, values) in updates) {
        if (!current()) return false;
        // Identity is retained independently of expansion/filter visibility.
        // An explicitly deleted relation no longer contributes pending edits.
        final existing = await draft.list(parent);
        if (!current()) return false;
        if (existing.any((row) => row.id == item.id)) {
          await draft.update(parent, item.id, body);
        }
        if (!current()) return false;
        values.changed.clear();
      }
      for (final (goodsId, changes, values) in masterUpdates) {
        if (!current() || !_hasPermission(Perm.goodsEdit)) return false;
        await draft.updateGoods(goodsId, changes);
        if (!current()) return false;
        values.base.addAll(changes);
        values.changed.clear();
      }
      if (updates.isNotEmpty || masterUpdates.isNotEmpty) await _load();
      return current();
    } catch (error) {
      if (mounted && current()) context.appApiError(error);
      return false;
    } finally {
      if (mounted && revision == _modeRevision) {
        setState(() => _flushingInline = false);
      }
    }
  }

  AppLocalizations get _l10n => AppLocalizations.of(context);

  bool _hasPermission(String permission) =>
      ref.read(isSuperAdminProvider) ||
      ref.read(currentPermissionsProvider).contains(permission);

  bool get _canEnterEdit => widget.canEdit && _hasPermission(Perm.goodsBomEdit);
  bool get _canEdit =>
      _editMode &&
      _canEnterEdit &&
      _editBoundary == ref.read(sensitiveReadBoundaryProvider);
  bool get _canCreate =>
      _canMutate && widget.canCreate && _hasPermission(Perm.goodsBomCreate);
  bool get _canDelete =>
      _canMutate && widget.canDelete && _hasPermission(Perm.goodsBomDelete);
  bool get _canMutate => _canEdit && _draft?.isCommitRecoveryPending != true;
  bool get _writeBusy =>
      _flushingInline ||
      _deleting ||
      _moving ||
      _pasting ||
      _choosingComponent ||
      _switchingMode ||
      _enteringEdit ||
      _finishingEdit ||
      _expandingAll ||
      _expandingPeers;

  GoodsBomRepository get _repository =>
      _draft ?? ref.read(goodsBomRepositoryProvider);
  bool get hasEditingSession => _editMode;

  void _notifyInteractionChanged() {
    if (!mounted) return;
    // Widget/authority replacement may run during an ancestor's build. Report
    // the latest state after that frame rather than marking the host dirty.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      if (_interactionReportScheduled) return;
      _interactionReportScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _interactionReportScheduled = false;
        if (mounted) _notifyInteractionChanged();
      });
      return;
    }
    final interacting =
        _editMode ||
        _enteringEdit ||
        _finishingEdit ||
        // A read-only expansion must not lock navigation. Editing sessions
        // still retain their existing save/discard ownership while it reads.
        (_writeBusy && (!(_expandingAll || _expandingPeers) || _editMode)) ||
        _addComponentOpen ||
        _modalInteractions > 0 ||
        _auditBusyRows.isNotEmpty;
    if (interacting == _reportedInteraction) return;
    _reportedInteraction = interacting;
    widget.onInteractionChanged?.call(interacting);
  }

  Future<T> _duringInteraction<T>(Future<T> Function() action) async {
    _modalInteractions++;
    _notifyInteractionChanged();
    try {
      return await action();
    } finally {
      _modalInteractions--;
      if (mounted) _notifyInteractionChanged();
    }
  }

  Future<void> refresh() async {
    // An edit session owns a stable snapshot until save/discard. A host refresh
    // must not rebuild its draft or replace inputs while the user is typing.
    if (!_writeBusy && !_editMode) await _load();
  }

  Future<bool> finishEditing() async {
    if (_enteringEdit) return false;
    if (!_editMode) return true;
    if (_writeBusy || _draft?.isBusy == true) return false;
    final revision = _modeRevision;
    _finishingEdit = true;
    _notifyInteractionChanged();
    try {
      return await _finishEditing();
    } finally {
      if (mounted && revision == _modeRevision) {
        setState(() => _finishingEdit = false);
        _notifyInteractionChanged();
      }
    }
  }

  // UtenBusyOverlay inserts its root entry after the first frame. Waiting for
  // the following frame lets the spinner actually paint before work starts,
  // including synchronous completion from a warm cache or a fast local API.
  Future<void> _paintFeedback() async {
    await WidgetsBinding.instance.endOfFrame;
    WidgetsBinding.instance.scheduleFrame();
    await WidgetsBinding.instance.endOfFrame;
  }

  Future<bool> _finishEditing() async {
    if (!await _flushInlineEdits(requireLookupSelection: true)) return false;
    if (!mounted) return false;
    final draft = _draft;
    final modeRevision = _modeRevision;
    if (draft != null && draft.hasChanges) {
      if (!_canEdit) {
        context.appWarning(_l10n.bomEditPermissionChanged);
        return false;
      }
      setState(() {
        _switchingMode = true;
        _checkingChanges = true;
      });
      try {
        await _paintFeedback();
        if (!mounted || !_canEdit || !identical(draft, _draft)) return false;
        BomEditPreview preview;
        while (true) {
          try {
            preview = await draft.preview();
            break;
          } on ApiException catch (error) {
            final confirmations = periodicConfirmationsOf(error);
            if (confirmations == null) rethrow;
            if (!mounted || !_canEdit || !identical(draft, _draft)) {
              return false;
            }
            setState(() => _switchingMode = false);
            await WidgetsBinding.instance.endOfFrame;
            if (!mounted || !_canEdit || !identical(draft, _draft)) {
              return false;
            }
            final confirmed = await askPeriodicConfirmations(
              context,
              confirmations,
            );
            if (confirmed == null ||
                !mounted ||
                !_canEdit ||
                !identical(draft, _draft)) {
              return false;
            }
            draft.confirmPeriodicFields(confirmed);
            setState(() => _switchingMode = true);
            await _paintFeedback();
            if (!mounted || !_canEdit || !identical(draft, _draft)) {
              return false;
            }
          }
        }
        if (!mounted || !_canEdit || !identical(draft, _draft)) return false;
        // 预览完成后才询问，服务端尚未修改任何共用组件。
        setState(() => _switchingMode = false);
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted || !_canEdit || !identical(draft, _draft)) return false;
        final action = await showDialog<_BomEditExitAction>(
          context: context,
          builder: (dialogContext) => UtenAlertDialog(
            title: Text(_l10n.bomEditSaveTitle),
            content: SizedBox(
              width: 460,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _l10n.bomEditSaveSummary(
                        preview.operationCount,
                        preview.affectedParents.length,
                      ),
                    ),
                    const SizedBox(height: UtenSpacing.s12),
                    if (preview.warnings.isNotEmpty) ...[
                      UtenInlineNotice(
                        level: UtenInlineNoticeLevel.warning,
                        message: preview.warnings.join('\n'),
                      ),
                      const SizedBox(height: UtenSpacing.s12),
                    ],
                    for (final parent in preview.affectedParents.take(6))
                      Padding(
                        padding: const EdgeInsets.only(bottom: UtenSpacing.s4),
                        child: Text(
                          '· ${parent.goodsName ?? parent.goodsCode ?? _l10n.bomEditUnnamedGoods}',
                        ),
                      ),
                    if (preview.affectedParents.length > 6)
                      Text(
                        _l10n.bomEditMoreGoods(
                          preview.affectedParents.length - 6,
                        ),
                      ),
                    const SizedBox(height: UtenSpacing.s12),
                    if (draft.isCommitRecoveryPending) ...[
                      UtenInlineNotice(
                        level: UtenInlineNoticeLevel.warning,
                        message: _l10n.bomEditSaveUnknown,
                      ),
                      const SizedBox(height: UtenSpacing.s12),
                    ],
                    UtenInlineNotice(
                      level: preview.otherUsageCount > 0
                          ? UtenInlineNoticeLevel.warning
                          : UtenInlineNoticeLevel.info,
                      message: preview.otherUsageCount > 0
                          ? _l10n.bomEditSharedWarning(preview.otherUsageCount)
                          : _l10n.bomEditSaveNote,
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(
                  dialogContext,
                  _BomEditExitAction.continueEditing,
                ),
                child: Text(_l10n.bomEditContinue),
              ),
              OutlinedButton(
                key: const Key('goods-bom-discard-and-exit'),
                onPressed: () =>
                    Navigator.pop(dialogContext, _BomEditExitAction.discard),
                child: Text(
                  draft.isCommitRecoveryPending
                      ? _l10n.bomEditDiscardRefresh
                      : _l10n.bomEditDiscardAndExit,
                ),
              ),
              FilledButton(
                key: const Key('goods-bom-save-confirm'),
                onPressed: () =>
                    Navigator.pop(dialogContext, _BomEditExitAction.save),
                child: Text(
                  preview.otherUsageCount > 0
                      ? _l10n.bomEditConfirmShared
                      : _l10n.bomEditConfirmSave,
                ),
              ),
            ],
          ),
        );
        if (!mounted ||
            modeRevision != _modeRevision ||
            !identical(draft, _draft)) {
          return false;
        }
        if (action == _BomEditExitAction.discard) {
          return await _exitEditSession(
            draft,
            modeRevision: modeRevision,
            discard: true,
          );
        }
        if (action != _BomEditExitAction.save || !_canEdit) return false;
        setState(() {
          _switchingMode = true;
          _checkingChanges = false;
        });
        await _paintFeedback();
        if (!mounted || !_canEdit || !identical(draft, _draft)) return false;
        await draft.commit(preview.previewToken, confirmSharedChanges: true);
        if (!mounted) return false;
        widget.onDataChanged?.call();
        context.appSuccess(_l10n.bomEditSaved);
      } on ApiException catch (error) {
        if (!mounted ||
            modeRevision != _modeRevision ||
            !identical(draft, _draft)) {
          return false;
        }
        final details = error.fieldErrors ?? const <ApiFieldError>[];
        return await _offerDiscardDraft(
          [
            error.message,
            for (final detail in details.take(10))
              '${detail.field}：${detail.message}',
            if (details.length > 10)
              _l10n.bomEditMoreProblems(details.length - 10),
          ].join('\n'),
        );
      } catch (_) {
        if (!mounted ||
            modeRevision != _modeRevision ||
            !identical(draft, _draft)) {
          return false;
        }
        return await _offerDiscardDraft(_l10n.bomEditSaveUnknown);
      } finally {
        if (mounted && modeRevision == _modeRevision) {
          setState(() => _switchingMode = false);
        }
      }
    }
    return _exitEditSession(draft, modeRevision: modeRevision);
  }

  Future<bool> _exitEditSession(
    GoodsBomEditDraft? draft, {
    required int modeRevision,
    bool discard = false,
  }) async {
    bool current() =>
        mounted && modeRevision == _modeRevision && identical(draft, _draft);
    if (!current()) return false;
    _closeAddComponentWindow();
    _clearTableEditors();
    draft?.close();
    setState(() {
      _editMode = false;
      _editBoundary = null;
      _draft = null;
      if (discard) {
        // A read failure must never leave the discarded draft looking like
        // saved data. The table owns loading/retry while canonical rows load.
        _roots = null;
        _visibleRowsCache = null;
        _selectedRowIds = <String>{};
      }
    });
    widget.onEditModeChanged?.call(false);
    await _load();
    return mounted && modeRevision == _modeRevision && !_editMode;
  }

  Future<bool> _offerDiscardDraft(String message) async {
    final draft = _draft;
    final modeRevision = _modeRevision;
    bool current() =>
        mounted &&
        _editMode &&
        modeRevision == _modeRevision &&
        identical(draft, _draft);
    if (!current()) return false;
    setState(() => _switchingMode = false);
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || !current()) return false;
    final discard = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => UtenAlertDialog(
        title: Text(_l10n.bomEditSaveFailedTitle),
        content: SizedBox(
          width: 460,
          child: Text(_l10n.bomEditRecoveryMessage(message)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(_l10n.bomEditKeepDraft),
          ),
          FilledButton(
            key: const Key('goods-bom-discard-draft'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(_l10n.bomEditDiscardRefresh),
          ),
        ],
      ),
    );
    if (discard != true || !current()) return false;
    return _exitEditSession(draft, modeRevision: modeRevision, discard: true);
  }

  Future<void> _toggleEditMode() async {
    if (_writeBusy || _expandingAll) return;
    if (_editMode) {
      await finishEditing();
      return;
    }
    if (!_canEnterEdit) return;
    final goodsId = widget.goodsId;
    final boundary = ref.read(sensitiveReadBoundaryProvider);
    final revision = ++_modeRevision;
    bool current() =>
        mounted &&
        revision == _modeRevision &&
        goodsId == widget.goodsId &&
        boundary == ref.read(sensitiveReadBoundaryProvider) &&
        _canEnterEdit;
    final draft = GoodsBomEditDraft(
      base: ref.read(goodsBomRepositoryProvider),
      api: ref.read(apiClientProvider),
      rootGoodsId: goodsId,
      isCurrent: current,
    );
    setState(() {
      _editingLearning = ref.read(goodsBomLearningProvider(goodsId));
      _enteringEdit = true;
      _pendingDraft = draft;
    });
    _notifyInteractionChanged();
    try {
      await _paintFeedback();
      if (!current()) return;
      final roots = await _readTree(draft, goodsId, current);
      if (!current()) return;
      final masters = await _prepareMasterValues(roots, draft, current);
      if (!current()) {
        for (final values in masters.values) {
          values.dispose();
        }
        return;
      }
      // Preparing snapshots must not replace the current table with a loading
      // screen or enable any write controls before the snapshot succeeds.
      _loadRevision++;
      _retireBomReadScopes();
      setState(() {
        _acceptTree(roots);
        _pruneSelection();
        _editMode = true;
        _editBoundary = boundary;
        _auditMode = false;
        _draft = draft;
        _adoptMasterValues(masters);
        _error = null;
        _loading = false;
      });
      widget.onEditModeChanged?.call(true);
    } on ApiException catch (error) {
      if (mounted && current()) context.appError(error.message);
    } catch (_) {
      if (mounted && current()) context.appError(_l10n.bomEditPrepareFailed);
    } finally {
      if (!identical(draft, _draft)) draft.close();
      if (mounted && revision == _modeRevision) {
        setState(() {
          _enteringEdit = false;
          _pendingDraft = null;
        });
        _notifyInteractionChanged();
      }
    }
  }

  Future<void> _toggleAuditMode() async {
    if (!_canAudit || _writeBusy) return;
    if (_editMode && !await finishEditing()) return;
    if (!mounted || !_canAudit) return;
    setState(() => _auditMode = !_auditMode);
  }

  Future<void> _importComponents() =>
      _duringInteraction(_importComponentsInSession);

  Future<void> _importComponentsInSession() async {
    if (!_canCreate || _writeBusy) return;
    final goodsId = widget.goodsId;
    final boundary = ref.read(sensitiveReadBoundaryProvider);
    bool current() =>
        mounted &&
        widget.goodsId == goodsId &&
        boundary == ref.read(sensitiveReadBoundaryProvider) &&
        _canEnterEdit &&
        widget.canCreate &&
        _hasPermission(Perm.goodsBomCreate);
    if (!await finishEditing() || !mounted || !current()) return;
    await showGoodsBomImport(
      context,
      ref,
      goodsId: goodsId,
      canWrite: current,
      canReplace: () =>
          current() && widget.canDelete && _hasPermission(Perm.goodsBomDelete),
      onImported: () {
        if (!current()) return;
        widget.onDataChanged?.call();
        _load();
      },
    );
    if (current() && !_editMode) await _toggleEditMode();
  }

  Future<void> _showLearning({bool showMaterialEvidence = false}) =>
      _duringInteraction(
        () => _showLearningPanel(showMaterialEvidence: showMaterialEvidence),
      );

  Future<void> _showLearningPanel({required bool showMaterialEvidence}) async {
    final goodsId = widget.goodsId;
    final boundary = ref.read(sensitiveReadBoundaryProvider);
    bool canWrite() =>
        mounted &&
        widget.goodsId == goodsId &&
        boundary == ref.read(sensitiveReadBoundaryProvider) &&
        _canEnterEdit;
    final openedInEditMode = _canEdit;
    await showGoodsBomLearning(
      context,
      goodsId,
      showMaterialEvidence: showMaterialEvidence,
      canWrite: () => openedInEditMode && canWrite(),
      beforeRelearn: () async => canWrite() && await finishEditing(),
      onRelearned: () {
        if (mounted) _load();
      },
    );
    if (openedInEditMode && canWrite() && !_editMode) await _toggleEditMode();
  }

  Future<void> _previewBom() async {
    final goodsId = widget.goodsId;
    final boundary = ref.read(sensitiveReadBoundaryProvider);
    if (!await finishEditing() ||
        !mounted ||
        goodsId != widget.goodsId ||
        boundary != ref.read(sensitiveReadBoundaryProvider)) {
      return;
    }
    widget.onPreview?.call();
  }

  Future<UtenExportSelection?> _prepareBomExport() async {
    final goodsId = widget.goodsId;
    final boundary = ref.read(sensitiveReadBoundaryProvider);
    bool current() =>
        mounted &&
        goodsId == widget.goodsId &&
        boundary == ref.read(sensitiveReadBoundaryProvider);
    if (!await finishEditing() || !current()) return null;
    return UtenExportSelection(stillCurrent: current);
  }

  /// 当前勾选的行键集合(复合键 `父货品id|关系行id`，见 [_rowId])。
  ///
  /// 本页「当前选中」的唯一真相：表格勾选框与单击行都写入这里，审计模式同样适用。
  /// 不再另留一个 _selected 字段，否则两份真相一旦错位，批量删除
  /// 删的就不是用户勾的那几条。
  Set<String> _selectedRowIds = <String>{};

  /// 批量删除的网络段进行中(只包住网络调用本身，确认框弹出时必须是 false)。
  bool _deleting = false;

  /// 当前展开的组件 goodsId 集合：CRUD 重载后据此恢复展开，让新加的子组件可见。
  final Set<String> _expandedIds = {};
  final Map<String, bool> _occurrenceExpansion = {};

  /// 审计模式（V256）：点已审格把该组件标记为「已核对无误」（绿色），再点取消。
  /// 标记持久化在服务端，多人/跨天/换机器都保留；编辑行内容后服务端自动清除。
  bool _auditMode = false;

  /// 同一关系行防连点；不同组件可以连续核对，不互相阻塞。
  final Map<String, Completer<void>> _auditBusyRows = {};
  final Map<String, int> _auditRevisions = {};

  /// 「审计模式」按钮可见性：goods:bom:audit 或超管（已审绿色/已审列只在该模式
  /// 下出现，只有持有权限者能改标记）。
  bool get _canAudit =>
      ref.read(isSuperAdminProvider) ||
      ref.read(currentPermissionsProvider).contains(Perm.goodsBomAudit);

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
    WidgetsBinding.instance.addObserver(this);
    _boundarySubscription = ref.listenManual(sensitiveReadBoundaryProvider, (
      previous,
      next,
    ) {
      if (previous == null || previous == next || !mounted) return;
      final hadDraft = _draft?.hasChanges == true;
      _modeRevision++;
      _draft?.close();
      _pendingDraft?.close();
      for (final pending in _auditBusyRows.values) {
        if (!pending.isCompleted) pending.complete();
      }
      _auditBusyRows.clear();
      _auditRevisions.clear();
      _loadRevision++;
      _treeExpansionRevision++;
      _expandingAll = false;
      _invalidatePeerExpansion();
      _retireBomReadScopes();
      _singleLoadingNodes.clear();
      _clearTableEditors();
      setState(() {
        _draft = null;
        _pendingDraft = null;
        _enteringEdit = false;
        _finishingEdit = false;
        _switchingMode = false;
        _choosingComponent = false;
        _editMode = false;
        _editBoundary = null;
        _auditMode = false;
        _addComponentCandidates = null;
        _roots = null;
        _visibleRowsCache = null;
        _selectedRowIds = <String>{};
        _expandedIds.clear();
        _occurrenceExpansion.clear();
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        widget.onEditModeChanged?.call(false);
        _notifyInteractionChanged();
        if (hadDraft) context.appWarning(_l10n.bomEditBoundaryExpired);
        if (_hasPermission(Perm.goodsView)) {
          _load();
        } else {
          setState(() {
            _loading = false;
            _error = _l10n.bomEditNoView;
          });
        }
      });
    });
    _load();
  }

  @override
  void dispose() {
    _retireBomReadScopes();
    _clearTableEditors();
    _boundarySubscription?.close();
    _draft?.close();
    _pendingDraft?.close();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final active = TickerMode.valuesOf(context).enabled;
    if (_wasActive == false && active) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_editMode && !_writeBusy) _load();
      });
    }
    _wasActive = active;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        _wasActive == true &&
        ModalRoute.of(context)?.isCurrent == true &&
        !_editMode &&
        !_writeBusy) {
      _load();
    }
  }

  @override
  void didUpdateWidget(covariant GoodsBomTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.goodsId != widget.goodsId) {
      _treeExpansionRevision++;
      _expandingAll = false;
      _invalidatePeerExpansion();
      _retireBomReadScopes();
      _singleLoadingNodes.clear();
      _clearTableEditors();
      _modeRevision++;
      _roots = null;
      _visibleRowsCache = null;
      _expandedIds.clear();
      _occurrenceExpansion.clear();
      _selectedRowIds = <String>{};
      _editMode = false;
      _draft?.close();
      _pendingDraft?.close();
      _draft = null;
      _pendingDraft = null;
      _enteringEdit = false;
      _finishingEdit = false;
      _switchingMode = false;
      _choosingComponent = false;
      _auditMode = false;
      _addComponentCandidates = null;
      _load();
      _notifyInteractionChanged();
    }
  }

  /// 展开/刷新若与审计写入交错，只重读相应父件，不能让旧 GET 覆盖新标记。
  Future<List<GoodsBomItem>> _readBomItems(
    String goodsId, {
    GoodsBomRepository? repository,
    bool Function()? isCurrent,
  }) async {
    final source = repository ?? _repository;
    final generation = _loadRevision;
    final boundary = ref.read(sensitiveReadBoundaryProvider);
    bool current() =>
        mounted &&
        generation == _loadRevision &&
        boundary == ref.read(sensitiveReadBoundaryProvider) &&
        (isCurrent?.call() ?? true);
    bool hasPending() =>
        _auditBusyRows.keys.any((key) => key.startsWith('$goodsId|'));
    while (current()) {
      final pending = [
        for (final entry in _auditBusyRows.entries)
          if (entry.key.startsWith('$goodsId|')) entry.value.future,
      ];
      if (pending.isNotEmpty) await Future.wait(pending);
      if (!current()) return const [];
      if (hasPending()) continue;
      final revision = _auditRevisions[goodsId] ?? 0;
      final key = (goodsId, generation, revision, boundary);
      final cached = _bomReadSnapshots[source]?[key];
      if (cached != null) return cached;
      final scoped = _pendingBomReads.putIfAbsent(source, () => {});
      final queue = _bomReadScopes.putIfAbsent(source, () => {}).putIfAbsent((
        generation,
        boundary,
      ), _BomReadScope.new);
      final reading = scoped.putIfAbsent(
        key,
        () => queue.run(() => source.list(goodsId)),
      );
      final List<GoodsBomItem> items;
      try {
        items = await reading;
      } finally {
        if (identical(scoped[key], reading)) scoped.remove(key);
        if (scoped.isEmpty && identical(_pendingBomReads[source], scoped)) {
          _pendingBomReads.remove(source);
        }
      }
      if (!current()) return const [];
      if (revision == (_auditRevisions[goodsId] ?? 0) && !hasPending()) {
        final snapshot = List<GoodsBomItem>.unmodifiable(items);
        _bomReadSnapshots.putIfAbsent(source, () => {})[key] = snapshot;
        return snapshot;
      }
    }
    return const [];
  }

  void _retireBomReadScopes() {
    for (final scopes in _bomReadScopes.values) {
      for (final scope in scopes.values) {
        scope.retire();
      }
    }
    _bomReadScopes.clear();
    _pendingBomReads.clear();
    _bomReadSnapshots.clear();
  }

  Future<void> _load({bool expandAll = false}) async {
    final supersededExpansion = !expandAll && _expandingAll;
    if (supersededExpansion) {
      _treeExpansionRevision++;
      _expandingAll = false;
    }
    final supersededPeers = _expandingPeers;
    if (supersededPeers) {
      _invalidatePeerExpansion();
    }
    for (final node in _singleLoadingNodes.keys) {
      node.loading = false;
    }
    _singleLoadingNodes.clear();
    _retireBomReadScopes();
    final revision = ++_loadRevision;
    final goodsId = widget.goodsId;
    final repository = _repository;
    final boundary = ref.read(sensitiveReadBoundaryProvider);
    bool current() =>
        mounted &&
        revision == _loadRevision &&
        goodsId == widget.goodsId &&
        boundary == ref.read(sensitiveReadBoundaryProvider) &&
        identical(repository, _repository);
    setState(() {
      _loading = true;
      _error = null;
    });
    if (supersededExpansion || supersededPeers) _notifyInteractionChanged();
    try {
      final roots = await _readTree(
        repository,
        goodsId,
        current,
        expandAll: expandAll,
      );
      if (!current()) return;
      final masters = repository is GoodsBomEditDraft
          ? await _prepareMasterValues(roots, repository, current)
          : <String, _BomMasterValues>{};
      if (!current()) {
        for (final values in masters.values) {
          values.dispose();
        }
        return;
      }
      if (!_editMode && !expandAll) {
        ref.invalidate(goodsBomLearningProvider(goodsId));
      }
      setState(() {
        _adoptMasterValues(masters);
        _acceptTree(roots);
        if (expandAll) {
          _occurrenceExpansion.clear();
          _expandedIds.addAll([
            for (final node in _bulkExpandableBranches(roots))
              if (node.expanded) node.item.componentGoodsId,
          ]);
        }
        // Keep rows and editor identity when the accepted snapshot is equal.
        // A real structure change still prunes relations that no longer exist.
        _pruneSelection();
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!current()) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!current()) return;
      setState(() {
        _error = '加载组装信息失败'; // TODO(l10n): 补 arb
        _loading = false;
      });
    }
  }

  void _acceptTree(List<_BomNode> roots) {
    final displayed = _roots;
    if (displayed != null && _sameSnapshotTree(displayed, roots)) return;
    _roots = roots;
    _visibleRowsCache = null;
  }

  static bool _sameSnapshotTree(List<_BomNode> before, List<_BomNode> after) {
    if (before.length != after.length) return false;
    for (var index = 0; index < before.length; index++) {
      final previous = before[index];
      final next = after[index];
      if (previous.expanded != next.expanded ||
          previous.loading != next.loading ||
          _itemSnapshot(previous.item) != _itemSnapshot(next.item) ||
          !listEquals(previous.item.warnings, next.item.warnings)) {
        return false;
      }
      final previousChildren = previous.children;
      final nextChildren = next.children;
      if ((previousChildren == null) != (nextChildren == null) ||
          (previousChildren != null &&
              !_sameSnapshotTree(previousChildren, nextChildren!))) {
        return false;
      }
    }
    return true;
  }

  // Value comparison happens only when accepting a read, never on scroll or
  // selection frames. Include every field so fresh business facts are retained.
  static Object _itemSnapshot(GoodsBomItem item) => (
    (
      item.id,
      item.componentGoodsId,
      item.componentCode,
      item.componentName,
      item.componentModel,
      item.componentSpec,
      item.componentMaterial,
      item.componentStockQty,
      item.componentUnitName,
      item.componentColorName,
      item.componentSourceType,
      item.componentIssueMethod,
    ),
    (
      item.colorId,
      item.colorLegacyId,
      item.defaultSupplierId,
      item.vendLegacyId,
      item.qty,
      item.price,
      item.total,
      item.summary,
      item.legacyId,
      item.hasChildren,
      item.controlStage,
      item.consumptionBasis,
      item.basisOutputQty,
      item.allowPartialPackage,
      item.hardGate,
      item.auditedAt,
      item.systemLearned,
      item.unitWeightGrams,
    ),
    (
      item.actual.qty,
      item.actual.perUnitQty,
      item.actual.status,
      item.actual.usesActual,
      item.actual.netQty,
      item.actual.outputQty,
      item.actual.sampleCount,
      item.actual.defectQty,
      item.actual.perProducedQty,
      item.actual.defectRate,
      item.actual.updatedAt,
      item.actual.relearnedAt,
    ),
  );

  Future<List<_BomNode>> _readTree(
    GoodsBomRepository repository,
    String goodsId,
    bool Function() current, {
    bool expandAll = false,
  }) async {
    // One load owns its read cache. Repeated shared assemblies still produce
    // separate occurrence nodes, but never issue duplicate snapshot requests.
    final snapshots = <String, List<GoodsBomItem>>{};
    final loaded = _roots;
    if (expandAll && loaded != null) {
      // Collapse retains its snapshot, just like the ordinary branch toggle.
      // Bulk expansion only fetches parents whose children have not been read.
      final pending = [(goodsId, loaded)];
      var visited = 0;
      for (var cursor = 0; cursor < pending.length && current(); cursor++) {
        final (parentId, nodes) = pending[cursor];
        if (snapshots.containsKey(parentId)) continue;
        final items = <GoodsBomItem>[];
        for (final node in nodes) {
          items.add(node.item);
          if (node.children case final children?) {
            pending.add((node.item.componentGoodsId, children));
          }
          if (++visited % 128 == 0) {
            await Future<void>.delayed(Duration.zero);
            if (!current()) return const [];
          }
        }
        snapshots[parentId] = items;
      }
    }
    final reads = <String, Future<List<GoodsBomItem>>>{};
    Future<List<_BomNode>> read(String id) async {
      final items = await reads.putIfAbsent(
        id,
        () => snapshots.containsKey(id)
            ? Future.value(snapshots[id]!)
            : _readBomItems(id, repository: repository, isCurrent: current),
      );
      return _nodesForItems(items, current);
    }

    final roots = await read(goodsId);
    var level = [
      for (final node in roots)
        (node, <String>{goodsId}, '$goodsId/${node.item.id}'),
    ];
    // Breadth-first, at most four independent reads at a time across the entire
    // level; recursive Future.wait would multiply concurrency at every depth.
    for (var depth = 0; depth <= 10 && current(); depth++) {
      final expanded = level
          .where(
            (entry) =>
                !entry.$2.contains(entry.$1.item.componentGoodsId) &&
                (entry.$1.item.hasChildren ||
                    _childAppendParents.contains(
                      entry.$1.item.componentGoodsId,
                    )) &&
                (expandAll ||
                    (_occurrenceExpansion[entry.$3] ??
                        _expandedIds.contains(entry.$1.item.componentGoodsId))),
          )
          .toList();
      final next = <(_BomNode, Set<String>, String)>[];
      for (var start = 0; start < expanded.length; start += 4) {
        if (!current()) return roots;
        await Future.wait([
          for (final entry in expanded.skip(start).take(4))
            () async {
              final node = entry.$1;
              // An edit session cannot become writable with an incomplete
              // visible snapshot. Read-only refreshes may retain a collapsed
              // failed subtree and let the user retry its own expand control.
              try {
                node.children = await read(node.item.componentGoodsId);
                node.expanded = true;
              } catch (_) {
                if (expandAll || repository is GoodsBomEditDraft) rethrow;
              }
            }(),
        ], eagerError: true);
        await Future<void>.delayed(Duration.zero);
      }
      for (final entry in expanded) {
        final node = entry.$1;
        final ancestors = {...entry.$2, node.item.componentGoodsId};
        for (final child in node.children ?? const <_BomNode>[]) {
          next.add((child, ancestors, '${entry.$3}/${child.item.id}'));
        }
      }
      level = next;
      if (level.isEmpty) break;
      await Future<void>.delayed(Duration.zero);
    }
    return roots;
  }

  Future<List<_BomNode>> _nodesForItems(
    List<GoodsBomItem> items,
    bool Function() current,
  ) async {
    final nodes = <_BomNode>[];
    for (var index = 0; index < items.length && current(); index++) {
      if (index > 0 && index % 128 == 0) {
        await Future<void>.delayed(Duration.zero);
        if (!current()) return const [];
      }
      nodes.add(_BomNode(items[index]));
    }
    return current() ? nodes : const [];
  }

  /// Match the bounded snapshot reader and stop corrupt cyclic paths. Each
  /// occurrence keeps its own node while shared assemblies reuse their reads.
  Iterable<_BomNode> _bulkExpandableBranches(List<_BomNode> roots) sync* {
    Iterable<_BomNode> walk(
      List<_BomNode> nodes,
      Set<String> ancestors,
      int depth,
    ) sync* {
      if (depth > 10) return;
      for (final node in nodes) {
        final id = node.item.componentGoodsId;
        if (ancestors.contains(id)) continue;
        if (!node.item.hasChildren && !_childAppendParents.contains(id)) {
          continue;
        }
        yield node;
        if (node.children case final children?) {
          yield* walk(children, {...ancestors, id}, depth + 1);
        }
      }
    }

    yield* walk(roots, {widget.goodsId}, 0);
  }

  bool get _allBomBranchesExpanded {
    var found = false;
    for (final node in _bulkExpandableBranches(_roots ?? const [])) {
      found = true;
      if (!node.expanded || node.children == null) return false;
    }
    return found;
  }

  Future<void> _expandAllBomBranches() async {
    if (_expandingAll ||
        _loading ||
        _writeBusy ||
        _roots == null ||
        _auditBusyRows.isNotEmpty ||
        _visibleRows.any((row) => row.node.loading)) {
      return;
    }
    final revision = ++_treeExpansionRevision;
    final readRevision = _loadRevision;
    final boundary = ref.read(sensitiveReadBoundaryProvider);
    bool current() =>
        mounted &&
        revision == _treeExpansionRevision &&
        readRevision == _loadRevision &&
        boundary == ref.read(sensitiveReadBoundaryProvider);
    setState(() => _expandingAll = true);
    _notifyInteractionChanged();
    try {
      // Raw editors stay mounted and owned by their existing controllers.
      // Expanding reads the same draft, without staging or submitting inputs.
      final cached = <_BomNode>[];
      var complete = true;
      for (final node in _bulkExpandableBranches(_roots!)) {
        if (node.children == null) {
          complete = false;
          break;
        }
        cached.add(node);
        if (cached.length % 128 == 0) {
          await Future<void>.delayed(Duration.zero);
          if (!current()) return;
        }
      }
      if (!current()) return;
      if (complete) {
        setState(() {
          _occurrenceExpansion.clear();
          for (final node in cached) {
            node.expanded = true;
            _expandedIds.add(node.item.componentGoodsId);
          }
          _visibleRowsCache = null;
        });
        return;
      }
      await _load(expandAll: true);
    } finally {
      if (mounted && revision == _treeExpansionRevision) {
        setState(() => _expandingAll = false);
        _notifyInteractionChanged();
      }
    }
  }

  void _collapseAllBomBranches() {
    if (_expandingAll || _loading || _writeBusy) return;
    void collapse(List<_BomNode> nodes) {
      for (final node in nodes) {
        node.expanded = false;
        if (node.children case final children?) collapse(children);
      }
    }

    setState(() {
      collapse(_roots ?? const []);
      _expandedIds.clear();
      _occurrenceExpansion.clear();
      _visibleRowsCache = null;
      _pruneSelection();
    });
  }

  Future<void> _expandPeerBomBranches(_BomRow row) async {
    if (_writeBusy ||
        _loading ||
        _auditBusyRows.isNotEmpty ||
        row.isPlaceholder) {
      return;
    }
    final shown = _visibleRows;
    if (!shown.any(
      (candidate) =>
          candidate.occurrenceKey == row.occurrenceKey &&
          identical(candidate.node, row.node),
    )) {
      return;
    }
    List<_BomNode>? siblings;
    var parentPath = widget.goodsId;
    if (row.depth == 0) {
      siblings = _roots;
    } else {
      parentPath = row.occurrenceKey.substring(
        0,
        row.occurrenceKey.lastIndexOf('/'),
      );
      for (final candidate in shown) {
        if (candidate.occurrenceKey == parentPath) {
          siblings = candidate.node.children;
          break;
        }
      }
    }
    final targets = [
      for (final node in siblings ?? const <_BomNode>[])
        if (!node.expanded &&
            !node.loading &&
            (node.item.hasChildren ||
                _childAppendParents.contains(node.item.componentGoodsId)))
          node,
    ];
    if (targets.isEmpty) return;
    final token = ++_peerExpansionRevision;
    final readRevision = _loadRevision;
    final boundary = ref.read(sensitiveReadBoundaryProvider);
    final repository = _repository;
    bool current() =>
        mounted &&
        token == _peerExpansionRevision &&
        readRevision == _loadRevision &&
        boundary == ref.read(sensitiveReadBoundaryProvider) &&
        identical(repository, _repository);
    setState(() {
      _expandingPeers = true;
      _peerLoadingNodes.addAll(targets);
      for (final node in targets) {
        node.loading = true;
      }
    });
    _notifyInteractionChanged();
    try {
      final results = <_BomNode, List<_BomNode>>{};
      for (var start = 0; start < targets.length && current(); start += 4) {
        await Future.wait([
          for (final node in targets.skip(start).take(4))
            () async {
              results[node] =
                  node.children ??
                  await _nodesForItems(
                    await _readBomItems(
                      node.item.componentGoodsId,
                      repository: repository,
                      isCurrent: current,
                    ),
                    current,
                  );
            }(),
        ], eagerError: true);
        await Future<void>.delayed(Duration.zero);
      }
      if (!current()) return;
      final masters = repository is GoodsBomEditDraft
          ? await _prepareMasterValues(
              results.values.expand((nodes) => nodes),
              repository,
              current,
            )
          : <String, _BomMasterValues>{};
      if (!current()) {
        for (final values in masters.values) {
          values.dispose();
        }
        return;
      }
      setState(() {
        _adoptMasterValues(masters);
        for (final entry in results.entries) {
          entry.key.children = entry.value;
          entry.key.expanded = true;
          _occurrenceExpansion['$parentPath/${entry.key.item.id}'] = true;
        }
        _visibleRowsCache = null;
      });
    } catch (error) {
      if (mounted && current()) context.appApiError(error);
    } finally {
      if (mounted && token == _peerExpansionRevision) {
        setState(() {
          _peerExpansionRevision++;
          _expandingPeers = false;
          for (final node in targets) {
            node.loading = false;
          }
          _peerLoadingNodes.clear();
        });
        _notifyInteractionChanged();
      }
    }
  }

  void _invalidatePeerExpansion() {
    _peerExpansionRevision++;
    _expandingPeers = false;
    for (final node in _peerLoadingNodes) {
      node.loading = false;
    }
    _peerLoadingNodes.clear();
  }

  /// 可见节点平铺：根 → （展开的）子级递归，级联序号 1 / 1.1 / 1.1.2。
  ///
  /// `ancestorContinuations` 按 [UtenTreeTableCell] 的硬契约累积：长度恒等于
  /// depth、`[i]` = 深度 i 的祖先后面还有没有兄弟。这里的展开是懒加载的
  /// （`hasChildren` 是服务端事实，不能从扁平行推），所以保留本地 walk；
  /// 同口径的通用推导见 `utenTreeProjection`。
  List<_BomRow> get _visibleRows {
    final cached = _visibleRowsCache;
    if (cached != null) return cached;
    final rows = <_BomRow>[];
    void walk(
      List<_BomNode> nodes,
      int depth,
      String prefix,
      String parentGoodsId,
      List<bool> ancestorContinuations,
      String parentPath,
    ) {
      for (var i = 0; i < nodes.length; i++) {
        final seq = prefix.isEmpty ? '${i + 1}' : '$prefix.${i + 1}';
        final n = nodes[i];
        final isLastChild = i == nodes.length - 1;
        final path = '$parentPath/${n.item.id}';
        rows.add(
          _BomRow(
            n,
            depth,
            seq,
            parentGoodsId,
            List.unmodifiable(ancestorContinuations),
            isLastChild,
            path,
          ),
        );
        if (n.expanded && n.children != null) {
          walk(n.children!, depth + 1, seq, n.item.componentGoodsId, [
            ...ancestorContinuations,
            !isLastChild,
          ], path);
        }
        if (n.expanded &&
            _childAppendParents.contains(n.item.componentGoodsId)) {
          rows.add(
            _BomRow(
              _BomNode(
                GoodsBomItem(
                  id: '__new-child:${n.item.componentGoodsId}',
                  componentGoodsId: '',
                ),
              ),
              depth + 1,
              '$seq.${(n.children?.length ?? 0) + 1}',
              n.item.componentGoodsId,
              [...ancestorContinuations, !isLastChild],
              true,
              '$path/__new-child',
            ),
          );
        }
      }
    }

    walk(
      _roots ?? const <_BomNode>[],
      0,
      '',
      widget.goodsId,
      const [],
      widget.goodsId,
    );
    return _visibleRowsCache = rows;
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
    if (_writeBusy || _loading) return;
    final id = node.item.componentGoodsId;
    if (!node.item.hasChildren && !_childAppendParents.contains(id)) return;
    if (node.expanded) {
      setState(() {
        _setOccurrenceExpanded(node, false);
        _visibleRowsCache = null;
        // 整棵子树的行随折叠消失，它们的勾选跟着剪掉(见 _pruneSelection)。
        _pruneSelection();
      });
      return;
    }
    if (node.children != null) {
      setState(() {
        _setOccurrenceExpanded(node, true);
        _visibleRowsCache = null;
      });
      return;
    }
    if (node.loading) return;
    final repository = _repository;
    final boundary = ref.read(sensitiveReadBoundaryProvider);
    final revision = _loadRevision;
    setState(() {
      node.loading = true;
      _singleLoadingNodes[node] = revision;
    });
    try {
      final items = await _readBomItems(id, repository: repository);
      if (!mounted ||
          revision != _loadRevision ||
          boundary != ref.read(sensitiveReadBoundaryProvider) ||
          !identical(repository, _repository) ||
          node.item.componentGoodsId != id ||
          (!node.item.hasChildren && !_childAppendParents.contains(id))) {
        return;
      }
      bool current() =>
          mounted &&
          revision == _loadRevision &&
          boundary == ref.read(sensitiveReadBoundaryProvider) &&
          identical(repository, _repository);
      final children = await _nodesForItems(items, current);
      if (!current()) return;
      final masters = repository is GoodsBomEditDraft
          ? await _prepareMasterValues(children, repository, current)
          : <String, _BomMasterValues>{};
      if (!current()) {
        for (final values in masters.values) {
          values.dispose();
        }
        return;
      }
      setState(() {
        _adoptMasterValues(masters);
        node.children = children;
        _setOccurrenceExpanded(node, true);
        _visibleRowsCache = null;
        node.loading = false;
      });
    } catch (_) {
      if (!mounted ||
          revision != _loadRevision ||
          boundary != ref.read(sensitiveReadBoundaryProvider)) {
        return;
      }
      setState(() => node.loading = false);
      context.appError('加载子级组件失败'); // TODO(l10n): 补 arb
    } finally {
      if (_singleLoadingNodes[node] == revision) {
        _singleLoadingNodes.remove(node);
        if (mounted && node.loading) {
          setState(() => node.loading = false);
        }
      }
    }
  }

  void _setOccurrenceExpanded(_BomNode node, bool expanded) {
    for (final row in _visibleRows) {
      if (identical(row.node, node)) {
        _occurrenceExpansion[row.occurrenceKey] = expanded;
        break;
      }
    }
    node.expanded = expanded;
  }

  void _expandGoodsAfterMutation(String goodsId) {
    _expandedIds.add(goodsId);
    void walk(List<_BomNode> nodes, String parentPath) {
      for (final node in nodes) {
        final path = '$parentPath/${node.item.id}';
        if (node.item.componentGoodsId == goodsId) {
          _occurrenceExpansion.remove(path);
        }
        if (node.children case final children?) walk(children, path);
      }
    }

    walk(_roots ?? const [], widget.goodsId);
  }

  // ---- 增删改 -------------------------------------------------------------

  Future<void> _pickTableComponent({
    _BomRow? replacing,
    String? parentGoodsId,
    GoodsListItem? selected,
    String? inputKey,
  }) => _duringInteraction(() async {
    if (_writeBusy || (replacing == null ? !_canCreate : !_canMutate)) return;
    if (!await _flushInlineEdits()) return;
    if (!mounted) return;
    final draft = _draft;
    if (draft == null) return;
    final revision = _modeRevision;
    final boundary = ref.read(sensitiveReadBoundaryProvider);
    final parent = parentGoodsId ?? replacing?.parentGoodsId ?? widget.goodsId;
    bool current() =>
        mounted &&
        _canMutate &&
        identical(draft, _draft) &&
        revision == _modeRevision &&
        boundary == ref.read(sensitiveReadBoundaryProvider) &&
        (replacing != null || _canCreate);
    setState(() => _choosingComponent = true);
    _notifyInteractionChanged();
    try {
      if (replacing == null) {
        final picked = selected == null
            ? await ref.read(bomComponentPickerProvider)(context, ref)
            : [selected];
        if (picked.isEmpty || !current()) return;
        final staged = await _stageNewTableComponents(
          picked,
          parent,
          draft,
          current,
        );
        if (!staged || !current()) return;
        if (parent != widget.goodsId) _expandGoodsAfterMutation(parent);
        _childAppendParents.remove(parent);
        if (inputKey != null) _componentInputs[inputKey]?.clear();
        await _load();
        return;
      }
      final goods =
          selected ??
          await ref.read(bomComponentSinglePickerProvider)(context, ref);
      if (goods == null || !mounted || !current()) return;
      final currentItems = await draft.list(parent);
      if (!mounted || !current()) return;
      final originals = currentItems.where(
        (item) => item.id == replacing.node.item.id,
      );
      if (originals.isEmpty) return;
      final original = originals.first;
      if (original.componentGoodsId == goods.id) return;
      if (goods.isPeriodicIssue &&
          goods.periodicCostBasis != null &&
          goods.periodicCostBasis != GoodsPeriodicCostBasis.own) {
        context.appError(
          _l10n.goodsBomBatchSharedPeriodicNotAllowed(
            goods.name ?? goods.code ?? '',
          ),
        );
        return;
      }
      final sameUnit = original.componentUnitName == goods.unitName;
      final sameShape = original.isPeriodicEdge == goods.isPeriodicIssue;
      final item = GoodsBomItem(
        id: original.id,
        componentGoodsId: goods.id,
        componentCode: goods.code,
        componentName: goods.name,
        componentModel: goods.model,
        componentSpec: goods.spec,
        componentMaterial: goods.material,
        componentStockQty: goods.stockQty,
        componentUnitName: goods.unitName,
        componentColorName: goods.colorName,
        colorId: goods.colorId,
        price: goods.price,
        summary: original.summary,
        componentSourceType: goods.sourceType,
        componentIssueMethod: goods.issueMethod,
        qty: sameUnit && sameShape ? original.qty : null,
        controlStage: sameShape ? original.controlStage : BomControlStage.start,
        consumptionBasis: sameShape
            ? original.consumptionBasis
            : BomConsumptionBasis.perUnit,
        basisOutputQty: sameShape ? original.basisOutputQty : 1,
        allowPartialPackage: sameShape ? original.allowPartialPackage : true,
        hardGate: goods.isPeriodicIssue
            ? false
            : sameShape
            ? original.hardGate
            : true,
      );
      draft.rememberItems([item]);
      Future<GoodsBomItem> stage(Map<String, dynamic> body) async {
        if (!current()) throw StateError(_l10n.bomEditPermissionChanged);
        final request = <String, dynamic>{
          'componentGoodsId': goods.id,
          'qty': item.qty,
          'controlStage': item.controlStage.code,
          'consumptionBasis': item.consumptionBasis.code,
          'basisOutputQty': item.basisOutputQty,
          'allowPartialPackage': item.allowPartialPackage,
          'hardGate': item.hardGate,
          'colorId': goods.colorId,
          if (goods.colorId == null) 'colorLegacyId': 0,
          // A supplier/colour override for the old component is not a rule for the new one.
          'defaultSupplierId': null, 'vendLegacyId': 0,
          'summary': original.summary,
          ...body,
        };
        // This picker changes the component, never an independently authorised price.
        request.remove('price');
        request.remove('total');
        if (goods.isPeriodicIssue) {
          request.remove('qty');
          request.remove('controlStage');
          request.remove('consumptionBasis');
          request.remove('basisOutputQty');
          request.remove('allowPartialPackage');
          request.remove('hardGate');
          if (body.containsKey('qty')) request['qty'] = body['qty'];
        }
        return draft.update(parent, original.id, request);
      }

      final needsQuantity = item.qty == null || goods.isPeriodicIssue;
      if (needsQuantity) {
        if (!mounted || !current()) return;
        final saved = await showDialog<bool>(
          context: context,
          builder: (_) => _BomItemEditDialog(
            parentGoodsId: parent,
            editing: item,
            repository: draft,
            canWrite: current,
            requireQuantity: true,
            onSaveBody: stage,
            title: _l10n.bomReplaceComponent,
            referenceGrams: parent == widget.goodsId
                ? widget.productWeightGrams
                : null,
          ),
        );
        if (saved != true || !current()) return;
      } else {
        await stage({'qty': item.qty});
        if (!mounted || !current()) return;
        context.appSuccess(_l10n.bomEditComponentStaged);
      }
      if (parent != widget.goodsId) _expandGoodsAfterMutation(parent);
      _componentInputs.remove('row:${_rowId(replacing)}')?.dispose();
      _inlineValues.remove(_rowId(replacing))?.dispose();
      await _load();
    } finally {
      if (mounted && revision == _modeRevision) {
        setState(() => _choosingComponent = false);
        _notifyInteractionChanged();
      }
    }
  });

  Future<bool> _stageNewTableComponents(
    List<GoodsListItem> picked,
    String parent,
    GoodsBomEditDraft draft,
    bool Function() current,
  ) async {
    final unique = {for (final item in picked) item.id: item}.values.toList();
    for (final goods in unique) {
      if (goods.isPeriodicIssue &&
          goods.periodicCostBasis != null &&
          goods.periodicCostBasis != GoodsPeriodicCostBasis.own) {
        context.appError(
          _l10n.goodsBomBatchSharedPeriodicNotAllowed(
            goods.name ?? goods.code ?? '',
          ),
        );
        return false;
      }
    }
    final templates = <GoodsBomItem>[];
    final requests = <Map<String, dynamic>>[];
    for (final goods in unique) {
      if (!current()) return false;
      final template = GoodsBomItem(
        id: '',
        componentGoodsId: goods.id,
        componentCode: goods.code,
        componentName: goods.name,
        componentModel: goods.model,
        componentSpec: goods.spec,
        componentMaterial: goods.material,
        componentStockQty: goods.stockQty,
        componentUnitName: goods.unitName,
        componentColorName: goods.colorName,
        colorId: goods.colorId,
        componentSourceType: goods.sourceType,
        componentIssueMethod: goods.issueMethod,
        qty: goods.isPeriodicIssue ? null : 1,
        hardGate: !goods.isPeriodicIssue,
      );
      final request = <String, dynamic>{
        'componentGoodsId': goods.id,
        if (!goods.isPeriodicIssue) 'qty': 1,
        if (goods.colorId != null) 'colorId': goods.colorId,
      };
      if (goods.isPeriodicIssue) {
        Map<String, dynamic>? reviewed;
        final saved = await showDialog<bool>(
          context: context,
          builder: (_) => _BomItemEditDialog(
            parentGoodsId: parent,
            editing: template,
            repository: draft,
            canWrite: current,
            requireQuantity: true,
            showSuccess: false,
            title: _l10n.bomNewComponentRow,
            referenceGrams: parent == widget.goodsId
                ? widget.productWeightGrams
                : null,
            onSaveBody: (body) async {
              reviewed = Map<String, dynamic>.of(body)
                ..remove('price')
                ..remove('total');
              return template;
            },
          ),
        );
        if (saved != true || reviewed == null || !current()) return false;
        request.addAll(reviewed!);
      }
      templates.add(template);
      requests.add(request);
    }
    if (!current()) return false;
    draft.rememberItems(templates);
    // The entire selection is one draft mutation: a later duplicate/cycle
    // rolls back every earlier item from this picker confirmation.
    await draft.paste(
      mode: BomPasteMode.append,
      targets: [BomPasteTarget(parent)],
      items: requests,
    );
    if (!mounted || !current()) return false;
    context.appSuccess(_l10n.bomEditComponentStaged);
    return true;
  }

  Future<void> _addChildRow(_BomRow row) async {
    if (!_canCreate || _writeBusy || row.isPlaceholder) return;
    setState(() {
      _childAppendParents.add(row.node.item.componentGoodsId);
      row.node.children ??= [];
      row.node.expanded = true;
      _expandGoodsAfterMutation(row.node.item.componentGoodsId);
      _visibleRowsCache = null;
    });
  }

  Widget _componentLookup(
    String inputKey, {
    required String parentGoodsId,
    _BomRow? replacing,
  }) {
    if (replacing == null) {
      return _componentLookupEditor(inputKey, parentGoodsId: parentGoodsId);
    }
    final label =
        replacing.node.item.componentName ??
        replacing.node.item.componentCode ??
        '';
    return _lazyCell(
      replacing,
      'name',
      _l10n.bomReplaceComponent,
      label,
      (_) => _componentLookupEditor(
        inputKey,
        parentGoodsId: parentGoodsId,
        replacing: replacing,
      ),
    );
  }

  Widget _componentLookupEditor(
    String inputKey, {
    required String parentGoodsId,
    _BomRow? replacing,
  }) {
    final revision = _modeRevision;
    final boundary = ref.read(sensitiveReadBoundaryProvider);
    final draft = _draft;
    bool current() =>
        mounted &&
        _canMutate &&
        identical(draft, _draft) &&
        revision == _modeRevision &&
        boundary == ref.read(sensitiveReadBoundaryProvider);
    final initial =
        replacing?.node.item.componentName ??
        replacing?.node.item.componentCode ??
        '';
    final controller = _componentInputs.putIfAbsent(
      inputKey,
      () => TextEditingController(text: initial),
    );
    return _bomTableInput(
      child: UtenReferencePickerField<GoodsListItem>(
        key: ValueKey('goods-bom-name-$inputKey'),
        controller: controller,
        label: replacing == null
            ? _l10n.bomNewComponentRow
            : _l10n.bomReplaceComponent,
        hint: _l10n.bomChooseComponent,
        pickerLabel: replacing == null
            ? _l10n.bomChooseComponent
            : _l10n.bomReplaceComponent,
        pickerKey: ValueKey(
          replacing != null
              ? 'goods-bom-replace-${replacing.occurrenceKey}'
              : inputKey.startsWith('new:')
              ? 'goods-bom-choose-new-${inputKey.substring(4)}'
              : 'goods-bom-choose-$inputKey',
        ),
        pickerIcon: Icons.manage_search_rounded,
        enabled: _canMutate && !_writeBusy,
        suggestionScope: (boundary, revision, parentGoodsId),
        isCurrent: current,
        loadSuggestions: (query) async {
          if (!current()) return const [];
          final result = await ref.read(bomComponentSuggestionsProvider)(
            ref,
            query,
          );
          if (!current()) return const [];
          final candidates = result
              .where((goods) => goods.id != parentGoodsId)
              .toList();
          final text = query.trim().toLowerCase();
          int rank(GoodsListItem goods) {
            final name = (goods.name ?? '').toLowerCase();
            final code = (goods.code ?? '').toLowerCase();
            if (name == text || code == text) return 0;
            if (name.startsWith(text) || code.startsWith(text)) return 1;
            return 2;
          }

          candidates.sort((a, b) => rank(a).compareTo(rank(b)));
          return candidates;
        },
        labelOf: (goods) => goods.name ?? goods.code ?? '',
        onInputChanged: (_) {},
        onEditingDismissed: replacing == null
            ? null
            : () {
                controller.text = initial;
              },
        onSelected: (goods) async {
          if (!current()) return;
          try {
            await _pickTableComponent(
              replacing: replacing,
              parentGoodsId: parentGoodsId,
              selected: goods,
              inputKey: inputKey,
            );
          } catch (error) {
            if (mounted && current()) context.appApiError(error);
          }
        },
        onOpenPicker: (_) => _pickTableComponent(
          replacing: replacing,
          parentGoodsId: parentGoodsId,
          inputKey: inputKey,
        ),
        optionBuilder: (context, goods) => ListTile(
          dense: true,
          title: Text(
            goods.name ?? goods.code ?? '',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            [goods.code, goods.model, goods.spec, goods.colorName]
                .whereType<String>()
                .where((value) => value.isNotEmpty)
                .join(' / '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }

  List<MasterTableAppendRow> get _appendRows =>
      _canCreate ? _editableAppendRows : const [];
  //
  // 添加组件：选中某组件行 → 默认作为该组件的子组件；未选中 → 顶层。浮窗内父级可选。
  // 保存把添加动作暂存到所选父级的会话草稿，退出并确认后统一提交。
  //
  // 2026-10-19 二轮口径：浮窗是页面内常驻浮层（不是路由弹窗）——底层组装表照常
  // 可点可滚；跳去其它页面时随本页被盖住（回来现场还在，切页签靠 keep-alive
  // 保活）；保存成功才关闭并清掉草稿。窗口本体可缩成悬浮球（见 UtenFloatingWindow）。

  /// 添加组件浮窗会话是否在进行（打开/缩小成球都算）。true 时 tab keep-alive，
  /// 页签切走再回来现场不丢。
  bool get _addComponentOpen => _addComponentCandidates != null;
  List<_BomParentOption>? _addComponentCandidates;
  String? _addComponentDefaultParent;
  final _addComponentWindowKey = GlobalKey<UtenFloatingWindowState>();

  Future<void> _addItem() async {
    if (!_canCreate || _writeBusy) return;
    // 已开着（含缩成球）：只把窗口展开回原位，保留正在核对的内容。
    if (_addComponentOpen) {
      _addComponentWindowKey.currentState?.expand();
      return;
    }
    if (!await _flushInlineEdits() || !mounted || !_canCreate) return;
    final candidates = <_BomParentOption>[
      _BomParentOption(goodsId: widget.goodsId, label: '顶层(本货品)'),
      for (final r in _visibleRows)
        if (!r.isPlaceholder)
          _BomParentOption(
            goodsId: r.node.item.componentGoodsId,
            label:
                '${r.seq} · 层级 ${r.depth + 1} · '
                '${r.node.item.componentName ?? r.node.item.componentCode ?? ''}',
          ),
    ];
    // 只勾一条时默认加在它下面；勾了 0 条或多条都回落顶层(多选时「加在谁下面」
    // 没有唯一答案，浮窗里再让用户自己选)。
    setState(() {
      _addComponentCandidates = candidates;
      _addComponentDefaultParent =
          _singleSelectedRow?.node.item.componentGoodsId ?? widget.goodsId;
    });
    _notifyInteractionChanged();
  }

  void _closeAddComponentWindow() {
    setState(() {
      _addComponentCandidates = null;
      _addComponentDefaultParent = null;
    });
    _notifyInteractionChanged();
  }

  /// 浮窗内暂存成功：展开目标父级并重读草稿，清除窗口内的暂选内容。
  Future<void> _onAddComponentSaved(String parentGoodsId) async {
    if (parentGoodsId != widget.goodsId) {
      _expandGoodsAfterMutation(parentGoodsId);
    }
    _closeAddComponentWindow();
    await _load();
  }

  Future<void> _editSelected() => _duringInteraction(_editSelectedItem);

  Future<void> _editSelectedItem() async {
    if (!_canMutate || _writeBusy) return;
    if (!await _flushInlineEdits() || !mounted || !_canEdit) return;
    final row = _singleSelectedRow;
    if (row == null) return;
    final repository = _repository;
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _BomItemEditDialog(
        parentGoodsId: row.parentGoodsId,
        editing: row.node.item,
        repository: repository,
        canWrite: () =>
            mounted && _canMutate && identical(repository, _repository),
        // 货品资料单重只对直接挂在本产品下的行有意义 (嵌套行的父件是别的货品)。
        referenceGrams: row.parentGoodsId == widget.goodsId
            ? widget.productWeightGrams
            : null,
      ),
    );
    if (saved == true) {
      _inlineValues.remove(_rowId(row))?.dispose();
      await _load();
    }
  }

  /// 批量删除勾中的组件(勾中一条也走这条路，删除动作只有一个实现)。
  ///
  /// 确认框弹出前不能有任何 busy 态：UtenBusyOverlay 是挂 root Overlay 的裸
  /// entry，Navigator 每次 rearrange 都把它重新抬到最顶，会盖住之后弹出的对话框
  /// 并让它点不动(全站铁律)。所以遮罩只包住确认之后的纯网络段，且 finally 必清。
  Future<void> _deleteSelected() => _duringInteraction(_deleteSelectedItems);

  Future<void> _deleteSelectedItems() async {
    if (!_canDelete || _writeBusy) return;
    if (!await _flushInlineEdits() || !mounted || !_canDelete) return;
    final repository = _repository;
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
        return UtenAlertDialog(
          scrollable: false,
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
    if (!mounted || !_canDelete || !identical(repository, _repository)) return;

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
        () => repository.deleteMany(widget.goodsId, [
          for (final t in targets) t.itemId,
        ]),
        errorFallback: '删除失败，请稍后重试', // TODO(l10n): 补 arb
      );
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
    if (!mounted) return;
    if (deleted != null) {
      for (final target in targets) {
        _inlineValues
            .remove('${target.parentGoodsId}|${target.itemId}')
            ?.dispose();
      }
      context.appSuccess(_l10n.bomEditDeleteStaged(deleted));
    }
    // 失败也重载：树可能已被别人改过，重载顺带把删掉的行从勾选集剪掉。
    await _load();
  }

  /// 单次批量删除请求的条数上限(与服务端 itemIds 上限一致)。
  static const int _batchDeleteLimit = 500;

  // ---- 右键菜单（2026-09-25 统一口径：右键=选中当前行+自绘小框弹窗） ---------
  //
  // 与货品资料列表同款：MasterDataTableView 先把右键命中的行纳入选择集，再弹
  // UtenContextMenu（锚定指针、无遮罩）；编辑只在菜单与双击提供，增删复用悬浮组。
  // 审计模式的「标记/取消已核对」也走这里（单击行不再兼任审计开关，勾选与审计
  // 两种语义从此不打架）。

  List<UtenContextMenuEntry> _rowMenuItems(_BomRow row) {
    if (row.isPlaceholder) return const [];
    final single = _selectedRowIds.length == 1;
    return [
      if (_canEdit) ...[
        UtenMenuItem(
          label: '编辑', // TODO(l10n): 补 arb
          enabled: single && _canMutate && !_writeBusy,
          onTap: _editSelected,
        ),
        if (_canCreate)
          UtenMenuItem(
            label: '添加子组件', // TODO(l10n): 补 arb
            enabled: _canCreate && !_writeBusy,
            onTap: _addItem,
          ),
        if (_canDelete)
          UtenMenuItem(
            label: '删除', // TODO(l10n): 补 arb
            enabled: _canDelete && _selectedRowIds.isNotEmpty && !_writeBusy,
            destructive: true,
            onTap: _deleteSelected,
          ),
        const UtenMenuDivider(),
        UtenMenuItem(
          label: _l10n.bomEditCopy,
          enabled: _canMutate && _selectedRowIds.isNotEmpty && !_writeBusy,
          onTap: _copySelected,
        ),
        if (_canCreate)
          UtenMenuItem(
            label: _l10n.bomEditPaste,
            enabled: _canPaste && single && !_writeBusy,
            onTap: _pasteSelected,
          ),
      ],
      if (_auditMode) ...[
        if (_canEdit) const UtenMenuDivider(),
        UtenMenuItem(
          label: row.node.item.audited ? '取消已核对' : '标记已核对无误', // TODO(l10n)
          enabled: _canAudit && !_auditBusyRows.containsKey(_rowId(row)),
          onTap: () => _toggleAudited(row),
        ),
      ],
    ];
  }

  bool get _canPaste =>
      _canCreate &&
      ref.read(goodsClipboardProvider).bomItems?.isNotEmpty == true;

  Future<void> _copySelected() async {
    if (!_canMutate || _writeBusy) return;
    if (!await _flushInlineEdits() || !mounted || !_canEdit) return;
    final selectedRows = _visibleRows
        .where((row) => _selectedRowIds.contains(_rowId(row)))
        .toList();
    final rows = <String, GoodsBomItem>{
      for (final row in selectedRows)
        if (!selectedRows.any(
          (ancestor) =>
              row.occurrenceKey.startsWith('${ancestor.occurrenceKey}/'),
        ))
          _rowId(row): row.node.item,
    };
    if (rows.isEmpty) return;
    ref
        .read(goodsClipboardProvider.notifier)
        .copyBom(
          rows.values.toList(),
          widget.productName ?? widget.productCode ?? _l10n.bomEditCurrentGoods,
        );
    context.appSuccess(_l10n.bomEditCopied(rows.length));
  }

  Future<void> _pasteSelected() async {
    if (!_canPaste || _writeBusy) return;
    if (!await _flushInlineEdits() || !mounted || !_canCreate) return;
    if (_selectedRowIds.length > 1) {
      context.appWarning(_l10n.bomEditPasteParentRequired);
      return;
    }
    final repository = _repository;
    final items = ref.read(goodsClipboardProvider).bomItems!;
    _draft?.rememberItems(items);
    final target =
        _singleSelectedRow?.node.item.componentGoodsId ?? widget.goodsId;
    final bodies = [for (final item in items) _copyBody(item)];
    final periodicBodies = [
      for (var i = 0; i < items.length; i++)
        if (items[i].isPeriodicEdge) bodies[i],
    ];
    setState(() => _pasting = true);
    try {
      BomPasteResult result;
      while (true) {
        if (!_canCreate || !identical(repository, _repository)) return;
        try {
          result = await repository.paste(
            mode: BomPasteMode.append,
            targets: [BomPasteTarget(target)],
            items: bodies,
          );
          break;
        } on ApiException catch (error) {
          final confirmations = periodicConfirmationsOf(error);
          if (confirmations == null || !mounted) rethrow;
          setState(() => _pasting = false);
          await WidgetsBinding.instance.endOfFrame;
          if (!mounted || !_canCreate || !identical(repository, _repository)) {
            return;
          }
          final confirmed = await askPeriodicConfirmations(
            context,
            confirmations,
          );
          if (confirmed == null || !mounted || !_canCreate) return;
          applyPeriodicConfirmations(periodicBodies, confirmed);
          setState(() => _pasting = true);
        }
      }
      if (!mounted || !_canCreate || !identical(repository, _repository)) {
        return;
      }
      if (target != widget.goodsId) _expandGoodsAfterMutation(target);
      if (result.warnings.isEmpty) {
        context.appSuccess(_l10n.bomEditPasteStaged(result.added));
      } else {
        context.appWarning(
          _l10n.bomEditReviewWarnings(
            _l10n.bomEditPasteStaged(result.added),
            result.warnings.join('；'),
          ),
        );
      }
      await _load();
    } on ApiException catch (error) {
      if (mounted) {
        context.appError(error.message, fieldErrors: error.fieldErrors);
      }
    } catch (_) {
      if (mounted) context.appError(_l10n.bomEditPasteFailed);
    } finally {
      if (mounted) setState(() => _pasting = false);
    }
  }

  Map<String, dynamic> _copyBody(GoodsBomItem item) => {
    'componentGoodsId': item.componentGoodsId,
    'copiedFromBomItemId': item.id,
    'qty': item.qty,
    'price': item.price,
    'summary': item.summary,
    if (item.colorId != null) 'colorId': item.colorId,
    if (item.defaultSupplierId != null)
      'defaultSupplierId': item.defaultSupplierId,
    if (!item.isPeriodicEdge) ...{
      'controlStage': item.controlStage.code,
      'consumptionBasis': item.consumptionBasis.code,
      'basisOutputQty': item.basisOutputQty,
      'allowPartialPackage': item.allowPartialPackage,
      'hardGate': item.hardGate,
    },
  };

  // ---- 审计标记（V256） ---------------------------------------------------
  //
  // 已审格/右键菜单修改标记。PUT 已返回完整行，直接更新已加载的同一关系，
  // 不再为一次打标重读根清单及全部展开子树。只在保存成功后显示已核对。

  Iterable<_BomNode> _auditNodes(String parentGoodsId, String itemId) sync* {
    Iterable<_BomNode> walk(List<_BomNode> nodes, String parent) sync* {
      for (final node in nodes) {
        if (parent == parentGoodsId && node.item.id == itemId) yield node;
        final children = node.children;
        if (children != null) {
          yield* walk(children, node.item.componentGoodsId);
        }
      }
    }

    yield* walk(_roots ?? const [], widget.goodsId);
  }

  Future<void> _toggleAudited(_BomRow row) async {
    final key = _rowId(row);
    if (!_auditMode ||
        _loading ||
        _writeBusy ||
        !_canAudit ||
        _auditBusyRows.containsKey(key)) {
      return;
    }
    final item = row.node.item;
    final originals = {
      for (final node in _auditNodes(row.parentGoodsId, item.id))
        node: node.item,
    };
    if (!originals.containsKey(row.node)) return;
    final repository = ref.read(goodsBomRepositoryProvider);
    final boundary = ref.read(sensitiveReadBoundaryProvider);
    final pending = Completer<void>();
    setState(() {
      _auditBusyRows[key] = pending;
      _auditRevisions.update(
        row.parentGoodsId,
        (value) => value + 1,
        ifAbsent: () => 1,
      );
    });
    _notifyInteractionChanged();
    try {
      final updated = await repository.setAudited(
        row.parentGoodsId,
        item.id,
        !item.audited,
      );
      if (!mounted ||
          boundary != ref.read(sensitiveReadBoundaryProvider) ||
          !identical(repository, ref.read(goodsBomRepositoryProvider))) {
        return;
      }
      setState(() {
        var structureChanged = false;
        for (final node in _auditNodes(row.parentGoodsId, item.id)) {
          // 编辑/重载已换过节点或行时，以新读到的内容为准，旧请求不能覆盖它。
          if (!identical(node.item, originals[node])) continue;
          if (node.item.componentGoodsId != updated.componentGoodsId ||
              !updated.hasChildren) {
            structureChanged = structureChanged || node.children != null;
            node.children = null;
            node.expanded = false;
            node.loading = false;
          }
          node.item = updated;
        }
        if (structureChanged) {
          _visibleRowsCache = null;
          _pruneSelection();
        }
      });
      widget.onDataChanged?.call();
    } on ApiException catch (e) {
      if (!mounted || boundary != ref.read(sensitiveReadBoundaryProvider)) {
        return;
      }
      context.appError(e.message);
    } catch (_) {
      if (!mounted || boundary != ref.read(sensitiveReadBoundaryProvider)) {
        return;
      }
      context.appError('保存核对标记失败，请稍后重试'); // TODO(l10n): 补 arb
    } finally {
      if (identical(_auditBusyRows[key], pending)) {
        _auditRevisions.update(
          row.parentGoodsId,
          (value) => value + 1,
          ifAbsent: () => 1,
        );
        _auditBusyRows.remove(key);
      }
      if (!pending.isCompleted) pending.complete();
      if (mounted) setState(() {});
      if (mounted) _notifyInteractionChanged();
    }
  }

  // ---- 拖拽移动（2026-10-19：长按拖行排序 / 悬停展开下探 / 移入任意层级） ----
  //
  // 与表格组件 UtenTableRowDrag 的分工：表格只管手势、幽灵卡、落点指示与
  // 悬停自动展开回调；层级语义（同层前后插入 = 换父件保持/调整 sort_order，
  // 移入 = 换父件）与持久化在这里。成环的完整校验在服务端（可见树只是子集）。

  /// 拖拽移动的网络段进行中（UtenBusyOverlay 遮罩；落点已定，无确认框）。
  bool _moving = false;

  /// 目标行是否在被拖行的子树里（可见部分的前置判断；深度上限 10 与服务端一致）。
  bool _isInDraggedSubtree(_BomRow target, List<_BomRow> dragged) {
    bool within(_BomNode ancestor, _BomNode candidate, [int depth = 0]) {
      if (depth > 10) return false;
      if (identical(ancestor, candidate)) return true;
      final kids = ancestor.children;
      if (kids == null) return false;
      for (final k in kids) {
        if (within(k, candidate, depth + 1)) return true;
      }
      return false;
    }

    for (final d in dragged) {
      if (within(d.node, target.node)) return true;
    }
    return false;
  }

  List<_BomRow> _dragPayloadOf(_BomRow pressed) {
    if (_selectedRowIds.contains(_rowId(pressed))) {
      // 多选批量：勾选行按可见顺序整批拖走。
      final keys = _selectedRowIds;
      final seen = <String>{};
      return _visibleRows
          .where((row) => keys.contains(_rowId(row)) && seen.add(_rowId(row)))
          .toList();
    }
    return [pressed];
  }

  /// 落点是否「整块已在目标位置」：同层、连续、且整块已紧贴锚点的对应一侧——
  /// 放置结果与现状完全一致。跳过网络请求、直接说明，避免「提示成功但看着
  /// 没变化」的困惑（2026-10-19 用户反馈；服务端语义本身正确）。
  bool _dropIsNoOp(
    List<_BomRow> dragged,
    _BomRow target,
    UtenTableRowDropMode mode,
  ) {
    if (mode == UtenTableRowDropMode.into) return false;
    if (dragged.any((r) => r.parentGoodsId != target.parentGoodsId)) {
      return false;
    }
    final draggedIds = dragged.map((r) => r.node.item.id).toSet();
    // 可见平铺里同层的行序即层内顺序（目标行可见 = 该层可见）。
    final levelRows = _visibleRows
        .where((r) => r.parentGoodsId == target.parentGoodsId)
        .toList();
    final indices = <int>[];
    for (var i = 0; i < levelRows.length; i++) {
      if (draggedIds.contains(levelRows[i].node.item.id)) indices.add(i);
    }
    if (indices.length != dragged.length) return false;
    indices.sort();
    if (indices.last - indices.first != indices.length - 1) return false;
    final anchorIndex = levelRows.indexWhere(
      (r) => r.node.item.id == target.node.item.id,
    );
    if (anchorIndex < 0) return false;
    return mode == UtenTableRowDropMode.above
        ? anchorIndex == indices.last + 1
        : anchorIndex == indices.first - 1;
  }

  /// 落点持久化：above = 逐条插到目标前（保序）；below = 逆序插到目标后
  /// （服务端逐条「插参照后」，逆序提交恰好正序落位）；into = 追加到目标层末尾。
  /// 成功后把移入的层级展开（移动结果立即可见）并整树重载。
  Future<void> _onRowsDropped(
    List<_BomRow> dragged,
    _BomRow target,
    UtenTableRowDropMode mode,
  ) async {
    if (!_canMutate ||
        _writeBusy ||
        _loading ||
        dragged.isEmpty ||
        target.isPlaceholder ||
        dragged.any((row) => row.isPlaceholder)) {
      return;
    }
    if (_isInDraggedSubtree(target, dragged)) return;
    if (_dropIsNoOp(dragged, target, mode)) {
      context.appSuccess('已在当前位置，未移动'); // TODO(l10n): 补 arb
      return;
    }

    final repository = _repository;
    final revision = _modeRevision;
    if (!await _flushInlineEdits() ||
        !mounted ||
        !_canEdit ||
        revision != _modeRevision ||
        !identical(repository, _repository)) {
      return;
    }

    final targetParent = mode == UtenTableRowDropMode.into
        ? target.node.item.componentGoodsId
        : target.parentGoodsId;
    final anchorId = target.node.item.id;
    final moves = <GoodsBomMove>[
      if (mode == UtenTableRowDropMode.below)
        for (final r in dragged.reversed)
          GoodsBomMove(
            itemId: r.node.item.id,
            targetParentGoodsId: targetParent,
            anchorItemId: anchorId,
            afterAnchor: true,
          )
      else
        for (final r in dragged)
          GoodsBomMove(
            itemId: r.node.item.id,
            targetParentGoodsId: targetParent,
            anchorItemId: mode == UtenTableRowDropMode.above ? anchorId : null,
          ),
    ];
    if (moves.isEmpty) return;

    setState(() => _moving = true);
    int? moved;
    try {
      moved = await context.guardAction(
        () => repository.move(widget.goodsId, moves),
        errorFallback: '移动组件失败，请稍后重试', // TODO(l10n): 补 arb
      );
    } finally {
      if (mounted) setState(() => _moving = false);
    }
    if (!mounted ||
        revision != _modeRevision ||
        !identical(repository, _repository)) {
      return;
    }
    if (moved != null) {
      context.appSuccess(_l10n.bomEditMoveStaged(moved));
    }
    if (mode == UtenTableRowDropMode.into) {
      // 移入的层级自动展开：重载后新位置直接可见（与本页「添加子组件后保持
      // 展开」同口径）。
      _expandGoodsAfterMutation(target.node.item.componentGoodsId);
    }
    await _load();
  }

  // A viewer with editing capability keeps the same keyed row ancestors even
  // before entering edit mode. Live predicates enable gestures only inside a
  // writable session; reads, writes and recovery never remount the row.
  UtenTableRowDrag<_BomRow>? get _rowDrag =>
      _canEnterEdit ? _editableRowDrag : null;

  late final UtenTableRowDrag<_BomRow> _editableRowDrag =
      UtenTableRowDrag<_BomRow>(
        canDragRow: (r) =>
            !r.isPlaceholder && _canMutate && !_loading && !_writeBusy,
        dragRowsOf: _dragPayloadOf,
        dragLabelOf: (r) =>
            r.node.item.componentName ?? r.node.item.componentCode ?? '组件',
        canDrop: (target, dragged) =>
            _canMutate &&
            !_loading &&
            !_writeBusy &&
            !target.isPlaceholder &&
            !_isInDraggedSubtree(target, dragged),
        // 任何可见节点都能接收子级(叶子挂上组件后自然成父件)；
        // 成环与重复的权威校验在服务端。
        canDropInto: (target, dragged) =>
            _canMutate &&
            !_loading &&
            !_writeBusy &&
            !target.isPlaceholder &&
            !_isInDraggedSubtree(target, dragged),
        onHoverAutoExpand: (target) {
          if (!_canMutate || _loading || _writeBusy) return;
          final node = target.node;
          if (node.item.hasChildren && !node.expanded && !node.loading) {
            _toggle(node);
          }
        },
        onDrop: _onRowsDropped,
      );

  // ---- 渲染 ---------------------------------------------------------------

  Widget _lazyCell(
    _BomRow row,
    String field,
    String label,
    String preview,
    WidgetBuilder editor, {
    bool changed = false,
    bool retainFocusWhenDisabled = false,
    TextAlign textAlign = TextAlign.start,
  }) => _bomTableInput(
    child: UtenInlineEditCell(
      key: ValueKey((
        'goods-bom-editor',
        field,
        row.occurrenceKey,
        row.node.item.componentGoodsId,
        _modeRevision,
      )),
      activationKey: ValueKey('goods-bom-activate-$field-${row.occurrenceKey}'),
      semanticLabel: masterEditText(
        context,
        '编辑$label',
        'Edit $label',
        '$label 편집',
      ),
      enabled: _canMutate && !_writeBusy,
      changed: changed,
      retainFocusWhenDisabled: retainFocusWhenDisabled,
      preview: Text(
        preview.isEmpty ? '—' : preview,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: textAlign,
      ),
      editorBuilder: editor,
    ),
  );

  void _adoptMasterValues(Map<String, _BomMasterValues> prepared) {
    for (final entry in prepared.entries) {
      // Concurrent expansion of two aliases can prepare the same component.
      // Preserve its first editor and any input already entered into it.
      final adopted = _masterValues.putIfAbsent(entry.key, () => entry.value);
      if (!identical(adopted, entry.value)) entry.value.dispose();
    }
  }

  /// Prepare every displayed master editor before publishing a new table.
  /// Building/selecting/scrolling a cell performs no network or setState work.
  Future<Map<String, _BomMasterValues>> _prepareMasterValues(
    Iterable<_BomNode> roots,
    GoodsBomEditDraft draft,
    bool Function() current,
  ) async {
    final prepared = <String, _BomMasterValues>{};
    if (!_hasPermission(Perm.goodsEdit)) return prepared;
    final ids = <String>{};
    var visited = 0;
    Future<void> collect(Iterable<_BomNode> nodes) async {
      for (final node in nodes) {
        if (++visited % 128 == 0) {
          await Future<void>.delayed(Duration.zero);
          if (!current()) return;
        }
        final id = node.item.componentGoodsId;
        if (!_masterValues.containsKey(id)) ids.add(id);
        if (node.expanded && node.children != null) {
          await collect(node.children!);
          if (!current()) return;
        }
      }
    }

    await collect(roots);
    final pending = ids.toList();
    var preparing = true;
    try {
      for (var start = 0; start < pending.length && current(); start += 4) {
        await Future.wait([
          for (final id in pending.skip(start).take(4))
            () async {
              final snapshot = await draft.goodsSnapshot(id);
              if (preparing &&
                  current() &&
                  snapshot?['componentGoodsWritable'] == true) {
                prepared[id] = _BomMasterValues(snapshot!);
              }
            }(),
        ], eagerError: true);
        await Future<void>.delayed(Duration.zero);
      }
      return prepared;
    } catch (_) {
      preparing = false;
      for (final values in prepared.values) {
        values.dispose();
      }
      rethrow;
    }
  }

  Widget _masterCell(_BomRow row, String field, String? fallback) {
    if (row.isPlaceholder) return const SizedBox.shrink();
    final goodsId = row.node.item.componentGoodsId;
    if (!_canEdit || !_hasPermission(Perm.goodsEdit)) {
      return Text(fallback ?? '', maxLines: 1, overflow: TextOverflow.ellipsis);
    }
    final values = _masterValues[goodsId];
    if (values == null) {
      return Text(fallback ?? '', maxLines: 1, overflow: TextOverflow.ellipsis);
    }
    void changed(Object? value) {
      if (!_canMutate || !_hasPermission(Perm.goodsEdit)) return;
      if (value == values.base[field]) {
        values.changed.remove(field);
      } else {
        values.changed.add(field);
      }
    }

    if (field == 'sourceType') {
      return _lazyCell(
        row,
        field,
        masterEditText(context, '来源', 'Source', '공급 방식'),
        values.sourceType ?? '',
        (_) => UtenDropdownField(
          value: values.sourceType,
          allowClear: false,
          dense: true,
          enabled: _canMutate && !_writeBusy,
          items: [
            for (final option in kGoodsSourceTypeOptions)
              UtenDropdownItem(value: option.value, label: option.label),
          ],
          onChanged: (value) {
            if (_writeBusy || !_canMutate || value == null) return;
            setState(() {
              values.sourceType = value;
              changed(value);
            });
          },
        ),
        changed: values.changed.contains(field),
      );
    }
    final label = switch (field) {
      'model' => masterEditText(context, '型号', 'Model', '모델'),
      'spec' => masterEditText(context, '规格', 'Specification', '규격'),
      _ => masterEditText(context, '材质', 'Material', '재질'),
    };
    return _lazyCell(
      row,
      field,
      label,
      values.textFor(field),
      (_) => TextField(
        key: ValueKey('goods-bom-master-$field-${row.occurrenceKey}'),
        controller: values.controllerFor(field),
        autofocus: true,
        enabled: _canMutate,
        readOnly: _writeBusy,
        decoration: const UtenInputDecoration(InputDecoration(isDense: true)),
        onChanged: (value) => changed(value.trim()),
      ),
      changed: values.changed.contains(field),
      retainFocusWhenDisabled: true,
    );
  }

  Widget _colorCell(_BomRow row) {
    if (row.isPlaceholder) return const SizedBox.shrink();
    final values = _valuesFor(row);
    return _lazyCell(
      row,
      'color',
      masterEditText(context, '颜色', 'Color', '색상'),
      values.colorLabel ?? '',
      (_) => Consumer(
        builder: (context, cellRef, child) {
          final colors = cellRef.watch(colorDictProvider).value ?? const [];
          final selected = colors.where((color) => color.id == values.colorId);
          return UtenDropdownField(
            value: values.colorId,
            selectedLabel: selected.isEmpty
                ? values.colorLabel
                : selected.first.name ??
                      selected.first.code ??
                      selected.first.id,
            dense: true,
            enabled: _canMutate && !_writeBusy,
            hintText: values.item.colorId != null && values.colorId == null
                ? '—'
                : row.node.item.componentColorName,
            items: [
              for (final color in colors)
                UtenDropdownItem(
                  value: color.id,
                  label: color.name ?? color.code ?? color.id,
                ),
            ],
            onChanged: (value) {
              if (!_canMutate || _writeBusy) return;
              setState(() {
                values.colorId = value;
                final chosen = colors
                    .where((color) => color.id == value)
                    .firstOrNull;
                values.colorLabel = value == null
                    ? null
                    : chosen?.name ?? chosen?.code ?? chosen?.id;
                if (value == row.node.item.colorId) {
                  values.changed.remove('colorId');
                } else {
                  values.changed.add('colorId');
                }
              });
            },
          );
        },
      ),
      changed: values.changed.contains('colorId'),
    );
  }

  /// 表格列（与 MasterDataTableView 对齐：key 仅标识用，本页不接筛选/排序）。
  /// 2026-09-25 口径「表格显示啥导出啥」：需求阶段/缺料处理/单价/金额四列从展示
  /// 退役（数据仍在行上，编辑弹窗/复制粘贴/成本聚合不受影响）；后端导出同列集。
  /// 「已审」列只在审计模式下出现（点该格翻已核对状态），关闭即普通清单视图。
  Widget _inlineText(_BomRow row, String field, String label) {
    if (row.isPlaceholder) return const SizedBox.shrink();
    final values = _valuesFor(row);
    final unit = field != 'qty'
        ? null
        : row.node.item.isPeriodicEdge &&
              row.node.item.periodicUnitWeightGrams != null
        ? '克'
        : row.node.item.componentUnitName;
    final entered = values.textFor(field);
    final preview =
        field == 'qty' && entered.isNotEmpty && unit?.trim().isNotEmpty == true
        ? '$entered ${unit!.trim()}'
        : entered;
    final original = switch (field) {
      'qty' =>
        row.node.item.isPeriodicEdge
            ? _plainQty(
                row.node.item.periodicUnitWeightGrams ?? row.node.item.qty,
              )
            : row.node.item.designQtyText,
      'basisOutputQty' => formatBomQty(row.node.item.basisOutputQty),
      _ => row.node.item.summary ?? '',
    };
    return _lazyCell(
      row,
      field,
      label,
      preview,
      (_) => TextField(
        key: ValueKey('goods-bom-inline-$field-${row.occurrenceKey}'),
        controller: switch (field) {
          'qty' => values.qty,
          'basisOutputQty' => values.basis,
          _ => values.summary,
        },
        autofocus: true,
        enabled: _canMutate,
        readOnly: _writeBusy,
        keyboardType: field == 'summary'
            ? TextInputType.text
            : const TextInputType.numberWithOptions(decimal: true),
        textAlign: field == 'summary' ? TextAlign.start : TextAlign.end,
        decoration: UtenInputDecoration(
          InputDecoration(hintText: label, isDense: true, suffixText: unit),
        ),
        onChanged: (value) {
          if (!_canMutate) return;
          if (value == original) {
            values.changed.remove(field);
          } else {
            values.changed.add(field);
          }
        },
      ),
      changed: values.changed.contains(field),
      textAlign: field == 'summary' ? TextAlign.start : TextAlign.end,
      retainFocusWhenDisabled: true,
    );
  }

  String _treeIdentityTitle(_BomRow row) => row.isPlaceholder
      ? _l10n.bomNewComponentRow
      : row.node.item.componentName ?? row.node.item.componentCode ?? '未命名组件';

  List<MasterColumnDef<_BomRow>> get _columns {
    final l10n = AppLocalizations.of(context);
    final identityMaxDepth = _visibleRows.fold<int>(
      0,
      (deepest, row) => row.depth > deepest ? row.depth : deepest,
    );
    final identityHasEditor =
        _canEdit || _visibleRows.any((row) => row.isPlaceholder);
    final scope = (
      l10n,
      _canEdit,
      _auditMode,
      _hasPermission(Perm.stockView),
      identityMaxDepth,
      identityHasEditor,
      UtenTreeTableCell.toggleExtentOf(
        context,
        desktop: UtenTreeTableCell.compactDesktopToggleExtent,
      ),
    );
    if (_columnsCacheScope == scope && _columnsCache != null) {
      return _columnsCache!;
    }
    _columnsCacheScope = scope;
    return _columnsCache = [
      // 与物料分析、成本共用紧凑树格；层级由缩进、连线和展开位表达。
      // 编号与学习来源各自成列，查看及编辑模式不再叠级联号、层级文字。
      MasterColumnDef(
        key: 'treeIdentity',
        label: '组件名称',
        width:
            340 +
            UtenTreeTableCell.toggleExtentOf(
              context,
              desktop: UtenTreeTableCell.compactDesktopToggleExtent,
            ) -
            48,
        minimumWidthOf: (context) => UtenTreeTableCell.compactMinimumWidthOf(
          context,
          depth: identityMaxDepth,
          titleWidth: identityHasEditor
              ? 2 * UtenEditableGridCellSpec.heightOf(context) +
                    UtenEditableGridCellSpec.contentPadding.horizontal +
                    UtenSpacing.s24
              : UtenSpacing.s24,
        ),
        value: (r) => r.node.item.componentName ?? r.node.item.componentCode,
        measureValueOf: (row) => '${row.depth}|${_treeIdentityTitle(row)}',
        measureWidthOf: (context, row, textScaler) =>
            UtenTreeTableCell.compactMeasureWidthOf(
              context,
              title: _treeIdentityTitle(row),
              depth: row.depth,
              textScaler: textScaler,
              titleChrome: identityHasEditor
                  ? 2 * UtenEditableGridCellSpec.heightOf(context) +
                        UtenEditableGridCellSpec.contentPadding.horizontal
                  : 0,
            ),
        measureWidthScope: (
          UtenTreeTableCell.toggleExtentOf(
            context,
            desktop: UtenTreeTableCell.compactDesktopToggleExtent,
          ),
          identityHasEditor,
        ),
        cellBuilderHandlesSemantics: true,
        // 树列吃满整行高度 + 连线跨过数据格纵向内边距，否则层级竖线会在
        // 行与行之间断开（与物料分析主表 / 级联页同一处理，2026-09-15）。
        fillsCellHeight: true,
        // 纯展示列不进导出投影：序号/名称由后端导出列集兜底
        // （GoodsBomExportProjection 强制保留），打印预览不受影响。
        exportable: false,
        cellBuilder: (context, r) {
          if (r.isPlaceholder) {
            return UtenTreeTableCell.compact(
              depth: r.depth,
              levelLabel: '组件 ${r.depth + 1} 级',
              title: _treeIdentityTitle(r),
              titleWidget: _componentLookup(
                'child:${r.parentGoodsId}',
                parentGoodsId: r.parentGoodsId,
              ),
              ancestorContinuations: r.ancestorContinuations,
              isLastChild: r.isLastChild,
            );
          }
          final cell = UtenTreeTableCell.compact(
            key: ValueKey('goods-bom-tree-cell-${r.node.item.id}'),
            toggleKey: ValueKey('goods-bom-tree-toggle-${r.node.item.id}'),
            depth: r.depth,
            levelLabel: '组件 ${r.depth + 1} 级',
            title: _treeIdentityTitle(r),
            subtitle: r.node.loading ? '正在加载下级…' : null,
            hasChildren:
                r.node.item.hasChildren ||
                _childAppendParents.contains(r.node.item.componentGoodsId),
            expanded: r.node.expanded,
            onToggle: r.node.loading || _writeBusy || _loading
                ? null
                : () => _toggle(r.node),
            onExpandPeers: _writeBusy || _loading || _auditBusyRows.isNotEmpty
                ? null
                : () => unawaited(_expandPeerBomBranches(r)),
            ancestorContinuations: r.ancestorContinuations,
            isLastChild: r.isLastChild,
            leafAction: _canCreate
                ? UtenPickerIconButton(
                    key: ValueKey('goods-bom-add-child-${r.occurrenceKey}'),
                    tooltip: _l10n.bomAddChildComponent,
                    icon: Icons.add_circle_outline_rounded,
                    onPressed: _writeBusy ? null : () => _addChildRow(r),
                  )
                : null,
            titleWidget: _canEdit
                ? _componentLookup(
                    'row:${_rowId(r)}',
                    parentGoodsId: r.parentGoodsId,
                    replacing: r,
                  )
                : null,
          );
          return cell;
        },
      ),
      // 已审列（V256）：审计标记持久在服务端，但只在做核对的人眼前出现——
      // 进「审计模式」才显示 ✓ 列（改标记要 goods:bom:audit），关闭即正常清单。
      // T13（2026-10-10）：树形首列保持第一，「已审」状态列提到第 2 列，
      // 学习来源随之后移——审计模式下核对状态比来源分类更常看。
      if (_auditMode)
        MasterColumnDef(
          key: 'audited',
          label: '已审',
          width: 64,
          value: (r) => r.node.item.audited ? '已核对' : '',
          // 交互辅助列（点格翻核对状态），不进导出投影——后端导出列集没有它。
          exportable: false,
          // 点这一格 = 翻「已核对无误」（2026-09-25：右键菜单之外的快捷路径）；
          // 图标弃用细体 ✓ 文本，换实心圆形对勾（已核对，绿色）/ 空心圆（未核对，
          // 待点选），年长用户隔着屏幕也认得出状态。
          cellBuilder: (context, r) {
            final saving = _auditBusyRows.containsKey(_rowId(r));
            return Tooltip(
              message: saving
                  ? '正在保存核对标记'
                  : r.node.item.audited
                  ? '已核对，点击取消'
                  : '点击标记已核对',
              child: IconButton(
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                visualDensity: VisualDensity.compact,
                iconSize: 22,
                icon: saving
                    ? SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          key: ValueKey('goods-bom-audit-saving-${_rowId(r)}'),
                          strokeWidth: 2,
                        ),
                      )
                    : Icon(
                        r.node.item.audited
                            ? Icons.check_circle
                            : Icons.radio_button_unchecked,
                        // 已核对=绿（ADR-169 绿档同色相；原裸 green.shade700 收编
                        // 进控件级 *Text/*OnDark，明暗各自保对比度）。
                        color: r.node.item.audited
                            ? (Theme.of(context).brightness == Brightness.dark
                                  ? UtenColors.successOnDark
                                  : UtenColors.successText)
                            : Theme.of(context).colorScheme.onSurfaceVariant
                                  .withValues(alpha: 0.45),
                      ),
                onPressed: saving || !_canAudit
                    ? null
                    : () => _toggleAudited(r),
              ),
            );
          },
        ),
      // 系统学习来源列（2026-09-29）：系统学出的组件标「系统学习」(ADR-129)，
      // 整格铺品红分类底色（ADR-169：来源分类强调非语义状态，原品牌青/info
      // 让给「他方执行中/正在执行」语义档）；人工维护行不铺色留空。
      // 与「BOM 学习记录」状态列同色。
      MasterColumnDef(
        key: 'learned',
        label: '学习来源',
        width: 110,
        value: (r) => r.node.item.systemLearned ? l10n.bomLearnedEdge : null,
        cellColor: (context, r) => r.node.item.systemLearned
            ? utenStatusBadgeCellColor(UtenStatusBadgeType.fuchsia)
            : null,
        // key 是既有用例锚点（goods_bom_columns_test：按行定位学习标记）。
        cellBuilder: (context, r) => r.node.item.systemLearned
            ? KeyedSubtree(
                key: ValueKey('goods-bom-learned-${r.node.item.id}'),
                child: Text(
                  l10n.bomLearnedEdge,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              )
            : const SizedBox.shrink(),
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
        cellBuilder: (context, r) =>
            _masterCell(r, 'model', r.node.item.componentModel),
      ),
      MasterColumnDef(
        key: 'spec',
        label: '规格',
        width: 170,
        value: (r) => r.node.item.componentSpec,
        cellBuilder: (context, r) =>
            _masterCell(r, 'spec', r.node.item.componentSpec),
      ),
      // 2026-10-10「数量+单位」全站口径：独立「单位」列退役，组件单位内联进
      // 设计/真实使用数量（见 _bomQtyText / _bomActualQtyText）。
      MasterColumnDef(
        key: 'color',
        label: '颜色',
        width: 80,
        value: (r) => r.node.item.componentColorName,
        cellBuilder: !_canEdit ? null : (context, r) => _colorCell(r),
      ),
      MasterColumnDef(
        key: 'material',
        label: '材质',
        width: 120,
        value: (r) => r.node.item.componentMaterial,
        cellBuilder: (context, r) =>
            _masterCell(r, 'material', r.node.item.componentMaterial),
      ),
      if (_hasPermission(Perm.stockView))
        MasterColumnDef(
          key: 'stockQty',
          label: '库存数量',
          width: 120,
          type: 'number',
          value: (r) {
            final item = r.node.item;
            final stock = item.componentStockQty;
            if (stock == null) return '—';
            final unit = item.componentUnitName?.trim();
            return '${formatBomQty(stock)}${unit == null || unit.isEmpty ? '' : ' $unit'}';
          },
          exactValueOf: (r) => r.node.item.componentStockQty?.toString(),
        ),
      MasterColumnDef(
        key: 'source',
        label: '来源',
        width: 64,
        value: (r) => r.node.item.componentSourceType,
        cellBuilder: (context, r) =>
            _masterCell(r, 'sourceType', r.node.item.componentSourceType),
      ),
      MasterColumnDef(
        key: 'consumptionBasis',
        label: '计量方式',
        width: 92,
        value: (r) =>
            r.isPlaceholder ? null : r.node.item.consumptionBasis.label,
        cellBuilder: !_canEdit
            ? null
            : (context, r) {
                if (r.isPlaceholder) return const SizedBox.shrink();
                if (r.node.item.isPeriodicEdge) {
                  return Text(r.node.item.consumptionBasis.label);
                }
                final values = _valuesFor(r);
                return _lazyCell(
                  r,
                  'consumptionBasis',
                  masterEditText(context, '计量方式', 'Consumption basis', '소모 기준'),
                  values.consumption.label,
                  (_) => UtenDropdownField(
                    value: values.consumption.code,
                    allowClear: false,
                    dense: true,
                    items: [
                      for (final basis in BomConsumptionBasis.values)
                        UtenDropdownItem(value: basis.code, label: basis.label),
                    ],
                    enabled: _canMutate && !_writeBusy,
                    onChanged: (value) {
                      if (value == null || !_canMutate || _writeBusy) return;
                      setState(() {
                        values.consumption = BomConsumptionBasis.fromCode(
                          value,
                        );
                        if (values.consumption ==
                            r.node.item.consumptionBasis) {
                          values.changed.remove('consumptionBasis');
                        } else {
                          values.changed.add('consumptionBasis');
                        }
                      });
                    },
                  ),
                  changed: values.changed.contains('consumptionBasis'),
                );
              },
      ),
      MasterColumnDef(
        key: 'basisOutputQty',
        label: '基准产量',
        width: 88,
        type: 'number',
        value: (r) => r.isPlaceholder ? null : r.node.item.basisOutputQtyText,
        cellBuilder: !_canEdit
            ? null
            : (context, r) => r.node.item.isPeriodicEdge
                  ? Text(r.node.item.basisOutputQtyText)
                  : _inlineText(r, 'basisOutputQty', '基准产量'),
        exactValueOf: (r) => r.node.item.basisOutputQty.toString(),
      ),
      MasterColumnDef(
        key: 'allowPartialPackage',
        label: '尾包',
        width: 72,
        value: (r) => r.isPlaceholder ? null : r.node.item.partialPackageLabel,
        cellBuilder: !_canEdit
            ? null
            : (context, r) {
                if (r.isPlaceholder) return const SizedBox.shrink();
                if (r.node.item.isPeriodicEdge ||
                    _valuesFor(r).consumption !=
                        BomConsumptionBasis.perPackage) {
                  return const Text('—');
                }
                final values = _valuesFor(r);
                return _lazyCell(
                  r,
                  'allowPartialPackage',
                  masterEditText(context, '尾包', 'Partial package', '부분 포장'),
                  values.partial
                      ? masterEditText(context, '允许', 'Allowed', '허용')
                      : masterEditText(context, '整包', 'Whole package', '전체 포장'),
                  (_) => UtenDropdownField(
                    value: values.partial ? 'yes' : 'no',
                    allowClear: false,
                    dense: true,
                    items: const [
                      UtenDropdownItem(value: 'yes', label: '允许'),
                      UtenDropdownItem(value: 'no', label: '整包'),
                    ],
                    enabled: _canMutate && !_writeBusy,
                    onChanged: (value) {
                      if (value == null || !_canMutate || _writeBusy) return;
                      setState(() {
                        values.partial = value == 'yes';
                        if (values.partial == r.node.item.allowPartialPackage) {
                          values.changed.remove('allowPartialPackage');
                        } else {
                          values.changed.add('allowPartialPackage');
                        }
                      });
                    },
                  ),
                  changed: values.changed.contains('allowPartialPackage'),
                );
              },
      ),
      // 整批领到车间内料仓的料 (颗粒等，ADR-131)：这一格是单个重量，按克显示；
      // 与货品资料单重相差 20% 以上或服务端有提醒时标黄待核对。
      MasterColumnDef(
        key: 'qty',
        label: l10n.bomDesignQty,
        width: 150,
        type: 'number',
        info: '整批领到车间内料仓的料 (颗粒等)，这一格是单个重量，按克填写和显示。',
        value: (r) => _bomQtyText(r.node.item),
        cellBuilder: !_canEdit
            ? null
            : (context, r) => _inlineText(r, 'qty', l10n.bomDesignQty),
        exactValueOf: (r) =>
            (r.node.item.isPeriodicEdge
                    ? r.node.item.periodicUnitWeightGrams ?? r.node.item.qty
                    : r.node.item.qty)
                ?.toString(),
        // 「黄框待核对」既有语义（ADR-169 §2.5 不动）；裸 Colors.amber 收编进
        // 语义 warning 档（同色相）。
        cellColor: (context, r) => _weightNeedsReview(r)
            ? UtenColors.warning.withValues(alpha: 0.28)
            : null,
      ),
      // 真实使用数量(只读，ADR-129)：与设计使用数量同一计量口径；没有数据或
      // 不适用显示「—」，悬停说明计算按哪个数、依据几批、累计多少。
      MasterColumnDef(
        key: 'actualQty',
        label: l10n.bomActualQty,
        width: 150,
        type: 'number',
        value: (r) => _bomActualQtyText(r.node.item),
        exactValueOf: (r) => r.node.item.actual.qty?.toString(),
        cellBuilder: (context, r) => Tooltip(
          message: bomActualUsageTip(
            l10n,
            r.node.item.actual,
            netUnit: r.node.item.componentUnitName,
          ),
          child: Text(_bomActualQtyText(r.node.item)),
        ),
      ),
      MasterColumnDef(
        key: 'summary',
        label: '备注',
        width: 120,
        value: (r) => r.node.item.summary,
        cellBuilder: !_canEdit
            ? null
            : (context, r) => _inlineText(r, 'summary', '备注'),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAliveClientMixin
    ref.watch(isSuperAdminProvider);
    ref.watch(currentPermissionsProvider);
    final visible = _visibleRows;
    final hasExpandableBranches = _bulkExpandableBranches(
      _roots ?? const [],
    ).isNotEmpty;
    final branchReadPending = visible.any((row) => row.node.loading);
    ref.watch(sensitiveReadBoundaryProvider);
    ref.watch(goodsClipboardProvider);
    final selectedCount = _selectedRowIds.length;
    // 查询态保留多选和已选摘要，写入能力只由模式与权限决定。
    const selectable = true;
    final learning = ref.watch(
      goodsBomLearningProvider(widget.goodsId).select(
        (latest) =>
            (_editMode || _enteringEdit) ? _editingLearning ?? latest : latest,
      ),
    );
    final evidence =
        learning.asData?.value.materialEvidence ??
        const <GoodsBomMaterialEvidence>[];
    final pendingMaterials = <String, String>{
      for (final row in evidence.where((row) => !row.inBom))
        '${row.componentGoodsId}|${row.colorId}|${row.unitId}':
            '${row.componentName ?? row.componentCode ?? "物料"}'
            '${row.componentCode == null ? "" : " [${row.componentCode}]"}'
            '${row.colorName == null ? "" : " (${row.colorName})"}',
    };
    return Stack(
      children: [
        // 统一表格（与货品资料列表同款）：Excel 表头分隔线 + 拖拽列宽 + 底部横滑条。
        Positioned.fill(
          child: Column(
            children: [
              if (learning.hasError)
                const Padding(
                  padding: EdgeInsets.only(bottom: UtenSpacing.s8),
                  child: UtenInlineNotice(
                    level: UtenInlineNoticeLevel.warning,
                    message: '选料与学习状态加载失败，请点击刷新重试。',
                  ),
                ),
              if (pendingMaterials.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
                  child: UtenInlineNotice(
                    key: const Key('bom-selected-materials-notice'),
                    message:
                        '已记录材料身份：${pendingMaterials.values.take(3).join("、")}'
                        '${pendingMaterials.length > 3 ? "等 ${pendingMaterials.length} 种" : ""}。'
                        '尚未加入 BOM；单耗待核的记录不参与配方计算，实际用料按原流程核清后学习。',
                    trailing: UtenButton(
                      onPressed: () =>
                          _showLearning(showMaterialEvidence: true),
                      child: const Text('查看选料与结构'),
                    ),
                  ),
                ),
              Expanded(
                child: MasterDataTableView<_BomRow>(
                  expensiveRowMounts:
                      _editMode || visible.any((row) => row.isPlaceholder),
                  tableKey:
                      'features.basic_data.widgets.goods_bom_tab.GoodsBomTabState.build.1',
                  // 按 selectable/审计模式分键，进出审计模式时整棵表重建而不是原地重排
                  // （「已审」列的出现/消失会把行子树换父级，SelectionArea 的
                  // SelectionKeepAlive 带着 GlobalKey 一起被搬走，同一帧里
                  // 「Duplicate GlobalKeys detected」崩）。代价是切模式会丢掉列宽与
                  // 滚动位置，可以接受：那本来就是一次模式切换，不是刷新。
                  key: ValueKey('goods-bom-table-$selectable-$_auditMode'),
                  columns: _columns,
                  items: visible,
                  dataCellVerticalPadding:
                      UtenTreeTableCell.compactCellVerticalPadding,
                  bodyPresentationBuilder: (context, child) => Stack(
                    fit: StackFit.passthrough,
                    children: [
                      child,
                      if (_enteringEdit || (_loading && _roots != null))
                        Positioned(
                          top: 0,
                          left: 0,
                          right: 0,
                          child: IgnorePointer(
                            child: Material(
                              color: Theme.of(context).colorScheme.surface,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const LinearProgressIndicator(
                                    key: Key('goods-bom-read-progress'),
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.all(
                                      UtenSpacing.s8,
                                    ),
                                    child: Text(
                                      _enteringEdit
                                          ? _l10n.bomEditPreparing
                                          : _l10n.bomEditRefreshing,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  appendRows: _appendRows,
                  facets: const {},
                  nullCounts: const {},
                  filters: const {},
                  onFilterChanged: (_, _) {},
                  // 多选：最前列勾选框 + 表头三态全选；「已选 N 项 + 清除」胶囊与
                  // 添加组件/编辑/删除一起驻右下悬浮组（batchActionsBuilder），
                  // 普通视图与全屏路由同款渲染。
                  selectable: selectable,
                  // _BomRow 无天然唯一 id，用复合键(见 _rowId)。
                  idOf: (row) => row.isPlaceholder ? null : _rowId(row),
                  unselectableLeadingBuilder: (_, _) => const SizedBox.shrink(),
                  rowKeyOf: (row) => row.occurrenceKey,
                  selectedIds: _selectedRowIds,
                  onSelectedIdsChanged: (next) =>
                      setState(() => _selectedRowIds = next),
                  // 投影缓存只随树结构变化；勾选始终按业务行键比较。
                  isSelected: (row) => _selectedRowIds.contains(_rowId(row)),
                  // 右键菜单：组件先选中当前行再弹自绘小框（与货品资料列表同款）。
                  rowMenuBuilder: _rowMenuItems,
                  backgroundMenuBuilder: _canCreate
                      ? () => [
                          UtenMenuItem(
                            label: _l10n.bomEditNewComponent,
                            enabled: _canCreate && !_writeBusy,
                            onTap: _addItem,
                          ),
                          UtenMenuItem(
                            label: _l10n.bomEditPaste,
                            enabled:
                                _canPaste &&
                                _selectedRowIds.length <= 1 &&
                                !_writeBusy,
                            onTap: _pasteSelected,
                          ),
                        ]
                      : null,
                  // 已审行浅绿底也只在审计模式出现（与「已审」列同进退）——审计标记是
                  // 核对工作态，普通视图不该有无从解释的绿色行；单击选中时表格组件
                  // 自动加深加亮。绿/黄为「已核对/待核对」既有语义（ADR-169 §2.5），
                  // 裸色收编进语义档。
                  rowColor: (r) => _auditMode && r.node.item.audited
                      ? UtenColors.success.withValues(alpha: 0.15)
                      : (_weightNeedsReview(r)
                            ? UtenColors.warning.withValues(alpha: 0.12)
                            : null),
                  // 工具条驻左：表头设置/全屏为内建按钮，其余业务按钮走
                  // toolbarLeadingActions 紧随其后（2026-09-25 口径：顶部按钮全部靠左、
                  // 统一高度/同色、不带 icon——大动作在右下悬浮组）。
                  toolbarLeadingActions: [
                    UtenTreeExpansionButton(
                      key: const Key('goods-bom-tree-expansion'),
                      expanded: _allBomBranchesExpanded,
                      isLoading: _expandingAll,
                      height: UtenTableToolbar.controlHeight,
                      onExpand:
                          _loading ||
                              _writeBusy ||
                              _auditBusyRows.isNotEmpty ||
                              branchReadPending ||
                              !hasExpandableBranches
                          ? null
                          : _expandAllBomBranches,
                      onCollapse: _loading || _writeBusy
                          ? null
                          : _collapseAllBomBranches,
                    ),
                    UtenButton(
                      key: const Key('goods-bom-learning'),
                      height: UtenTableToolbar.controlHeight,
                      // 在学习记录里重学后真实使用数量会变，本页签跟着重读。
                      onPressed: _showLearning,
                      child: Text(
                        AppLocalizations.of(context).bomLearningTitle,
                      ),
                    ),
                    if (widget.onPreview != null)
                      UtenButton(
                        key: const ValueKey('goods-bom-preview'),
                        height: UtenTableToolbar.controlHeight,
                        onPressed: _writeBusy ? null : _previewBom,
                        child: const Text('预览'), // TODO(l10n): 补 arb
                      ),
                    // 导出组件（goods:export）：与「预览」弹窗里的下载Excel 同一端点
                    // （整树展开的加密 xlsx），列集与本表一致。
                    UtenExportButton(
                      prepareExport: _prepareBomExport,
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
                    if (_canCreate)
                      UtenButton(
                        key: const Key('goods-bom-import'),
                        height: UtenTableToolbar.controlHeight,
                        onPressed: _writeBusy ? null : _importComponents,
                        child: const Text('导入组件'),
                      ),
                  ],
                  batchActionsBuilder: (context, ids) => [
                    if (_canCreate)
                      UtenButton(
                        key: const Key('goods-bom-add-component'),
                        size: UtenButtonSize.large,
                        icon: Icons.add_rounded,
                        onPressed: _writeBusy ? null : _addItem,
                        child: const Text('添加组件'),
                      ),
                    if (_canDelete)
                      UtenButton(
                        key: const Key('goods-bom-delete-selected'),
                        type: UtenButtonType.danger,
                        size: UtenButtonSize.large,
                        icon: Icons.delete_outline,
                        onPressed: selectedCount == 0 || _writeBusy
                            ? null
                            : _deleteSelected,
                        child: const Text('删除'),
                      ),
                    if (_canEnterEdit || _editMode)
                      UtenButton(
                        key: const Key('goods-bom-edit-mode'),
                        type: _editMode
                            ? UtenButtonType.danger
                            : UtenButtonType.primary,
                        size: UtenButtonSize.large,
                        isLoading: _enteringEdit,
                        onPressed: _writeBusy ? null : _toggleEditMode,
                        child: Text(
                          _editMode
                              ? _l10n.bomEditExitAndSave
                              : _l10n.bomEditMode,
                        ),
                      ),
                    if (_canAudit)
                      UtenButton(
                        key: const Key('goods-bom-audit-mode'),
                        type: _auditMode
                            ? UtenButtonType.danger
                            : UtenButtonType.primary,
                        size: UtenButtonSize.large,
                        onPressed: _writeBusy ? null : _toggleAuditMode,
                        child: Text(
                          _auditMode
                              ? _l10n.bomEditExitAudit
                              : _l10n.bomEditAuditMode,
                        ),
                      ),
                  ],
                  isLoading: _loading && _roots == null,
                  error: _error,
                  onRetry: _load,
                  // 双击行 = 展开/收起该行子级（2026-10-19 用户口径；表格组件的
                  // onRowTap 只在手动双击判定里触发，单击仍是选中，语义不打架）。
                  onRowTap: (row) {
                    if (row.isPlaceholder) return;
                    if (_canEdit) {
                      _selectedRowIds = {_rowId(row)};
                      _editSelected();
                    } else {
                      _toggle(row.node);
                    }
                  },
                  // 长按拖拽（goods:bom:edit 才挂）：单行换位 / 多选批量 / 悬停
                  // 展开下探移入任意层级；普通列表页与只读账号不受影响。
                  rowDrag: _rowDrag,
                  emptyMessage: _canEdit
                      ? '暂无组装信息，点右下「添加组件」录入'
                      : _l10n.bomEditEmpty,
                ),
              ),
            ],
          ),
        ),
        // 批量删除网络段的全屏加载遮罩(root Overlay 传送门，不占布局)。
        // 确认框已经关掉才会挂上来，否则它会盖住确认框(见 _deleteSelected)。
        if (_deleting)
          const UtenBusyOverlay(
            title: '正在删除组件',
            description: '正在把所选组件从组装清单中移除，请勿重复提交或关闭页面。',
          ),
        // 拖拽移动网络段的全屏加载遮罩(落点已定，无确认框，直接包网络段)。
        if (_pasting || _switchingMode)
          UtenBusyOverlay(
            title: _pasting
                ? _l10n.bomEditPasting
                : _checkingChanges
                ? _l10n.bomEditChecking
                : _l10n.bomEditSaving,
            description: _l10n.bomEditProcessing,
          ),
        if (_moving)
          const UtenBusyOverlay(
            title: '正在移动组件',
            description: '正在保存新的组装层级与顺序，请勿重复提交或关闭页面。',
          ),
        // 添加组件浮窗（页面内浮层，2026-10-19 二轮）：无蒙版、底层表格照常可点；
        // 跳页/切页签随本页隐藏，回来现场还在；保存成功才由会话关闭。
        if (_addComponentCandidates case final candidates?)
          Positioned.fill(
            child: _BomItemAddDialog(
              windowKey: _addComponentWindowKey,
              parentCandidates: candidates,
              defaultParentGoodsId:
                  _addComponentDefaultParent ?? widget.goodsId,
              existingPeriodicCount: _periodicEdgeCountByParent,
              onClose: _closeAddComponentWindow,
              onSaved: _onAddComponentSaved,
              repository: _repository,
              canWrite: () => mounted && _canCreate,
              beforeSave: () => _flushInlineEdits(),
            ),
          ),
      ],
    );
  }

  /// 数量列文本：期间边显示「X 克」(基本单位千克时 = 数量 × 1000)，
  /// 其它行是设计使用数量——2026-10-10「数量+单位」内联口径，统一带组件单位。
  static String _bomQtyText(GoodsBomItem item) {
    if (item.isPeriodicEdge) {
      final grams = item.periodicUnitWeightGrams;
      if (grams != null) return '${periodicGramsText(grams)} 克';
      // 单位不能按克换算：按基本单位显示小数 (不出现科学计数法)。
      return formatQtyWithUnit(
        item.qty,
        item.componentUnitName,
        maxDecimals: 6,
      );
    }
    return formatQtyWithUnit(item.qty, item.componentUnitName, maxDecimals: 6);
  }

  /// 真实使用数量：没有数据或不适用显示「—」，有数带组件单位。
  static String _bomActualQtyText(GoodsBomItem item) => item.actual.qty == null
      ? '—'
      : formatQtyWithUnit(
          item.actual.qty,
          item.componentUnitName,
          maxDecimals: 6,
        );
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
    builder: (ctx) => UtenAlertDialog(
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
    builder: (ctx) => UtenAlertDialog(
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

/// 期间边一行的请求体：组件单位能按克换算时按克提交 unitWeightGrams (服务端换成基本单位存)，
/// 不能换算时 [entered] 就是基本单位的用量，只提交 qty。形状字段不提交 (服务端固定)。
Map<String, dynamic> _periodicEdgeBody(
  String componentGoodsId,
  double entered,
  String? unitName,
) => periodicBomQuantityBody(componentGoodsId, entered, unitName);

/// 期间边输入值对应的克数 (不能换算为 null，此时不在页面判断异常单重，交服务端)。
double? _enteredGrams(double entered, String? unitName) =>
    periodicGramsPerBaseUnit(unitName) == null ? null : entered;

/// 添加组件浮窗（多选批量）：选父级 + 右滑窗勾选多个组件（component scope）+ 每个用量，
/// 一次添加多个组件到同一层级。组件属性只读、用量可改、单价取自组件。
///
/// 2026-10-19 二轮起是页面内常驻浮层（宿主 [GoodsBomTabState] 的会话）：关闭/保存
/// 都经 [onClose]/[onSaved] 回调交给宿主，组件自身不再操作 Navigator。
///
/// 保存把整批追加动作自动暂存到本页草稿；本地校验失败保留浮窗供用户修改。
/// 退出并保存时服务端复核重复、成环、停用与并发状态，整批确认后一次事务提交。
class _BomItemAddDialog extends ConsumerStatefulWidget {
  const _BomItemAddDialog({
    required this.windowKey,
    required this.parentCandidates,
    required this.defaultParentGoodsId,
    required this.onClose,
    required this.onSaved,
    required this.repository,
    required this.canWrite,
    this.existingPeriodicCount = const {},
    this.beforeSave,
  });

  /// 透传给内部 [UtenFloatingWindow] 的 key：宿主用它把缩成球的窗口展开
  /// （见 [_GoodsBomTabState._addItem]）。
  final GlobalKey<UtenFloatingWindowState>? windowKey;
  final List<_BomParentOption> parentCandidates;
  final String defaultParentGoodsId;
  final VoidCallback onClose;

  /// 加入会话草稿后回调，参数为本次暂存的父级 goodsId。
  final ValueChanged<String> onSaved;
  final GoodsBomRepository repository;
  final bool Function() canWrite;
  final Future<bool> Function()? beforeSave;

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
  AppLocalizations get _l10n => AppLocalizations.of(context);
  late String _parentGoodsId;
  final List<_PickedComponent> _picked = [];
  final _componentSearchCtl = TextEditingController();
  bool _saving = false;
  bool _preparingSave = false;
  String? _error;
  int _lookupGeneration = 0;
  ProviderSubscription<SensitiveReadBoundary>? _lookupSubscription;
  final _contentSizeKey = GlobalKey();

  /// 服务端逐行给出的不合格原因(「第几行 哪个组件：为什么」)。
  List<String> _problems = const [];

  /// 单次追加的组件上限(与服务端粘贴命令的行数上限一致)。
  static const int _maxLines = 200;

  @override
  void initState() {
    super.initState();
    _parentGoodsId = widget.defaultParentGoodsId;
    _lookupSubscription = ref.listenManual(sensitiveReadBoundaryProvider, (
      previous,
      next,
    ) {
      if (mounted && previous != next) setState(() => _lookupGeneration++);
    });
  }

  @override
  void dispose() {
    _lookupSubscription?.close();
    _componentSearchCtl.dispose();
    for (final p in _picked) {
      p.qtyCtl.dispose();
    }
    super.dispose();
  }

  Future<void> _pickComponents({String initialKeyword = ''}) async {
    final boundary = ref.read(sensitiveReadBoundaryProvider);
    final generation = _lookupGeneration;
    final parent = _parentGoodsId;
    if (!_lookupIsCurrent(boundary, generation, parent)) return;
    final list = initialKeyword.trim().isEmpty
        ? await ref.read(bomComponentPickerProvider)(context, ref)
        : await showUtenGoodsPickerMulti(
            context,
            ref,
            allowScopeExpansion: true,
            initialKeyword: initialKeyword,
            readBoundary: boundary,
          );
    if (list.isEmpty || !_lookupIsCurrent(boundary, generation, parent)) return;
    _addComponents(list);
  }

  bool _lookupIsCurrent(
    SensitiveReadBoundary boundary,
    int generation,
    String parent,
  ) =>
      mounted &&
      widget.canWrite() &&
      !_saving &&
      generation == _lookupGeneration &&
      parent == _parentGoodsId &&
      boundary == ref.read(sensitiveReadBoundaryProvider);

  void _addComponents(List<GoodsListItem> list) {
    if (!mounted || _saving) return;
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
      _componentSearchCtl.clear();
    });
  }

  Future<void> _save() async {
    if (_saving || _preparingSave || !widget.canWrite()) return;
    if (widget.beforeSave case final beforeSave?) {
      _preparingSave = true;
      bool ready;
      try {
        ready = await beforeSave();
      } finally {
        _preparingSave = false;
      }
      if (!ready || !mounted || !widget.canWrite()) return;
    }
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
      if (!ok || !mounted || !widget.canWrite()) return;
      for (final body in periodicBodies) {
        body[periodicConfirmUnusualWeight] = true;
      }
    }
    // 同一产品第二种整批领料的料 (双色 / 双料) 要确认，换料应改原来那一行。
    final existing = widget.existingPeriodicCount[_parentGoodsId] ?? 0;
    if (periodicBodies.isNotEmpty && existing + periodicBodies.length >= 2) {
      if (!mounted) return;
      final ok = await _confirmSecondPeriodicMaterial(context);
      if (!ok || !mounted || !widget.canWrite()) return;
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
      final repo = widget.repository;
      BomPasteResult result;
      while (true) {
        if (!mounted || !widget.canWrite()) return;
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
          if (confirmed == null || !mounted || !widget.canWrite()) return;
          applyPeriodicConfirmations(periodicBodies, confirmed);
          setState(() => _saving = true);
        }
      }
      if (!mounted) return;
      // 服务端的提醒 (如与货品资料单重相差 20% 以上) 只提示、不拦截。
      if (result.warnings.isNotEmpty) {
        context.appWarning(
          _l10n.bomEditReviewWarnings(
            _l10n.bomEditAddStaged(result.added),
            result.warnings.join('；'),
          ),
        );
      } else {
        context.appSuccess(
          _l10n.bomEditAddStaged(result.added),
        ); // TODO(l10n): 补 arb
      }
      widget.onSaved(_parentGoodsId);
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
    final lookupBoundary = ref.watch(sensitiveReadBoundaryProvider);
    final lookupGeneration = _lookupGeneration;
    final lookupParent = _parentGoodsId;
    bool lookupCurrent() =>
        _lookupIsCurrent(lookupBoundary, lookupGeneration, lookupParent);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final box =
          _contentSizeKey.currentContext?.findRenderObject() as RenderBox?;
      if (box?.hasSize == true) {
        widget.windowKey?.currentState?.fitBodyHeight(
          box!.size.height + UtenSpacing.s16 * 2,
        );
      }
    });
    return UtenFloatingWindow(
      key: widget.windowKey,
      title: '添加组件',
      initialSize: const Size(560, 380),
      minSize: const Size(320, 240),
      onClose: widget.onClose,
      body: Stack(
        children: [
          SingleChildScrollView(
            padding: const EdgeInsets.all(UtenSpacing.s16),
            child: Column(
              key: _contentSizeKey,
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
                    if (v != null && v != _parentGoodsId) {
                      setState(() {
                        _parentGoodsId = v;
                        _lookupGeneration++;
                      });
                    }
                  },
                ),
                const SizedBox(height: UtenSpacing.s12),
                Text(
                  '已选组件 ${_picked.length}', // TODO(l10n)
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: UtenSpacing.s8),
                UtenReferencePickerField<GoodsListItem>(
                  key: const Key('bom-component-lookup'),
                  controller: _componentSearchCtl,
                  label: '组件',
                  hint: '名称 / 编号 / 系列',
                  pickerLabel: '选择组件',
                  pickerIcon: Icons.manage_search_rounded,
                  enabled: !_saving,
                  suggestionScope: (
                    lookupBoundary,
                    lookupGeneration,
                    lookupParent,
                  ),
                  isCurrent: lookupCurrent,
                  loadSuggestions: (query) async {
                    if (!lookupCurrent()) return const [];
                    final result = await ref.read(
                      bomComponentSuggestionsProvider,
                    )(ref, query);
                    return lookupCurrent() ? result : const [];
                  },
                  labelOf: (goods) => goods.name ?? goods.code ?? '货品',
                  onInputChanged: (_) {},
                  onSelected: (goods) {
                    if (lookupCurrent()) _addComponents([goods]);
                  },
                  onOpenPicker: (query) async {
                    if (lookupCurrent()) {
                      await _pickComponents(initialKeyword: query);
                    }
                  },
                  optionBuilder: (_, goods) => Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: UtenSpacing.s12,
                      vertical: UtenSpacing.s8,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(goods.name ?? goods.code ?? '货品'),
                        Text(
                          [
                                goods.code,
                                goods.series,
                                goods.model,
                                goods.spec,
                                goods.colorName,
                              ]
                              .whereType<String>()
                              .where((value) => value.isNotEmpty)
                              .join(' / '),
                          style: theme.textTheme.bodySmall,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ),
                if (_picked.isNotEmpty) ...[
                  const SizedBox(height: UtenSpacing.s12),
                  _pickedTable(theme),
                ],
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
          // 批量添加组件网络段的全屏加载遮罩（root Overlay 传送门，不占布局）。
          if (_saving)
            const UtenBusyOverlay(
              title: '正在添加组件',
              description: '正在一次性保存全部组件，请勿重复提交或关闭弹窗。',
            ),
        ],
      ),
      actions: _dialogActions(
        theme,
        onCancel: widget.onClose,
        onSave: _save,
        saving: _saving,
      ),
    );
  }

  /// 已选组件清单（2026-10-19 二轮 UI 口径）：单行紧凑表格——左列货品
  /// （编号 名称 · 颜色，一行省略），右列窄数量框（dense、无浮动标签、右对齐，
  /// 后缀带组件单位；整批领料按克填单重后缀显「克」），行尾移除按钮。
  Widget _pickedTable(ThemeData theme) {
    final outline = theme.colorScheme.outlineVariant;
    Widget header(String label) => Text(
      label,
      style: theme.textTheme.labelSmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
        fontWeight: FontWeight.w600,
      ),
    );
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: outline),
        borderRadius: UtenRadius.mdAll,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: double.infinity,
            color: theme.colorScheme.surfaceContainerHighest.withValues(
              alpha: 0.5,
            ),
            padding: const EdgeInsets.symmetric(
              horizontal: UtenSpacing.s12,
              vertical: UtenSpacing.s6,
            ),
            child: Row(
              children: [
                Expanded(child: header('货品')),
                SizedBox(width: _pickedQtyFieldWidth, child: header('数量')),
                const SizedBox(width: UtenSpacing.s24),
              ],
            ),
          ),
          for (final (index, p) in _picked.indexed)
            Container(
              decoration: BoxDecoration(
                border: index == 0
                    ? null
                    : Border(
                        top: BorderSide(color: outline.withValues(alpha: 0.6)),
                      ),
              ),
              padding: const EdgeInsets.fromLTRB(
                UtenSpacing.s12,
                UtenSpacing.s4,
                UtenSpacing.s4,
                UtenSpacing.s4,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      [
                        '${p.goods.code ?? ''} ${p.goods.name ?? ''}'.trim(),
                        if (p.goods.colorName?.isNotEmpty == true)
                          p.goods.colorName!,
                      ].where((s) => s.isNotEmpty).join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                  const SizedBox(width: UtenSpacing.s8),
                  SizedBox(
                    width: _pickedQtyFieldWidth,
                    child: _qtyCell(theme, p),
                  ),
                  SizedBox(
                    width: UtenSpacing.s24,
                    child: IconButton(
                      tooltip: '移除',
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minHeight: UtenSpacing.s24,
                        minWidth: UtenSpacing.s24,
                      ),
                      icon: Icon(
                        Icons.close_rounded,
                        size: 16,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      onPressed: () => setState(() {
                        p.qtyCtl.dispose();
                        _picked.remove(p);
                      }),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// 数量格：空/非正数红框即错（保存前的本地可视校验；提交校验仍走 [_save]）。
  Widget _qtyCell(ThemeData theme, _PickedComponent p) =>
      BomComponentQuantityField(
        goods: p.goods,
        controller: p.qtyCtl,
        fieldKey: ValueKey('goods-bom-add-qty-${p.goods.id}'),
        enabled: !_saving,
      );

  static const double _pickedQtyFieldWidth = 104;
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
    required this.repository,
    required this.canWrite,
    this.referenceGrams,
    this.onSaveBody,
    this.requireQuantity = false,
    this.showSuccess = true,
    this.title,
  });

  final String parentGoodsId;
  final GoodsBomItem editing;
  final GoodsBomRepository repository;
  final bool Function() canWrite;
  final Future<GoodsBomItem> Function(Map<String, dynamic>)? onSaveBody;
  final bool requireQuantity;
  final bool showSuccess;
  final String? title;

  /// 父件 (产品) 货品资料单重折算的克数；期间边单重与它相差 20% 以上时提醒核对。
  final double? referenceGrams;

  @override
  ConsumerState<_BomItemEditDialog> createState() => _BomItemEditDialogState();
}

class _BomItemEditDialogState extends ConsumerState<_BomItemEditDialog> {
  late final SensitiveReadBoundary _dialogBoundary;
  ProviderSubscription<SensitiveReadBoundary>? _dialogBoundarySubscription;
  AppLocalizations get _l10n => AppLocalizations.of(context);
  final _qtyCtl = TextEditingController();
  final _summaryCtl = TextEditingController();
  bool _saving = false;
  String? _error;

  /// 打开时的设计使用数量文本：保存时与它比较，判断用户是否改了数量。
  late final String _initialQtyText;

  @override
  void initState() {
    super.initState();
    _dialogBoundary = ref.read(sensitiveReadBoundaryProvider);
    _dialogBoundarySubscription = ref.listenManual(
      sensitiveReadBoundaryProvider,
      (previous, next) {
        if (next == _dialogBoundary || !mounted) return;
        final route = ModalRoute.of(context);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || route == null || !route.isActive) return;
          final navigator = route.navigator;
          if (navigator == null) return;
          if (route.isCurrent) {
            navigator.pop(false);
          } else {
            navigator.removeRoute(route);
          }
        });
      },
    );
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
    _dialogBoundarySubscription?.close();
    _qtyCtl.dispose();
    _summaryCtl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving || !widget.canWrite()) return;
    final e = widget.editing;
    final raw = _qtyCtl.text.trim();
    final entered = double.tryParse(raw);
    if (e.isPeriodicEdge) {
      if (entered == null || !entered.isFinite || entered <= 0) {
        final label = _periodicWeightLabel(context, e.componentUnitName);
        setState(() => _error = '「$label」必须是大于 0 的数字'); // TODO(l10n): 补 arb
        return;
      }
    } else {
      // 只有改了才提交数量：不改就不碰服务端的设计使用数量(学习组件不被接管)。
      final qtyChanged = raw != _initialQtyText;
      if (qtyChanged || widget.requireQuantity) {
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
      if (!ok || !mounted || !widget.canWrite()) return;
      confirmUnusual = true;
    }
    final body = <String, dynamic>{
      // 期间边按克提交 (服务端换成基本单位存，形状固定为开工前、按每件、不设齐套门槛)。
      if (e.isPeriodicEdge)
        ..._periodicEdgeBody(e.componentGoodsId, entered!, e.componentUnitName)
      else ...{
        'componentGoodsId': e.componentGoodsId,
        if (raw != _initialQtyText || widget.requireQuantity)
          'qty': double.parse(raw),
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
      final repo = widget.repository;
      GoodsBomItem updated;
      while (true) {
        if (!mounted || !widget.canWrite()) return;
        try {
          updated = widget.onSaveBody == null
              ? await repo.update(widget.parentGoodsId, e.id, body)
              : await widget.onSaveBody!(body);
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
          if (confirmed == null || !mounted || !widget.canWrite()) return;
          applyPeriodicConfirmations([body], confirmed);
          setState(() => _saving = true);
        }
      }
      if (!mounted) return;
      // 服务端的提醒 (如与货品资料单重相差 20% 以上) 只提示、不拦截。
      if (widget.showSuccess && updated.warnings.isNotEmpty) {
        context.appWarning(
          _l10n.bomEditReviewWarnings(
            _l10n.bomEditComponentStaged,
            updated.warnings.join('；'),
          ),
        );
      } else if (widget.showSuccess) {
        context.appSuccess(_l10n.bomEditComponentStaged);
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
    if (ref.watch(sensitiveReadBoundaryProvider) != _dialogBoundary ||
        !widget.canWrite()) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final e = widget.editing;
    return UtenDialogFrame(
      shape: const RoundedRectangleBorder(borderRadius: UtenRadius.xxlAll),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 600),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _dialogHeader(context, theme, widget.title ?? '编辑组件'),
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
                              // 「标黄提醒待核对」既有语义；裸 Colors.amber 收编进 warning 档。
                              color: UtenColors.warning.withValues(alpha: 0.25),
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
