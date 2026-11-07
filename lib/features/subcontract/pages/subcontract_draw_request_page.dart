import '../../../components/inputs/uten_field_hint_icon.dart';
// ADR-143 §4.2 委外领料页(/operations/workbench/subcontract/draw-request?orderItemIds=...)。
//
// 2026-11-07 用户要求恢复逐任务输入：单种物料用实物数量，多种物料按套备料。
// 默认联合分配本批可领；修改后由服务端重新核对共享库存并预览各仓实发。
// 提交在锁内按相同规则重验。手填量遇到库存变化时保留；未知结果只重试原提交。
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
import '../../../components/inputs/uten_input.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_floating_action_group.dart';
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
    this.repository,
  });

  final List<String> orderItemIds;

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

  /// 每个任务最近一次服务端核对的事实。
  final _tasks = <String, SubcontractDrawPreviewTask>{};

  /// 输入留在原控制器；重新核对不会覆盖手工输入。
  final _quantities = <String, TextEditingController>{};
  final _liveMaxima = <String, String>{};
  SubcontractDrawPreview? _preview;

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

  @override
  void initState() {
    super.initState();
    _ownerScope = ref.read(authenticatedScopeProvider);
    _ownerBackend = ref.read(apiBaseUrlProvider);
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    for (final controller in _quantities.values) {
      controller.dispose();
    }
    super.dispose();
  }

  bool get _scopeCurrent =>
      mounted &&
      ref.read(authenticatedScopeProvider) == _ownerScope &&
      ref.read(apiBaseUrlProvider) == _ownerBackend;

  bool _acceptPreview(int request) =>
      _scopeCurrent && request == _previewRequest;

  /// 首次进入或刷新未编辑的任务时，以实时可领量回填。
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
      _liveMaxima.clear();
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
      final preview = await _gateway.preview([
        for (final id in ids) SubcontractDrawRequestItem(orderItemId: id),
      ]);
      if (!_acceptPreview(request)) return;
      // 旧输入框可能还挂在本帧的树上：换上新控制器后，下一帧再释放旧的。
      final stale = _quantities.values.toList(growable: false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        for (final controller in stale) {
          controller.dispose();
        }
      });
      setState(() {
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
        _quantities
          ..clear()
          ..addEntries(
            preview.tasks.map(
              (task) => MapEntry(
                task.orderItemId,
                TextEditingController(text: task.defaultInputQtyText ?? ''),
              ),
            ),
          );
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

  String _rawInput(String id) => _quantities[id]?.text.trim() ?? '';

  String? _quantityError(String id) {
    final raw = _rawInput(id);
    return raw.isNotEmpty &&
            raw != _tasks[id]?.defaultInputQtyText &&
            nonNegativeDocumentQuantityText(raw, fractionDigits: 4) == null
        ? '请输入非负数，最多 4 位小数'
        : null;
  }

  String? _inputOf(String id) => _quantityError(id) == null
      ? positiveDocumentQuantityText(_rawInput(id))
      : null;

  SubcontractDrawRequestItem _requestItem(String id, String qty) {
    final planItemId = _tasks[id]?.materialPlanItemId;
    return planItemId == null
        ? SubcontractDrawRequestItem(orderItemId: id, qty: qty)
        : SubcontractDrawRequestItem(
            orderItemId: id,
            materialQty: qty,
            materialPlanItemId: planItemId,
          );
  }

  /// 本次真正提交的任务(数量 > 0)。
  List<SubcontractDrawRequestItem> get _submitItems => [
    for (final id in _order)
      if (_inputOf(id) case final qty?) _requestItem(id, qty),
  ];

  void _quantityChanged(String _) {
    if (_uncertain || _saving || _confirming) return;
    setState(() {
      _edited = true;
      _previewDirty = true;
      _notice = null;
      _submitError = null;
      _liveMaxima.clear();
    });
  }

  Future<void> _checkStock() async {
    if (!_scopeCurrent || _loading || _saving || _confirming || _uncertain) {
      return;
    }
    if (_order.any((id) => _quantityError(id) != null)) {
      context.appWarning('请修正本次领料数量');
      return;
    }
    final items = _submitItems;
    if (items.isEmpty) {
      context.appWarning('请填写至少一个任务的本次领料数量');
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
      final tasks = {for (final task in preview.tasks) task.orderItemId: task};
      for (final item in items) {
        final task = tasks[item.orderItemId];
        if (task == null ||
            positiveDocumentQuantityText(task.defaultInputQtyText ?? '') !=
                (item.materialQty ?? item.qty) ||
            task.materialPlanItemId != item.materialPlanItemId) {
          throw const FormatException('领料核对结果有变化，请返回任务中心重新选择');
        }
      }
      setState(() {
        _preview = preview;
        _tasks.addAll(tasks);
        _previewDirty = false;
        _liveMaxima.clear();
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

  void _recordStockError(ApiException error) {
    _submitError = _message(error);
    _liveMaxima.clear();
    final details = error.details;
    if (details?['kind'] != 'SUBCONTRACT_DRAW_QUANTITY_EXCEEDED') return;
    final rows = details?['quantities'];
    if (rows is! List) return;
    for (final row in rows.whereType<Map<String, dynamic>>()) {
      final id = row['orderItemId'];
      final maximum = recordedDocumentDecimal(row, 'maximumQty');
      if (id is String && maximum != null && _tasks.containsKey(id)) {
        _liveMaxima[id] = maximum;
      }
    }
  }

  String? get _blocked {
    if (_loading) return '正在加载领料预览';
    if (_saving) return '正在提交领料，请稍候';
    if (_confirming) return '请确认本次领料';
    if (_uncertain) return _pendingItems == null ? '领料提交状态需要核对' : null;
    if (_order.isEmpty) return '没有可领料的委外任务，请返回委外任务中心重新选择';
    if (_order.any((id) => _quantityError(id) != null)) {
      return '请修正本次领料数量';
    }
    if (_previewDirty) return '请先核对本次领料的库存';
    if (!_edited &&
        _order.any((id) => _tasks[id]?.defaultInputQtyText == null)) {
      return '服务端未返回领料原数量，请刷新核对后提交';
    }
    if (_submitItems.isEmpty) return '本次没有可领料数量的委外任务，请返回委外任务中心重新选择';
    if (_preview?.lines.isEmpty ?? true) return '本次没有可发出的物料';
    return null;
  }

  String _idempotencyKey(List<SubcontractDrawRequestItem> items) {
    final canonical = [
      for (final item in [
        ...items,
      ]..sort((a, b) => a.orderItemId.compareTo(b.orderItemId)))
        '${item.orderItemId}:${item.qty}:${item.materialQty}:${item.materialPlanItemId}:'
            '${_tasks[item.orderItemId]?.quantityText('drawnQty')}:'
            '${_tasks[item.orderItemId]?.quantityText('drawableQty')}',
    ].join('|');
    return businessIdempotencyKey(
      'subcontract-draw',
      '$_attemptNonce|$canonical',
    );
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
                  AbsorbPointer(
                    absorbing: _saving || _loading,
                    child: UtenCollapsingHeaderScrollView(
                      collapsingHeader: _header(),
                      body: UtenPageEdgePadding(
                        padding: const EdgeInsets.all(UtenSpacing.s12),
                        child: _linesTable(),
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

  Widget _header() {
    final theme = Theme.of(context);
    final preview = _previewDirty ? null : _preview;
    return UtenPageEdgePadding(
      padding: const EdgeInsets.all(UtenSpacing.s12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Flexible(
                child: Text(
                  '${_order.length} 个委外任务'
                  '${preview == null ? '' : ' · ${preview.materialKindCount} 种物料 · 预计 ${preview.documentCount} 张出仓单'}',
                  key: const Key('subcontract-draw-request-summary'),
                  style: theme.textTheme.titleMedium,
                ),
              ),
              const UtenFieldHintIcon(
                info:
                    '单种物料填写实物量，多种物料按套备料。填 0 或留空可跳过这次领料。共用物料按交期、订货单号和行号分配。下表列出各仓的实际物料数量。',
                dense: true,
              ),
              if (!_uncertain &&
                  (_submitError == null || _liveMaxima.isNotEmpty))
                Padding(
                  padding: const EdgeInsetsDirectional.only(
                    start: UtenSpacing.s8,
                  ),
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      _liveMaxima.isNotEmpty
                          ? '库存不足'
                          : _previewDirty
                          ? '待核对库存'
                          : preview?.lines.isNotEmpty == true
                          ? '库存满足'
                          : '暂无可领',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: _liveMaxima.isEmpty
                            ? null
                            : theme.colorScheme.error,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          if (_notice != null) ...[
            const SizedBox(height: UtenSpacing.s8),
            Semantics(
              liveRegion: true,
              child: Text(
                _notice!,
                key: const Key('subcontract-draw-request-notice'),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.tertiary,
                ),
              ),
            ),
          ],
          if (_submitError != null) ...[
            const SizedBox(height: UtenSpacing.s8),
            Semantics(
              liveRegion: true,
              child: Text(
                _submitError!,
                key: const Key('subcontract-draw-request-error'),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          ],
          const SizedBox(height: UtenSpacing.s12),
          _quantityInputs(),
        ],
      ),
    );
  }

  Widget _quantityInputs() => LayoutBuilder(
    builder: (context, constraints) {
      final theme = Theme.of(context);
      final cardWidth = constraints.maxWidth.clamp(0.0, 340.0);
      return Wrap(
        key: const Key('subcontract-draw-request-tasks'),
        spacing: UtenSpacing.s12,
        runSpacing: UtenSpacing.s12,
        children: [
          for (final id in _order)
            if (_tasks[id] case final task?)
              SizedBox(
                width: cardWidth.toDouble(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${_label(task.orderBillNo)} · ${_label(task.goodsName)}',
                      style: theme.textTheme.bodyMedium,
                    ),
                    Text(
                      _maximumLabel(task),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: UtenSpacing.s4),
                    UtenInput(
                      key: ValueKey('subcontract-draw-request-qty-$id'),
                      label: task.usesMaterialQuantity
                          ? '本次领料${task.materialUnitName.isEmpty ? '' : '（${task.materialUnitName}）'}'
                          : '按套备料（套）',
                      controller: _quantities[id],
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      enabled:
                          !_saving && !_loading && !_uncertain && !_confirming,
                      onChanged: _quantityChanged,
                      errorMessage: _quantityError(id),
                    ),
                  ],
                ),
              ),
        ],
      );
    },
  );

  String _maximumLabel(SubcontractDrawPreviewTask task) {
    final live = _liveMaxima[task.orderItemId];
    final qty = formatExactQtyWithUnit(
      live ?? task.batchInputMaxText,
      task.usesMaterialQuantity ? task.materialUnitName : '套',
    );
    if (qty.isEmpty) return '本批可领 —';
    final checked =
        !_previewDirty &&
        (_preview?.tasks.any((row) => row.orderItemId == task.orderItemId) ??
            false);
    return '${live != null || checked ? '本批可领' : '上次核对可领'} $qty';
  }

  Widget _linesTable() => MasterDataTableView<SubcontractDrawPreviewLine>(
    tableKey:
        'features.subcontract.pages.subcontract_draw_request_page.SubcontractDrawRequestPageState._linesTable.1',
    key: const Key('subcontract-draw-request-lines'),
    primary: true,
    bottomContentPadding: UtenFloatingActionGroup.scrollClearance,
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
        value: (line) => _label(line.warehouseName),
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
        sortable: true,
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
      // 2026-10-10 数量+单位口径：单位内联在数量后(如 `12 PCS`)，独立单位列删除；
      // 原数量文本与单位同列显示，不对已记值取位。
      MasterColumnDef(
        key: 'qty',
        label: '本次领料数量',
        sortable: true,
        exactValueOf: (line) => line.quantityText('qty'),
        width: 130,
        type: 'number',
        value: (line) =>
            formatExactQtyWithUnit(line.quantityText('qty'), line.unitName),
      ),
      MasterColumnDef(
        key: 'warehouseAvailableQty',
        label: '仓库可用',
        sortable: true,
        exactValueOf: (line) => line.quantityText('warehouseAvailableQty'),
        width: 120,
        type: 'number',
        value: (line) => formatExactQtyWithUnit(
          line.quantityText('warehouseAvailableQty'),
          line.unitName,
        ),
      ),
      MasterColumnDef(
        key: 'task',
        label: '委外任务',
        sortable: true,
        filterFromRows: true,
        width: 200,
        value: (line) {
          final task = _tasks[line.orderItemId];
          if (task == null) return '—';
          return '${_label(task.orderBillNo)} · ${_label(task.goodsName)}';
        },
      ),
    ],
    items: _previewDirty ? const [] : _preview?.lines ?? const [],
    emptyMessage: _previewDirty ? '核对库存后显示出仓物料' : '本次没有可发出的物料',
  );

  static String _message(ApiException error) =>
      error.fieldErrors?.firstOrNull?.message.trim().isNotEmpty == true
      ? error.fieldErrors!.first.message
      : error.message;

  static String _label(String? value) =>
      value?.trim().isNotEmpty == true ? value!.trim() : '—';
}
