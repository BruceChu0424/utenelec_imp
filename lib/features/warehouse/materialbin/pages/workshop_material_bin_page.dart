// 车间内料仓页 (/workshop-material/bin?workshopId=, ADR-131 §8.1)。
//
// 车间看: 内料仓里每种料的账面、本期领入 / 退回 / 其它耗用、估计已用与估计还剩、
// 仓库还有多少; 顶部是盘点与自动结算状态 ("差什么、谁来补")。
// 只开通、还没开启整批领料的内料仓 (ADR-147 已开通, 收车间直送) 只列现有的料与数量。
// 通用入口是车间总览 (唯一的车间清单, 开通/开启整批领料/撤销都在总览里批量办)。
// 操作: 申请领料、退回、其它耗用、盘点、记录。按钮只按服务端下发的 allowedActions 显示。
// 车间成员只看本车间 (服务端按对象范围过滤); 多个车间时顶部切换。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../../../components/buttons/uten_back_button.dart';
import '../../../../components/buttons/uten_button.dart';
import '../../../../components/data_display/uten_status_cell_color.dart';
import '../../../../components/feedback/uten_busy_overlay.dart';
import '../../../../components/feedback/uten_context_menu.dart';
import '../../../../components/feedback/uten_empty.dart';
import '../../../../components/feedback/uten_inline_notice.dart';
import '../../../../components/layout/uten_app_bar.dart';
import '../../../../components/layout/uten_content_container.dart';
import '../../../../components/layout/uten_filter_toolbar.dart';
import '../../../../components/layout/uten_floating_action_group.dart';
import '../../../../core/l10n/gen/app_localizations.dart';
import '../../../../core/network/api_exception.dart';
import '../../../../core/router/nav_helpers.dart';
import '../../../../core/router/page_resume_provider.dart';
import '../../../../core/router/route_access_policy.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/uten_tokens.dart';
import '../../../../core/ui/app_notification.dart';
import '../../../../core/utils/china_datetime.dart';
import '../../../../shared/auth/permissions.dart';
import '../../../../shared/models/paged_result.dart';
import '../../../basic_data/widgets/master_data_table_view.dart';
import '../../../stock/counts/models/stock_count_request.dart';
import '../../../stock/counts/repositories/stock_count_request_repository.dart';
import '../../../stock/counts/widgets/stock_count_inline_editor.dart';
import '../models/workshop_material_models.dart';
import '../repositories/workshop_material_repository.dart';
import '../widgets/workshop_material_close_poller.dart';
import '../widgets/workshop_material_close_status_banner.dart';
import '../widgets/workshop_material_enable_panel.dart';
import '../widgets/workshop_material_labels.dart';
import '../widgets/workshop_material_other_issue_dialog.dart';
import '../widgets/workshop_material_overview.dart';
import '../widgets/workshop_material_request_dialog.dart';

class WorkshopMaterialBinPage extends ConsumerStatefulWidget {
  const WorkshopMaterialBinPage({super.key, this.workshopId});

  /// 指定车间时直达；通用入口显示所有可见车间的启用总览。
  final String? workshopId;

  @override
  ConsumerState<WorkshopMaterialBinPage> createState() =>
      _WorkshopMaterialBinPageState();
}

