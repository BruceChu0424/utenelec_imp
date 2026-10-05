// ADR-143 §4.2 委外领料页(/operations/workbench/subcontract/draw-request?orderItemIds=...)。
//
// 照车间「领料汇总」页：头部「N 个委外任务 · M 种物料 · 预计 K 张出仓单」；
// 任务表逐行填写本次领料数量(默认 = 本批可领，即同一批量领料按「交期、订货单号、
// 行号」先后联合分配共享物料后的可领量)；物料表是服务端预览出的「领料仓库 × 物料」
// 出仓明细，改数量后 300ms 去抖重新预览。数量只在服务端算，页面不推算。
// 提交带幂等键(每次进页/每次有了确定结果都换一个新的随机串，只在结果未确认时
// 沿用同一键重试)；服务端在锁内按同一顺序重算，实时可领低于提交量时 409，
// 页面重新预览并按实时本批可领回填，用户核对后再提交。
// 填 0 = 本次不领该任务(不参与预览分配，也不提交)。
// 所选任务已领满 / 已结束领料时预览整批 409：只给「返回委外任务中心」，回去重新勾选。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/idempotency_key.dart';
import '../../../shared/badges/badge_registry.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/subcontract_draw.dart';
import '../repositories/subcontract_draw_repository.dart';
import '../widgets/subcontract_draw_status.dart';

class SubcontractDrawRequestPage extends ConsumerStatefulWidget {
  const SubcontractDrawRequestPage({
    super.key,
    required this.orderItemIds,
    this.repository,
  });

  final List<String> orderItemIds;

  /// 测试注入；默认取 [subcontractDrawRepositoryProvider]。
  final SubcontractDrawGateway? repository;

  /// 改数量后重新预览的去抖时长。
  static const previewDebounce = Duration(milliseconds: 300);

  @override
  ConsumerState<SubcontractDrawRequestPage> createState() =>
      _SubcontractDrawRequestPageState();
}

