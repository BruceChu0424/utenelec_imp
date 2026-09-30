// 车间内料仓用量报表与结算页 (ADR-131 §5.10；路由 /reports/workshop-material)。
//
// 入口：生产 hub 报表中心、财务 hub 报表中心 (同一路由)。报表一律不挂数。
//
// - 顶部选内料仓与期间 (「全部期间」= 本仓每一期)；
// - 结算状态卡：本期 (或最近一次盘点的那一期) 盘点 / 结算到哪一步、被什么拦住、
//   该谁来补；「立即重试」「重新结算」「撤销结算」只按服务端下发的 allowedActions
//   显示 (不在页面里判断权限)。撤销结算要再认证：服务端回「需要再认证」时网络层
//   统一弹密码框，输完原请求自动重发。重试后每 2 秒查一次结算状态，最多 60 秒；
// - 五个分段：用量表 / 产品用料 / 浪费率趋势 / 缺单重清单 / 收发明细，都用
//   MasterDataTableView。金额列只在服务端下发了金额时出现 (没有看成本权限的人
//   收到的金额为空，整列隐藏)。缺单重清单点行直接跳到该产品的组装信息 (BOM) 填单重。
// - 网络写操作期间由本页持有 UtenBusyOverlay；弹原因框前先撤遮罩。
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/uten_goods_identity_cell.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/inputs/required_field_decoration.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/models/paged_result.dart';
import '../../basic_data/widgets/goods_issue_method_dialog.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/workshop_material_report_models.dart';
import '../repositories/workshop_material_report_repository.dart';

/// 报表分段。
enum WmReportView { usage, product, trend, missing, ledger }

class WorkshopMaterialReportsPage extends ConsumerStatefulWidget {
  const WorkshopMaterialReportsPage({
    super.key,
    this.initialBinId,
    this.initialPeriodId,
    this.initialView = WmReportView.usage,
  });

  /// 深链预选的内料仓 (仓库 id)；不传取第一个。
  final String? initialBinId;

  /// 深链预选的期间；不传 = 全部期间。
  final String? initialPeriodId;
  final WmReportView initialView;

  @override
  ConsumerState<WorkshopMaterialReportsPage> createState() =>
      _WorkshopMaterialReportsPageState();
}

