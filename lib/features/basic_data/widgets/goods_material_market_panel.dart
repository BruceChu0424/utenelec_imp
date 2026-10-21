import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/layout/uten_adaptive_panel.dart';
import '../../../components/layout/uten_picker_confirm_bar.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/utils/display_datetime.dart';
import '../../../shared/auth/native_read_view_scope_mixin.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/formatters/exact_decimal.dart';
import '../../../shared/pricing/material_market_l10n.dart';
import '../../../shared/pricing/material_market_models.dart';
import '../../../shared/pricing/material_market_repository.dart';
import '../../../shared/pricing/price_analysis_models.dart';

/// Optional market evidence. It never changes the historical reference or
/// transaction chart, and an unavailable snapshot cannot block those reads.
class GoodsMaterialMarketPanel extends ConsumerStatefulWidget {
  const GoodsMaterialMarketPanel({
    super.key,
    required this.goodsId,
    required this.contextIdentity,
  });

  final String goodsId;
  final String contextIdentity;

  @override
  ConsumerState<GoodsMaterialMarketPanel> createState() =>
      _GoodsMaterialMarketPanelState();
}

class _GoodsMaterialMarketPanelState
    extends ConsumerState<GoodsMaterialMarketPanel>
    with
        NativeReadViewScopeMixin<GoodsMaterialMarketPanel>,
        WidgetsBindingObserver {
  MaterialMarketAnalysis? _data;
  bool _loading = false, _saving = false, _picking = false;
  bool _catalogBusy = false;
  bool _syncVerified = false;
  String? _error;
  int _revision = 0;
  final _routes = <ModalRoute<dynamic>>{};
  Timer? _expiryTimer;
  Timer? _deadlineTimer;
  bool _expiryRefreshPending = false;
  ModalRoute<dynamic>? _pageRoute;

  bool get _foreground =>
      (WidgetsBinding.instance.lifecycleState == null ||
          WidgetsBinding.instance.lifecycleState ==
              AppLifecycleState.resumed) &&
      (_pageRoute?.isCurrent ?? true);
  DateTime get _now => ref.read(materialMarketClockProvider)();

  String get _identity => '${widget.goodsId}|${widget.contextIdentity}';
  bool get _allowed {
    if (ref.read(isSuperAdminProvider)) return true;
    final grants = ref.read(currentPermissionsProvider);
    return grants.containsAll({Perm.goodsView, Perm.goodsPriceAnalysisView}) &&
        (grants.contains(Perm.purchaseOrderView) ||
            grants.contains(Perm.financeOrderApprovalView)) &&
        (grants.contains(Perm.purchaseOrderPriceView) ||
            grants.contains(Perm.financeViewAll));
  }

  bool get _canManage =>
      _allowed &&
      nativeReadCanWrite &&
      _data?.canManage == true &&
      !_loading &&
      !_saving;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    initializeNativeReadScope();
    ref.listenManual(currentPermissionsProvider, (_, _) {
      invalidateNativeReadAccess();
      _clear();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load();
      });
    });
    ref.listenManual(isSuperAdminProvider, (_, _) {
      invalidateNativeReadAccess();
      _clear();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load();
      });
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void didUpdateWidget(covariant GoodsMaterialMarketPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.goodsId != widget.goodsId ||
        oldWidget.contextIdentity != widget.contextIdentity) {
      _clear();
      _closeRoutes();
      final identity = _identity;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || identity != _identity) return;
        invalidateNativeReadAccess();
        _load();
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _pageRoute = ModalRoute.of(context);
    if (_foreground) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _resumeReads();
      });
    }
  }

  void _clear() {
    _expiryTimer?.cancel();
    _deadlineTimer?.cancel();
    _expiryRefreshPending = false;
    _revision++;
    if (!mounted) return;
    setState(() {
      _data = null;
      _error = null;
      _loading = false;
      _saving = false;
      _picking = false;
      _catalogBusy = false;
      _syncVerified = false;
    });
  }

  @override
  void nativeReadOwnerChanged() => _clear();
  @override
  void nativeReadPermissionChanged() => _clear();
  @override
  Future<void> nativeReadReload() => _load();

  Future<void> _load({bool background = false}) async {
    if (!mounted ||
        !_allowed ||
        _loading ||
        _saving ||
        _picking ||
        !_foreground) {
      return;
    }
    final preserve = background && nativeReadAccessConfirmed && _data != null;
    final identity = _identity;
    final owns = captureNativeOwnership();
    final accepts = preserve
        ? () => owns() && identity == _identity && nativeReadAccessConfirmed
        : captureNativeRead(_identity, () => _identity);
    if (!accepts()) return;
    final revision = ++_revision;
    _expiryTimer?.cancel();
    if (!preserve) _deadlineTimer?.cancel();
    _expiryRefreshPending = false;
    setState(() {
      if (!preserve) {
        _data = null;
        _syncVerified = false;
      }
      _loading = true;
      _error = null;
    });
    try {
      final result = await ref
          .read(materialMarketRepositoryProvider)
          .analysis(widget.goodsId);
      if (!accepts() || !_allowed || revision != _revision) return;
      acceptNativeRead();
      setState(() {
        _data = result;
        _loading = false;
        _syncVerified = true;
      });
      _scheduleExpiry(result);
    } catch (_) {
      if (!accepts() || revision != _revision) return;
      setState(() {
        _loading = false;
        _error = 'UNAVAILABLE';
        _syncVerified = false;
      });
      if (preserve && _data != null) _scheduleExpiry(_data!);
    }
  }

  void _scheduleExpiry(MaterialMarketAnalysis data) {
    _expiryTimer?.cancel();
    _scheduleDeadline(data);
    final now = _now;
    final deadlines = <DateTime>[
      if (data.seriesId != null && data.refreshAfterSeconds != null)
        now.add(Duration(seconds: data.refreshAfterSeconds!)),
      if (data.expiresAt?.isAfter(now) == true) data.expiresAt!,
      if (data.latestQuote?.expiresAt?.isAfter(now) == true)
        data.latestQuote!.expiresAt!,
    ];
    if (deadlines.isEmpty) return;
    final expiresAt = deadlines.reduce((a, b) => a.isBefore(b) ? a : b);
    final identity = _identity;
    final revision = _revision;
    _expiryTimer = Timer(expiresAt.difference(now), () {
      if (!mounted ||
          identity != _identity ||
          revision != _revision ||
          !identical(_data, data)) {
        return;
      }
      setState(() => _expiryRefreshPending = true);
      _flushExpiryRefresh();
    });
  }

  // A slow poll can retain evidence but cannot extend a market deadline.
  void _scheduleDeadline(MaterialMarketAnalysis data) {
    _deadlineTimer?.cancel();
    final now = _now;
    final deadlines = <DateTime>[
      if (data.expiresAt?.isAfter(now) == true) data.expiresAt!,
      if (data.latestQuote?.expiresAt?.isAfter(now) == true)
        data.latestQuote!.expiresAt!,
    ];
    if (deadlines.isEmpty) return;
    final deadline = deadlines.reduce((a, b) => a.isBefore(b) ? a : b);
    final identity = _identity;
    final owns = captureNativeOwnership();
    _deadlineTimer = Timer(deadline.difference(now), () {
      if (!owns() || identity != _identity || !identical(_data, data)) return;
      setState(() {});
      _scheduleDeadline(data);
    });
  }

  void _flushExpiryRefresh() {
    if (!_expiryRefreshPending ||
        !mounted ||
        !_foreground ||
        _loading ||
        _saving ||
        _picking ||
        !_allowed ||
        !nativeReadAccessConfirmed) {
      return;
    }
    _expiryRefreshPending = false;
    unawaited(_load(background: true));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !mounted) return;
    _resumeReads();
  }

  void _resumeReads() {
    if (!_foreground || !mounted) return;
    final data = _data;
    if (data == null && _error == null && !_loading && !_saving && !_picking) {
      unawaited(_load());
      return;
    }
    if (data?.current != null &&
        (data!.status == 'READY' ||
            data.status == 'BASELINE_ONLY' ||
            data.status == 'RESEARCH_ONLY') &&
        !data.freshAt(_now)) {
      setState(() => _expiryRefreshPending = true);
    }
    _flushExpiryRefresh();
  }

  Widget _track(BuildContext context, Widget child) {
    final route = ModalRoute.of(context);
    if (route != null) {
      _routes.removeWhere((candidate) => !candidate.isActive);
      _routes.add(route);
    }
    return trackNativeReadDialog(context, child);
  }

  void _closeRoutes() {
    final routes = _routes.toList();
    _routes.clear();
    // The page can unmount this optional panel while Navigator is rebuilding.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final route in routes) {
        if (route.isActive) route.navigator?.removeRoute(route);
      }
    });
  }

  Future<void> _pick() async {
    if (!_canManage || _picking) return;
    final before = _data!;
    final identity = _identity;
    final revision = _revision;
    final owns = captureNativeOwnership();
    bool current() =>
        owns() &&
        identity == _identity &&
        revision == _revision &&
        _canManage &&
        identical(before, _data);
    setState(() {
      _picking = true;
      _catalogBusy = true;
    });
    final repository = ref.read(materialMarketRepositoryProvider);
    final goodsId = widget.goodsId;
    final selected = await showUtenAdaptivePanel<String>(
      context: context,
      drawerWidth: 480,
      widthFraction: UtenPanelWidth.form,
      builder: (panelContext) => _track(
        panelContext,
        _MaterialMarketPicker(
          initialId: before.seriesId,
          isCurrent: current,
          onLoadingChanged: (loading) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (current()) setState(() => _catalogBusy = loading);
            });
          },
          load: () => repository.catalog(goodsId),
        ),
      ),
    );
    if (!current()) return;
    setState(() {
      _picking = false;
      _catalogBusy = false;
    });
    if (selected != null && selected != before.seriesId) {
      await _save(selected, before);
    }
    _flushExpiryRefresh();
  }

  Future<void> _unlink() async {
    if (!_canManage || _picking || _data?.seriesId == null) return;
    final before = _data!;
    final revision = _revision;
    final owns = captureNativeOwnership();
    bool current() =>
        owns() &&
        revision == _revision &&
        _canManage &&
        identical(before, _data);
    setState(() => _picking = true);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => _track(
        dialogContext,
        UtenAlertDialog(
          title: Text(materialMarketText(context, 'unlink')),
          content: Text(materialMarketText(context, 'unlinkConfirm')),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(materialMarketText(context, 'cancel')),
            ),
            FilledButton(
              key: const Key('material-market-unlink-confirm'),
              onPressed: () {
                if (current()) Navigator.pop(dialogContext, true);
              },
              child: Text(materialMarketText(context, 'confirm')),
            ),
          ],
        ),
      ),
    );
    if (!current()) return;
    setState(() => _picking = false);
    if (confirmed == true) await _save(null, before);
    _flushExpiryRefresh();
  }

  Future<void> _save(String? seriesId, MaterialMarketAnalysis before) async {
    if (!_canManage || !identical(before, _data)) return;
    final identity = _identity;
    final revision = _revision;
    final owns = captureNativeOwnership();
    bool current() =>
        owns() &&
        identity == _identity &&
        revision == _revision &&
        nativeReadCanWrite &&
        _allowed;
    setState(() => _saving = true);
    try {
      final result = await ref
          .read(materialMarketRepositoryProvider)
          .bind(
            widget.goodsId,
            seriesId: seriesId,
            expectedVersion: before.bindingVersion!,
          );
      if (!current()) return;
      setState(() {
        _data = result;
        _saving = false;
        _syncVerified = true;
      });
      _expiryRefreshPending = false;
      _scheduleExpiry(result);
    } catch (_) {
      if (!current()) return;
      // A timeout may follow a committed CAS write. Only a new GET verifies it;
      // never replay a command or leave an old link looking authoritative.
      setState(() {
        _data = null;
        _saving = false;
        _syncVerified = false;
        _error = 'saveUnverified';
      });
    }
  }

  @override
  void dispose() {
    _revision++;
    _expiryTimer?.cancel();
    _deadlineTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _closeRoutes();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(currentPermissionsProvider);
    ref.watch(isSuperAdminProvider);
    if (!_allowed) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final data = nativeReadAccessConfirmed ? _data : null;
    final snapshot = data?.current;
    final benchmark = data?.benchmark ?? snapshot;
    final quote = data?.latestQuote;
    final now = _now;
    final actionable = data?.actionableAt(now) == true;
    final researchOnly = data?.researchOnlyAt(now) == true;
    final canShowProjection = data?.canShowProjectionAt(now) == true;
    final effectiveStatus =
        data != null &&
            snapshot != null &&
            (data.status == 'READY' ||
                data.status == 'BASELINE_ONLY' ||
                data.status == 'RESEARCH_ONLY') &&
            !data.freshAt(now)
        ? 'STALE'
        : data?.status;
    final canManage = _canManage && !_picking;
    final manageVisible = data?.canManage == true && nativeReadCanWrite;
    return Material(
      key: const Key('material-market-panel'),
      color: theme.colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: UtenRadius.lgAll,
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: SelectionArea(
        child: Padding(
          padding: const EdgeInsets.all(UtenSpacing.s16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: UtenSpacing.s8,
                runSpacing: UtenSpacing.s4,
                children: [
                  Text(
                    materialMarketText(context, 'title'),
                    style: theme.textTheme.titleSmall,
                  ),
                  Wrap(
                    spacing: UtenSpacing.s4,
                    runSpacing: UtenSpacing.s4,
                    children: [
                      if (manageVisible)
                        UtenButton(
                          key: const Key('material-market-link'),
                          onPressed: canManage ? _pick : null,
                          type: UtenButtonType.ghost,
                          size: UtenButtonSize.small,
                          isLoading: _catalogBusy || _saving,
                          icon: Icons.link,
                          child: Text(
                            materialMarketText(
                              context,
                              data?.seriesId == null ? 'link' : 'change',
                            ),
                          ),
                        ),
                      if (manageVisible && data?.seriesId != null)
                        UtenButton(
                          key: const Key('material-market-unlink'),
                          onPressed: canManage ? _unlink : null,
                          type: UtenButtonType.ghost,
                          size: UtenButtonSize.small,
                          child: Text(materialMarketText(context, 'unlink')),
                        ),
                      UtenButton(
                        key: const Key('material-market-refresh'),
                        onPressed: _loading || _saving || _picking
                            ? null
                            : _load,
                        type: UtenButtonType.ghost,
                        size: UtenButtonSize.small,
                        isLoading: _loading,
                        icon: Icons.refresh,
                        child: Text(materialMarketText(context, 'refresh')),
                      ),
                    ],
                  ),
                ],
              ),
              if (_loading || _saving)
                Semantics(
                  liveRegion: true,
                  child: Text(
                    materialMarketText(context, _saving ? 'saving' : 'loading'),
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              if (_error != null)
                Text(
                  materialMarketText(context, _error!),
                  key: const Key('material-market-error'),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              if (data != null) ...[
                Text(
                  materialMarketText(
                    context,
                    effectiveStatus == 'READY' && !actionable
                        ? 'BASELINE_ONLY'
                        : effectiveStatus!,
                  ),
                  key: const Key('material-market-status'),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: actionable
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (benchmark != null) ...[
                  const SizedBox(height: UtenSpacing.s8),
                  Text(
                    benchmark.name,
                    key: const Key('material-market-bound-benchmark'),
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: UtenSpacing.s4),
                  _BenchmarkIdentity(snapshot: benchmark),
                  const SizedBox(height: UtenSpacing.s8),
                  _MarketSync(
                    analysis: data,
                    benchmark: benchmark,
                    verified: _syncVerified,
                  ),
                ],
                if (quote != null) ...[
                  const SizedBox(height: UtenSpacing.s12),
                  _DelayedQuote(quote: quote, now: now),
                ],
                if (snapshot != null) ...[
                  const SizedBox(height: UtenSpacing.s12),
                  Text(
                    '${materialMarketText(context, benchmark?.text('provider') == 'SHFE_PUBLIC_DAILY' || snapshot.data['schemaVersion'] == 2 ? 'settlement' : 'quote')}: '
                    '${priceNumber(snapshot.data['latestPrice'])} '
                    '${snapshot.denomination}',
                    key: const Key('material-market-quote'),
                    style: theme.textTheme.titleMedium,
                  ),
                  _EvidenceRow(snapshot: snapshot),
                  if (canShowProjection) ...[
                    const Divider(height: UtenSpacing.s24),
                    Text(
                      materialMarketText(
                        context,
                        researchOnly
                            ? 'researchProjection'
                            : actionable
                            ? 'projection'
                            : 'baselineProjection',
                      ),
                      style: theme.textTheme.titleSmall,
                    ),
                    const SizedBox(height: UtenSpacing.s8),
                    if (researchOnly)
                      Text(
                        materialMarketText(context, 'researchLimit'),
                        style: theme.textTheme.bodySmall,
                      ),
                    _Forecasts(
                      snapshot: snapshot,
                      allowDirection: actionable || researchOnly,
                    ),
                    const SizedBox(height: UtenSpacing.s8),
                    Text(
                      materialMarketText(context, 'sessions'),
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                  if (actionable) ...[
                    const SizedBox(height: UtenSpacing.s8),
                    Text(
                      materialMarketText(
                        context,
                        snapshot.text('procurementSignal'),
                      ),
                      key: const Key('material-market-signal'),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                  const SizedBox(height: UtenSpacing.s8),
                  Text(
                    materialMarketText(context, 'decisionLimit'),
                    style: theme.textTheme.bodySmall,
                  ),
                  _MarketEvidence(snapshot: snapshot),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _BenchmarkIdentity extends StatelessWidget {
  const _BenchmarkIdentity({required this.snapshot});
  final MaterialMarketBenchmark snapshot;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: UtenSpacing.s12,
    runSpacing: UtenSpacing.s4,
    children: [
      Text(materialMarketText(context, snapshot.text('commodity'))),
      Text(materialMarketText(context, snapshot.text('market'))),
      for (final key in ['grade', 'region', 'priceBasis'])
        if (snapshot.text(key).isNotEmpty) Text(snapshot.text(key)),
      Text(snapshot.denomination),
    ],
  );
}

class _MarketSync extends StatelessWidget {
  const _MarketSync({
    required this.analysis,
    required this.benchmark,
    required this.verified,
  });
  final MaterialMarketAnalysis analysis;
  final MaterialMarketBenchmark benchmark;
  final bool verified;

  @override
  Widget build(BuildContext context) {
    final sync = analysis.sync;
    final status = sync['status']?.toString() ?? 'OFFLINE';
    final key = !verified
        ? 'syncUnknown'
        : status == 'IDLE'
        ? (sync['autoUpdateEnabled'] == true ? 'autoConnected' : 'autoStopped')
        : 'sync$status';
    return DefaultTextStyle(
      style: Theme.of(context).textTheme.bodySmall!,
      child: Wrap(
        spacing: UtenSpacing.s12,
        runSpacing: UtenSpacing.s4,
        children: [
          Text(
            materialMarketText(context, key),
            key: const Key('material-market-sync'),
          ),
          Text(
            '${materialMarketText(context, 'source')}: ${benchmark.text('sourceName')}',
          ),
          for (final field in ['lastSuccessAt', if (verified) 'nextSyncAt'])
            if (sync[field] != null && sync[field].toString().isNotEmpty)
              Text(
                '${materialMarketText(context, field)}: ${DisplayDateTime.beijing(sync[field]?.toString(), fallback: '—')}',
              ),
        ],
      ),
    );
  }
}

class _DelayedQuote extends StatelessWidget {
  const _DelayedQuote({required this.quote, required this.now});
  final MaterialMarketQuote quote;
  final DateTime now;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        '${materialMarketText(context, 'delayedQuote')}: '
        '${priceNumber(quote.data['price'])} ${quote.denomination}',
        key: const Key('material-market-delayed-quote'),
        style: Theme.of(context).textTheme.titleMedium,
      ),
      if (!quote.currentAt(now))
        Text(
          materialMarketText(context, 'quoteStale'),
          key: const Key('material-market-delayed-stale'),
          style: Theme.of(context).textTheme.bodySmall,
        ),
      Wrap(
        spacing: UtenSpacing.s12,
        runSpacing: UtenSpacing.s4,
        children: [
          Text(
            '${materialMarketText(context, 'contract')}: ${quote.text('contract')}',
          ),
          Text(
            '${materialMarketText(context, 'marketTime')}: ${DisplayDateTime.beijing(quote.text('marketTime'), fallback: '—')}',
          ),
          Text(
            '${materialMarketText(context, 'fetchedAt')}: ${DisplayDateTime.beijing(quote.text('fetchedAt'), fallback: '—')}',
          ),
        ],
      ),
    ],
  );
}

class _EvidenceRow extends StatelessWidget {
  const _EvidenceRow({required this.snapshot});
  final MaterialMarketSnapshot snapshot;

  @override
  Widget build(BuildContext context) => DefaultTextStyle(
    style: Theme.of(context).textTheme.bodySmall!,
    child: Wrap(
      spacing: UtenSpacing.s12,
      runSpacing: UtenSpacing.s4,
      children: [
        Text(
          '${materialMarketText(context, 'source')}: ${snapshot.text('sourceName')}',
        ),
        Text(
          '${materialMarketText(context, snapshot.data['schemaVersion'] == 2 ? 'settlementDate' : 'asOf')}: ${snapshot.text('dataAsOf')}',
        ),
      ],
    ),
  );
}

class _Forecasts extends StatelessWidget {
  const _Forecasts({required this.snapshot, required this.allowDirection});
  final MaterialMarketSnapshot snapshot;
  final bool allowDirection;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final font = Theme.of(context).textTheme.bodyMedium?.fontSize ?? 14;
      final minimumWidth =
          215 * MediaQuery.textScalerOf(context).scale(font) / font;
      final columns = (constraints.maxWidth / minimumWidth).floor().clamp(1, 3);
      final width =
          (constraints.maxWidth - UtenSpacing.s16 * (columns - 1)) / columns;
      final forecasts = snapshot.forecasts;
      return Wrap(
        spacing: UtenSpacing.s16,
        runSpacing: UtenSpacing.s12,
        children: [
          for (final horizon in [1, 5, 20])
            SizedBox(
              width: width,
              key: ValueKey('material-market-horizon-$horizon'),
              child: Builder(
                builder: (context) {
                  final matches = forecasts.where((f) => f.horizon == horizon);
                  final forecast = matches.length == 1 ? matches.single : null;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        materialMarketHorizon(context, horizon),
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                      Text(
                        '${priceNumber(forecast?.data['price'])} ${snapshot.denomination}',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      if (forecast != null) ...[
                        Text(
                          '${materialMarketText(context, 'interval')}: '
                          '${priceNumber(forecast.data['lower80'])} – '
                          '${priceNumber(forecast.data['upper80'])}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        Text(
                          materialMarketText(
                            context,
                            allowDirection
                                ? forecast.text('direction')
                                : 'UNCERTAIN',
                          ),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ],
                  );
                },
              ),
            ),
        ],
      );
    },
  );
}

class _MarketEvidence extends StatelessWidget {
  const _MarketEvidence({required this.snapshot});
  final MaterialMarketSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final validation = snapshot.validation;
    return ExpansionTile(
      key: const Key('material-market-evidence'),
      tilePadding: EdgeInsets.zero,
      title: Text(materialMarketText(context, 'basis')),
      children: [
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final key in [
                'modelVersion',
                'libraryVersion',
                'generatedAt',
              ])
                Text(
                  '${materialMarketText(context, switch (key) {
                    'modelVersion' => 'model',
                    'libraryVersion' => 'library',
                    _ => 'generated',
                  })}: ${key == 'generatedAt' ? DisplayDateTime.beijing(snapshot.text(key), fallback: '—') : snapshot.text(key)}',
                ),
              Text(
                '${materialMarketText(context, 'dataset')}: ${snapshot.text('datasetDigest')}',
              ),
              if (snapshot.text('validationBasis') ==
                  'LATEST_HISTORY_REPLAY') ...[
                Text(materialMarketText(context, 'researchLimit')),
                Text(materialMarketText(context, 'anchorMAE')),
              ],
              for (final field in [
                'quoteContract',
                'sourceFetchedAt',
                'historyRecordCount',
              ])
                if (snapshot.text(field).isNotEmpty)
                  Text(
                    '${materialMarketText(context, field)}: ${field == 'sourceFetchedAt' ? DisplayDateTime.beijing(snapshot.text(field), fallback: '—') : snapshot.text(field)}',
                  ),
              Text(
                '${validation['backtestStart'] ?? '—'} – ${validation['backtestEnd'] ?? '—'}',
              ),
              for (final key in [
                'folds',
                'baselineMAE',
                'modelMAE',
                'coverage80',
              ])
                Text(
                  '${materialMarketText(context, key == 'coverage80'
                      ? snapshot.researchOnly
                            ? 'replayCoverage'
                            : 'coverage'
                      : key)}: '
                  '${key == 'coverage80' && validation[key] != null ? '${priceNumber(financeExactMultiplyTexts([validation[key].toString(), '100']))}%' : priceNumber(validation[key])}',
                ),
              Text(
                materialMarketText(context, 'maeHint'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (snapshot.text('rollPolicy').isNotEmpty)
                Text(snapshot.text('rollPolicy')),
            ],
          ),
        ),
      ],
    );
  }
}

class _MaterialMarketPicker extends StatefulWidget {
  const _MaterialMarketPicker({
    required this.initialId,
    required this.load,
    required this.isCurrent,
    required this.onLoadingChanged,
  });
  final String? initialId;
  final Future<List<MaterialMarketBenchmark>> Function() load;
  final bool Function() isCurrent;
  final ValueChanged<bool> onLoadingChanged;

  @override
  State<_MaterialMarketPicker> createState() => _MaterialMarketPickerState();
}

class _MaterialMarketPickerState extends State<_MaterialMarketPicker> {
  List<MaterialMarketBenchmark> _rows = [];
  String? _selected;
  String _search = '';
  bool _loading = true, _failed = false;

  @override
  void initState() {
    super.initState();
    _selected = widget.initialId;
    _load();
  }

  Future<void> _load() async {
    widget.onLoadingChanged(true);
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final rows = await widget.load();
      if (!mounted || !widget.isCurrent()) return;
      setState(() {
        _rows = rows;
        _loading = false;
      });
      widget.onLoadingChanged(false);
    } catch (_) {
      if (!mounted || !widget.isCurrent()) return;
      setState(() {
        _rows = [];
        _loading = false;
        _failed = true;
      });
      widget.onLoadingChanged(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final selected = _rows.where((row) => row.seriesId == _selected);
    final choice = selected.length == 1 ? selected.single : null;
    final canConfirm =
        !_loading &&
        !_failed &&
        choice != null &&
        choice.selectable &&
        choice.seriesId != widget.initialId &&
        widget.isCurrent();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(UtenSpacing.s16),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  materialMarketText(context, 'choose'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              IconButton(
                key: const Key('material-market-picker-close'),
                onPressed: () => Navigator.pop(context),
                tooltip: materialMarketText(context, 'close'),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s16),
            children: [
              Text(materialMarketText(context, 'selectionHint')),
              const SizedBox(height: UtenSpacing.s12),
              if (_loading)
                Text(materialMarketText(context, 'loading'))
              else if (_failed) ...[
                Text(materialMarketText(context, 'UNAVAILABLE')),
                UtenButton(
                  onPressed: widget.isCurrent() ? _load : null,
                  isLoading: _loading,
                  type: UtenButtonType.ghost,
                  child: Text(materialMarketText(context, 'refresh')),
                ),
              ] else if (_rows.isEmpty)
                Text(
                  materialMarketText(context, 'emptyCatalog'),
                  key: const Key('material-market-empty-catalog'),
                )
              else ...[
                TextField(
                  key: const Key('material-market-search'),
                  decoration: UtenInputDecoration(
                    InputDecoration(
                      labelText: materialMarketText(context, 'choose'),
                      prefixIcon: const Icon(Icons.search),
                    ),
                  ),
                  onChanged: (value) => setState(() => _search = value),
                ),
                for (final row in _rows.where(
                  (row) => row.data.values
                      .join(' ')
                      .toLowerCase()
                      .contains(_search.trim().toLowerCase()),
                ))
                  ListTile(
                    key: ValueKey('material-market-choice-${row.seriesId}'),
                    contentPadding: EdgeInsets.zero,
                    enabled: row.selectable,
                    selected: _selected == row.seriesId,
                    leading: Icon(
                      _selected == row.seriesId
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                    ),
                    title: Text(row.name),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _BenchmarkIdentity(snapshot: row),
                        Text(
                          '${materialMarketText(context, 'source')}: ${row.text('sourceName')}',
                        ),
                      ],
                    ),
                    onTap: () {
                      if (widget.isCurrent() && row.selectable) {
                        setState(() => _selected = row.seriesId);
                      }
                    },
                  ),
              ],
            ],
          ),
        ),
        UtenPickerConfirmBar(
          selectedCount: choice == null ? 0 : 1,
          summary: Text(
            choice?.name ?? materialMarketText(context, 'noSelection'),
          ),
          confirmEnabled: canConfirm,
          confirmButtonKey: const Key('material-market-picker-confirm'),
          confirmLabel: materialMarketText(context, 'confirm'),
          cancelLabel: materialMarketText(context, 'cancel'),
          onConfirm: () {
            if (canConfirm && widget.isCurrent()) {
              Navigator.pop(context, choice.seriesId);
            }
          },
        ),
      ],
    );
  }
}