class _WorkshopMaterialBinPageState
    extends ConsumerState<WorkshopMaterialBinPage> {
  late final StockCountInlineController _countEditor;
  void _countChanged() {
    if (mounted) setState(() {});
  }

  String _countKey(WmPositionRow row) =>
      stockCountRowKey(row.goodsId, row.colorId);
  List<WmPositionRow> _stockRows(WmPosition? position) {
    final rows = [...?position?.rows];
    final keys = rows.map(_countKey).toSet();
    if (_countEditor.active) {
      for (final snapshot in _countEditor.addedRows.values) {
        if (keys.add(snapshot.key)) {
          rows.add(
            WmPositionRow(
              goodsId: snapshot.goodsId,
              goodsCode: snapshot.goodsCode,
              goodsName: snapshot.goodsName,
              colorId: snapshot.colorId,
              colorName: snapshot.colorName,
              unitName: snapshot.unitName,
              bookQty: double.tryParse(snapshot.qty) ?? 0,
            ),
          );
        }
      }
    }
    return rows;
  }

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
  int _historyLoadGeneration = 0;
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

  /// 已开通内料仓的车间 (收车间直送; 可能也在整批领料)。
  List<WmSetting> get _enabled => [
    for (final s in _settings ?? const <WmSetting>[])
      if (s.opened) s,
  ];

  WmSetting? get _current {
    for (final s in _enabled) {
      if (s.workshopDepartmentId == _workshopId) return s;
    }
    return null;
  }

  WmSetting? get _selectedSetting {
    for (final setting in _settings ?? const <WmSetting>[]) {
      if (setting.workshopDepartmentId == _workshopId) return setting;
    }
    return null;
  }

  bool get _canViewStock =>
      ref.read(isSuperAdminProvider) ||
      ref.read(currentPermissionsProvider).contains(Perm.workshopMaterialView);

  bool get _canSetup => locationAllowedFor(
    ref.read(currentPermissionsProvider),
    ref.read(isSuperAdminProvider),
    RouteName.workshopMaterialSetup,
  );

  Future<void> _openSetup([WmSetting? setting]) async {
    if (!_canSetup || (setting != null && !setting.can(WmAction.setup))) return;
    if (_countEditor.active) {
      context.appInfo('请先送审或退出盘点，再进入设置');
      return;
    }
    await context.push(
      Uri(
        path: RouteName.workshopMaterialSetup,
        queryParameters: {'workshopId': ?setting?.workshopDepartmentId},
      ).toString(),
    );
    if (mounted) await _loadAll();
  }

  /// 打开开通面板 (单个车间); 办成后重读。
  Future<void> _openBinPanel(
    WmSetting setting, [
    WmBinPanelMode mode = WmBinPanelMode.open,
  ]) async {
    final saved = await showWorkshopBinOpeningPanel(
      context,
      settings: [setting],
      mode: mode,
    );
    if (saved != null && mounted) await _loadAll();
  }

  Future<void> _openWorkshop(WmSetting setting) async {
    if (!_canViewStock || !setting.opened) return;
    await context.push(
      RoutePath.workshopMaterialBin(workshopId: setting.workshopDepartmentId),
    );
    if (mounted) await _loadAll();
  }

  void _openOverview() {
    if (_countEditor.active) {
      context.appInfo('请先送审或退出盘点，再返回车间总览');
      return;
    }
    context.go(RouteName.workshopMaterialBin);
  }

  @override
  void initState() {
    super.initState();
    _countEditor = StockCountInlineController(
      ref.read(stockCountRequestRepositoryProvider),
    )..addListener(_countChanged);
    _workshopId = widget.workshopId;
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadAll());
  }

  @override
  void dispose() {
    _poller.stop();
    _countEditor.removeListener(_countChanged);
    _countEditor.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant WorkshopMaterialBinPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.workshopId == widget.workshopId) return;
    _loadSeq++;
    _historyLoadGeneration++;
    _poller.stop();
    _countEditor.clear();
    _myLocation = null;
    _view = _viewStock;
    _workshopId = widget.workshopId;
    _position = null;
    _periods = const [];
    _statusPeriod = null;
    _closeStatus = null;
    _history = null;
    _historyError = null;
    _loadAll();
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
      // 通用入口保持总览；不因已有已启用车间而默认跳到第一个仓。
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
      if (mounted && seq == _loadSeq) {
        setState(() {
          _error = e.message;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted && seq == _loadSeq) {
        setState(() {
          _error = '刷新失败, 请重试';
          _loading = false;
        });
      }
    }
  }

  void _selectWorkshop(String workshopId) {
    if (_countEditor.active) {
      context.appInfo('盘点已固定当前内料仓，请先送审或退出盘点再切换车间');
      return;
    }
    if (_workshopId == workshopId ||
        !_enabled.any(
          (setting) => setting.workshopDepartmentId == workshopId,
        )) {
      return;
    }
    _poller.stop();
    _historyLoadGeneration++;
    setState(() {
      _workshopId = workshopId;
      // 切仓即清掉旧仓的库存、权限动作和期间，不能在新仓标题下继续操作旧仓数据。
      _position = null;
      _periods = const [];
      _statusPeriod = null;
      _closeStatus = null;
      _history = null;
      _historyError = null;
      _historyLoading = false;
      _error = null;
      _loading = true;
    });
    _reloadWorkshop();
  }

  /// 读当前车间的现存、期间与结算状态 (异常由调用方处理)。
  Future<void> _loadWorkshop(int seq) async {
    if (!mounted) return;
    final setting = _current;
    if (setting == null || !_canViewStock) {
      if (_countEditor.active) _countEditor.clear();
      _poller.stop();
      _historyLoadGeneration++;
      setState(() {
        _position = null;
        _periods = const [];
        _statusPeriod = null;
        _closeStatus = null;
        _history = null;
        _historyError = null;
        _historyLoading = false;
        _loading = false;
      });
      return;
    }
    final binId = setting.binWarehouseId!;
    // 只开通、没开整批领料的内料仓没有期间。
    final results = await Future.wait<Object>([
      _repo.position(binId),
      if (setting.periodic) _repo.periods(binId),
    ]);
    if (!mounted || seq != _loadSeq || !_canViewStock) return;
    final position = results[0] as WmPosition;
    final periods = [if (setting.periodic) ...results[1] as List<WmPeriod>]
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
    if (_countEditor.active && _countEditor.warehouse?.id == binId) {
      await _countEditor.ensureRows(position.rows.map((row) => row.goodsId));
    }
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
    final generation = ++_historyLoadGeneration;
    final setting = _current;
    if (setting == null) return;
    final workshopId = setting.workshopDepartmentId;
    bool current() =>
        mounted &&
        generation == _historyLoadGeneration &&
        _current?.workshopDepartmentId == workshopId;
    setState(() {
      _historyLoading = true;
      _historyError = null;
    });
    try {
      final result = await _repo.requisitions(
        workshopId: workshopId,
        page: page,
      );
      if (!current()) return;
      setState(() {
        _history = result;
        _historyLoading = false;
      });
    } on ApiException catch (e) {
      if (current()) {
        setState(() {
          _historyLoading = false;
          _historyError = e.message;
        });
      }
    } catch (_) {
      if (current()) {
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
    ref.watch(currentPermissionsProvider);
    ref.watch(isSuperAdminProvider);
    ref.listen(currentPermissionsProvider, (previous, next) {
      if (_countEditor.active && !next.contains(stockCountSubmitPermission)) {
        _countEditor.clear();
      }
    });
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    _myLocation ??= currentLocationOr(context, RouteName.workshopMaterialBin);
    ref.onPageResume(
      _myLocation!,
      _loadAll,
      onReturn: () {
        if (_busyTitle != null) setState(() => _busyTitle = null);
      },
    );
    final setting = _selectedSetting;
    final title = setting == null
        ? l10n.workshopMaterialBin
        : l10n.workshopMaterialBinOf(setting.workshopName);
    return Scaffold(
      appBar: UtenAppBar(
        title: title,
        subtitle: _current?.currentPeriod == null
            ? null
            : wmPeriodLabel(_current!.currentPeriod!),
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
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButtonAnimator: FloatingActionButtonAnimator.noAnimation,
      floatingActionButton: _floatingActions(l10n),
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
    if (_workshopId == null) {
      return WorkshopMaterialOverview(
        settings: _settings ?? const [],
        canViewStock: _canViewStock,
        canSetup: _canSetup,
        loading: _loading,
        error: _error,
        onOpen: _openWorkshop,
        onChanged: _loadAll,
        onOpenMachines: _canSetup ? () => _openSetup() : null,
        onRetry: _loadAll,
      );
    }
    final enabled = _enabled;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 目标仓未启用或不可见时仍可主动切换到有权限的其它内料仓；不自动代选。
        if (enabled.length > 1 || (_current == null && enabled.isNotEmpty)) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s4),
            child: UtenFilterToolbar<String>(
              segmentsKey: const Key('wm-bin-workshops'),
              segments: [
                for (final setting in enabled)
                  UtenFilterSegment(
                    value: setting.workshopDepartmentId,
                    label: setting.workshopName,
                  ),
              ],
              selected: _current == null ? const {} : {_workshopId!},
              onSelectionChanged: _selectWorkshop,
            ),
          ),
          const SizedBox(height: UtenSpacing.s8),
        ],
        Expanded(child: _selectedWorkshopBody(l10n, theme)),
      ],
    );
  }

  Widget _selectedWorkshopBody(AppLocalizations l10n, ThemeData theme) {
    final selected = _selectedSetting;
    if (_workshopId != null && selected == null) {
      return UtenEmpty(
        icon: Icons.inventory_2_outlined,
        message: '指定车间当前不可用或无权查看',
        description: _enabled.isEmpty
            ? '请返回原任务核对车间，或刷新后重试。'
            : '请核对原任务的车间；也可以在上方主动选择其它可见的车间内料仓。',
        actionLabel: '重试',
        onAction: _loadAll,
      );
    }
    if (_current == null) {
      final canOpen = selected != null && selected.can(WmAction.open);
      return UtenEmpty(
        icon: Icons.inventory_2_outlined,
        message: selected == null
            ? l10n.wmBinNoneOpened
            : l10n.wmBinNotOpenTitle(selected.workshopName),
        description: canOpen
            ? l10n.wmBinNotOpenDescription
            : l10n.wmBinNotOpenAskWarehouse,
        actionLabel: canOpen ? l10n.wmBinMenuOpen : null,
        onAction: canOpen ? () => _openBinPanel(selected) : null,
      );
    }
    final position = _position;
    if (!_canViewStock) {
      return UtenEmpty(
        icon: Icons.settings_outlined,
        message: '当前只有设置权限',
        description: '可管理此车间配置；查看库存需要内料仓查看权限。',
        actionLabel: _canSetup && selected?.can(WmAction.setup) == true
            ? '车间设置'
            : null,
        onAction: _canSetup && selected?.can(WmAction.setup) == true
            ? () => _openSetup(selected)
            : null,
      );
    }
    final status = _closeStatus;
    final statusPeriod = _statusPeriod;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
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
        if (_current?.periodic == false) ...[
          UtenInlineNotice(
            key: const Key('wm-bin-direct-only'),
            message: l10n.wmBinDirectOnlyNotice,
          ),
          const SizedBox(height: UtenSpacing.s8),
        ],
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
              if (_countEditor.active) {
                context.appInfo('请先送审或退出盘点，再查看记录');
                return;
              }
              setState(() => _view = value);
              if (value == _viewHistory && _history == null) _loadHistory(1);
            },
          ),
        ),
        const SizedBox(height: UtenSpacing.s8),
        if (_countEditor.active) ...[
          _countContext(theme),
          const SizedBox(height: UtenSpacing.s12),
        ],
        Expanded(
          child: _view == _viewHistory
              ? _historyTable(l10n)
              : _stockTable(l10n, position),
        ),
      ],
    );
  }

  Widget? _floatingActions(AppLocalizations l10n) {
    if (_busyTitle != null) return null;
    // 总览的开通/开启整批领料/撤销是表格自己的右下批量动作。
    if (_workshopId == null) return null;
    if (_current == null || !_canViewStock || !_current!.periodic) {
      final current = _current;
      return UtenFloatingActionGroup(
        children: [
          UtenButton(
            key: const Key('wm-bin-overview'),
            type: UtenButtonType.secondary,
            size: UtenButtonSize.large,
            icon: Icons.warehouse_outlined,
            onPressed: _openOverview,
            child: const Text('车间总览'),
          ),
          if (current != null && current.can(WmAction.enablePeriodic))
            UtenButton(
              key: const Key('wm-bin-enable-periodic'),
              type: UtenButtonType.success,
              size: UtenButtonSize.large,
              icon: Icons.inventory_outlined,
              onPressed: () => _openBinPanel(current, WmBinPanelMode.periodic),
              child: Text(l10n.wmEnable),
            ),
        ],
      );
    }
    if (ref
        .watch(currentPermissionsProvider)
        .contains(stockCountSubmitPermission)) {
      return StockCountModeToolbar(
        controller: _countEditor,
        allowed: true,
        inactiveActionsBuilder: (start, history) => _businessActions(
          l10n,
          startInventoryCount: start,
          openCountHistory: history,
        ),
        warehouseId: _current?.binWarehouseId,
        goodsIds: () => _position?.rows.map((row) => row.goodsId) ?? const [],
        onStart: (_) async {
          setState(() => _view = _viewStock);
        },
        onSubmitted: _reloadWorkshop,
      );
    }
    return UtenFloatingActionGroup(children: _businessActions(l10n));
  }

  List<Widget> _businessActions(
    AppLocalizations l10n, {
    VoidCallback? startInventoryCount,
    VoidCallback? openCountHistory,
  }) {
    bool can(String action) => _position?.can(action) ?? false;
    final starting = openCountHistory != null && startInventoryCount == null;
    final more = <Widget>[
      MenuItemButton(
        key: const Key('wm-bin-overview'),
        leadingIcon: const Icon(Icons.warehouse_outlined),
        onPressed: _openOverview,
        child: const Text('车间总览'),
      ),
      if (_canSetup && _selectedSetting?.can(WmAction.setup) == true)
        MenuItemButton(
          key: const Key('wm-bin-settings'),
          leadingIcon: const Icon(Icons.settings_outlined),
          onPressed: () => _openSetup(_selectedSetting),
          child: const Text('本车间设置'),
        ),
      if (can(WmAction.returnMaterial))
        MenuItemButton(
          key: const Key('wm-bin-return'),
          leadingIcon: const Icon(Icons.assignment_return_outlined),
          onPressed: () => _openRequest('RETURN'),
          child: Text(l10n.wmReturn),
        ),
      if (can(WmAction.otherIssue))
        MenuItemButton(
          key: const Key('wm-bin-other-issue'),
          leadingIcon: const Icon(Icons.science_outlined),
          onPressed: _openOtherIssue,
          child: Text(l10n.wmOtherIssue),
        ),
      if (can(WmAction.startCount) || can(WmAction.editCount))
        MenuItemButton(
          key: const Key('wm-bin-count'),
          leadingIcon: const Icon(Icons.fact_check_outlined),
          onPressed: _openCount,
          child: const Text('周期盘点'),
        ),
      if (openCountHistory != null)
        MenuItemButton(
          key: const Key('wm-bin-my-counts'),
          leadingIcon: const Icon(Icons.history_outlined),
          onPressed: openCountHistory,
          child: const Text('盘点历史'),
        ),
    ];
    return [
      if (more.isNotEmpty)
        MenuAnchor(
          menuChildren: more,
          builder: (context, menu, _) => UtenButton(
            key: const Key('wm-bin-more'),
            size: UtenButtonSize.large,
            type: UtenButtonType.secondary,
            icon: Icons.more_horiz,
            onPressed: starting
                ? null
                : () => menu.isOpen ? menu.close() : menu.open(),
            child: const Text('更多操作'),
          ),
        ),
      if (openCountHistory != null)
        UtenButton(
          key: const Key('stock-count-mode'),
          size: UtenButtonSize.large,
          type: UtenButtonType.secondary,
          icon: Icons.fact_check_outlined,
          onPressed: startInventoryCount,
          isLoading: starting,
          child: const Text('库存盘点'),
        ),
      if (can(WmAction.request))
        UtenButton(
          key: const Key('wm-bin-request'),
          size: UtenButtonSize.large,
          icon: Icons.add_shopping_cart_outlined,
          onPressed: starting ? null : () => _openRequest('ISSUE'),
          child: Text(l10n.wmRequestIssue),
        ),
    ];
  }

  Widget _countContext(ThemeData theme) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Wrap(
        spacing: UtenSpacing.s8,
        runSpacing: UtenSpacing.s8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          // 2026-10-02 用户口径：盘点说明放最左、选填；「库存盘点 · 已改 N 项」计数退役。
          // 与即时库存页同一个 controller 自带的说明框(ADR-151)。
          StockCountReasonField(controller: _countEditor),
        ],
      ),
      if (_countEditor.error != null)
        UtenInlineNotice(
          level: UtenInlineNoticeLevel.error,
          message: _countEditor.error!,
          trailing: TextButton(
            onPressed: _countEditor.busy
                ? null
                : () => _countEditor.ensureRows(
                    _position?.rows.map((row) => row.goodsId) ?? const [],
                  ),
            child: const Text('重试'),
          ),
        ),
    ],
  );

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
          label: _countEditor.active ? '账面数量' : '账面 ($kg)',
          width: 110,
          type: 'number',
          value: (r) =>
              _countEditor.addedRows[_countKey(r)]?.qty ?? qty(r.bookQty),
        ),
        if (_countEditor.active) ...[
          MasterColumnDef<WmPositionRow>(
            key: 'countBaseUnit',
            label: '单位',
            width: 75,
            value: (row) =>
                _countEditor.rows[_countKey(row)]?.snapshot.unitName ??
                row.unitName,
          ),
          MasterColumnDef<WmPositionRow>(
            key: 'countBookWeight',
            label: '账面重量 (kg)',
            width: 145,
            value: (row) =>
                _countEditor.rows[_countKey(row)]?.snapshot.weightKg ?? '未称',
          ),
          ..._countEditor.columns<WmPositionRow>(_countKey),
        ],
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
      items: _stockRows(position),
      bottomContentPadding: UtenFloatingActionGroup.scrollClearance,
      facets: const {},
      nullCounts: const {},
      filters: const {},
      onFilterChanged: (_, _) {},
      rowKeyOf: (r) => r.key,
      isLoading: _loading && position == null,
      error: position == null ? _error : null,
      onRetry: _reloadWorkshop,
      emptyMessage: '内料仓暂无库存',
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
          key: 'status',
          label: '状态',
          width: 72,
          value: (r) => wmRequisitionStatusLabel(r.status),
          // 2026-10-01 口径「不同状态不同颜色」：待处理琥珀 / 已完成绿 / 已取消灰。
          // 历史表混排各状态，取默认（非任务）视角，与记录分段同口径。
          cellColor: (context, r) =>
              utenStatusBadgeCellColor(wmRequisitionStatusBadgeType(r.status)),
        ),
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
      bottomContentPadding: UtenFloatingActionGroup.scrollClearance,
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
      paginationScope: _current?.workshopDepartmentId,
      onPageChange: _loadHistory,
      emptyMessage: '还没有领料、退回记录',
    );
  }
}
