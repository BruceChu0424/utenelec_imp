// ADR-143 §4.2 委外领料页(/operations/workbench/subcontract/draw-request?orderItemIds=...)。
//
// 2026-11-07 用户要求恢复逐任务输入：单种物料用实物数量，多种物料按套备料。
// 2026-11-08 用户要求数量直接在表格里填写：主表一行一个任务，可分批领料；
// 服务端按仓分配的结果退为只读的出仓分配表，改数量时只清它，不动主表。
// 2026-11-09 第三轮改版：用户要求合并成一张表——删除上方的任务主表与「出仓分配」
// 标题，行 = 计划行 × 领料仓库(服务端候选行，含各仓可用量与联合分配的默认量)，
// 「领料数量」直接填在行内(逐仓实物量，支持分批)，委外单号与委外件名称拆成两列。
// 提交/核对走按行契约(lines)；未填的行与整任务跳过，整行无库存的任务保留一行
// 「未确定」仓位的 0 行，不静默消失。幂等、断网续传、409 行级标红语义不变。
// 2026-11-09 任务中心「物料」列(与车间同一个物料弹窗)：选中物料后带 planItemIds 进来，
// 页面只显示这些物料，默认量 = 每种物料自己的可领上限(整套没齐也能先领到货的物料)；
// 其余流程(行内改数量、核对库存、提交、分批)完全相同。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_refresh_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../components/layout/uten_grid_page_scrollbar.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/api_mutation_reload_safety.dart';
import '../../../core/network/server_config.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/idempotency_key.dart';
import '../../../shared/badges/badge_registry.dart';
import '../../../shared/formatters/quantity_display.dart';
import '../../../shared/measurement/document_quantity.dart';
import '../../../shared/providers/authenticated_scope_provider.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/subcontract_draw.dart';
import '../repositories/subcontract_draw_repository.dart';
import 'package:uten_imp/components/layout/uten_page_layout.dart';

class SubcontractDrawRequestPage extends ConsumerStatefulWidget {
  const SubcontractDrawRequestPage({
    super.key,
    required this.orderItemIds,
    this.planItemIds = const [],
    this.repository,
  });

  final List<String> orderItemIds;

  /// 从任务中心「物料」弹窗选中的物料(冻结计划行)；只对单个委外任务有效，
  /// 为空 = 按任务整套领料(批量领料 / 状态列「去领料」)。
  final List<String> planItemIds;

  /// 测试注入；默认取 [subcontractDrawRepositoryProvider]。
  final SubcontractDrawGateway? repository;

  @override
  ConsumerState<SubcontractDrawRequestPage> createState() =>
      _SubcontractDrawRequestPageState();
}