class _WorkshopMaterialReportsPageState
    extends ConsumerState<WorkshopMaterialReportsPage> {
  static const _pollInterval = Duration(seconds: 2);
  static const _pollWindow = Duration(seconds: 60);

  List<WmReportBin> _bins = const [];
  String? _binId;
  List<WmReportPeriod> _periods = const [];

  /// 选中的期间；null = 全部期间。
  String? _periodId;
  late WmReportView _view;

  bool _loadingMeta = true;
  String? _metaError;

  List<WmBinUsageRow>? _usage;
  List<WmProductUsageRow>? _product;
  List<WmWasteTrendPoint>? _trend;
  List<WmMissingWeightRow>? _missing;
  PagedResult<WmLedgerRow>? _ledger;
  bool _loadingData = false;
  String? _dataError;
  int _dataRequest = 0;

  /// 浪费率趋势当前看的料 (货品 + 颜色)。
  String? _trendMaterialKey;

  WmReportCloseStatus? _closeStatus;
  String? _closeError;
  int _closeRequest = 0;

  bool _busy = false;
  String _busyTitle = '';

  Timer? _pollTimer;
  DateTime? _pollDeadline;

  /// 正在轮询结算状态 (定时器在等下一次或正在查)。
  bool _polling = false;

  @override
  void initState() {
    super.initState();
    _view = widget.initialView;
    Future.microtask(_loadBins);
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  WorkshopMaterialReportRepository get _repo =>
      ref.read(workshopMaterialReportRepositoryProvider);

  WmReportPeriod? get _selectedPeriod {
    for (final p in _periods) {
      if (p.id == _periodId) return p;
    }
    return null;
  }

  /// 结算状态卡看哪一期：选了期间就看它；没选看最近一次开始盘点的那一期
  /// (开着的那一期还没盘点，没有结算可看)。
  WmReportPeriod? get _statusPeriod {
    final selected = _selectedPeriod;
    if (selected != null) return selected;
    WmReportPeriod? latest;
    for (final p in _periods) {
      if (p.status == null || p.status == 'OPEN') continue;
      if (latest == null || (p.periodNo ?? 0) > (latest.periodNo ?? 0)) {
        latest = p;
      }
    }
    return latest;
  }

  Future<void> _loadBins() async {
    setState(() {
      _loadingMeta = true;
      _metaError = null;
    });
    try {
      final bins = await _repo.bins();
      if (!mounted) return;
      final preferred = widget.initialBinId ?? _binId;
      setState(() {
        _bins = bins;
        _binId = bins.any((b) => b.binWarehouseId == preferred)
            ? preferred
            : (bins.isEmpty ? null : bins.first.binWarehouseId);
      });
      await _loadPeriods(initial: true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _metaError = e.message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _metaError = '读取车间内料仓失败，请重试');
    } finally {
      if (mounted) setState(() => _loadingMeta = false);
    }
  }

  Future<void> _loadPeriods({bool initial = false}) async {
    if (!mounted) return;
    final binId = _binId;
    if (binId == null) {
      setState(() {
        _periods = const [];
        _periodId = null;
        _closeStatus = null;
      });
      return;
    }
    try {
      // 复制一份再排序 (仓库可能返回不可变列表)：新的期在上。
      final periods = [...await _repo.periods(binId)]
        ..sort((a, b) => (b.periodNo ?? 0).compareTo(a.periodNo ?? 0));
      if (!mounted || binId != _binId) return;
      final wanted = initial ? widget.initialPeriodId : _periodId;
      setState(() {
        _periods = periods;
        _periodId = periods.any((p) => p.id == wanted) ? wanted : null;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _metaError = e.message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _metaError = '读取盘点期间失败，请重试');
    }
    if (!mounted) return;
    await Future.wait([_loadData(), _loadCloseStatus()]);
  }

  Future<void> _loadData([int page = 1]) async {
    if (!mounted) return;
    final binId = _binId;
    final request = ++_dataRequest;
    if (binId == null) {
      setState(() => _loadingData = false);
      return;
    }
    final period = _selectedPeriod;
    final from = period?.startDate;
    final to = period?.endDate;
    final view = _view;
    setState(() {
      _loadingData = true;
      _dataError = null;
    });
    try {
      switch (view) {
        case WmReportView.usage:
          final usageRows = await _repo.binUsage(binId, from: from, to: to);
          if (mounted && request == _dataRequest) {
            setState(() => _usage = usageRows);
          }
        case WmReportView.product:
          final productRows = await _repo.productUsage(
            binId,
            from: from,
            to: to,
          );
          if (mounted && request == _dataRequest) {
            setState(() => _product = productRows);
          }
        case WmReportView.trend:
          final trendRows = await _repo.wasteTrend(binId);
          if (mounted && request == _dataRequest) {
            setState(() {
              _trend = trendRows;
              final keys = trendRows.map((p) => p.materialKey).toSet();
              if (!keys.contains(_trendMaterialKey)) {
                _trendMaterialKey = keys.isEmpty ? null : keys.first;
              }
            });
          }
        case WmReportView.missing:
          final missingRows = await _repo.missingWeights(binId);
          if (mounted && request == _dataRequest) {
            setState(() => _missing = missingRows);
          }
        case WmReportView.ledger:
          final result = await _repo.ledger(
            binId,
            from: from,
            to: to,
            page: page,
          );
          if (mounted && request == _dataRequest) {
            setState(() => _ledger = result);
          }
      }
    } on ApiException catch (e) {
      if (mounted && request == _dataRequest) {
        setState(() => _dataError = e.message);
      }
    } catch (_) {
      if (mounted && request == _dataRequest) {
        setState(() => _dataError = '报表读取失败，请重试');
      }
    } finally {
      if (mounted && request == _dataRequest) {
        setState(() => _loadingData = false);
      }
    }
  }

  Future<void> _loadCloseStatus() async {
    if (!mounted) return;
    final period = _statusPeriod;
    final request = ++_closeRequest;
    if (period == null) {
      setState(() {
        _closeStatus = null;
        _closeError = null;
      });
      return;
    }
    try {
      final status = await _repo.closeStatus(period.id);
      if (!mounted || request != _closeRequest) return;
      setState(() {
        _closeStatus = status;
        _closeError = null;
      });
      // 刚提交盘点、正在自动结算：进页面就接着查，直到有结果或超过 60 秒。
      if (status.isSettling && !_polling) _startPolling();
    } on ApiException catch (e) {
      if (!mounted || request != _closeRequest) return;
      setState(() => _closeError = e.message);
    } catch (_) {
      if (!mounted || request != _closeRequest) return;
      setState(() => _closeError = '读取结算状态失败');
    }
  }

  // ---- 结算状态轮询 (每 2 秒，最多 60 秒) ----------------------------------

  void _startPolling() {
    _polling = true;
    _pollDeadline = DateTime.now().add(_pollWindow);
    _schedulePoll();
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _polling = false;
  }

  void _schedulePoll() {
    _pollTimer?.cancel();
    _pollTimer = null;
    final status = _closeStatus;
    final deadline = _pollDeadline;
    if (!mounted ||
        status == null ||
        !status.isSettling ||
        deadline == null ||
        DateTime.now().isAfter(deadline)) {
      _polling = false;
      return;
    }
    _pollTimer = Timer(_pollInterval, () async {
      _pollTimer = null;
      final before = _closeStatus?.status;
      await _loadCloseStatus();
      if (!mounted) return;
      final after = _closeStatus;
      if (after != null && !after.isSettling) {
        _polling = false;
        // 结算有了结果：期间状态、报表数字都可能变了，重读一次。
        if (after.status != before || after.isClosed) {
          await _loadPeriods();
        }
        return;
      }
      _schedulePoll();
    });
  }

  // ---- 结算动作 ------------------------------------------------------------

  Future<void> _retryClose() async {
    final status = _closeStatus;
    if (status == null || _busy) return;
    setState(() {
      _busy = true;
      _busyTitle = '正在提交结算';
    });
    try {
      final next = await _repo.retryClose(status);
      if (!mounted) return;
      // 先撤遮罩再给提示。
      setState(() {
        _busy = false;
        _closeStatus = next;
      });
      if (next.isClosed) {
        context.appSuccess('已结算');
        await _loadPeriods();
        return;
      }
      context.appInfo('已开始结算，结果出来后这里会自动更新');
      _startPolling();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      context.appError(e.message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      context.appError('结算提交失败，请稍后重试');
    }
  }

  Future<void> _reopen() async {
    final period = _statusPeriod;
    if (period == null || _busy) return;
    final reason = await _askReopenReason();
    if (reason == null || !mounted) return;
    setState(() {
      _busy = true;
      _busyTitle = '正在撤销结算';
    });
    try {
      // 每次结算尝试 (含被拦、失败) 都会让期间版本 +1，撤销前先取最新版本，
      // 免得拿列表里的旧版本被当成「这一期已被别人改过」。
      final fresh = await _repo.closeStatus(period.id);
      final next = await _repo.reopen(
        period.id,
        expectedVersion: fresh.rowVersion ?? period.rowVersion,
        reason: reason,
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _closeStatus = next;
      });
      context.appSuccess('已撤销结算');
      await _loadPeriods();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      context.appError(e.message);
      await _loadPeriods();
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      context.appError('撤销结算失败，请稍后重试');
    }
  }

  /// 撤销原因 (2-500 字，必填；空时红框)。取消返回 null。
  Future<String?> _askReopenReason() async {
    // 弹框前确保没有遮罩挡着 (遮罩只跟随网络调用本身)。
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return null;
    return showDialog<String>(
      context: context,
      builder: (_) => const _ReopenReasonDialog(),
    );
  }

  // ---- 交互 ----------------------------------------------------------------

  void _selectBin(String? binId) {
    if (binId == null || binId == _binId) return;
    _stopPolling();
    setState(() {
      _binId = binId;
      _periodId = null;
      _periods = const [];
      _usage = null;
      _product = null;
      _trend = null;
      _missing = null;
      _ledger = null;
      _closeStatus = null;
    });
    _loadPeriods();
  }

  void _selectPeriod(String? periodId) {
    final next = (periodId == null || periodId.isEmpty) ? null : periodId;
    if (next == _periodId) return;
    _stopPolling();
    setState(() => _periodId = next);
    _loadData();
    _loadCloseStatus();
  }

  void _selectView(WmReportView view) {
    if (view == _view) return;
    setState(() => _view = view);
    _loadData();
  }

  void _refresh() {
    _loadPeriods();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    ref.onPageResume(RouteName.workshopMaterialReports, _refresh);
    return Scaffold(
      appBar: UtenAppBar(
        title: l10n.workshopMaterialReports,
        leading: UtenBackButton(
          onPressed: () =>
              popOrBackTo(context, defaultPath: RouteName.production),
        ),
        actions: [
          IconButton(
            onPressed: _busy ? null : _refresh,
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
          ),
        ],
      ),
      body: SafeArea(
        child: Stack(
          children: [
            UtenContentContainer.wide(child: _body(context, l10n)),
            if (_busy)
              UtenBusyOverlay(title: _busyTitle, description: '请勿重复点击或离开本页。'),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context, AppLocalizations l10n) {
    final theme = Theme.of(context);
    if (_loadingMeta && _bins.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_bins.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(UtenSpacing.s24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _metaError ?? l10n.wmReportNoBin,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: _metaError == null
                      ? theme.colorScheme.onSurfaceVariant
                      : theme.colorScheme.error,
                ),
              ),
              if (_metaError != null) ...[
                const SizedBox(height: UtenSpacing.s12),
                UtenButton(onPressed: _loadBins, child: const Text('重试')),
              ],
            ],
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            UtenSpacing.s12,
            UtenSpacing.s12,
            UtenSpacing.s12,
            0,
          ),
          child: _selectors(l10n),
        ),
        if (_statusPeriod != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              UtenSpacing.s12,
              UtenSpacing.s12,
              UtenSpacing.s12,
              0,
            ),
            child: _CloseStatusCard(
              period: _statusPeriod!,
              status: _closeStatus,
              error: _closeError,
              onRetry: _retryClose,
              onReopen: _reopen,
              onReload: _loadCloseStatus,
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: UtenSpacing.s12,
            vertical: UtenSpacing.s8,
          ),
          child: UtenFilterToolbar<WmReportView>(
            segmentsKey: const Key('wm-report-view-segments'),
            segments: [
              UtenFilterSegment(
                value: WmReportView.usage,
                label: l10n.wmReportUsage,
              ),
              UtenFilterSegment(
                value: WmReportView.product,
                label: l10n.wmReportProduct,
              ),
              UtenFilterSegment(
                value: WmReportView.trend,
                label: l10n.wmReportTrend,
              ),
              UtenFilterSegment(
                value: WmReportView.missing,
                label: l10n.wmReportMissingWeight,
              ),
              UtenFilterSegment(
                value: WmReportView.ledger,
                label: l10n.wmReportLedger,
              ),
            ],
            selected: {_view},
            onSelectionChanged: _selectView,
          ),
        ),
        Expanded(child: _viewBody(context, l10n)),
      ],
    );
  }

  Widget _selectors(AppLocalizations l10n) {
    return Wrap(
      spacing: UtenSpacing.s12,
      runSpacing: UtenSpacing.s8,
      children: [
        SizedBox(
          width: 260,
          child: UtenDropdownField(
            key: const Key('wm-report-bin'),
            label: l10n.workshopMaterialBin,
            dense: true,
            allowClear: false,
            value: _binId,
            items: [
              for (final b in _bins)
                UtenDropdownItem(value: b.binWarehouseId, label: b.label),
            ],
            onChanged: _selectBin,
          ),
        ),
        SizedBox(
          width: 280,
          child: UtenDropdownField(
            key: const Key('wm-report-period'),
            label: l10n.wmReportPeriod,
            dense: true,
            allowClear: false,
            value: _periodId ?? '',
            items: [
              UtenDropdownItem(value: '', label: l10n.wmReportAllPeriods),
              for (final p in _periods)
                UtenDropdownItem(
                  value: p.id,
                  label: '${p.label} · ${_periodStatusText(p)}',
                ),
            ],
            onChanged: _selectPeriod,
          ),
        ),
      ],
    );
  }

  Widget _viewBody(BuildContext context, AppLocalizations l10n) {
    return switch (_view) {
      WmReportView.usage => _usageTable(l10n),
      WmReportView.product => _productTable(l10n),
      WmReportView.trend => _trendView(context, l10n),
      WmReportView.missing => _missingTable(l10n),
      WmReportView.ledger => _ledgerTable(l10n),
    };
  }

  // ---- 用量表 --------------------------------------------------------------

  Widget _usageTable(AppLocalizations l10n) {
    final rows = _usage ?? const <WmBinUsageRow>[];
    final showCost = rows.any((r) => r.hasCost);
    return MasterDataTableView<WmBinUsageRow>(
      tableKey:
          'features.production.pages.workshop_material_reports_page.WorkshopMaterialReportsPageState._usageTable.1',
      key: ValueKey('wm-usage-table-$showCost'),
      columns: [
        MasterColumnDef(
          key: 'period',
          label: l10n.wmReportPeriod,
          width: 190,
          filterFromRows: true,
          value: (r) => _periodText(r.periodNo, r.startDate, r.endDate),
        ),
        // 2026-09-29 用户口径：名称列只放名称，原「名称 颜色」拼接拆独立颜色列。
        MasterColumnDef(
          key: 'material',
          label: l10n.wmReportMaterial,
          width: 180,
          filterFromRows: true,
          value: (r) => r.goodsName,
        ),
        MasterColumnDef(
          key: 'materialColor',
          label: '颜色',
          width: 84,
          filterFromRows: true,
          value: (r) => UtenGoodsAttributeCell.text(r.colorName),
          cellBuilder: (_, r) => UtenGoodsAttributeCell(r.colorName),
        ),
        MasterColumnDef(
          key: 'costBasis',
          label: l10n.wmCostBasis,
          width: 96,
          value: (r) => goodsCostBasisLabel(context, r.costBasis) ?? '',
        ),
        _qtyCol('opening', '期初', (r) => r.openingQty),
        _qtyCol('in', '领入', (r) => r.transferInQty),
        _qtyCol('return', '退回', (r) => r.returnQty),
        _qtyCol('other', '其它耗用', (r) => r.otherIssueQty),
        _qtyCol('closing', '期末', (r) => r.closingQty),
        _qtyCol('actual', '实际', (r) => r.actualQty),
        MasterColumnDef(
          key: 'theory',
          label: '理论',
          width: 100,
          type: 'number',
          info: '按报工量 × BOM 单个重量算出的用量；辅料显示分摊基数 (当期主料理论合计)。',
          value: (r) => r.costBasis == 'SHARED'
              ? _qty(r.allocationBasisQty)
              : _qty(r.theoryQty),
        ),
        _qtyCol('diff', '差额', (r) => r.diffQty),
        MasterColumnDef(
          key: 'wasteRate',
          label: l10n.wmWasteRate,
          width: 90,
          type: 'number',
          info: '(实际 − 理论) ÷ 理论，只算主料；超出 -30% 到 +50% 标红。',
          value: (r) => _rate(r.wasteRate),
          cellColor: (context, r) => r.flags.contains('WASTE_OUT_OF_RANGE')
              ? Theme.of(context).colorScheme.errorContainer
              : null,
        ),
        MasterColumnDef(
          key: 'outcome',
          label: '处理方式',
          width: 150,
          value: (r) => _outcomeText(r.outcome),
        ),
        MasterColumnDef(
          key: 'flags',
          label: '标红原因',
          width: 220,
          value: (r) => r.flags.map(_flagText).join('；'),
          cellColor: (context, r) => r.flags.isNotEmpty
              ? Theme.of(context).colorScheme.errorContainer
              : null,
        ),
        if (showCost) ...[
          _moneyCol('unitCost', '单价', (r) => r.unitCost),
          _moneyCol(
            'currentValue',
            '金额',
            (r) => r.currentValue,
            info: '按价值现值计；下一列是结算当时的金额。',
          ),
          _moneyCol('valueAtClose', '结算时金额', (r) => r.valueAtClose),
        ],
      ],
      items: rows,
      facets: const {},
      nullCounts: const {},
      filters: const {},
      onFilterChanged: (_, _) {},
      isLoading: _loadingData && _usage == null,
      error: rows.isEmpty ? _dataError : null,
      onRetry: _loadData,
      emptyMessage: '这段时间没有内料仓用量',
      rowColor: (r) => r.flags.isEmpty
          ? null
          : Theme.of(
              context,
            ).colorScheme.errorContainer.withValues(alpha: 0.35),
    );
  }

  // ---- 产品用料 ------------------------------------------------------------

  Widget _productTable(AppLocalizations l10n) {
    final rows = _product ?? const <WmProductUsageRow>[];
    final showCost = rows.any((r) => r.hasCost);
    return MasterDataTableView<WmProductUsageRow>(
      tableKey:
          'features.production.pages.workshop_material_reports_page.WorkshopMaterialReportsPageState._productTable.1',
      key: ValueKey('wm-product-table-$showCost'),
      columns: [
        MasterColumnDef(
          key: 'period',
          label: l10n.wmReportPeriod,
          width: 190,
          filterFromRows: true,
          value: (r) => _periodText(r.periodNo, r.startDate, r.endDate),
        ),
        // 2026-09-29 用户口径：名称列只放名称，编号/颜色各占一列。
        MasterColumnDef(
          key: 'product',
          label: '产品',
          width: 180,
          filterFromRows: true,
          value: (r) => r.productName,
        ),
        MasterColumnDef(
          key: 'productCode',
          label: '编号',
          width: 110,
          filterFromRows: true,
          value: (r) => UtenGoodsAttributeCell.text(r.productCode),
          cellBuilder: (_, r) => UtenGoodsAttributeCell(r.productCode),
        ),
        MasterColumnDef(
          key: 'material',
          label: l10n.wmReportMaterial,
          width: 170,
          filterFromRows: true,
          value: (r) => r.materialName,
        ),
        MasterColumnDef(
          key: 'materialColor',
          label: '颜色',
          width: 84,
          filterFromRows: true,
          value: (r) => UtenGoodsAttributeCell.text(r.materialColorName),
          cellBuilder: (_, r) => UtenGoodsAttributeCell(r.materialColorName),
        ),
        _productQtyCol('output', '完工', (r) => r.outputQty),
        MasterColumnDef(
          key: 'unitWeight',
          label: l10n.wmUnitWeightGrams,
          width: 110,
          type: 'number',
          value: (r) => _grams(r.unitWeightGrams),
        ),
        _productQtyCol('theory', '理论', (r) => r.theoryQty),
        _productQtyCol('allocated', '分摊实际', (r) => r.allocatedQty),
        MasterColumnDef(
          key: 'basis',
          label: '口径',
          width: 130,
          info: '本期这种料只有这一个产品用，就是真实单耗；否则按理论比例分摊。',
          value: (r) => r.exclusivePeriod
              ? l10n.wmTrueUnitUsage
              : l10n.wmAllocatedByTheory,
          cellColor: (context, r) => r.exclusivePeriod
              ? Theme.of(context).colorScheme.secondaryContainer
              : null,
        ),
        MasterColumnDef(
          key: 'actualPerUnit',
          label: '实际 / 完工 (克)',
          width: 130,
          type: 'number',
          info: '只对真实单耗的行：本期实际用量 ÷ 完工，可与单个重量对比。',
          value: (r) => r.exclusivePeriod ? _grams(r.actualPerUnitGrams) : '',
        ),
        if (showCost) ...[
          MasterColumnDef(
            key: 'amount',
            label: '材料金额',
            width: 120,
            type: 'money',
            value: (r) => _money(r.materialAmount),
          ),
          MasterColumnDef(
            key: 'valueAtClose',
            label: '结算时金额',
            width: 120,
            type: 'money',
            value: (r) => _money(r.valueAtClose),
          ),
          MasterColumnDef(
            key: 'unitCost',
            label: '单件材料成本',
            width: 120,
            type: 'money',
            value: (r) => _money(r.unitMaterialCost, digits: 4),
          ),
        ],
      ],
      items: rows,
      facets: const {},
      nullCounts: const {},
      filters: const {},
      onFilterChanged: (_, _) {},
      isLoading: _loadingData && _product == null,
      error: rows.isEmpty ? _dataError : null,
      onRetry: _loadData,
      emptyMessage: '这段时间没有已结算的产品用料',
    );
  }

  // ---- 浪费率趋势 ----------------------------------------------------------

  Widget _trendView(BuildContext context, AppLocalizations l10n) {
    final theme = Theme.of(context);
    final all = _trend ?? const <WmWasteTrendPoint>[];
    if (_loadingData && _trend == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (all.isEmpty) {
      return Center(
        child: Text(
          _dataError ?? '还没有已结算的主料浪费率',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: _dataError == null
                ? theme.colorScheme.onSurfaceVariant
                : theme.colorScheme.error,
          ),
        ),
      );
    }
    final materials = <String, String>{};
    for (final p in all) {
      materials.putIfAbsent(p.materialKey, () => p.materialLabel);
    }
    final key = materials.containsKey(_trendMaterialKey)
        ? _trendMaterialKey!
        : materials.keys.first;
    final points = all.where((p) => p.materialKey == key).toList()
      ..sort((a, b) => (a.startDate ?? '').compareTo(b.startDate ?? ''));
    return ListView(
      padding: const EdgeInsets.all(UtenSpacing.s12),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: SizedBox(
            width: 320,
            child: UtenDropdownField(
              key: const Key('wm-trend-material'),
              label: l10n.wmReportMaterial,
              dense: true,
              allowClear: false,
              value: key,
              items: [
                for (final e in materials.entries)
                  UtenDropdownItem(
                    value: e.key,
                    label: e.value.isEmpty ? l10n.wmReportMaterial : e.value,
                  ),
              ],
              onChanged: (v) {
                if (v != null) setState(() => _trendMaterialKey = v);
              },
            ),
          ),
        ),
        const SizedBox(height: UtenSpacing.s12),
        Text(
          '${l10n.wmWasteRate}：横轴是每一期的起止日；虚线之外 (低于 -30% 或高于 +50%) 标红。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: UtenSpacing.s8),
        SizedBox(
          key: const Key('wm-trend-chart'),
          height: 240,
          child: CustomPaint(
            painter: _WasteTrendPainter(
              points: points,
              lineColor: theme.colorScheme.primary,
              alertColor: theme.colorScheme.error,
              gridColor: theme.colorScheme.outlineVariant,
              labelStyle:
                  theme.textTheme.labelSmall ?? const TextStyle(fontSize: 11),
            ),
            size: Size.infinite,
          ),
        ),
        const SizedBox(height: UtenSpacing.s12),
        for (final p in points)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Text(
              '${_periodText(p.periodNo, p.startDate, p.endDate)}  '
              '${l10n.wmWasteRate} ${_rate(p.wasteRate)}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: _rateOutOfRange(p.wasteRate)
                    ? theme.colorScheme.error
                    : null,
              ),
            ),
          ),
      ],
    );
  }

  // ---- 缺单重清单 ----------------------------------------------------------

  Widget _missingTable(AppLocalizations l10n) {
    final rows = _missing ?? const <WmMissingWeightRow>[];
    return MasterDataTableView<WmMissingWeightRow>(
      tableKey:
          'features.production.pages.workshop_material_reports_page.WorkshopMaterialReportsPageState._missingTable.1',
      key: const ValueKey('wm-missing-table'),
      columns: [
        MasterColumnDef(
          key: 'period',
          label: l10n.wmReportPeriod,
          width: 190,
          filterFromRows: true,
          value: (r) => _periodText(r.periodNo, r.startDate, r.endDate),
        ),
        // 2026-09-29 用户口径：名称列只放名称，编号/颜色各占一列。
        MasterColumnDef(
          key: 'product',
          label: '产品',
          width: 180,
          value: (r) => r.productName,
        ),
        MasterColumnDef(
          key: 'productCode',
          label: '编号',
          width: 110,
          value: (r) => UtenGoodsAttributeCell.text(r.productCode),
          cellBuilder: (_, r) => UtenGoodsAttributeCell(r.productCode),
        ),
        MasterColumnDef(
          key: 'material',
          label: l10n.wmReportMaterial,
          width: 180,
          value: (r) => r.materialName,
        ),
        MasterColumnDef(
          key: 'materialColor',
          label: '颜色',
          width: 84,
          value: (r) => UtenGoodsAttributeCell.text(r.materialColorName),
          cellBuilder: (_, r) => UtenGoodsAttributeCell(r.materialColorName),
        ),
        MasterColumnDef(
          key: 'output',
          label: '产量',
          width: 110,
          type: 'number',
          value: (r) => _qty(r.outputQty),
        ),
        MasterColumnDef(
          key: 'action',
          label: '去填单重',
          width: 120,
          value: (r) => l10n.wmOpenBom,
          cellBuilder: (context, r) => Text(
            l10n.wmOpenBom,
            style: TextStyle(color: Theme.of(context).colorScheme.primary),
          ),
        ),
      ],
      items: rows,
      facets: const {},
      nullCounts: const {},
      filters: const {},
      onFilterChanged: (_, _) {},
      // 一键跳到该产品的组装信息 (BOM) 页签补单个重量。
      onRowTap: (r) {
        final id = r.productGoodsId;
        if (id == null) return;
        context.push(RoutePath.basicinfoGoodsDetail(id, tab: 'bom'));
      },
      canOpenRow: (r) => r.productGoodsId != null,
      isLoading: _loadingData && _missing == null,
      error: rows.isEmpty ? _dataError : null,
      onRetry: _loadData,
      emptyMessage: '没有缺单个重量的产品',
    );
  }

  // ---- 收发明细 ------------------------------------------------------------

  Widget _ledgerTable(AppLocalizations l10n) {
    final page = _ledger;
    final rows = page?.items ?? const <WmLedgerRow>[];
    return MasterDataTableView<WmLedgerRow>(
      tableKey:
          'features.production.pages.workshop_material_reports_page.WorkshopMaterialReportsPageState._ledgerTable.1',
      key: const ValueKey('wm-ledger-table'),
      columns: [
        MasterColumnDef(
          key: 'date',
          label: '业务日期',
          width: 120,
          type: 'date',
          value: (r) => r.businessDate,
        ),
        MasterColumnDef(
          key: 'kind',
          label: '类型',
          width: 130,
          filterFromRows: true,
          value: (r) =>
              _ledgerKindText(r.sourceKind) + (r.isSupplement ? ' (补录)' : ''),
        ),
        // 2026-09-29 用户口径：名称列只放名称，原「名称 颜色」拼接拆独立颜色列。
        MasterColumnDef(
          key: 'material',
          label: l10n.wmReportMaterial,
          width: 180,
          filterFromRows: true,
          value: (r) => r.goodsName,
        ),
        MasterColumnDef(
          key: 'materialColor',
          label: '颜色',
          width: 84,
          filterFromRows: true,
          value: (r) => UtenGoodsAttributeCell.text(r.colorName),
          cellBuilder: (_, r) => UtenGoodsAttributeCell(r.colorName),
        ),
        MasterColumnDef(
          key: 'qty',
          label: '数量',
          width: 110,
          type: 'number',
          value: (r) {
            final q = r.signedQty;
            if (q == null) return '';
            return '${q > 0 ? '+' : ''}${_qty(q)}${r.unitName ?? ''}';
          },
        ),
        MasterColumnDef(
          key: 'docNo',
          label: '来源单据',
          width: 170,
          value: (r) => r.sourceLabel,
        ),
        MasterColumnDef(
          key: 'operator',
          label: '操作人',
          width: 100,
          value: (r) => r.operatorName,
        ),
        MasterColumnDef(
          key: 'period',
          label: '所属期',
          width: 80,
          value: (r) => r.periodNo == null ? '' : '第 ${r.periodNo} 期',
        ),
      ],
      items: rows,
      facets: const {},
      nullCounts: const {},
      filters: const {},
      onFilterChanged: (_, _) {},
      isLoading: _loadingData && page == null,
      loadingMore: _loadingData && page != null,
      error: rows.isEmpty ? _dataError : null,
      onRetry: _loadData,
      emptyMessage: '这段时间没有内料仓收发记录',
      currentPage: page?.page ?? 1,
      totalPages: page?.totalPages ?? 1,
      onPageChange: _loadData,
    );
  }

  // ---- 列与文字 ------------------------------------------------------------

  MasterColumnDef<WmBinUsageRow> _qtyCol(
    String key,
    String label,
    double? Function(WmBinUsageRow r) read,
  ) => MasterColumnDef(
    key: key,
    label: label,
    width: 96,
    type: 'number',
    value: (r) => _qty(read(r)),
  );

  MasterColumnDef<WmProductUsageRow> _productQtyCol(
    String key,
    String label,
    double? Function(WmProductUsageRow r) read,
  ) => MasterColumnDef(
    key: key,
    label: label,
    width: 100,
    type: 'number',
    value: (r) => _qty(read(r)),
  );

  MasterColumnDef<WmBinUsageRow> _moneyCol(
    String key,
    String label,
    double? Function(WmBinUsageRow r) read, {
    String? info,
  }) => MasterColumnDef(
    key: key,
    label: label,
    width: 110,
    type: 'money',
    info: info,
    value: (r) => _money(read(r)),
  );

  String _periodStatusText(WmReportPeriod p) => switch (p.status) {
    'OPEN' => '进行中',
    'COUNTING' => '盘点中',
    'COUNTED' => '已盘点',
    'CLOSED' => '已结算',
    _ => '',
  };
}

