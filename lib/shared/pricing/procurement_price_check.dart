import 'dart:async';
import 'dart:convert';
import 'dart:collection';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dio/dio.dart';
import '../../components/layout/uten_editable_grid.dart';
import '../../components/feedback/uten_dialog.dart';
import '../../core/network/server_config.dart';
import '../../core/performance/ui_work_budget.dart';
import '../../core/ui/action_feedback.dart';
import '../../core/theme/uten_colors.dart';
import '../../core/theme/uten_tokens.dart';
import '../auth/permissions.dart';
import '../auth/session_snapshot_provider.dart';
import '../providers/authenticated_scope_provider.dart';
import '../formatters/exact_decimal.dart';
import 'price_analysis_models.dart';
import 'price_analysis_repository.dart';
import 'price_analysis_l10n.dart';

typedef PriceBatchRead =
    Future<List<PriceCheckResult>> Function(
      List<Map<String, dynamic>> items,
      CancelToken cancelToken,
    );

bool priceCheckOperandsReady(String quantity, String unitPrice) {
  final qty = financeExactDecimalUnits(quantity, scale: financeAmountScale);
  final price = financeExactDecimalUnits(unitPrice, scale: financeAmountScale);
  return qty != null &&
      qty > BigInt.zero &&
      price != null &&
      price >= BigInt.zero;
}

/// One read-only batch for the editor. Old results disappear before the
/// debounce starts; an ABA input change never revives an earlier response.
class PriceCheckBatchController extends ChangeNotifier {
  PriceCheckBatchController(
    this.read, {
    this.delay = const Duration(milliseconds: 300),
  });
  final PriceBatchRead read;
  final Duration delay;
  Timer? _timer;
  CancelToken? _cancelToken;
  int _revision = 0;
  bool _disposed = false;
  String? _signature;
  Map<String, PriceCheckResult> _results = const {};
  bool loading = false;
  PriceCheckResult? result(String key) => _results[key];

  void invalidate() {
    _cancelToken?.cancel('Price context changed');
    _cancelToken = null;
    _revision++;
    _timer?.cancel();
    _signature = null;
    _results = const {};
    loading = false;
    if (!_disposed) notifyListeners();
  }