class _SubcontractDrawRequestPageState
    extends ConsumerState<SubcontractDrawRequestPage> {
  /// 任务顺序(首次预览的服务端顺序 = 联合分配顺序)。
  final _order = <String>[];

  /// 每个任务最近一次服务端核对的事实(委外单号、委外件名称、数量口径)。
  final _tasks = <String, SubcontractDrawPreviewTask>{};

  /// 候选行(计划行 × 仓)：唯一的输入面。只在服务端核对后换新；输入时行实例不变。
  List<SubcontractDrawPreviewLine> _rows = const [];

  /// 行输入留在原控制器；重新核对不覆盖手工输入。
  final _inputs = <String, TextEditingController>{};

  /// 每行服务端默认量(联合分配的预填值)，用于识别「未改动的合法默认」。
  final _rowDefaults = <String, String>{};

  /// 409 行级上限：单仓超限按行身份，整行超限按 任务|计划行。
  final _liveRowMaxima = <String, String>{};
  final _liveLineMaxima = <String, String>{};

  SubcontractDrawPreview? _preview;

  final _pageScroll = ScrollController();
  final _tablePinned = ValueNotifier<bool>(false);

  bool _loading = true;
  bool _saving = false;
  bool _confirming = false;
  bool _uncertain = false;
  bool _edited = false;
  bool _previewDirty = false;
  String? _loadError;

  /// 预览整批 409(所选任务里有已领满 / 已结束领料 / 不再可见的)：同一批重试永远失败，
  /// 出错页只给「返回委外任务中心」。
  bool _loadConflict = false;
  String? _submitError;
  String? _notice;
  int _previewRequest = 0;

  /// 结果未确认(断网/超时/5xx)时冻结的幂等键：重试沿用同一键，不会重复建单。
  String? _pendingKey;
  List<SubcontractDrawRequestItem>? _pendingItems;

  static const _checkKey = Key('subcontract-draw-request-stock-check');
  late final AuthenticatedScope? _ownerScope;
  late final String _ownerBackend;

  /// 本次提交尝试的随机串，拼进幂等键。进页(含 409 回填)与每次有了确定结果
  /// (成功 / 被拒)都换新：撤回或退料后再领同样数量也是一次新的领料，不会被当成重放。
  String _attemptNonce = _newNonce();

  static String _newNonce() => const Uuid().v4();

  SubcontractDrawGateway get _gateway =>
      widget.repository ?? ref.read(subcontractDrawRepositoryProvider);

  List<String> get _requestedIds {
    final seen = <String>{};
    return [
      for (final id in widget.orderItemIds)
        if (id.trim().isNotEmpty && seen.add(id.trim())) id.trim(),
    ];
  }

  /// 按物料领料时只显示所选物料；多任务批量领料不带物料(按任务整套)。
  Set<String>? get _selectedPlanItems {
    final ids = {
      for (final id in widget.planItemIds)
        if (id.trim().isNotEmpty) id.trim(),
    };
    return ids.isEmpty || _requestedIds.length != 1 ? null : ids;
  }

  @override
  void initState() {
    super.initState();
    _ownerScope = ref.read(authenticatedScopeProvider);
    _ownerBackend = ref.read(apiBaseUrlProvider);
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    for (final controller in _inputs.values) {
      controller.dispose();
    }
    _pageScroll.dispose();
    _tablePinned.dispose();
    super.dispose();
  }

  bool get _scopeCurrent =>
      mounted &&
      ref.read(authenticatedScopeProvider) == _ownerScope &&
      ref.read(apiBaseUrlProvider) == _ownerBackend;

  bool _acceptPreview(int request) =>
      _scopeCurrent && request == _previewRequest;

  /// 首次进入或刷新未编辑的任务时，以实时可领量回填各仓默认量。
  Future<void> _load({String? notice, bool fillMaximum = false}) async {
    if (!_scopeCurrent ||
        _saving ||
        _confirming ||
        _uncertain ||
        _loading && _order.isNotEmpty) {
      return;
    }
    if (_edited && !fillMaximum) {
      await _checkStock();
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    final request = ++_previewRequest;
    setState(() {
      _loading = true;
      _loadError = null;
      _loadConflict = false;
      _submitError = null;
      _pendingKey = null;
      _pendingItems = null;
      _liveRowMaxima.clear();
      _liveLineMaxima.clear();
      _attemptNonce = _newNonce();
      _notice = notice;
    });
    try {
      final ids = _requestedIds;
      if (ids.isEmpty || ids.length > SubcontractDrawRepository.batchLimit) {
        throw const FormatException(
          '请返回委外任务中心「领料」，选择 1 至 '
          '${SubcontractDrawRepository.batchLimit} 个可领料的委外任务',
        );
      }
      final planItems = _selectedPlanItems;
      final preview = await _gateway.preview([
        for (final id in ids)
          SubcontractDrawRequestItem(
            orderItemId: id,
            planItemIds: planItems == null
                ? null
                : (planItems.toList()..sort()),
          ),
      ]);
      if (!_acceptPreview(request)) return;
      // 旧控制器的延迟释放在 _rememberPreview(resetInputs) 里统一做，这里不再重复。
      setState(() {
        _rememberPreview(preview, resetInputs: true);
        _loading = false;
      });
    } catch (error) {
      if (!_acceptPreview(request)) return;
      final message = switch (error) {
        ApiException() => _message(error),
        FormatException() => error.message,
        _ => '领料预览加载失败，请重新加载',
      };
      setState(() {
        _loading = false;
        if (fillMaximum && _edited) {
          _previewDirty = true;
          _submitError = message;
        } else {
          _loadError = message;
          _loadConflict = error is ApiException && error.httpStatus == 409;
        }
      });
    }
  }

  /// 记住一次核对结果。默认量(服务端预填)只在重建输入框时写入控制器；
  /// 重新核对不覆盖手工输入——行的默认值与用户输入一致时本就是同一个数。
  /// 按物料领料时服务端仍回全部开放物料的候选行，这里只留所选物料。
  void _rememberPreview(
    SubcontractDrawPreview preview, {
    bool resetInputs = false,
  }) {
    _preview = preview;
    _edited = false;
    _previewDirty = false;
    _order
      ..clear()
      ..addAll(preview.tasks.map((task) => task.orderItemId));
    _tasks
      ..clear()
      ..addEntries(
        preview.tasks.map((task) => MapEntry(task.orderItemId, task)),
      );
    final planItems = _selectedPlanItems;
    final lines = planItems == null
        ? preview.lines
        : [
            for (final line in preview.lines)
              if (planItems.contains(line.planItemId)) line,
          ];
    _rows = lines;
    _rowDefaults
      ..clear()
      ..addEntries([
        for (final line in lines)
          MapEntry(
            line.identity,
            positiveDocumentQuantityText(line.quantityText('qty') ?? '') ?? '',
          ),
      ]);
    if (resetInputs) {
      final stale = _inputs.values.toList(growable: false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        for (final controller in stale) {
          controller.dispose();
        }
      });
      _inputs
        ..clear()
        ..addEntries([
          for (final line in lines)
            MapEntry(
              line.identity,
              TextEditingController(text: _rowDefaults[line.identity]),
            ),
        ]);
    }
  }

  String _rawInput(String identity) => _inputs[identity]?.text.trim() ?? '';

  String? _quantityError(SubcontractDrawPreviewLine line) {
    if (line.warehouseId == null) return null; // 未定仓行不可输入
    final raw = _rawInput(line.identity);
    return raw.isNotEmpty &&
            raw != _rowDefaults[line.identity] &&
            nonNegativeDocumentQuantityText(raw, fractionDigits: 4) == null
        ? '请输入非负数，最多 4 位小数'
        : null;
  }

  /// 行输入 > 0 的规范文本；空/0/非法返回 null(= 本次不从该行领)。
  String? _rowInput(SubcontractDrawPreviewLine line) {
    if (line.warehouseId == null) return null;
    if (_quantityError(line) != null) return null;
    return positiveDocumentQuantityText(_rawInput(line.identity));
  }

  /// 本次真正提交的任务(至少有一行 > 0)；行按任务分组，未填的任务不进提交。
  List<SubcontractDrawRequestItem> get _submitItems {
    final byTask = <String, List<SubcontractDrawRequestLine>>{};
    for (final line in _rows) {
      final qty = _rowInput(line);
      if (qty == null) continue;
      (byTask[line.orderItemId] ??= []).add(
        SubcontractDrawRequestLine(
          planItemId: line.planItemId,
          warehouseId: line.warehouseId!,
          qty: qty,
        ),
      );
    }
    return [
      for (final id in _order)
        if (byTask[id] case final lines?)
          SubcontractDrawRequestItem(orderItemId: id, lines: lines),
    ];
  }

  void _quantityChanged(String _) {
    if (_uncertain || _saving || _confirming) return;
    setState(() {
      _edited = true;
      _previewDirty = true;
      _notice = null;
      _submitError = null;
      _liveRowMaxima.clear();
      _liveLineMaxima.clear();
    });
  }

  Future<void> _checkStock() async {
    if (!_scopeCurrent || _loading || _saving || _confirming || _uncertain) {
      return;
    }
    if (_rows.any((line) => _quantityError(line) != null)) {
      context.appWarning('请修正领料数量');
      return;
    }
    final items = _submitItems;
    if (items.isEmpty) {
      context.appWarning('请填写至少一行的领料数量');
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    final request = ++_previewRequest;
    setState(() {
      _loading = true;
      _previewDirty = true;
      _submitError = null;
      _notice = null;
    });
    try {
      final preview = await _gateway.preview(items);
      if (!_acceptPreview(request)) return;
      _verifyEcho(preview, items);
      setState(() {
        _rememberPreview(preview);
        _liveRowMaxima.clear();
        _liveLineMaxima.clear();
      });
    } on ApiException catch (error) {
      if (!_acceptPreview(request)) return;
      setState(() => _recordStockError(error));
    } on FormatException catch (error) {
      if (!_acceptPreview(request)) return;
      setState(() => _submitError = error.message);
    } catch (_) {
      if (!_acceptPreview(request)) return;
      setState(() => _submitError = '库存核对失败，请重试');
    } finally {
      if (_acceptPreview(request)) {
        setState(() => _loading = false);
      }
    }
  }

  /// 服务端必须把提交的每一行按原数量回显(定向分配的默认量 = 用户填写量)，
  /// 否则视为核对结果有变化，要求回任务中心重新选择。
  void _verifyEcho(
    SubcontractDrawPreview preview,
    List<SubcontractDrawRequestItem> items,
  ) {
    final rows = {for (final line in preview.lines) line.identity: line};
    for (final item in items) {
      for (final requested
          in item.lines ?? const <SubcontractDrawRequestLine>[]) {
        final identity =
            '${item.orderItemId}|${requested.planItemId}|${requested.warehouseId}';
        final echoed = rows[identity];
        if (echoed == null ||
            positiveDocumentQuantityText(echoed.quantityText('qty') ?? '') !=
                requested.qty) {
          throw const FormatException('领料核对结果有变化，请返回任务中心重新选择');
        }
      }
    }
  }

  void _recordStockError(ApiException error) {
    _submitError = _message(error);
    _liveRowMaxima.clear();
    _liveLineMaxima.clear();
    final details = error.details;
    if (details?['kind'] != 'SUBCONTRACT_DRAW_QUANTITY_EXCEEDED') return;
    final rows = details?['quantities'];
    if (rows is! List) return;
    for (final row in rows.whereType<Map<String, dynamic>>()) {
      final id = row['orderItemId'];
      final maximum = recordedDocumentDecimal(row, 'maximumQty');
      if (id is! String || maximum == null || !_tasks.containsKey(id)) continue;
      final planItemId = row['planItemId'];
      final warehouseId = row['warehouseId'];
      if (planItemId is String && warehouseId is String) {
        _liveRowMaxima['$id|$planItemId|$warehouseId'] = maximum;
      } else if (planItemId is String) {
        _liveLineMaxima['$id|$planItemId'] = maximum;
      } else {
        // 兼容旧任务级明细：该任务所有行按同一上限标红。
        for (final line in _rows.where((line) => line.orderItemId == id)) {
          _liveRowMaxima[line.identity] = maximum;
        }
      }
    }
  }

  String? get _blocked {
    if (_loading) return '正在加载领料预览';
    if (_saving) return '正在提交领料，请稍候';
    if (_confirming) return '请确认本次领料';
    if (_uncertain) return _pendingItems == null ? '领料提交状态需要核对' : null;
    if (_order.isEmpty) return '没有可领料的委外任务，请返回委外任务中心重新选择';
    if (_rows.any((line) => _quantityError(line) != null)) {
      return '请修正领料数量';
    }
    if (_previewDirty) return '请先核对本次领料的库存';
    if (_submitItems.isEmpty) return '本次没有填写领料数量，请返回委外任务中心重新选择';
    if (_rows.isEmpty) return '本次没有可发出的物料';
    return null;
  }

  String _idempotencyKey(List<SubcontractDrawRequestItem> items) {
    final canonical = [
      for (final item in [
        ...items,
      ]..sort((a, b) => a.orderItemId.compareTo(b.orderItemId)))
        '${item.orderItemId}:'
            '${_canonicalLines(item.lines)}:'
            '${_tasks[item.orderItemId]?.quantityText('drawnQty')}:'
            '${_tasks[item.orderItemId]?.quantityText('drawableQty')}',
    ].join('|');
    return businessIdempotencyKey(
      'subcontract-draw',
      '$_attemptNonce|$canonical',
    );
  }

  /// 行按(计划行, 仓)排序后拼接，同一批领料只有一种规范表示。
  static String _canonicalLines(List<SubcontractDrawRequestLine>? lines) {
    final ordered = [...?lines]
      ..sort(
        (a, b) => '${a.planItemId}|${a.warehouseId}'.compareTo(
          '${b.planItemId}|${b.warehouseId}',
        ),
      );
    return [
      for (final line in ordered)
        '${line.planItemId}|${line.warehouseId}|${line.qty}',
    ].join(',');
  }

  Future<void> _submit() async {
    if (!_scopeCurrent || _blocked != null) return;
    final items =
        _pendingItems ??
        List<SubcontractDrawRequestItem>.unmodifiable(_submitItems);
    // 提交即生成出仓单、仓库按单发料，误触代价高：先弹二次确认。「重试领料」
    // 是结果未确认时的续传（数量保持原提交内容），不再多弹一道。
    if (!_uncertain) {
      final docCount = _preview?.documentCount;
      setState(() => _confirming = true);
      try {
        final confirmed = await UtenDialog.show(
          context,
          title: '提交领料',
          confirmLabel: '确认提交',
          content: Text(
            '将提交 ${items.length} 个委外任务的领料'
            '${docCount == null ? '' : '，预计生成 $docCount 张出仓单'}。'
            '提交后由仓库按领料仓库发出直属物料，委外商加工后分批回厂。确认提交？',
          ),
        );
        if (confirmed != true || !_scopeCurrent) return;
      } finally {
        if (mounted) setState(() => _confirming = false);
      }
    }
    final key = _pendingKey ?? _idempotencyKey(items);
    setState(() {
      _saving = true;
      _submitError = null;
      _notice = null;
      _pendingKey = key;
      _pendingItems = items;
    });
    try {
      final result = await _gateway.submit(items: items, idempotencyKey: key);
      if (!mounted || !_scopeCurrent) return;
      _pendingKey = null;
      _pendingItems = null;
      _attemptNonce = _newNonce();
      setState(() {
        _saving = false;
        _uncertain = false;
      });
      unawaited(refreshBadges(ref));
      context.appSuccess(
        result.replayed
            ? '本批领料已提交过，请等待仓库发料'
            : '已提交 ${items.length} 个委外任务的领料，共 ${result.documentCount} 张出仓单，等待仓库发料',
      );
      if (context.canPop()) {
        context.pop(true);
      } else {
        context.go(RouteName.operationsSubcontractDrawSegment());
      }
    } on ApiException catch (error) {
      if (!_scopeCurrent) return;
      // A retry can fail before the service checks the key. Only a response
      // from the replay lookup or a later stock check settles the original.
      final retryUnproven =
          _uncertain &&
          !const {
            'SUBCONTRACT_DRAW_QUANTITY_EXCEEDED',
            'SUBCONTRACT_DRAW_REPLAY_RETIRED',
          }.contains(error.details?['kind']);
      final uncertain =
          retryUnproven || !ApiMutationReloadSafety.isDefiniteRejection(error);
      if (uncertain) {
        setState(() {
          _saving = false;
          _uncertain = true;
          _submitError = retryUnproven
              ? '${_message(error)}。上次领料结果仍待核对，已保留原提交数量。'
              : '暂未确认领料结果，请点击「重试领料」继续本批提交；数量保持原提交内容。';
        });
        return;
      }
      _pendingKey = null;
      _pendingItems = null;
      _attemptNonce = _newNonce();
      setState(() {
        _saving = false;
        _uncertain = false;
      });
      if (error.httpStatus == 409) {
        if (_edited) {
          setState(() {
            _previewDirty = true;
            _recordStockError(error);
          });
          return;
        }
        await _load(notice: '${_message(error)}。已按实时本批可领重新填写，请核对后再提交。');
        return;
      }
      setState(() => _submitError = _message(error));
    } catch (_) {
      if (!_scopeCurrent) return;
      setState(() {
        _saving = false;
        _uncertain = true;
        _submitError = '暂未确认领料结果，请点击「重试领料」继续本批提交；数量保持原提交内容。';
      });
    }
  }

  void _back() => popOrBackTo(
    context,
    defaultPath: RouteName.operationsSubcontractDrawSegment(),
  );

  /// 预览整批 409 后回任务中心：带 true 让列表清掉这批勾选并重拉。
  void _backAfterConflict() {
    if (context.canPop()) {
      context.pop(true);
    } else {
      context.go(RouteName.operationsSubcontractDrawSegment());
    }
  }

  @override
  Widget build(BuildContext context) {
    final scope = ref.watch(authenticatedScopeProvider);
    final backend = ref.watch(apiBaseUrlProvider);
    if (scope != _ownerScope || backend != _ownerBackend) {
      return Scaffold(
        appBar: const UtenAppBar(title: '委外领料'),
        body: UtenEmpty(
          message: '会话已变化，请返回委外任务中心重新选择',
          actionLabel: '返回委外任务中心',
          onAction: _back,
        ),
      );
    }
    final blocked = _blocked;
    final ready = !_loading && _loadError == null && _order.isNotEmpty;
    return PopScope(
      canPop: !_saving && !_uncertain,
      child: Scaffold(
        appBar: UtenAppBar(
          title: '委外领料',
          leading: UtenBackButton(
            enabled: !_saving && !_uncertain,
            onPressed: _back,
          ),
          actions: [
            UtenRefreshButton(
              key: const Key('subcontract-draw-request-refresh'),
              tooltip: _uncertain
                  ? '请先重试领料，确认本批结果'
                  : _edited
                  ? '按填写数量核对库存'
                  : '按实时可领量重新填写',
              busy: _loading,
              enabled: !_saving && !_uncertain,
              onRefresh: _load,
            ),
          ],
        ),
        body: SafeArea(
          child: UtenContentContainer.wide(
            child: Stack(
              children: [
                if (_loading && _order.isEmpty)
                  const SizedBox.expand()
                else if (_loadError != null)
                  UtenEmpty.error(
                    key: const Key('subcontract-draw-request-load-error'),
                    message: _loadError,
                    description: _loadConflict
                        ? '所选委外任务有变化，请回到委外任务中心「领料」刷新后重新勾选。'
                        : null,
                    actionLabel: _loadConflict ? '返回委外任务中心' : '重新加载',
                    onAction: _loadConflict ? _backAfterConflict : _load,
                  )
                else if (_order.isEmpty)
                  UtenEmpty(
                    message: '暂无可领料的委外任务',
                    description: '请返回委外任务中心「领料」，刷新后查看到料情况。',
                    actionLabel: '返回委外任务中心',
                    onAction: _back,
                  )
                else
                  SizedBox.expand(
                    child: AbsorbPointer(
                      absorbing: _saving || _loading,
                      child: UtenGridPageScrollbar(
                        pinned: _tablePinned,
                        controller: _pageScroll,
                        child: UtenPageEdgePadding.scroll(
                          padding: const EdgeInsets.fromLTRB(
                            UtenSpacing.s12,
                            UtenSpacing.s12,
                            UtenSpacing.s12,
                            UtenFloatingActionGroup.scrollClearance,
                          ),
                          // 不用懒加载列表：表格滚出视口时输入行和焦点都要留着。
                          builder: (context, padding) => SingleChildScrollView(
                            controller: _pageScroll,
                            padding: padding,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [..._feedback(), _table()],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                if (_loading || _saving)
                  UtenBusyOverlay(
                    semanticsKey: Key(
                      _loading
                          ? 'subcontract-draw-request-loading'
                          : 'subcontract-draw-request-saving',
                    ),
                    title: _loading ? '正在核对本批可领' : '正在提交领料',
                    description: _loading
                        ? '正在按交期、订货单号、行号联合分配共享物料。'
                        : '正在生成委外材料出仓单，请勿重复提交或离开本页。',
                  ),
              ],
            ),
          ),
        ),
        floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
        floatingActionButtonAnimator: FloatingActionButtonAnimator.noAnimation,
        floatingActionButton: !ready
            ? null
            : UtenFloatingActionGroup(
                compactPrimaryActionKey: _previewDirty ? _checkKey : _submitKey,
                children: [
                  UtenButton(
                    type: UtenButtonType.secondary,
                    size: UtenButtonSize.large,
                    onPressed: _saving || _uncertain ? null : _back,
                    child: const Text('返回'),
                  ),
                  if (_edited && !_uncertain)
                    UtenButton(
                      key: const Key('subcontract-draw-request-fill-maximum'),
                      type: UtenButtonType.secondary,
                      size: UtenButtonSize.large,
                      onPressed: () => _load(fillMaximum: true),
                      child: const Text('按本批可领量填写'),
                    ),
                  if (_previewDirty)
                    UtenButton(
                      key: _checkKey,
                      size: UtenButtonSize.large,
                      icon: Icons.inventory_2_outlined,
                      onPressed: _checkStock,
                      child: const Text('核对库存'),
                    ),
                  UtenButton(
                    key: _submitKey,
                    type: UtenButtonType.danger,
                    size: UtenButtonSize.large,
                    icon: Icons.move_to_inbox_rounded,
                    isLoading: _saving,
                    onPressed: blocked == null ? _submit : null,
                    onDisabledTap: () =>
                        context.appWarning(blocked ?? '正在提交领料'),
                    child: Text(
                      _uncertain ? '重试领料' : '提交领料(${_submitItems.length})',
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  static const _submitKey = Key('subcontract-draw-request-submit');

  static const _quantityHelp =
      '每行填本次要从该仓领出的实物量，可只领一部分(分批)；留空或 0 表示本次不从该行领。'
      '共用物料按交期、订货单号和行号联合分配，超限以服务端核对为准。';

  bool get _inputEnabled =>
      !_saving && !_loading && !_uncertain && !_confirming;

  List<Widget> _feedback() {
    final theme = Theme.of(context);
    Widget line(String text, Key key, Color color) => Padding(
      padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
      child: Semantics(
        liveRegion: true,
        child: Text(
          text,
          key: key,
          style: theme.textTheme.bodyMedium?.copyWith(color: color),
        ),
      ),
    );
    return [
      if (_notice case final notice?)
        line(
          notice,
          const Key('subcontract-draw-request-notice'),
          theme.colorScheme.tertiary,
        ),
      if (_submitError case final error?)
        line(
          error,
          const Key('subcontract-draw-request-error'),
          theme.colorScheme.error,
        ),
    ];
  }

  Widget _table() => MasterDataTableView<SubcontractDrawPreviewLine>(
    // 第三轮改版合成一张表：新表位，旧任务表/分配表的存量布局自然作废。
    tableKey:
        'features.subcontract.pages.subcontract_draw_request_page.SubcontractDrawRequestPageState._table.1',
    key: const Key('subcontract-draw-request-lines'),
    embedded: true,
    stickyHeaderPinned: _tablePinned,
    // 不开放「表头设置」：隐藏输入列后仍能按默认量提交，看不到自己领了多少。
    showColumnChooser: false,
    facets: const {},
    nullCounts: const {},
    filters: const {},
    onFilterChanged: (_, _) {},
    rowKeyOf: (line) => line.identity,
    columns: [
      MasterColumnDef(
        key: 'warehouseName',
        label: '领料仓库',
        sortable: true,
        filterFromRows: true,
        width: 160,
        value: (line) =>
            line.warehouseId == null ? '未确定' : _label(line.warehouseName),
      ),
      MasterColumnDef(
        key: 'goodsName',
        label: '物料名称',
        sortable: true,
        width: 200,
        value: (line) => _label(line.goodsName),
      ),
      MasterColumnDef(
        key: 'goodsCode',
        label: '编号',
        // 2026-11-11 口径：编号列可排序 + 按值筛选（全量预览表就地收集桶）。
        sortable: true,
        filterFromRows: true,
        width: 130,
        value: (line) => _label(line.goodsCode),
      ),
      MasterColumnDef(
        key: 'colorName',
        label: '颜色',
        sortable: true,
        filterFromRows: true,
        width: 90,
        value: (line) => _label(line.colorName),
      ),
      MasterColumnDef(
        key: 'qty',
        label: '领料数量',
        info: _quantityHelp,
        width: 230,
        type: 'number',
        // 2026-11-11 口径：数量列可排序（输入列就地按当前值排，同财务核价页）。
        sortable: true,
        value: (line) => _rawInput(line.identity),
        exactValueOf: (line) => _rawInput(line.identity),
        exactListenableOf: (line) => _inputs[line.identity],
        cellBuilder: (context, line) => _quantityCell(line),
      ),
      // 可用量只作提示：以最近一次核对为准，改动后标「上次核对」。
      MasterColumnDef(
        key: 'warehouseAvailableQty',
        label: '仓库可用',
        sortable: true,
        exactValueOf: (line) => line.quantityText('warehouseAvailableQty'),
        width: 150,
        type: 'number',
        value: (line) => formatExactQtyWithUnit(
          line.quantityText('warehouseAvailableQty'),
          line.unitName,
        ),
        cellBuilder: _availableCell,
      ),
      MasterColumnDef(
        key: 'orderBillNo',
        label: '委外单号',
        sortable: true,
        filterFromRows: true,
        width: 160,
        value: (line) => _label(_tasks[line.orderItemId]?.orderBillNo),
      ),
      MasterColumnDef(
        key: 'orderGoodsName',
        label: '委外件名称',
        sortable: true,
        width: 180,
        value: (line) => _label(_tasks[line.orderItemId]?.goodsName),
      ),
    ],
    items: _rows,
    emptyMessage: '本次没有可发出的物料',
  );

  Widget _quantityCell(SubcontractDrawPreviewLine line) {
    final error = _quantityError(line);
    final unavailable = line.warehouseId == null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: UtenInput(
                key: ValueKey('subcontract-draw-request-qty-${line.identity}'),
                controller: _inputs[line.identity],
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                enabled: _inputEnabled && !unavailable,
                onChanged: _quantityChanged,
                errorMessage: error,
              ),
            ),
            if (line.unitName.isNotEmpty) ...[
              const SizedBox(width: UtenSpacing.s8),
              Text(line.unitName),
            ],
          ],
        ),
        // 输入框自身的错误已由单元格语义播报，这里只补可见文字。
        if (error != null)
          ExcludeSemantics(child: UtenFieldMessage.error(error, maxLines: 2)),
        if (unavailable)
          const ExcludeSemantics(child: UtenFieldMessage.autofill('该物料暂无可用库存')),
      ],
    );
  }

  bool get _availabilityCurrent => !_previewDirty;

  Widget _availableCell(BuildContext context, SubcontractDrawPreviewLine line) {
    final text = formatExactQtyWithUnit(
      line.quantityText('warehouseAvailableQty'),
      line.unitName,
    );
    if (text.isEmpty) return const Text('—');
    final colors = Theme.of(context).colorScheme;
    final exceeded =
        _liveRowMaxima.containsKey(line.identity) ||
        _liveLineMaxima.containsKey('${line.orderItemId}|${line.planItemId}');
    return Text(
      _availabilityCurrent ? text : '上次核对 $text',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: exceeded
            ? colors.error
            : _availabilityCurrent
            ? null
            : colors.onSurfaceVariant,
      ),
    );
  }

  static String _message(ApiException error) =>
      error.fieldErrors?.firstOrNull?.message.trim().isNotEmpty == true
      ? error.fieldErrors!.first.message
      : error.message;

  static String _label(String? value) =>
      value?.trim().isNotEmpty == true ? value!.trim() : '—';
}