// ---- 结算状态卡 --------------------------------------------------------------

class _CloseStatusCard extends StatelessWidget {
  const _CloseStatusCard({
    required this.period,
    required this.status,
    required this.error,
    required this.onRetry,
    required this.onReopen,
    required this.onReload,
  });

  final WmReportPeriod period;
  final WmReportCloseStatus? status;
  final String? error;
  final VoidCallback onRetry;
  final VoidCallback onReopen;
  final VoidCallback onReload;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final s = status;
    final lines = <Widget>[];
    var alert = false;
    if (s == null) {
      lines.add(
        error == null
            ? const LinearProgressIndicator()
            : Row(
                children: [
                  Expanded(
                    child: Text(
                      error!,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ),
                  TextButton(onPressed: onReload, child: const Text('重试')),
                ],
              ),
      );
    } else {
      lines.add(
        Text(
          _headline(s),
          key: const Key('wm-close-headline'),
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
      );
      if (s.closeState == 'BLOCKED' || s.blockers.isNotEmpty) {
        alert = s.blockers.any((b) => b.kind != 'PREVIOUS_PERIOD_OPEN');
        for (final b in s.blockers) {
          lines.add(
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '· ${_blockerText(l10n, b)}',
                key: ValueKey('wm-close-blocker-${b.kind}'),
                style: theme.textTheme.bodySmall,
              ),
            ),
          );
        }
      }
      if (s.closeState == 'HELD') {
        lines.add(
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              l10n.wmReopenHeld(
                ChinaDateTime.formatIsoInstant(
                  s.heldUntil,
                  fallback: s.heldUntil ?? '',
                ),
              ),
              key: const Key('wm-close-held'),
              style: theme.textTheme.bodySmall,
            ),
          ),
        );
      }
      if (s.closeState == 'FAILED') {
        alert = true;
        lines.add(
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              s.failures >= 3
                  ? l10n.wmCloseFailing
                  : '结算没有成功，系统会自动重试。'
                        '${s.lastErrorMessage == null ? '' : '原因：${s.lastErrorMessage}'}',
              key: const Key('wm-close-failed'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
        );
        if (s.failures >= 3 && s.lastErrorMessage != null) {
          lines.add(
            Text(
              '原因：${s.lastErrorMessage}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          );
        }
      }
      if (s.lastCloseNo != null) {
        lines.add(
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              [
                '第 ${s.lastCloseNo} 次结算',
                if (s.lastClosedAt != null)
                  ChinaDateTime.formatIsoInstant(
                    s.lastClosedAt,
                    fallback: s.lastClosedAt!,
                  ),
                if (s.lastClosedByName != null) s.lastClosedByName!,
              ].join(' · '),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        );
      }
    }
    final actions = <Widget>[
      if (s != null && s.can('CLOSE_RETRY'))
        UtenButton(
          key: const Key('wm-close-retry'),
          size: UtenButtonSize.small,
          onPressed: onRetry,
          child: Text(
            s.closeState == 'HELD' ? l10n.wmSettleAgain : l10n.wmCloseRetry,
          ),
        ),
      if (s != null && s.can('REOPEN'))
        UtenButton(
          key: const Key('wm-close-reopen'),
          size: UtenButtonSize.small,
          type: UtenButtonType.danger,
          onPressed: onReopen,
          child: Text(l10n.wmReopen),
        ),
    ];
    return Container(
      key: const Key('wm-close-status-card'),
      width: double.infinity,
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: alert
            ? theme.colorScheme.errorContainer.withValues(alpha: 0.45)
            : theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(UtenRadius.control),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                alert ? Icons.error_outline_rounded : Icons.fact_check_outlined,
                size: 20,
                color: alert
                    ? theme.colorScheme.error
                    : theme.colorScheme.primary,
              ),
              const SizedBox(width: UtenSpacing.s8),
              Expanded(
                child: Text(
                  '${l10n.wmCloseState} · ${period.label}',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s8),
          ...lines,
          if (actions.isNotEmpty) ...[
            const SizedBox(height: UtenSpacing.s8),
            Wrap(
              spacing: UtenSpacing.s8,
              runSpacing: UtenSpacing.s8,
              children: actions,
            ),
          ],
        ],
      ),
    );
  }

  String _headline(WmReportCloseStatus s) {
    switch (s.status) {
      case 'OPEN':
        return '这一期还没盘点';
      case 'COUNTING':
        return '正在盘点，提交盘点后系统自动结算';
      case 'CLOSED':
        return '已结算';
      case 'COUNTED':
        return switch (s.closeState) {
          'QUEUED' => '已盘点，正在结算…',
          'BLOCKED' => '已盘点，结算被下面的事拦住；补完后系统自动结算',
          'HELD' => '已撤销结算',
          'FAILED' => '已盘点，结算没有成功',
          _ => '已盘点，等待结算',
        };
      default:
        return '';
    }
  }

  String _blockerText(AppLocalizations l10n, WmReportCloseBlocker b) {
    final samples = b.samples.take(5).join('、');
    final base = switch (b.kind) {
      'PREVIOUS_PERIOD_OPEN' => l10n.wmCloseWaitingPrevious,
      'DRAFT_REPORT' =>
        l10n.wmCloseBlockedReport(b.count) +
            (samples.isEmpty ? '' : '：$samples'),
      'MISSING_WEIGHT' =>
        l10n.wmCloseBlockedWeight(b.count) +
            (samples.isEmpty ? '' : '：$samples'),
      'THEORY_WITHOUT_STOCK' =>
        l10n.wmCloseBlockedStock(b.samples.isEmpty ? '有一种料' : b.samples.first) +
            (b.count > 1 ? ' (共 ${b.count} 种料)' : ''),
      _ => '还有 ${b.count} 项没处理完',
    };
    final who = b.responsible;
    return who == null ? base : '$base；负责：$who';
  }
}

