import 'package:uten_imp/components/buttons/uten_refresh_button.dart';
// 车间内料仓用量报表与结算页 (ADR-131 §5.10；路由 /reports/workshop-material)。
//
// 入口：生产 hub 报表中心、财务 hub 报表中心 (同一路由)。报表一律不挂数。
//
// - 顶部选内料仓与期间 (「全部期间」= 本仓每一期)；
// - 结算状态卡：本期 (或最近一次盘点的那一期) 盘点 / 结算到哪一步、被什么拦住、
//   该谁来补；「立即重试」「重新结算」「撤销结算」只按服务端下发的 allowedActions
//   显示 (不在页面里判断权限)。撤销结算要再认证：服务端回「需要再认证」时网络层
//   统一弹密码框，输完原请求自动重发。重试后每 2 秒查一次结算状态，最多 60 秒；
// - 五个分段：用量表 / 产品用料 / 耗用差异率趋势 / 缺单重清单 / 收发明细，都用
//   MasterDataTableView。金额列只在服务端下发了金额时出现 (没有看成本权限的人
//   收到的金额为空，整列隐藏)。缺单重清单点行直接跳到该产品的组装信息 (BOM) 填单重。
// - 网络写操作期间由本页持有 UtenBusyOverlay；弹原因框前先撤遮罩。
import 'package:uten_imp/components/feedback/uten_dialog.dart';
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
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/paging/scoped_paged_read_view_mixin.dart';
import '../../basic_data/widgets/goods_issue_method_dialog.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/workshop_material_report_models.dart';
import '../repositories/workshop_material_report_repository.dart';
import 'package:uten_imp/components/layout/uten_page_layout.dart';

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
    extends ConsumerState<WorkshopMaterialReportsPage>
    with ScopedPagedReadViewMixin<WorkshopMaterialReportsPage> {
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
  final _ledgerRows = MasterDataTableRowsController<WmLedgerRow>();
  Object? _acceptedLedgerQuery;
  bool _loadingData = false;
  String? _dataError;
  int _dataRequest = 0;
  int _metadataEpoch = 0;

  @override
  void scopedPagedReadOwnerChanged() {
    _stopPolling();
    setState(() {
      _metadataEpoch++;
      _ledgerRows.update(const []);
      _acceptedLedgerQuery = null;
      _dataRequest++;
      _closeRequest++;
      _bins = const [];
      _periods = const [];
      _binId = null;
      _periodId = null;
      _usage = null;
      _product = null;
      _trend = null;
      _missing = null;
      _ledger = null;
      _closeStatus = null;
      _loadingMeta = false;
      _loadingData = false;
      _metaError = scopedPagedReadRejection?.message;
      _dataError = scopedPagedReadRejection?.message;
      _closeError = null;
    });
  }

  /// 耗用差异率趋势当前看的料 (货品 + 颜色)。
  String? _trendMaterialKey;
  final _reportHeaderKey = GlobalKey(debugLabel: 'wm-report-header');
  final _reportBodyKey = GlobalKey(debugLabel: 'wm-report-body');

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
    final epoch = _metadataEpoch;
    setState(() {
      _loadingMeta = true;
      _metaError = null;
    });
    try {
      final bins = await _repo.bins();
      if (!mounted || epoch != _metadataEpoch) return;
      final preferred = widget.initialBinId ?? _binId;
      setState(() {
        _bins = bins;
        _binId = bins.any((b) => b.binWarehouseId == preferred)
            ? preferred
            : (bins.isEmpty ? null : bins.first.binWarehouseId);
      });
      await _loadPeriods(initial: true);
    } on ApiException catch (e) {
      if (!mounted || epoch != _metadataEpoch) return;
      setState(() => _metaError = e.message);
    } catch (_) {
      if (!mounted || epoch != _metadataEpoch) return;
      setState(() => _metaError = '读取车间内料仓失败，请重试');
    } finally {
      if (mounted && epoch == _metadataEpoch) {
        setState(() => _loadingMeta = false);
      }
    }
  }

  Future<void> _loadPeriods({bool initial = false}) async {
    if (!mounted) return;
    final epoch = _metadataEpoch;
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
      if (!mounted || epoch != _metadataEpoch || binId != _binId) return;
      final wanted = initial ? widget.initialPeriodId : _periodId;
      setState(() {
        _periods = periods;
        _periodId = periods.any((p) => p.id == wanted) ? wanted : null;
      });
    } on ApiException catch (e) {
      if (!mounted || epoch != _metadataEpoch) return;
      setState(() => _metaError = e.message);
    } catch (_) {
      if (!mounted || epoch != _metadataEpoch) return;
      setState(() => _metaError = '读取盘点期间失败，请重试');
    }
    if (!mounted || epoch != _metadataEpoch) return;
    await Future.wait([_loadData(), _loadCloseStatus()]);
  }

  Future<void> _loadData([int? page, bool useCache = false]) async {
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
    final readQuery = (_repo, binId, from, to, view);
    page ??= _acceptedLedgerQuery == readQuery
        ? _ledgerRows.visiblePage ?? _ledger?.page ?? 1
        : 1;
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
          final repository = _repo;
          final result = await readScopedPage<WmLedgerRow>(
            page,
            query: (repository, binId, from, to, view),
            currentQuery: () => (
              _repo,
              _binId,
              _selectedPeriod?.startDate,
              _selectedPeriod?.endDate,
              _view,
            ),
            useCache: useCache,
            fetchPage: (page) =>
                repository.ledger(binId, from: from, to: to, page: page),
          );
          if (mounted && request == _dataRequest) {
            setState(() {
              _ledger = result;
              _acceptedLedgerQuery = readQuery;
            });
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

  Future<void> _refresh() => _bins.isEmpty ? _loadBins() : _loadPeriods();

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
        actions: [UtenRefreshButton(enabled: !(_busy), onRefresh: _refresh)],
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
    return UtenCollapsingHeaderScrollView(
      key: const Key('wm-report-coordinator'),
      collapsingHeader: Column(
        key: _reportHeaderKey,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(0, UtenSpacing.s12, 0, 0),
            child: _selectors(l10n),
          ),
          if (_statusPeriod != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(0, UtenSpacing.s12, 0, 0),
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
            padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s8),
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
        ],
      ),
      body: KeyedSubtree(key: _reportBodyKey, child: _viewBody(context, l10n)),
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
      expensiveRowMounts: false,
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
        _qtyCol('adjustment', '已审核账面修正', (r) => r.adjustmentQty),
        _qtyCol('closing', '期末', (r) => r.closingQty),
        _qtyCol('actual', '盘点推算耗用', (r) => r.actualQty),
        MasterColumnDef(
          key: 'countEvidence',
          label: '盘点来源',
          width: 300,
          info: '期初沿用上期已提交盘点；满、半、空都属于估盘。称重和袋数也不代表逐产品实测。',
          value: (r) => r.countEvidenceLabel,
        ),
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
          width: 125,
          type: 'number',
          info: '(盘点推算耗用 − 理论) ÷ 理论；含估盘、漏录和单重误差，不能直接当作报废率。超出 -30% 到 +50% 标红。',
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
      expensiveRowMounts: false,
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
          value: (r) => r.unitWeightGrams == null && r.unitWeightBase != null
              ? '未设置重量换算'
              : _grams(r.unitWeightGrams),
          info: '按材料基本单位的重量档案换成克；没有配置换算时不猜，需维护该单位的重量编码。',
        ),
        MasterColumnDef(
          key: 'materialUnit',
          label: '材料单位',
          width: 100,
          info: '理论和分摊耗用使用此材料基本单位；单个重量与独占期平均换算成克显示。',
          value: (r) => r.materialUnitName ?? '未提供',
        ),
        _productQtyCol('theory', '理论', (r) => r.theoryQty),
        _productQtyCol('allocated', '分摊耗用', (r) => r.allocatedQty),
        MasterColumnDef(
          key: 'basis',
          label: '口径',
          width: 150,
          info: '本期这种料只有一个产品用时给独占期平均耗用，仍受盘点与报工误差影响；多产品按理论比例分摊。',
          value: (r) => r.exclusivePeriod
              ? l10n.wmTrueUnitUsage
              : l10n.wmAllocatedByTheory,
          cellColor: (context, r) => r.exclusivePeriod
              ? Theme.of(context).colorScheme.secondaryContainer
              : null,
        ),
        MasterColumnDef(
          key: 'countEvidence',
          label: '盘点来源',
          width: 300,
          value: (r) => r.countEvidenceLabel,
        ),
        MasterColumnDef(
          key: 'actualPerUnit',
          label: '独占期平均 (克/件)',
          width: 155,
          type: 'number',
          info: '独占期分摊耗用 ÷ 完工量；含估盘时也是估算值，不是逐件称量的单耗。',
          value: (r) => !r.exclusivePeriod
              ? ''
              : r.actualPerUnitGrams == null && r.actualPerUnitBase != null
              ? '未设置重量换算'
              : _grams(r.actualPerUnitGrams),
        ),
        if (showCost) ...[
          MasterColumnDef(
            key: 'amount',
            label: '材料金额',
            width: 120,
            type: 'money',
            aiSensitive: true,
            value: (r) => _money(r.materialAmount),
          ),
          MasterColumnDef(
            key: 'valueAtClose',
            label: '结算时金额',
            width: 120,
            type: 'money',
            aiSensitive: true,
            value: (r) => _money(r.valueAtClose),
          ),
          MasterColumnDef(
            key: 'unitCost',
            label: '单件材料成本',
            width: 120,
            type: 'money',
            aiSensitive: true,
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

  // ---- 耗用差异率趋势 ------------------------------------------------------

  Widget _trendView(BuildContext context, AppLocalizations l10n) {
    final theme = Theme.of(context);
    final all = _trend ?? const <WmWasteTrendPoint>[];
    if (_loadingData && _trend == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (all.isEmpty) {
      return Center(
        child: Text(
          _dataError ?? '还没有已结算的主料耗用差异率',
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
    return UtenPageEdgePadding.scroll(
      padding: const EdgeInsets.all(UtenSpacing.s12),
      builder: (context, resolvedPagePadding) => ListView(
        key: const Key('wm-trend-scroll'),
        padding: resolvedPagePadding,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(
              width: 320,
              child: UtenDropdownField(
                key: const Key('wm-trend-material'),
                label: l10n.wmReportMaterial,
                info:
                    '${l10n.wmWasteRate}：反映盘点耗用与理论的差额，不等于报废率。'
                    '空心点含容器估盘；低于 -30% 或高于 +50% 标红。',
                selectedMaxLines: null,
                menuMatchContentWidth: true,
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
          const SizedBox(height: UtenSpacing.s8),
          _WasteTrendChart(key: const Key('wm-trend-chart'), points: points),
          const SizedBox(height: UtenSpacing.s12),
          for (final p in points)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: DefaultTextStyle.merge(
                style: theme.textTheme.bodySmall?.copyWith(
                  color: _rateOutOfRange(p.wasteRate)
                      ? theme.colorScheme.error
                      : null,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_periodText(p.periodNo, p.startDate, p.endDate)),
                    Text(
                      '${l10n.wmWasteRate} ${p.hasEstimatedCount ? '≈ ' : ''}${_rate(p.wasteRate)}',
                    ),
                    Text(p.countEvidenceLabel),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ---- 缺单重清单 ----------------------------------------------------------

  Widget _missingTable(AppLocalizations l10n) {
    final rows = _missing ?? const <WmMissingWeightRow>[];
    return MasterDataTableView<WmMissingWeightRow>(
      expensiveRowMounts: false,
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
      rowsController: _ledgerRows,
      expensiveRowMounts: false,
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
      paginationScope: (
        _binId,
        _periodId,
        _view,
        _selectedPeriod?.startDate,
        _selectedPeriod?.endDate,
      ),
      onPageChange: (page) => _loadData(page, true),
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
    // Material cost (cost permission): never sent to the AI assistant.
    aiSensitive: true,
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
    return UtenAlertDialog(
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

// ---- 耗用差异率折线 ----------------------------------------------------------

class _WasteTrendChart extends StatefulWidget {
  const _WasteTrendChart({super.key, required this.points});
  final List<WmWasteTrendPoint> points;
  @override
  State<_WasteTrendChart> createState() => _WasteTrendChartState();
}

class _WasteTrendChartState extends State<_WasteTrendChart> {
  final _horizontal = ScrollController();
  @override
  void dispose() {
    _horizontal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, box) {
        final painter = WasteTrendPainter(
          points: widget.points,
          lineColor: theme.colorScheme.primary,
          alertColor: theme.colorScheme.error,
          gridColor: theme.colorScheme.outlineVariant,
          labelStyle:
              theme.textTheme.labelSmall ?? const TextStyle(fontSize: 11),
          textScaler: MediaQuery.textScalerOf(context),
          textDirection: Directionality.of(context),
          locale: Localizations.maybeLocaleOf(context),
        );
        final chartSize = Size(
          math.max(box.maxWidth, painter.minimumWidth),
          painter.minimumHeight,
        );
        return SizedBox(
          height: chartSize.height + UtenSpacing.s12,
          child: Scrollbar(
            controller: _horizontal,
            thumbVisibility: true,
            notificationPredicate: (notification) =>
                notification.metrics.axis == Axis.horizontal,
            child: SingleChildScrollView(
              controller: _horizontal,
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: chartSize.width,
                height: chartSize.height,
                child: CustomPaint(
                  key: const Key('wm-trend-chart-canvas'),
                  painter: painter,
                  size: chartSize,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class WasteTrendPainter extends CustomPainter {
  WasteTrendPainter({
    required this.points,
    required this.lineColor,
    required this.alertColor,
    required this.gridColor,
    required this.labelStyle,
    required this.textScaler,
    required this.textDirection,
    required this.locale,
  });

  final List<WmWasteTrendPoint> points;
  final Color lineColor;
  final Color alertColor;
  final Color gridColor;
  final TextStyle labelStyle;
  final TextScaler textScaler;
  final TextDirection textDirection;
  final Locale? locale;

  static const _low = -30.0;
  static const _high = 50.0;

  late final range = _range();
  (double, double) _range() {
    final rates = [
      for (final p in points)
        if (p.wasteRate != null) p.wasteRate! * 100,
    ];
    return (
      math.min(_low, rates.isEmpty ? _low : rates.reduce(math.min)) - 10,
      math.max(_high, rates.isEmpty ? _high : rates.reduce(math.max)) + 10,
    );
  }

  TextPainter _labelPainter(String text) => TextPainter(
    text: TextSpan(text: text, style: labelStyle),
    textDirection: textDirection,
    textScaler: textScaler,
    locale: locale,
    maxLines: 1,
  )..layout();

  Size _measure(String text) {
    final painter = _labelPainter(text);
    final result = painter.size;
    painter.dispose();
    return result;
  }

  String _date(int i) {
    final end = points[i].endDate ?? points[i].startDate ?? '';
    return end.length >= 10 ? end.substring(5, 10) : end;
  }

  late final _ticks = [
    for (final v in [_low, 0.0, _high])
      (
        value: v,
        text: '${v.toStringAsFixed(0)}%',
        size: _measure('${v.toStringAsFixed(0)}%'),
      ),
  ];
  late final _dates = [
    for (var i = 0; i < points.length; i++)
      if (i % math.max(1, (points.length / 8).ceil()) == 0 ||
          i == points.length - 1)
        (index: i, text: _date(i), size: _measure(_date(i))),
  ];
  late final _left = math.max(
    48.0,
    math.max(
      _ticks.map((tick) => tick.size.width).reduce(math.max) + 8,
      _dates.first.size.width / 2 + 4,
    ),
  );
  late final _right = math.max(12.0, _dates.last.size.width / 2 + 4);
  late final _tickHeight = _ticks
      .map((tick) => tick.size.height)
      .reduce(math.max);
  late final _top = math.max(8.0, _tickHeight / 2 + 4);
  late final _bottom = math.max(
    28.0,
    _dates.map((date) => date.size.height).reduce(math.max) + 12,
  );

  double get minimumWidth {
    var plot = 120.0;
    for (var i = 1; i < _dates.length; i++) {
      final before = _dates[i - 1], after = _dates[i];
      final needed = (before.size.width + after.size.width) / 2 + 8;
      plot = math.max(
        plot,
        needed * (points.length - 1) / (after.index - before.index),
      );
    }
    return _left + plot + _right;
  }

  double get minimumHeight =>
      math.max(240.0, _tickHeight * 4 + 24 + _top + _bottom);

  Rect plotRect(Size size) =>
      Rect.fromLTRB(_left, _top, size.width - _right, size.height - _bottom);
  double _x(int i, Rect rect) => points.length <= 1
      ? rect.center.dx
      : rect.left + i * rect.width / (points.length - 1);
  double _y(double value, Rect rect) =>
      rect.top + (range.$2 - value) / (range.$2 - range.$1) * rect.height;

  List<Rect> _tickLabelBounds(Rect rect) {
    // Extreme rates can cluster the unchanged -30/0/+50 threshold lines.
    // Place readable labels in the axis slot with leaders to their actual y;
    // the numeric domain must not make the painted surface arbitrarily tall.
    final descending = _ticks.reversed.toList();
    final centers = [for (final tick in descending) _y(tick.value, rect)];
    final gap = _tickHeight + 8;
    for (var i = 1; i < centers.length; i++) {
      centers[i] = math.max(centers[i], centers[i - 1] + gap);
    }
    centers.last = math.min(centers.last, rect.bottom - _tickHeight / 2);
    for (var i = centers.length - 2; i >= 0; i--) {
      centers[i] = math.min(centers[i], centers[i + 1] - gap);
    }
    centers.first = math.max(centers.first, rect.top + _tickHeight / 2);
    for (var i = 1; i < centers.length; i++) {
      centers[i] = math.max(centers[i], centers[i - 1] + gap);
    }
    return [
      for (var i = descending.length - 1; i >= 0; i--)
        Rect.fromLTWH(
          4,
          centers[i] - descending[i].size.height / 2,
          descending[i].size.width,
          descending[i].size.height,
        ),
    ];
  }

  /// These are the actual painted label bounds, including the first/last dates.
  List<({String text, Rect bounds, bool date})> labelBounds(Size size) {
    final rect = plotRect(size);
    final tickBounds = _tickLabelBounds(rect);
    return [
      for (var i = 0; i < _ticks.length; i++)
        (text: _ticks[i].text, bounds: tickBounds[i], date: false),
      for (final date in _dates)
        (
          text: date.text,
          bounds: Rect.fromLTWH(
            _x(date.index, rect) - date.size.width / 2,
            rect.bottom + 8,
            date.size.width,
            date.size.height,
          ),
          date: true,
        ),
    ];
  }

  @override
  void paint(Canvas canvas, Size size) {
    final rect = plotRect(size);
    final left = rect.left, width = rect.width, height = rect.height;
    if (width <= 0 || height <= 0) return;

    double y(double v) => _y(v, rect);
    double x(int i) => _x(i, rect);

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
    for (var i = 0; i < points.length; i++) {
      final r = points[i].wasteRate;
      if (r != null) {
        final v = r * 100;
        final out = v < _low || v > _high;
        canvas.drawCircle(
          Offset(x(i), y(v)),
          out ? 5 : 3.5,
          Paint()
            ..color = out ? alertColor : lineColor
            ..strokeWidth = 2
            ..style = points[i].hasEstimatedCount
                ? PaintingStyle.stroke
                : PaintingStyle.fill,
        );
      }
    }
    final labels = labelBounds(size);
    for (var i = 0; i < _ticks.length; i++) {
      final label = labels[i];
      final actualY = y(_ticks[i].value);
      if ((label.bounds.center.dy - actualY).abs() > 1e-6) {
        final leader = _ticks[i].value == 0 ? grid : alertLine;
        final gutter = Offset(left - 2, label.bounds.center.dy);
        canvas.drawLine(
          Offset(label.bounds.right + 2, label.bounds.center.dy),
          gutter,
          leader,
        );
        canvas.drawLine(gutter, Offset(left - 2, actualY), leader);
      }
    }
    for (final label in labels) {
      _text(canvas, label.text, label.bounds.topLeft);
    }
  }

  void _text(Canvas canvas, String text, Offset at) {
    final painter = _labelPainter(text);
    painter.paint(canvas, at);
    painter.dispose();
  }

  @override
  bool shouldRepaint(covariant WasteTrendPainter old) =>
      old.points != points ||
      old.lineColor != lineColor ||
      old.alertColor != alertColor ||
      old.gridColor != gridColor ||
      old.labelStyle != labelStyle ||
      old.textScaler != textScaler ||
      old.textDirection != textDirection ||
      old.locale != locale;
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
  'UNALLOCATED_LOSS' => '有盘点耗用没理论，记损失',
  'GAIN' => '盘盈',
  'NOTHING' => '本期没用',
  'EXPENSED' => '记车间费用',
  null => '未结算',
  _ => '',
};

String _flagText(String flag) => switch (flag) {
  'WASTE_OUT_OF_RANGE' => '耗用差异率超出 -30% 到 +50%',
  'OTHER_ISSUE_LARGE' => '试模清机等用料偏多',
  'ACTUAL_WITHOUT_THEORY' => '有盘点耗用但没有报工',
  'GAIN_PRICE_ZERO' => '盘盈没有参考价，按 0 计',
  _ => '需要核对',
};

String _ledgerKindText(String? kind) => switch (kind) {
  'OPENING' => '已审核期初盘点',
  'ADJUSTMENT' => '已审核账面修正',
  'ISSUE' => '领入',
  'RETURN' => '退回仓库',
  'OTHER_ISSUE' => '试模清机等用料',
  'CONSUME' => '盘点耗用',
  'CONSUME_REVERSE' => '盘点耗用冲回',
  'GAIN' => '盘盈',
  'GAIN_REVERSE' => '盘盈冲回',
  _ => '',
};
