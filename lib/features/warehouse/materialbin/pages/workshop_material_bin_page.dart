// 车间内料仓页 (/workshop-material/bin?workshopId=, ADR-131 §8.1)。
//
// 车间看: 内料仓里每种料的账面、本期领入 / 退回 / 其它耗用、估计已用与估计还剩、
// 仓库还有多少; 顶部是盘点与自动结算状态 ("差什么、谁来补")。
// 操作: 申请领料、退回、其它耗用、盘点、记录。按钮只按服务端下发的 allowedActions 显示。
// 车间成员只看本车间 (服务端按对象范围过滤); 多个车间时顶部切换。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../../../components/buttons/uten_back_button.dart';
import '../../../../components/buttons/uten_button.dart';
import '../../../../components/feedback/uten_busy_overlay.dart';
import '../../../../components/feedback/uten_context_menu.dart';
import '../../../../components/feedback/uten_empty.dart';
import '../../../../components/feedback/uten_inline_notice.dart';
import '../../../../components/layout/uten_app_bar.dart';
import '../../../../components/layout/uten_content_container.dart';
import '../../../../components/layout/uten_filter_toolbar.dart';
import '../../../../core/l10n/gen/app_localizations.dart';
import '../../../../core/network/api_exception.dart';
import '../../../../core/router/nav_helpers.dart';
import '../../../../core/router/page_resume_provider.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/uten_tokens.dart';
import '../../../../core/ui/app_notification.dart';
import '../../../../core/utils/china_datetime.dart';
import '../../../../shared/models/paged_result.dart';
import '../../../basic_data/widgets/master_data_table_view.dart';
import '../models/workshop_material_models.dart';
import '../repositories/workshop_material_repository.dart';
import '../widgets/workshop_material_close_poller.dart';
import '../widgets/workshop_material_close_status_banner.dart';
import '../widgets/workshop_material_labels.dart';
import '../widgets/workshop_material_other_issue_dialog.dart';
import '../widgets/workshop_material_request_dialog.dart';

class WorkshopMaterialBinPage extends ConsumerStatefulWidget {
  const WorkshopMaterialBinPage({super.key, this.workshopId});

  /// 深链指定的车间 (通知"结算被拦住"落点带它); 为空时取第一个已开启的车间。
  final String? workshopId;

  @override
  ConsumerState<WorkshopMaterialBinPage> createState() =>
      _WorkshopMaterialBinPageState();
}