// ---- 撤销原因弹窗 ------------------------------------------------------------

class _ReopenReasonDialog extends StatefulWidget {
  const _ReopenReasonDialog();

  @override
  State<_ReopenReasonDialog> createState() => _ReopenReasonDialogState();
}

class _ReopenReasonDialogState extends State<_ReopenReasonDialog> {
  final _ctl = TextEditingController();
  String? _error;

  @override
  void initState() {
    super.initState();
    _ctl.addListener(_onChanged);
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _ctl.text.trim();
    if (text.length < 2 || text.length > 500) {
      setState(() => _error = '请写清撤销原因 (2 到 500 个字)');
      return;
    }
    Navigator.of(context).pop(text);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(l10n.wmReopen),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '撤销后这一期的金额从各工单成本里退回；改完后点「${l10n.wmSettleAgain}」，'
              '或 24 小时后系统自动重新结算。撤销需要再输一次登录密码。',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: UtenSpacing.s12),
            TextField(
              key: const Key('wm-reopen-reason'),
              controller: _ctl,
              autofocus: true,
              maxLines: 3,
              maxLength: 500,
              decoration: UtenInputDecoration(
                applyRequiredEmpty(
                  InputDecoration(
                    labelText: '${l10n.wmReopenReason} *',
                    error: _error == null
                        ? null
                        : UtenFieldMessage.error(_error!),
                    border: const OutlineInputBorder(),
                  ),
                  theme,
                  requiredEmpty: _ctl.text.trim().isEmpty,
                ),
              ),
            ),
          ],
        ),
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('wm-reopen-confirm'),
          style: FilledButton.styleFrom(
            backgroundColor: theme.colorScheme.error,
          ),
          onPressed: _submit,
          child: Text(l10n.wmReopen),
        ),
      ],
    );
  }
}