class _SubcontractDrawRequestPageState
    extends ConsumerState<SubcontractDrawRequestPage> {
  /// 任务顺序(首次预览的服务端顺序 = 联合分配顺序)。
  final _order = <String>[];

  /// 每个任务最近一次参与预览时的服务端事实(填 0 移出本批后保留最后一次的值)。
  final _tasks = <String, SubcontractDrawPreviewTask>{};
  final _quantities = <String, TextEditingController>{};
  final _quantityErrors = <String, String>{};

  /// 用户手动改过数量的任务；未改过的任务跟随服务端本批可领默认值。
  final _touched = <String>{};
  SubcontractDrawPreview? _preview;

  bool _loading = true;
  bool _previewing = false;
  bool _saving = false;
  bool _uncertain = false;
  String? _loadError;

  /// 预览整批 409(所选任务里有已领满 / 已结束领料 / 不再可见的)：同一批重试永远失败，
  /// 出错页只给「返回委外任务中心」。
  bool _loadConflict = false;
  String? _previewError;
  String? _submitError;
  String? _notice;
  Timer? _debounce;
  int _previewRequest = 0;

  /// 结果未确认(断网/超时/5xx)时冻结的幂等键：重试沿用同一键，不会重复建单。
  String? _pendingKey;

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
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    for (final controller in _quantities.values) {
      controller.dispose();
    }
    super.dispose();
  }

  /// 全量重新预览：所有任务按服务端本批可领默认值回填(首次进入、409 回填、手动刷新)。
  Future<void> _load({String? notice}) async {
    if (!mounted || _saving) return;
    _debounce?.cancel();
    final request = ++_previewRequest;
    setState(() {
      _loading = true;
      _previewing = false;
      _loadError = null;
      _loadConflict = false;
      _previewError = null;
      _submitError = null;
      _uncertain = false;
      _pendingKey = null;
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
      if (!mounted || request != _previewRequest) return;
      // 旧输入框可能还挂在本帧的树上：换上新控制器后，下一帧再释放旧的。
      final stale = _quantities.values.toList(growable: false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        for (final controller in stale) {
          controller.dispose();
        }
      });
      setState(() {
        _preview = preview;
        _order
          ..clear()
          ..addAll(preview.tasks.map((task) => task.orderItemId));
        _tasks
          ..clear()
          ..addEntries(
            preview.tasks.map((task) => MapEntry(task.orderItemId, task)),
          );
        _touched.clear();
        _quantityErrors.clear();
        _quantities
          ..clear()
          ..addEntries(
            preview.tasks.map(
              (task) => MapEntry(
                task.orderItemId,
                TextEditingController(text: subcontractDrawQty(task.qty)),
              ),
            ),
          );
        _loading = false;
      });
    } on ApiException catch (error) {
      if (!mounted || request != _previewRequest) return;
      setState(() {
        _loading = false;
        _loadError = _message(error);
        _loadConflict = error.httpStatus == 409;
      });
    } on FormatException catch (error) {
      if (!mounted || request != _previewRequest) return;
      setState(() {
        _loading = false;
        _loadError = error.message;
      });
    } catch (_) {
      if (!mounted || request != _previewRequest) return;
      setState(() {
        _loading = false;
        _loadError = '领料预览加载失败，请重新加载';
      });
    }
  }

  /// 某任务输入框的数值；不可解析返回 null。
  num? _inputOf(String id) => num.tryParse(_quantities[id]?.text.trim() ?? '');

  /// 用户填 0 = 本次不领(移出本批)。
  bool _excluded(String id) => _touched.contains(id) && _inputOf(id) == 0;

  String? _quantityError(String id) {
    final task = _tasks[id];
    if (task == null) return null;
    final input = _quantities[id]?.text.trim() ?? '';
    final value = num.tryParse(input);
    if (value == null || !value.isFinite || value < 0) {
      return '请输入不小于 0 的本次领料数量';
    }
    if (!RegExp(r'^\d+(\.\d{1,4})?$').hasMatch(input)) {
      return '数量最多支持 4 位小数';
    }
    if (value > task.batchDrawableQty + 0.00000001) {
      return '不能超过本批可领 ${subcontractDrawQty(task.batchDrawableQty)}';
    }
    return null;
  }

  void _onQuantityChanged(String id) {
    _touched.add(id);
    final error = _quantityError(id);
    setState(() {
      _submitError = null;
      if (error == null) {
        _quantityErrors.remove(id);
      } else {
        _quantityErrors[id] = error;
      }
    });
    _debounce?.cancel();
    if (_quantityErrors.isNotEmpty) return;
    _debounce = Timer(SubcontractDrawRequestPage.previewDebounce, _repreview);
  }

  /// 去抖后的重新预览：改过的任务带本次数量，没改过的任务带 null 跟随服务端默认。
  Future<void> _repreview() async {
    if (!mounted || _saving || _uncertain) return;
    final request = ++_previewRequest;
    final items = [
      for (final id in _order)
        if (!_excluded(id))
          SubcontractDrawRequestItem(
            orderItemId: id,
            qty: _touched.contains(id) ? _inputOf(id) : null,
          ),
    ];
    if (items.isEmpty) {
      setState(() {
        _previewing = false;
        _previewError = null;
        _preview = const SubcontractDrawPreview(
          tasks: [],
          lines: [],
          documentCount: 0,
        );
      });
      return;
    }
    setState(() {
      _previewing = true;
      _previewError = null;
    });
    try {
      final preview = await _gateway.preview(items);
      if (!mounted || request != _previewRequest) return;
      setState(() {
        _preview = preview;
        for (final task in preview.tasks) {
          _tasks[task.orderItemId] = task;
          if (!_touched.contains(task.orderItemId)) {
            _quantities[task.orderItemId]?.text = subcontractDrawQty(task.qty);
          }
        }
        _quantityErrors
          ..clear()
          ..addEntries([
            for (final id in _order)
              if (_quantityError(id) case final error?) MapEntry(id, error),
          ]);
        _previewing = false;
      });
    } on ApiException catch (error) {
      if (!mounted || request != _previewRequest) return;
      setState(() {
        _previewing = false;
        _previewError = _message(error);
      });
    } catch (_) {
      if (!mounted || request != _previewRequest) return;
      setState(() {
        _previewing = false;
        _previewError = '领料预览刷新失败，请按实时可领量重新填写';
      });
    }
  }

  /// 本次真正提交的任务(数量 > 0)。
  List<SubcontractDrawRequestItem> get _submitItems => [
    for (final id in _order)
      if (_inputOf(id) case final qty? when qty > 0)
        SubcontractDrawRequestItem(orderItemId: id, qty: qty),
  ];

  String? get _blocked {
    if (_loading) return '正在加载领料预览';
    if (_saving) return '正在提交领料，请稍候';
    if (_order.isEmpty) return '没有可领料的委外任务，请返回委外任务中心重新选择';
    if (_quantityErrors.isNotEmpty) return _quantityErrors.values.first;
    if (_debounce?.isActive == true || _previewing) {
      return '正在按新数量重新核对物料，请稍候';
    }
    if (_previewError != null) return '可领量已变化，请按实时可领量重新填写后再提交';
    if (_submitItems.isEmpty) return '请至少给一个委外任务填写大于 0 的本次领料数量';
    if (_preview?.lines.isEmpty ?? true) return '本次没有可发出的物料';
    return null;
  }

  String _idempotencyKey(List<SubcontractDrawRequestItem> items) {
    final canonical = [
      for (final item in [
        ...items,
      ]..sort((a, b) => a.orderItemId.compareTo(b.orderItemId)))
        '${item.orderItemId}:${item.qty}:'
            '${_tasks[item.orderItemId]?.drawnQty}:'
            '${_tasks[item.orderItemId]?.drawableQty}',
    ].join('|');
    return businessIdempotencyKey(
      'subcontract-draw',
      '$_attemptNonce|$canonical',
    );
  }

  Future<void> _submit() async {
    if (_blocked != null) return;
    final items = _submitItems;
    final key = _pendingKey ?? _idempotencyKey(items);
    setState(() {
      _saving = true;
      _submitError = null;
      _notice = null;
      _pendingKey = key;
    });
    try {
      final result = await _gateway.submit(items: items, idempotencyKey: key);
      if (!mounted) return;
      _pendingKey = null;
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
      if (!mounted) return;
      final uncertain =
          error is NetworkException ||
          error is NetworkTimeoutException ||
          error.code == 'NETWORK' ||
          error.code == 'NETWORK_TIMEOUT' ||
          error.code == 'INTERNAL' ||
          (error.httpStatus != null && error.httpStatus! >= 500);
      if (uncertain) {
        setState(() {
          _saving = false;
          _uncertain = true;
          _submitError = '暂未确认领料结果，请点击「重试领料」继续本批提交；数量保持原提交内容。';
        });
        return;
      }
      _pendingKey = null;
      _attemptNonce = _newNonce();
      setState(() => _saving = false);
      if (error.httpStatus == 409) {
        // 实时可领低于提交量：按实时本批可领重新预览并回填，用户核对后再提交。
        await _load(notice: '${_message(error)}。已按实时本批可领重新填写，请核对后再提交。');
        return;
      }
      setState(() => _submitError = _message(error));
    } catch (_) {
      if (!mounted) return;
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
    final blocked = _blocked;
    final ready = !_loading && _loadError == null && _order.isNotEmpty;
    return PopScope(
      canPop: !_saving,
      child: Scaffold(
        appBar: UtenAppBar(
          title: '委外领料',
          leading: UtenBackButton(onPressed: _saving ? null : _back),
          actions: [
            IconButton(
              key: const Key('subcontract-draw-request-refresh'),
              tooltip: _uncertain ? '请先重试领料，确认本批结果' : '按实时可领量重新填写',
              onPressed: _loading || _saving || _uncertain ? null : _load,
              icon: const Icon(Icons.refresh_rounded),
            ),
            const SizedBox(width: UtenSpacing.s8),
          ],
        ),
        body: SafeArea(
          child: UtenContentContainer.wide(
            child: Stack(
              children: [
                if (_loading)
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
                    absorbing: _saving,
                    child: UtenCollapsingHeaderScrollView(
                      collapsingHeader: _header(),
                      body: Padding(
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
                children: [
                  UtenButton(
                    type: UtenButtonType.secondary,
                    size: UtenButtonSize.large,
                    onPressed: _saving ? null : _back,
                    child: const Text('返回'),
                  ),
                  UtenButton(
                    key: const Key('subcontract-draw-request-submit'),
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

  Widget _header() {
    final theme = Theme.of(context);
    final preview = _preview;
    final included = _order.where((id) => !_excluded(id)).length;
    return Padding(
      padding: const EdgeInsets.all(UtenSpacing.s12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '$included 个委外任务 · ${preview?.materialKindCount ?? 0} 种物料 · '
            '预计 ${preview?.documentCount ?? 0} 张出仓单',
            key: const Key('subcontract-draw-request-summary'),
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: UtenSpacing.s8),
          Text(
            '本次领料数量默认等于本批可领：多个任务共用同一种物料时，按交期、订货单号、行号先后分配。'
            '可以改小，填 0 表示本次不领该任务。提交后仓库按领料仓库发出直属物料，委外商加工后分批回厂。',
            style: theme.textTheme.bodySmall,
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
          if (_previewError != null || _submitError != null) ...[
            const SizedBox(height: UtenSpacing.s8),
            Semantics(
              liveRegion: true,
              child: Text(
                _submitError ?? _previewError!,
                key: const Key('subcontract-draw-request-error'),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
            if (_previewError != null && !_saving)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const Key('subcontract-draw-request-refill'),
                  onPressed: _load,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('按实时可领重新填写'),
                ),
              ),
          ],
          const SizedBox(height: UtenSpacing.s12),
          SizedBox(
            height: (96 + 52.0 * _order.length).clamp(180.0, 420.0),
            child: _tasksTable(),
          ),
          const SizedBox(height: UtenSpacing.s12),
          Row(
            children: [
              Text('本次出仓物料', style: theme.textTheme.titleSmall),
              if (_previewing) ...[
                const SizedBox(width: UtenSpacing.s8),
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: UtenSpacing.s4),
                Text('正在重新核对…', style: theme.textTheme.bodySmall),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _tasksTable() {
    final rows = [for (final id in _order) ?_tasks[id]];
    final editable = !_saving && !_uncertain;
    return MasterDataTableView<SubcontractDrawPreviewTask>(
      tableKey:
          'features.subcontract.pages.subcontract_draw_request_page.SubcontractDrawRequestPageState._tasksTable.1',
      key: const Key('subcontract-draw-request-tasks'),
      facets: const {},
      nullCounts: const {},
      filters: const {},
      onFilterChanged: (_, _) {},
      showFullscreenToggle: false,
      rowKeyOf: (task) => task.orderItemId,
      columns: [
        MasterColumnDef(
          key: 'orderBillNo',
          label: '委外订货单号',
          width: 150,
          value: (task) => _label(task.orderBillNo),
        ),
        MasterColumnDef(
          key: 'supplierName',
          label: '委外商',
          width: 150,
          value: (task) => _label(task.supplierName),
        ),
        MasterColumnDef(
          key: 'goodsName',
          label: '委外件名称',
          width: 180,
          value: (task) => _label(task.goodsName),
        ),
        MasterColumnDef(
          key: 'goodsCode',
          label: '编号',
          width: 130,
          value: (task) => _label(task.goodsCode),
        ),
        MasterColumnDef(
          key: 'colorName',
          label: '颜色',
          width: 90,
          value: (task) => _label(task.colorName),
        ),
        MasterColumnDef(
          key: 'unitName',
          label: '单位',
          width: 70,
          value: (task) => _label(task.unitName),
        ),
        _qtyColumn('orderQty', '订货数量', (task) => task.orderQty),
        _qtyColumn('drawnQty', '已领', (task) => task.drawnQty),
        _qtyColumn('drawableQty', '可领', (task) => task.drawableQty),
        _qtyColumn(
          'batchDrawableQty',
          '本批可领',
          (task) => task.batchDrawableQty,
          info: '同一批领料里多个任务共用同一种物料时，按交期、订货单号、行号先后分配后本任务还能领的数量。',
        ),
        MasterColumnDef(
          key: 'qty',
          label: '本次领料数量',
          info: '大于 0 且不超过本批可领，最多 4 位小数；填 0 表示本次不领该任务。',
          width: 170,
          type: 'number',
          value: (task) => _quantities[task.orderItemId]?.text,
          exactValueOf: (task) => _quantities[task.orderItemId]?.text,
          exactListenableOf: (task) => _quantities[task.orderItemId],
          cellBuilder: (context, task) => TextField(
            key: ValueKey('subcontract-draw-qty-${task.orderItemId}'),
            controller: _quantities[task.orderItemId],
            enabled: editable,
            textAlign: TextAlign.right,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: UtenInputDecoration(
              InputDecoration(
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 8,
                ),
                error: _quantityErrors[task.orderItemId] == null
                    ? null
                    : UtenFieldMessage.error(
                        _quantityErrors[task.orderItemId]!,
                      ),
              ),
            ),
            onChanged: (_) => _onQuantityChanged(task.orderItemId),
          ),
        ),
      ],
      items: rows,
      emptyMessage: '暂无委外任务',
    );
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
        width: 160,
        value: (line) => _label(line.warehouseName),
      ),
      MasterColumnDef(
        key: 'goodsName',
        label: '物料名称',
        width: 200,
        value: (line) => _label(line.goodsName),
      ),
      MasterColumnDef(
        key: 'goodsCode',
        label: '编号',
        width: 130,
        value: (line) => _label(line.goodsCode),
      ),
      MasterColumnDef(
        key: 'colorName',
        label: '颜色',
        width: 90,
        value: (line) => _label(line.colorName),
      ),
      MasterColumnDef(
        key: 'unitName',
        label: '单位',
        width: 70,
        value: (line) => _label(line.unitName),
      ),
      MasterColumnDef(
        key: 'qty',
        label: '本次领料数量',
        width: 120,
        type: 'number',
        value: (line) => subcontractDrawQty(line.qty),
      ),
      MasterColumnDef(
        key: 'warehouseAvailableQty',
        label: '仓库可用',
        width: 110,
        type: 'number',
        value: (line) => subcontractDrawQty(line.warehouseAvailableQty),
      ),
      MasterColumnDef(
        key: 'task',
        label: '委外任务',
        width: 200,
        value: (line) {
          final task = _tasks[line.orderItemId];
          if (task == null) return '—';
          return '${_label(task.orderBillNo)} · ${_label(task.goodsName)}';
        },
      ),
    ],
    items: _preview?.lines ?? const [],
    emptyMessage: '本次没有可发出的物料',
  );

  MasterColumnDef<SubcontractDrawPreviewTask> _qtyColumn(
    String key,
    String label,
    double Function(SubcontractDrawPreviewTask task) qty, {
    String? info,
  }) => MasterColumnDef(
    key: key,
    label: label,
    info: info,
    width: 100,
    type: 'number',
    value: (task) => subcontractDrawQty(qty(task)),
  );

  static String _message(ApiException error) =>
      error.fieldErrors?.firstOrNull?.message.trim().isNotEmpty == true
      ? error.fieldErrors!.first.message
      : error.message;

  static String _label(String? value) =>
      value?.trim().isNotEmpty == true ? value!.trim() : '—';
}