  void update(List<Map<String, dynamic>> items, {required bool enabled}) {
    final signature = enabled ? jsonEncode(items) : null;
    if (enabled && signature == _signature) return;
    invalidate();
    if (!enabled || items.isEmpty || _disposed) return;
    _signature = signature;
    loading = true;
    final revision = _revision;
    // Freeze all values; the row controllers remain owned by the editor.
    final snapshot = (jsonDecode(signature!) as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    _timer = Timer(delay, () => _load(snapshot, revision));
  }

  /// Editors defer both payload capture and deep copying until input settles.
  /// Old evidence is hidden immediately; each row is then frozen in bounded
  /// UI slices, and a change during capture discards the entire snapshot.
  void updateFromRows<T>({
    required Iterable<T> Function() rows,
    required Map<String, dynamic>? Function(T row) payloadOf,
    required bool enabled,
  }) {
    invalidate();
    if (!enabled || _disposed) return;
    loading = true;
    final revision = _revision;
    _timer = Timer(delay, () => _captureAndLoad(rows, payloadOf, revision));
  }

  Future<void> _captureAndLoad<T>(
    Iterable<T> Function() rows,
    Map<String, dynamic>? Function(T row) payloadOf,
    int revision,
  ) async {
    bool current() => !_disposed && revision == _revision;
    final work = UiWorkBudget(isCurrent: current, debugLabel: 'price-check');
    try {
      work.ensureCurrent();
      final sources = List<T>.of(rows(), growable: false);
      final snapshot = <Map<String, dynamic>>[];
      for (final row in sources) {
        work.ensureCurrent();
        final payload = payloadOf(row);
        if (payload != null) {
          // Keep exact decimal strings and nested operands, without a large
          // whole-table JSON string/copy on every keystroke.
          snapshot.add(
            Map<String, dynamic>.from(jsonDecode(jsonEncode(payload)) as Map),
          );
        }
        await work.checkpoint();
      }
      work.ensureCurrent();
      await _load(snapshot, revision);
    } on UiWorkCancelled {
      // The newer input/identity owns all result and loading state.
    } catch (_) {
      if (current()) {
        loading = false;
        notifyListeners();
      }
    }
  }

  Future<void> _load(List<Map<String, dynamic>> items, int revision) async {
    final next = <String, PriceCheckResult>{};
    final cancelToken = _cancelToken = CancelToken();
    try {
      for (var offset = 0; offset < items.length; offset += 100) {
        if (_disposed || revision != _revision) return;
        final chunk = items.skip(offset).take(100).toList();
        final rows = await read(chunk, cancelToken);
        if (_disposed || revision != _revision) return;
        final expected = {
          for (final item in chunk) item['rowKey']: item['goodsId'],
        };
        for (final row in rows) {
          if (expected[row.text('rowKey')] == row.text('goodsId')) {
            next[row.text('rowKey')] = row;
          }
        }
        for (final item in chunk) {
          next.putIfAbsent(
            item['rowKey'] as String,
            () => PriceCheckResult.unavailable,
          );
        }
      }
    } catch (_) {
      if (_disposed || revision != _revision) return;
      for (final item in items) {
        next[item['rowKey'] as String] = PriceCheckResult.unavailable;
      }
    }
    if (_disposed || revision != _revision) return;
    _results = next;
    loading = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelToken?.cancel('Price editor closed');
    _revision++;
    _timer?.cancel();
    super.dispose();
  }
}

class PriceCheckBinding {
  const PriceCheckBinding({
    required this.listenables,
    required this.payload,
    this.contextKey,
  });
  final List<Listenable> listenables;
  final Map<String, dynamic>? Function() payload;