// ---- 浪费率折线 --------------------------------------------------------------

class _WasteTrendPainter extends CustomPainter {
  _WasteTrendPainter({
    required this.points,
    required this.lineColor,
    required this.alertColor,
    required this.gridColor,
    required this.labelStyle,
  });

  final List<WmWasteTrendPoint> points;
  final Color lineColor;
  final Color alertColor;
  final Color gridColor;
  final TextStyle labelStyle;

  static const _low = -30.0;
  static const _high = 50.0;

  @override
  void paint(Canvas canvas, Size size) {
    const left = 48.0;
    const bottom = 28.0;
    const top = 8.0;
    const right = 12.0;
    final width = size.width - left - right;
    final height = size.height - top - bottom;
    if (width <= 0 || height <= 0) return;

    final rates = [
      for (final p in points)
        if (p.wasteRate != null) p.wasteRate! * 100,
    ];
    var lo = math.min(_low, rates.isEmpty ? _low : rates.reduce(math.min));
    var hi = math.max(_high, rates.isEmpty ? _high : rates.reduce(math.max));
    lo -= 10;
    hi += 10;
    double y(double v) => top + (hi - v) / (hi - lo) * height;
    double x(int i) => points.length <= 1
        ? left + width / 2
        : left + i * width / (points.length - 1);

    final grid = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    final alertLine = Paint()
      ..color = alertColor.withValues(alpha: 0.7)
      ..strokeWidth = 1;
    for (final v in [_low, 0.0, _high]) {
      final yy = y(v);
      final paint = v == 0 ? grid : alertLine;
      // 虚线：阈值线；实线：0 线。
      if (v == 0) {
        canvas.drawLine(Offset(left, yy), Offset(left + width, yy), paint);
      } else {
        for (var dx = left; dx < left + width; dx += 8) {
          canvas.drawLine(
            Offset(dx, yy),
            Offset(math.min(dx + 4, left + width), yy),
            paint,
          );
        }
      }
      _text(canvas, '${v.toStringAsFixed(0)}%', Offset(4, yy - 7));
    }

    final line = Paint()
      ..color = lineColor
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final path = Path();
    var started = false;
    for (var i = 0; i < points.length; i++) {
      final r = points[i].wasteRate;
      if (r == null) continue;
      final o = Offset(x(i), y(r * 100));
      if (started) {
        path.lineTo(o.dx, o.dy);
      } else {
        path.moveTo(o.dx, o.dy);
        started = true;
      }
    }
    canvas.drawPath(path, line);
    final step = math.max(1, (points.length / 8).ceil());
    for (var i = 0; i < points.length; i++) {
      final r = points[i].wasteRate;
      if (r != null) {
        final v = r * 100;
        final out = v < _low || v > _high;
        canvas.drawCircle(
          Offset(x(i), y(v)),
          out ? 5 : 3.5,
          Paint()..color = out ? alertColor : lineColor,
        );
      }
      if (i % step == 0 || i == points.length - 1) {
        final end = points[i].endDate ?? points[i].startDate ?? '';
        final label = end.length >= 10 ? end.substring(5, 10) : end;
        _text(canvas, label, Offset(x(i) - 16, top + height + 8));
      }
    }
  }