class _WorkshopMaterialBinPageState
    extends ConsumerState<WorkshopMaterialBinPage> {
  static const _viewStock = 'stock';
  static const _viewHistory = 'history';

  final _nonce = const Uuid().v4();
  List<WmSetting>? _settings;
  String? _workshopId;
  WmPosition? _position;
  List<WmPeriod> _periods = const [];
  WmPeriod? _statusPeriod;
  WmCloseStatus? _closeStatus;
  bool _loading = true;
  String? _error;
  bool _retrying = false;
  String _view = _viewStock;
  PagedResult<WmRequisition>? _history;
  bool _historyLoading = false;
  String? _historyError;
  String? _busyTitle;
  String? _myLocation;
  int _loadSeq = 0;
  late final WmClosePoller _poller = WmClosePoller(
    load: () => ref
        .read(workshopMaterialRepositoryProvider)
        .closeStatus(_statusPeriod!.id),
    onStatus: (status) {
      if (!mounted) return;
      setState(() => _closeStatus = status);
      if (!status.settling) _reloadWorkshop();
    },
  );

  WorkshopMaterialRepository get _repo =>
      ref.read(workshopMaterialRepositoryProvider);

  List<WmSetting> get _enabled => [
    for (final s in _settings ?? const <WmSetting>[])
      if (s.periodicEnabled && s.binWarehouseId != null) s,
  ];

  WmSetting? get _current {
    for (final s in _enabled) {
      if (s.workshopDepartmentId == _workshopId) return s;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _workshopId = widget.workshopId;
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadAll());
  }

  @override
  void dispose() {
    _poller.stop();
    super.dispose();
  }

  Future<void> _loadAll() async {
    final seq = ++_loadSeq;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final settings = await _repo.settings();
      if (!mounted || seq != _loadSeq) return;
      _settings = settings;
      final enabled = _enabled;
      if (!enabled.any((s) => s.workshopDepartmentId == _workshopId)) {
        _workshopId = enabled.isEmpty
            ? null
            : enabled.first.workshopDepartmentId;
      }
      await _loadWorkshop(seq);
    } on ApiException catch (e) {
      if (mounted && seq == _loadSeq) {
        setState(() {
          _loading = false;
          _error = e.message;
        });
      }
    } catch (_) {
      if (mounted && seq == _loadSeq) {
        setState(() {
          _loading = false;
          _error = '加载失败, 请重试';
        });
      }
    }
  }

  Future<void> _reloadWorkshop() async {
    final seq = ++_loadSeq;
    try {
      await _loadWorkshop(seq);
    } on ApiException catch (e) {
      if (mounted && seq == _loadSeq) setState(() => _error = e.message);
    } catch (_) {
      if (mounted && seq == _loadSeq) setState(() => _error = '刷新失败, 请重试');
    }
  }

  /// 读当前车间的现存、期间与结算状态 (异常由调用方处理)。
  Future<void> _loadWorkshop(int seq) async {
    if (!mounted) return;
    final setting = _current;
    if (setting == null) {
      setState(() {
        _position = null;
        _periods = const [];
        _statusPeriod = null;
        _closeStatus = null;
        _loading = false;
      });
      return;
    }
    final binId = setting.binWarehouseId!;
    final results = await Future.wait<Object>([
      _repo.position(binId),
      _repo.periods(binId),
    ]);
    if (!mounted || seq != _loadSeq) return;
    final position = results[0] as WmPosition;
    final periods = [...results[1] as List<WmPeriod>]
      ..sort((a, b) => a.periodNo.compareTo(b.periodNo));
    // 顶部状态说的是最早一期"盘点中 / 已盘点未结算"的那一期 (期间按顺序结算)。
    WmPeriod? statusPeriod;
    for (final p in periods) {
      if (p.status == WmPeriodStatus.counting ||
          p.status == WmPeriodStatus.counted) {
        statusPeriod = p;
        break;
      }
    }
    statusPeriod ??= _periodById(periods, position.periodId);
    WmCloseStatus? closeStatus;
    if (statusPeriod != null && statusPeriod.status == WmPeriodStatus.counted) {
      closeStatus = await _repo.closeStatus(statusPeriod.id);
      if (!mounted || seq != _loadSeq) return;
    } else if (statusPeriod != null) {
      closeStatus = WmCloseStatus(
        status: statusPeriod.status,
        closeState: statusPeriod.closeState,
        allowedActions: statusPeriod.allowedActions,
      );
    } else if (position.periodStatus != null) {
      closeStatus = WmCloseStatus(
        status: position.periodStatus!,
        closeState: position.closeState,
        blockers: position.blockers,
        heldUntil: position.heldUntil,
        allowedActions: position.allowedActions,
      );
    }
    setState(() {
      _position = position;
      _periods = periods;
      _statusPeriod = statusPeriod;
      _closeStatus = closeStatus;
      _loading = false;
      _error = null;
    });
    if (closeStatus != null && closeStatus.settling && statusPeriod != null) {
      if (!_poller.active) _poller.start();
    }
    if (_view == _viewHistory) _loadHistory(1);
  }

  WmPeriod? _periodById(List<WmPeriod> periods, String? id) {
    if (id == null) return null;
    for (final p in periods) {
      if (p.id == id) return p;
    }
    return null;
  }

  Future<void> _loadHistory(int page) async {
    final setting = _current;
    if (setting == null) return;
    setState(() {
      _historyLoading = true;
      _historyError = null;
    });
    try {
      final result = await _repo.requisitions(
        workshopId: setting.workshopDepartmentId,
        page: page,
      );
      if (!mounted) return;
      setState(() {
        _history = result;
        _historyLoading = false;
      });
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _historyLoading = false;
          _historyError = e.message;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _historyLoading = false;
          _historyError = '加载记录失败, 请重试';
        });
      }
    }
  }

  Map<String, WmPositionRow> get _positionByKey => {
    for (final row in _position?.rows ?? const <WmPositionRow>[]) row.key: row,
  };

  Future<void> _openRequest(String kind) async {
    final setting = _current;
    if (setting == null) return;
    final done = await showWorkshopMaterialRequestSheet(
      context,
      kind: kind,
      workshopId: setting.workshopDepartmentId,
      workshopName: setting.workshopName,
      positionByKey: _positionByKey,
    );
    if (done == true && mounted) await _reloadWorkshop();
  }

  Future<void> _openOtherIssue() async {
    final setting = _current;
    if (setting == null) return;
    final rows = [
      for (final row in _position?.rows ?? const <WmPositionRow>[])
        if (row.bookQty > 0) row,
    ];
    if (rows.isEmpty) {
      context.appWarning('内料仓里现在没有料, 不用登记其它耗用');
      return;
    }
    final done = await showWorkshopMaterialOtherIssueDialog(
      context,
      workshopId: setting.workshopDepartmentId,
      materials: rows,
    );
    if (done == true && mounted) await _reloadWorkshop();
  }

  /// 盘点: 有"盘点中"的一期就接着盘; 否则进开着的那一期 (盘点页里点"开始盘点")。
  Future<void> _openCount() async {
    WmPeriod? target;
    for (final p in _periods) {
      if (p.status == WmPeriodStatus.counting) target = p;
    }
    if (target == null) {
      for (final p in _periods) {
        if (p.status == WmPeriodStatus.open) target = p;
      }
    }
    final periodId = target?.id ?? _current?.currentPeriod?.id;
    if (periodId == null) {
      context.appWarning('还没有可盘点的一期, 请刷新后再试');
      return;
    }
    await context.push(RoutePath.workshopMaterialCount(periodId));
  }

  Future<void> _retryClose() async {
    final period = _statusPeriod;
    if (period == null) return;
    setState(() => _retrying = true);
    try {
      final status = await _repo.closeRetry(
        period.id,
        idempotencyKey: wmIdempotencyKey('close-retry', _nonce, {
          'period': period.id,
          'at': DateTime.now().millisecondsSinceEpoch ~/ 60000,
        }),
      );
      if (!mounted) return;
      setState(() => _closeStatus = status);
      _poller.start();
    } on ApiException catch (e) {
      if (mounted) context.appWarning(e.message);
    } catch (_) {
      if (mounted) context.appWarning('没能发起重新结算, 请稍后再试');
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  Future<void> _cancelRequisition(WmRequisition requisition) async {
    final reason = await _askReason(
      title: '取消这张申请',
      label: '取消原因',
      confirm: '取消申请',
    );
    if (reason == null || !mounted) return;
    setState(() => _busyTitle = '正在取消申请');
    try {
      await _repo.cancelRequisition(
        requisition.id,
        expectedVersion: requisition.rowVersion,
        reason: reason,
        idempotencyKey: wmIdempotencyKey('cancel', _nonce, {
          'id': requisition.id,
          'v': requisition.rowVersion,
          'reason': reason,
        }),
      );
      if (!mounted) return;
      setState(() => _busyTitle = null);
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      context.appSuccess('已取消 ${requisition.requestNo}');
      await _reloadWorkshop();
    } on ApiException catch (e) {
      if (mounted) {
        setState(() => _busyTitle = null);
        context.appWarning(e.message);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _busyTitle = null);
        context.appWarning('网络不稳定, 请刷新后看看是否已取消');
      }
    }
  }

  Future<String?> _askReason({
    required String title,
    required String label,
    required String confirm,
  }) async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: TextField(
          key: const Key('wm-reason-input'),
          controller: controller,
          autofocus: true,
          maxLength: 500,
          decoration: InputDecoration(labelText: label, counterText: ''),
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          UtenButton(
            type: UtenButtonType.ghost,
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('返回'),
          ),
          UtenButton(
            type: UtenButtonType.danger,
            onPressed: () {
              final text = controller.text.trim();
              if (text.length < 2) return;
              Navigator.of(dialogContext).pop(text);
            },
            child: Text(confirm),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    _myLocation ??= currentLocationOr(context, RouteName.workshopMaterialBin);
    ref.onPageResume(
      _myLocation!,
      _reloadWorkshop,
      onReturn: () {
        if (_busyTitle != null) setState(() => _busyTitle = null);
      },
    );
    final setting = _current;
    final title = setting == null
        ? l10n.workshopMaterialBin
        : l10n.workshopMaterialBinOf(setting.workshopName);
    return Scaffold(
      appBar: UtenAppBar(
        title: title,
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.dashboard),
        ),
        actions: [
          IconButton(
            key: const Key('wm-bin-refresh'),
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新',
            onPressed: () {
              setState(() => _busyTitle = null);
              _loadAll();
            },
          ),
        ],
      ),
      body: SafeArea(
        child: Stack(
          children: [
            UtenContentContainer.wide(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s12),
                child: _body(l10n, theme),
              ),
            ),
            if (_busyTitle != null) UtenBusyOverlay(title: _busyTitle!),
          ],
        ),
      ),
    );
  }

  Widget _body(AppLocalizations l10n, ThemeData theme) {
    if (_loading && _settings == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _settings == null) {
      return UtenEmpty.error(
        message: _error,
        actionLabel: '重试',
        onAction: _loadAll,
      );
    }
    final enabled = _enabled;
    if (enabled.isEmpty) {
      return UtenEmpty(
        icon: Icons.inventory_2_outlined,
        message: '还没有开启整批领料的车间',
        description: '请找仓库在"${l10n.workshopMaterialSetup}"里开启。',
      );
    }
    final position = _position;
    final status = _closeStatus;
    final statusPeriod = _statusPeriod;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (enabled.length > 1) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s4),
            child: UtenFilterToolbar<String>(
              segmentsKey: const Key('wm-bin-workshops'),
              segments: [
                for (final s in enabled)
                  UtenFilterSegment(
                    value: s.workshopDepartmentId,
                    label: s.workshopName,
                  ),
              ],
              selected: {?_workshopId},
              onSelectionChanged: (value) {
                setState(() {
                  _workshopId = value;
                  _history = null;
                });
                _poller.stop();
                _reloadWorkshop();
              },
            ),
          ),
          const SizedBox(height: UtenSpacing.s8),
        ],
        if (status != null && status.status != WmPeriodStatus.open) ...[
          WmCloseStatusBanner(
            status: status,
            periodLabel: statusPeriod == null
                ? null
                : wmPeriodLabel(statusPeriod),
            onRetry: _retryClose,
            retrying: _retrying,
          ),
          const SizedBox(height: UtenSpacing.s8),
        ],
        if (_error != null) ...[
          UtenInlineNotice(
            level: UtenInlineNoticeLevel.error,
            message: _error!,
          ),
          const SizedBox(height: UtenSpacing.s8),
        ],
        _actions(l10n, position),
        const SizedBox(height: UtenSpacing.s8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s4),
          child: UtenFilterToolbar<String>(
            segmentsKey: const Key('wm-bin-view'),
            segments: [
              UtenFilterSegment(value: _viewStock, label: l10n.wmOnHand),
              UtenFilterSegment(value: _viewHistory, label: l10n.wmHistory),
            ],
            selected: {_view},
            onSelectionChanged: (value) {
              setState(() => _view = value);
              if (value == _viewHistory && _history == null) _loadHistory(1);
            },
            trailing: _current?.currentPeriod == null
                ? null
                : Text(
                    '本期: ${wmPeriodLabel(_current!.currentPeriod!)}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
          ),
        ),
        const SizedBox(height: UtenSpacing.s8),
        Expanded(
          child: _view == _viewHistory
              ? _historyTable(l10n)
              : _stockTable(l10n, position),
        ),
      ],
    );
  }

  Widget _actions(AppLocalizations l10n, WmPosition? position) {
    bool can(String action) => position?.can(action) ?? false;
    final buttons = <Widget>[
      if (can(WmAction.request))
        UtenButton(
          key: const Key('wm-bin-request'),
          icon: Icons.add_shopping_cart_outlined,
          onPressed: () => _openRequest('ISSUE'),
          child: Text(l10n.wmRequestIssue),
        ),
      if (can(WmAction.returnMaterial))
        UtenButton(
          key: const Key('wm-bin-return'),
          type: UtenButtonType.secondary,
          icon: Icons.assignment_return_outlined,
          onPressed: () => _openRequest('RETURN'),
          child: Text(l10n.wmReturn),
        ),
      if (can(WmAction.otherIssue))
        UtenButton(
          key: const Key('wm-bin-other-issue'),
          type: UtenButtonType.secondary,
          icon: Icons.science_outlined,
          onPressed: _openOtherIssue,
          child: Text(l10n.wmOtherIssue),
        ),
      if (can(WmAction.startCount) || can(WmAction.editCount))
        UtenButton(
          key: const Key('wm-bin-count'),
          type: UtenButtonType.tonal,
          icon: Icons.fact_check_outlined,
          onPressed: _openCount,
          child: Text(l10n.wmCount),
        ),
    ];
    if (buttons.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s4),
      child: Wrap(
        spacing: UtenSpacing.s8,
        runSpacing: UtenSpacing.s8,
        children: buttons,
      ),
    );
  }

  Widget _stockTable(AppLocalizations l10n, WmPosition? position) {
    final kg = l10n.wmKg;
    String qty(double v) => wmQty(v);
    return MasterDataTableView<WmPositionRow>(
      tableKey:
          'features.warehouse.materialbin.pages.workshop_material_bin_page.WorkshopMaterialBinPageState._stockTable.1',
      key: const Key('wm-bin-stock-table'),
      columns: [
        MasterColumnDef(
          key: 'goodsCode',
          label: '料号',
          width: 120,
          value: (r) => r.goodsCode,
        ),
        MasterColumnDef(
          key: 'goodsName',
          label: '料名',
          width: 170,
          value: (r) => r.goodsName,
        ),
        MasterColumnDef(
          key: 'colorName',
          label: '颜色',
          width: 90,
          value: (r) => r.colorName,
        ),
        MasterColumnDef(
          key: 'estimatedRemainingQty',
          label: '估计还剩 ($kg)',
          width: 120,
          type: 'number',
          value: (r) => qty(r.estimatedRemainingQty),
        ),
        MasterColumnDef(
          key: 'bookQty',
          label: '账面 ($kg)',
          width: 110,
          type: 'number',
          value: (r) => qty(r.bookQty),
        ),
        MasterColumnDef(
          key: 'lastCount',
          label: '上次盘点',
          width: 150,
          value: (r) => r.lastCountQty == null
              ? '还没盘过'
              : '${qty(r.lastCountQty!)} $kg (${r.lastCountDate ?? ''})',
        ),
        MasterColumnDef(
          key: 'periodInQty',
          label: '本期领入 ($kg)',
          width: 120,
          type: 'number',
          value: (r) => qty(r.periodInQty),
        ),
        MasterColumnDef(
          key: 'periodReturnQty',
          label: '本期退回 ($kg)',
          width: 120,
          type: 'number',
          value: (r) => qty(r.periodReturnQty),
        ),
        MasterColumnDef(
          key: 'periodOtherQty',
          label: '其它耗用 ($kg)',
          width: 120,
          type: 'number',
          value: (r) => qty(r.periodOtherQty),
        ),
        MasterColumnDef(
          key: 'estimatedUsedQty',
          label: '估计已用 ($kg)',
          width: 120,
          type: 'number',
          value: (r) => qty(r.estimatedUsedQty),
        ),
        MasterColumnDef(
          key: 'warehouseAvailableQty',
          label: '仓库还有 ($kg)',
          width: 120,
          type: 'number',
          value: (r) => qty(r.warehouseAvailableQty),
        ),
        MasterColumnDef(
          key: 'notes',
          label: '提示',
          width: 260,
          value: (r) => [
            if (r.missingWeightProducts > 0)
              '有 ${r.missingWeightProducts} 个产品没填单个重量, 估计已用偏少',
            if (r.draftReportCount > 0) '有 ${r.draftReportCount} 张报工还没审',
          ].join('; '),
        ),
      ],
      items: position?.rows ?? const [],
      facets: const {},
      nullCounts: const {},
      filters: const {},
      onFilterChanged: (_, _) {},
      rowKeyOf: (r) => r.key,
      isLoading: _loading && position == null,
      error: position == null ? _error : null,
      onRetry: _reloadWorkshop,
      emptyMessage: '内料仓里还没有料\n仓库直接发料或车间申请领料后, 这里会显示每种料的现存',
    );
  }

  Widget _historyTable(AppLocalizations l10n) {
    final page = _history;
    return MasterDataTableView<WmRequisition>(
      tableKey:
          'features.warehouse.materialbin.pages.workshop_material_bin_page.WorkshopMaterialBinPageState._historyTable.1',
      key: const Key('wm-bin-history-table'),
      columns: [
        MasterColumnDef(
          key: 'requestNo',
          label: '单号',
          width: 160,
          value: (r) => r.requestNo,
        ),
        MasterColumnDef(
          key: 'kind',
          label: '类型',
          width: 100,
          value: (r) => wmRequisitionKindLabel(l10n, r.kind),
        ),
        MasterColumnDef(
          key: 'origin',
          label: '来源',
          width: 120,
          value: (r) => wmRequisitionOriginLabel(r.origin),
        ),
        MasterColumnDef(
          key: 'material',
          label: '料',
          width: 200,
          value: (r) => r.materialSummary,
        ),
        MasterColumnDef(
          key: 'totalQty',
          label: l10n.wmKg,
          width: 100,
          type: 'number',
          value: (r) => wmQty(r.totalQty),
        ),
        MasterColumnDef(
          key: 'status',
          label: '状态',
          width: 90,
          value: (r) => wmRequisitionStatusLabel(r.status),
        ),
        MasterColumnDef(
          key: 'receiver',
          label: l10n.wmReceiver,
          width: 100,
          value: (r) => r.receiverName,
        ),
        MasterColumnDef(
          key: 'requestedBy',
          label: '申请人',
          width: 100,
          value: (r) => r.requestedByName,
        ),
        MasterColumnDef(
          key: 'requestedAt',
          label: '申请时间',
          width: 150,
          value: (r) => ChinaDateTime.formatIsoInstant(r.requestedAt),
        ),
        MasterColumnDef(
          key: 'doneAt',
          label: '完成时间',
          width: 150,
          value: (r) => ChinaDateTime.formatIsoInstant(r.doneAt),
        ),
      ],
      items: page?.items ?? const [],
      facets: const {},
      nullCounts: const {},
      filters: const {},
      onFilterChanged: (_, _) {},
      rowKeyOf: (r) => r.id,
      canShowRowMenu: (r) => r.isPending && r.can(WmAction.cancel),
      rowMenuBuilder: (r) => [
        if (r.isPending && r.can(WmAction.cancel))
          UtenMenuItem(
            label: '取消这张申请',
            icon: Icons.cancel_outlined,
            destructive: true,
            onTap: () => _cancelRequisition(r),
          ),
      ],
      isLoading: _historyLoading && page == null,
      loadingMore: _historyLoading && page != null,
      error: page == null ? _historyError : null,
      onRetry: () => _loadHistory(page?.page ?? 1),
      currentPage: page?.page ?? 1,
      totalPages: page?.totalPages ?? 1,
      onPageChange: _loadHistory,
      emptyMessage: '还没有领料、退回记录',
    );
  }
}