  /// Frozen scalar operands without their own Listenable, such as color/unit.
  /// Parent rebuilds compare this value without capturing or clearing results.
  final Object? contextKey;
}

class ProcurementPriceCheckScope<R extends EditableGridRow>
    extends ConsumerStatefulWidget {
  const ProcurementPriceCheckScope({
    super.key,
    required this.grid,
    required this.kind,
    required this.bindingOf,
    required this.child,
    this.headerChanges = const [],
    this.contextKey = '',
    this.excludeOrderId,
    this.enabled = true,
  });
  final UtenEditableGridController<R> grid;
  final String kind;
  final PriceCheckBinding Function(R row) bindingOf;
  final List<Listenable> headerChanges;
  final String contextKey;
  final String? excludeOrderId;
  final bool enabled;
  final Widget child;
  @override
  ConsumerState<ProcurementPriceCheckScope<R>> createState() =>
      _PriceCheckScopeState<R>();
}

class _PriceCheckScopeState<R extends EditableGridRow>
    extends ConsumerState<ProcurementPriceCheckScope<R>> {
  late final PriceCheckBatchController _batch;
  final _keys = Map<Object, String>.identity();
  final _watched = <Listenable>[];
  final _sourceCallbacks = <Listenable, VoidCallback>{};
  final _rowsForSource = <Listenable, List<R>>{};
  final _textSnapshots =
      <TextEditingController, ({String text, List<Object?> contexts})>{};
  final _rowContexts = Map<Object, Object?>.identity();
  List<R> _boundRows = const [];
  int _sequence = 0;
  bool get _allowed =>
      widget.enabled &&
      ref.read(authenticatedScopeProvider) != null &&
      confirmedSessionSnapshot(ref.read(sessionSnapshotProvider)) != null &&
      (ref.read(isSuperAdminProvider) ||
          ref.read(currentPermissionsProvider).containsAll({
            Perm.goodsView,
            Perm.goodsPriceAnalysisView,
          }));

  @override
  void initState() {
    super.initState();
    _batch = PriceCheckBatchController(
      (items, cancelToken) => ref
          .read(priceAnalysisRepositoryProvider)
          .check(
            widget.kind,
            items,
            excludeOrderId: widget.excludeOrderId,
            cancelToken: cancelToken,
          ),
    );
    widget.grid.draftListenable.addListener(_bind);
    ref.listenManual(
      authenticatedScopeProvider,
      (_, _) => _authorizationChanged(),
    );
    ref.listenManual(
      sessionSnapshotProvider,
      (_, _) => _authorizationChanged(),
    );
    ref.listenManual(
      currentPermissionsProvider,
      (_, _) => _authorizationChanged(),
    );
    ref.listenManual(apiBaseUrlProvider, (_, _) => _authorizationChanged());
    _bind();
  }

  void _authorizationChanged() {
    _batch.invalidate();
    _changed();
  }

  void _bind() {
    if (_syncBindings()) _changed();
  }

  bool _syncBindings() {
    final rows = widget.grid.rows;
    var changed = _boundRows.length != rows.length;
    if (!changed) {
      for (var index = 0; index < rows.length; index++) {
        if (!identical(_boundRows[index], rows[index])) {
          changed = true;
          break;
        }
      }
    }
    final retained = HashSet<Object>.identity()..addAll(rows);
    _keys.removeWhere((row, _) => !retained.contains(row));
    _rowContexts.removeWhere((row, _) => !retained.contains(row));
    final watched = <Listenable>[];
    _rowsForSource.clear();
    for (final row in rows) {
      _keys.putIfAbsent(row, () => 'price-row-${++_sequence}');
      final binding = widget.bindingOf(row);
      if (!_rowContexts.containsKey(row) ||
          _rowContexts[row] != binding.contextKey) {
        changed = true;
      }
      _rowContexts[row] = binding.contextKey;
      watched.addAll(binding.listenables);
      for (final source in binding.listenables) {
        _rowsForSource.putIfAbsent(source, () => []).add(row);
      }
    }
    watched.addAll(widget.headerChanges);
    if (!listEquals(_watched, watched)) {
      for (final source in _watched.toSet()) {
        source.removeListener(_sourceCallbacks.remove(source)!);
      }
      _watched
        ..clear()
        ..addAll(watched);
      for (final source in _watched.toSet()) {
        void changed() {
          if (source is TextEditingController) {
            final next = _textSnapshot(source);
            final previous = _textSnapshots[source];
            _textSnapshots[source] = next;
            if (previous?.text == next.text &&
                listEquals(previous?.contexts, next.contexts)) {
              return;
            }
          }
          for (final row in _rowsForSource[source] ?? <R>[]) {
            _rowContexts[row] = widget.bindingOf(row).contextKey;
          }
          _changed();
        }

        _sourceCallbacks[source] = changed;
        source.addListener(changed);
      }
      changed = true;
    }
    _boundRows = List<R>.of(rows, growable: false);
    _textSnapshots.removeWhere((source, _) => !_watched.contains(source));
    for (final source in _watched.whereType<TextEditingController>()) {
      _textSnapshots[source] = _textSnapshot(source);
    }
    return changed;
  }

  ({String text, List<Object?> contexts}) _textSnapshot(
    TextEditingController source,
  ) => (
    text: source.text,
    contexts: [
      for (final row in _rowsForSource[source] ?? <R>[])
        widget.bindingOf(row).contextKey,
    ],
  );

  void _changed() {
    // Goods selection can set colour/unit after its notifier fires. Read the
    // complete edit after debounce, while hiding old evidence immediately.
    _batch.updateFromRows<R>(
      rows: () => widget.grid.rows,
      payloadOf: (row) {
        final payload = widget.bindingOf(row).payload();
        return payload == null ? null : {'rowKey': _keys[row], ...payload};
      },
      enabled: _allowed,
    );
  }

  @override
  void didUpdateWidget(covariant ProcurementPriceCheckScope<R> oldWidget) {
    super.didUpdateWidget(oldWidget);
    final contextChanged =
        oldWidget.grid != widget.grid ||
        oldWidget.kind != widget.kind ||
        oldWidget.excludeOrderId != widget.excludeOrderId ||
        oldWidget.contextKey != widget.contextKey ||
        oldWidget.enabled != widget.enabled;
    if (oldWidget.grid != widget.grid) {
      oldWidget.grid.draftListenable.removeListener(_bind);
      widget.grid.draftListenable.addListener(_bind);
    }
    // Inline binding closures are recreated by ordinary parent rebuilds. Keep
    // the newest sources, but retain accepted evidence when operands are equal.
    final bindingChanged = _syncBindings();
    if (contextChanged || bindingChanged) {
      _changed();
    }
  }

  @override
  void dispose() {
    widget.grid.draftListenable.removeListener(_bind);
    for (final source in _watched.toSet()) {
      source.removeListener(_sourceCallbacks[source]!);
    }
    _batch.invalidate();
    _batch.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _PriceCheckInherited(batch: _batch, keys: _keys, child: widget.child);
}

class _PriceCheckInherited extends InheritedWidget {
  const _PriceCheckInherited({
    required this.batch,
    required this.keys,
    required super.child,
  });
  final PriceCheckBatchController batch;
  final Map<Object, String> keys;
  @override
  bool updateShouldNotify(_PriceCheckInherited oldWidget) => true;
}

/// The original input remains intact, including source locking, exact amount
/// entry and its own required-field validation. This adds advisory decoration.
class PriceCheckCell extends StatelessWidget {
  const PriceCheckCell({
    super.key,
    required this.row,
    required this.child,
    this.showUnavailableInfo = true,
  });
  final Object row;
  final Widget child;
  final bool showUnavailableInfo;

  /// 实际证据按钮与采购/委外列装饰估宽同源；不推导任何价格判断。
  static double evidenceExtentOf(BuildContext context) =>
      UtenControlMetrics.minimumHitExtent(context, desktop: 32);
  @override
  Widget build(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<_PriceCheckInherited>();
    if (scope == null) return child;
    return ListenableBuilder(
      listenable: scope.batch,
      builder: (context, _) {
        final result = scope.batch.result(scope.keys[row] ?? '');
        if (result == null) return child;
        final warning = result.warning;
        if (!warning && !showUnavailableInfo) return child;
        if (!warning && result.available) return child;
        final color = warning
            ? Theme.of(context).brightness == Brightness.dark
                  ? UtenColors.warningOnDark
                  : UtenColors.warningText
            : Theme.of(context).colorScheme.onSurfaceVariant;
        final message = _message(context, result);
        final tooltipKey = GlobalKey<TooltipState>();
        return DecoratedBox(
          decoration: BoxDecoration(
            border: warning ? Border.all(color: color, width: 1.5) : null,
            borderRadius: UtenRadius.smAll,
          ),
          child: Row(
            children: [
              Expanded(child: child),
              Focus(
                canRequestFocus: false,
                onFocusChange: (focused) {
                  if (focused) tooltipKey.currentState?.ensureTooltipVisible();
                },
                child: Tooltip(
                  key: tooltipKey,
                  message: message,
                  child: IconButton(
                    key: ValueKey('price-evidence-${scope.keys[row]}'),
                    padding: const EdgeInsets.all(UtenSpacing.s4),
                    constraints: BoxConstraints.tightFor(
                      width: evidenceExtentOf(context),
                      height: evidenceExtentOf(context),
                    ),
                    style: const ButtonStyle(
                      visualDensity: VisualDensity.standard,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    icon: Icon(
                      warning
                          ? Icons.warning_amber_rounded
                          : Icons.info_outline,
                      size: 18,
                      color: color,
                      semanticLabel: priceText(context, 'details'),
                    ),
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (dialogContext) => ListenableBuilder(
                        listenable: scope.batch,
                        builder: (context, _) {
                          final current = scope.batch.result(
                            scope.keys[row] ?? '',
                          );
                          return UtenAlertDialog(
                            maxWidth: 440,
                            showCloseButton: true,
                            onClose: () => Navigator.pop(dialogContext),
                            title: Text(
                              priceText(
                                context,
                                current?.warning == true
                                    ? 'warning'
                                    : 'UNAVAILABLE',
                              ),
                            ),
                            content: current == null
                                ? Text(priceText(context, 'UNAVAILABLE'))
                                : Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(_message(context, current)),
                                      if (current.text('message').isNotEmpty)
                                        ExpansionTile(
                                          tilePadding: EdgeInsets.zero,
                                          title: Text(
                                            priceText(context, 'explain'),
                                          ),
                                          children: [
                                            Text(current.text('message')),
                                          ],
                                        ),
                                    ],
                                  ),
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  static String _message(BuildContext context, PriceCheckResult result) {
    final reasons = priceStrings(result.data['reasonCodes']).toSet();
    final fallback = reasons.contains('SUPPLIER_SCOPE_FALLBACK');
    final peerWarning =
        reasons.contains('PEER_PRICE_ABOVE_REFERENCE') &&
        result.text('peerReferencePrice').isNotEmpty;
    final denomination = [
      result.text('currencyName'),
      result.text('unitName'),
    ].where((v) => v.isNotEmpty).join('/');
    String unitPrice(String key) =>
        '${priceNumber(result.text(key))}${denomination.isEmpty ? '' : ' $denomination'}';
    return [
      if (!result.available)
        reasons.isEmpty
            ? priceText(context, result.text('status'))
            : reasons.map((reason) => priceText(context, reason)).join(' · '),
      if (fallback) priceText(context, 'SUPPLIER_SCOPE_FALLBACK'),
      if (result.text('referencePrice').isNotEmpty)
        '${priceText(context, fallback
            ? 'peerReference'
            : peerWarning
            ? 'supplierReference'
            : 'baseline')}: ${unitPrice('referencePrice')}',
      if (result.text('weightedAveragePrice').isNotEmpty)
        '${priceText(context, fallback ? 'peerAverage' : 'average')}: ${unitPrice('weightedAveragePrice')}',
      if (result.text('percentageDeviation').isNotEmpty)
        '${priceText(context, 'deviation')}: ${priceNumber(result.text('percentageDeviation'))}%',
      if (result.text('estimatedImpact').isNotEmpty)
        '${priceText(context, 'impact')}: ${priceNumber(result.text('estimatedImpact'))}${result.text('currencyName').isEmpty ? '' : ' ${result.text('currencyName')}'}',
      if (peerWarning && !fallback) ...[
        '${priceText(context, 'peerReference')}: ${unitPrice('peerReferencePrice')}',
        if (result.text('peerPercentageDeviation').isNotEmpty)
          '${priceText(context, 'peerDeviation')}: ${priceNumber(result.text('peerPercentageDeviation'))}%',
      ],
    ].join('\n');
  }
}

/// A completed save remains successful. Only its server-authored assessment
/// is summarized; no client-side recalculation becomes a new posting fact.
void notifySavedPriceAssessment(
  BuildContext context,
  WidgetRef ref,
  Iterable<Map<String, dynamic>?> assessments,
) {
  if (ref.read(authenticatedScopeProvider) == null ||
      !(ref.read(isSuperAdminProvider) ||
          ref.read(currentPermissionsProvider).containsAll({
            Perm.goodsView,
            Perm.goodsPriceAnalysisView,
          }))) {
    return;
  }
  final rows = assessments
      .whereType<Map<String, dynamic>>()
      .expand((assessment) => priceMaps(assessment['items']))
      .toList();
  final warnings = rows
      .where((row) => row['state'] == 'WARNING' || row['severity'] == 'WARNING')
      .length;
  if (warnings == 0) return;
  context.appWarning(
    '${priceText(context, 'savedWarning')} ($warnings)',
    force: true,
  );
}