  void _text(Canvas canvas, String text, Offset at) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: labelStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, at);
  }

  @override
  bool shouldRepaint(covariant _WasteTrendPainter old) =>
      old.points != points ||
      old.lineColor != lineColor ||
      old.alertColor != alertColor;
}

// ---- 文字与数字 --------------------------------------------------------------

String _qty(double? v) {
  if (v == null) return '';
  if (v == v.roundToDouble()) return v.toStringAsFixed(0);
  return v
      .toStringAsFixed(4)
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
}

String _grams(double? v) {
  if (v == null) return '';
  final fixed = v.toStringAsFixed(3);
  return fixed
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
}

String _money(double? v, {int digits = 2}) =>
    v == null ? '' : v.toStringAsFixed(digits);

String _rate(double? v) => v == null ? '' : '${(v * 100).toStringAsFixed(1)}%';

bool _rateOutOfRange(double? v) => v != null && (v * 100 < -30 || v * 100 > 50);

String _periodText(int? no, String? start, String? end) {
  final head = no == null ? '' : '第 $no 期 ';
  final range = end == null ? '${start ?? ''} 起' : '${start ?? ''} 至 $end';
  return '$head$range'.trim();
}

String _outcomeText(String? outcome) => switch (outcome) {
  'ALLOCATED' => '按理论比例分到工单',
  'UNALLOCATED_LOSS' => '有实际没理论，记损失',
  'GAIN' => '盘盈',
  'NOTHING' => '本期没用',
  'EXPENSED' => '记车间费用',
  null => '未结算',
  _ => '',
};

String _flagText(String flag) => switch (flag) {
  'WASTE_OUT_OF_RANGE' => '浪费率超出 -30% 到 +50%',
  'OTHER_ISSUE_LARGE' => '试模清机等用料偏多',
  'ACTUAL_WITHOUT_THEORY' => '有实际用量但没有报工',
  'GAIN_PRICE_ZERO' => '盘盈没有参考价，按 0 计',
  _ => '需要核对',
};

String _ledgerKindText(String? kind) => switch (kind) {
  'ISSUE' => '领入',
  'RETURN' => '退回仓库',
  'OTHER_ISSUE' => '试模清机等用料',
  'CONSUME' => '盘点耗用',
  'CONSUME_REVERSE' => '盘点耗用冲回',
  'GAIN' => '盘盈',
  'GAIN_REVERSE' => '盘盈冲回',
  _ => '',
};
