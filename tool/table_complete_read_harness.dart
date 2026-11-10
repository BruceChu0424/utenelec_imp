// Local, synthetic acceptance surface for the production complete reader/table.
// No credentials, server calls, business commands, or production routes.
import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/inputs/uten_field_hint_icon.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/performance/ui_work_budget.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/paging/scoped_paged_read.dart';

const _quantity = '90071992547409.123456789012345678901234';
const _amount = '-123456789012345.000000000000000001';

enum _ReadOutcome { success, retired, interrupted, failed }

class TableStressRow {
  const TableStressRow(this.generation, this.index);
  final int generation;
  final int index;
  String get id => '$generation:$index';
  String get name => '合成货品 ${index.toString().padLeft(6, '0')}';
  String get category => '分类 ${index % 20}';
  String get quantity => _quantity;
  String get amount => _amount;
}

String _rowKey(TableStressRow row) => row.id;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    ProviderScope(
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: buildLightTheme(),
        home: const TableCompleteReadHarness(),
      ),
    ),
  );
}

class TableCompleteReadHarness extends StatefulWidget {
  const TableCompleteReadHarness({super.key});
  @override
  State<TableCompleteReadHarness> createState() => _HarnessState();
}

class _HarnessState extends State<TableCompleteReadHarness> {
  final _reader = ScopedPagedRead<TableStressRow>(idOf: _rowKey);
  final _rowsController = MasterDataTableRowsController<TableStressRow>();
  final _presentationRevision = Object();
  final _queryInput = TextEditingController(text: '初始查询');
  final _draft = TextEditingController(text: '保留的中文草稿 0001.0000');
  final _metrics = ValueNotifier<Map<String, Object?>>({});
  final _errors = <String>[];
  final _receipts = <Map<String, Object?>>[];
  final _profiles = <String, ({int calls, int micros, int maxMicros})>{};
  late final List<MasterColumnDef<TableStressRow>> _columns;
  late final int _total;
  late final int _delay;
  late final String _mode;
  late final Timer _pulse;
  final _clock = Stopwatch()..start();
  int _lastPulse = 0, _maxGap = 0, _pulses = 0;
  int _generation = 0, _active = 0, _maxActive = 0;
  int _requests = 0, _cancelled = 0, _complete = 0;
  int _lateReplies = 0, _lastSuccessfulGeneration = -1;
  int _expectedInterruptions = 0;
  String _expectedInput = '保留的中文草稿 0001.0000';
  int _valueVisits = 0, _identityVisits = 0;
  int _firstMs = -1, _completeMs = -1, _settledMs = -1;
  bool _loading = false, _visible = true, _disposed = false;
  String _phase = '启动', _query = '初始查询';
  String? _error;
  List<TableStressRow> _items = const [];
  Set<String> _selected = {};
  Map<String, String?> _filters = {};
  void Function(String, Duration)? _previousObserver;
  FlutterExceptionHandler? _previousErrorHandler;

  @override
  void initState() {
    super.initState();
    final query = Uri.base.queryParameters;
    _total = int.tryParse(query['rows'] ?? '') ?? 35000;
    _delay = int.tryParse(query['delay'] ?? '') ?? 10;
    _mode = query['scenario'] ?? 'load';
    if (_total < 1 || _total > 100000) {
      throw ArgumentError('Synthetic fixture supports 1..100000 rows');
    }
    final count = (int.tryParse(query['columns'] ?? '') ?? 30).clamp(5, 60);
    _columns = [
      MasterColumnDef(
        key: 'index',
        label: '序号',
        width: 100,
        sortable: true,
        value: (row) => _value(row.index.toString()),
      ),
      MasterColumnDef(
        key: 'name',
        label: '货品名称',
        width: 160,
        sortable: true,
        value: (row) => _value(row.name),
      ),
      MasterColumnDef(
        key: 'category',
        label: '分类',
        width: 120,
        filterFromRows: true,
        value: (row) => _value(row.category),
      ),
      MasterColumnDef(
        key: 'quantity',
        label: '原始数量',
        width: 260,
        value: (row) => _value(row.quantity),
      ),
      MasterColumnDef(
        key: 'amount',
        label: '原始金额',
        width: 260,
        value: (row) => _value(row.amount),
      ),
      for (var col = 5; col < count; col++)
        MasterColumnDef(
          key: 'field$col',
          label: '资料 $col',
          width: 150,
          defaultVisible: col.isEven,
          value: (row) => _value('值 $col / ${row.index % 137}'),
        ),
    ];
    _previousObserver = debugUiWorkSliceObserver;
    debugUiWorkSliceObserver = (label, duration) {
      final old = _profiles[label] ?? (calls: 0, micros: 0, maxMicros: 0);
      final micros = duration.inMicroseconds;
      _profiles[label] = (
        calls: old.calls + 1,
        micros: old.micros + micros,
        maxMicros: micros > old.maxMicros ? micros : old.maxMicros,
      );
    };
    _previousErrorHandler = FlutterError.onError;
    FlutterError.onError = (details) {
      _errors.add(details.exceptionAsString());
      _previousErrorHandler?.call(details);
      if (_phase == 'PASS') {
        _phase = 'FAIL';
        _record('late-framework-failure');
      }
    };
    _pulse = Timer.periodic(const Duration(milliseconds: 16), (_) {
      final now = _clock.elapsedMilliseconds;
      if (_lastPulse > 0 && now - _lastPulse > _maxGap) {
        _maxGap = now - _lastPulse;
      }
      _lastPulse = now;
      _pulses++;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_scenario()));
  }

  String _value(String value) {
    _valueVisits++;
    return value;
  }

  String _selectionId(TableStressRow row) {
    _identityVisits++;
    return row.id;
  }

  void _updateMetrics() {
    if (_disposed) return;
    _metrics.value = {
      'phase': _phase,
      'rows': _items.length,
      'total': _total,
      'firstMs': _firstMs,
      'completeMs': _completeMs,
      'settledMs': _settledMs,
      'syntheticBatchCalls': _requests,
      'active': _active,
      'cancelled': _cancelled,
      'selected': _selected.length,
      'errors': _errors.length,
      'maxEventLoopGapMs': _maxGap,
    };
  }

  Future<void> _scenario() async {
    try {
      late _ReadOutcome finalOutcome;
      switch (_mode) {
        case 'churn':
          final flights = <Future<_ReadOutcome>>[];
          for (var i = 0; i < 24; i++) {
            flights.add(_load('连续查询 $i', delay: 80));
            await Future<void>.delayed(const Duration(milliseconds: 35));
          }
          await Future.wait(flights);
          finalOutcome = await _load('连续操作后的最终查询');
          _require(_cancelled > 0, 'rapid queries must retire earlier reads');
          _require(
            _lateReplies > 0,
            'late responses must reach the tested reader',
          );
        case 'interrupt':
          final interrupted = await _load('断流查询', interruptAt: 1000);
          _require(
            interrupted == _ReadOutcome.interrupted,
            'expected injected interruption',
          );
          await WidgetsBinding.instance.endOfFrame;
          _require(
            _items.isEmpty && _rowsController.items.isEmpty && !_loading,
            'interruption must withdraw all provisional rows',
          );
          finalOutcome = await _load('断流后的恢复查询');
        case 'refresh':
          _require(
            await _load('保留查询') == _ReadOutcome.success,
            'initial read failed',
          );
          final accepted = _items;
          final selected = {_items.first.id};
          setState(() => _selected = selected);
          await WidgetsBinding.instance.endOfFrame;
          final failedRefresh = await _load(
            _query,
            sameQuery: true,
            interruptAt: 1000,
          );
          await WidgetsBinding.instance.endOfFrame;
          _require(
            failedRefresh == _ReadOutcome.interrupted,
            'expected refresh failure',
          );
          _require(
            identical(accepted, _items),
            'failed reread must keep accepted rows',
          );
          _require(
            setEquals(_selected, selected),
            'failed reread lost selection',
          );
          _require(
            _rowsController.items.length == _total,
            'table lost accepted rows',
          );
          finalOutcome = await _load(_query, sameQuery: true);
          _require(
            setEquals(_selected, selected),
            'successful reread lost selection',
          );
        case 'reopen':
          for (var i = 0; i < 12; i++) {
            final loading = _load('开关 $i', delay: 70);
            await Future<void>.delayed(const Duration(milliseconds: 90));
            _hide();
            await loading;
            _require(
              _items.isEmpty,
              'closed view must not retain provisional rows',
            );
            setState(() => _visible = true);
          }
          finalOutcome = await _load('重新打开后的最终查询');
        default:
          finalOutcome = await _load('初始查询');
      }
      _require(
        finalOutcome == _ReadOutcome.success,
        'final read did not complete successfully',
      );
      _require(
        _lastSuccessfulGeneration == _generation,
        'successful generation is stale',
      );
      _require(_active == 0 && !_loading, 'read work still active');
      _require(_items.length == _total, 'all rows must be present');
      _require(
        _rowsController.items.length == _total,
        'table projection lost rows',
      );
      _require(_draft.text == _expectedInput, 'sibling input must survive');
      final successfulGeneration = _lastSuccessfulGeneration;
      // Keep a real rendering window after the reader returns. The existing
      // controller.settled has a frame cap, so its return is not a latency SLA.
      for (var frame = 0; frame < 8; frame++) {
        WidgetsBinding.instance.ensureVisualUpdate();
        await WidgetsBinding.instance.endOfFrame;
      }
      _require(
        _generation == successfulGeneration &&
            _visible &&
            !_loading &&
            _active == 0,
        'the verified generation retired during the observation window',
      );
      _require(
        _rowsController.items.length == _total &&
            _rowsController.items.every(
              (row) => row.generation == successfulGeneration,
            ),
        'table generation changed during the observation window',
      );
      _phase = _errors.isEmpty ? 'PASS' : 'FAIL';
      _record('scenario-finished');
    } catch (error) {
      _errors.add(error.toString());
      _phase = 'FAIL';
      _record('scenario-failed');
    }
    _updateMetrics();
  }

  void _require(bool value, String message) {
    if (!value) throw StateError(message);
  }

  Future<_ReadOutcome> _load(
    String query, {
    int? delay,
    int? interruptAt,
    bool sameQuery = false,
  }) async {
    final own = sameQuery ? _generation : ++_generation;
    final elapsed = Stopwatch()..start();
    if (!sameQuery) _reader.invalidate();
    ApiException? injectedFailure;
    setState(() {
      _query = query;
      if (!sameQuery) {
        _items = const [];
        _selected = {};
        _filters = {};
      }
      _loading = true;
      _error = null;
      _phase = '读取';
      _firstMs = _completeMs = _settledMs = -1;
    });
    _updateMetrics();
    _active++;
    if (_active > _maxActive) _maxActive = _active;
    bool current() => mounted && !_disposed && _visible && own == _generation;
    try {
      final result = await _reader.read(
        1,
        scope: ('synthetic-table', own, query),
        isCurrent: current,
        fetchPage: (_) => throw StateError('sized loader required'),
        fetchPageSized: (page, size) async {
          _requests++;
          await Future<void>.delayed(Duration(milliseconds: delay ?? _delay));
          // Deliberately ignore cancellation: the production reader, not the
          // fixture loader, must reject a late reply from the old generation.
          if (!current()) _lateReplies++;
          final offset = (page - 1) * size;
          if (interruptAt != null && offset >= interruptAt) {
            injectedFailure = ApiException(
              'INCOMPLETE_READ_PROTOCOL',
              '合成传输已中断',
            );
            throw injectedFailure!;
          }
          final take = (_total - offset).clamp(0, size);
          return PagedResult<TableStressRow>(
            items: [
              for (var i = 0; i < take; i++) TableStressRow(own, offset + i),
            ],
            page: page,
            size: size,
            total: _total,
            totalPages: (_total + size - 1) ~/ size,
            readScopeVersion: 'synthetic-scope',
          );
        },
        onProgressiveBatch: (partial) {
          if (sameQuery) {
            _errors.add(
              'accepted same-query reread published a provisional prefix',
            );
            return;
          }
          if (!current()) {
            _errors.add('stale progressive publication');
            return;
          }
          _require(partial.items.length <= _total, 'prefix exceeds total');
          if (_firstMs < 0) _firstMs = elapsed.elapsedMilliseconds;
          setState(() => _items = partial.items);
          _updateMetrics();
        },
      );
      if (!current()) {
        _errors.add('reader returned successful stale result');
        return _ReadOutcome.failed;
      }
      _completeMs = elapsed.elapsedMilliseconds;
      if (_firstMs < 0) _firstMs = _completeMs;
      setState(() {
        _items = result.items;
        _loading = false;
        _phase = '布局';
      });
      final budget = UiWorkBudget(isCurrent: current);
      for (var i = 0; i < result.items.length; i++) {
        final row = result.items[i];
        _require(
          row.index == i && row.generation == own,
          'row identity/order mismatch',
        );
        _require(
          row.quantity == _quantity && row.amount == _amount,
          'precision mismatch',
        );
        await budget.checkpoint();
      }
      _require(
        result.total == _total && result.items.length == _total,
        'complete count mismatch',
      );
      await WidgetsBinding.instance.endOfFrame;
      await _rowsController.settled;
      if (!current()) throw const UiWorkCancelled();
      _require(
        _rowsController.items.length == _total,
        'controller projection count mismatch',
      );
      for (var i = 0; i < _rowsController.items.length; i++) {
        final row = _rowsController.items[i];
        _require(
          row.index == i && row.generation == own,
          'controller projection identity mismatch',
        );
        await budget.checkpoint();
      }
      _settledMs = elapsed.elapsedMilliseconds;
      _complete++;
      _lastSuccessfulGeneration = own;
      _phase = '完成';
      _record('read-complete');
      return _ReadOutcome.success;
    } catch (error) {
      if (!current()) {
        _cancelled++;
        return _ReadOutcome.retired;
      } else {
        final expected =
            injectedFailure != null && identical(error, injectedFailure);
        if (!sameQuery) _reader.invalidate();
        setState(() {
          if (!sameQuery) _items = const [];
          _loading = false;
          _error = error is ApiException ? error.message : error.toString();
          _phase = '中断';
        });
        if (expected) {
          _expectedInterruptions++;
          return _ReadOutcome.interrupted;
        }
        _errors.add(error.toString());
        return _ReadOutcome.failed;
      }
    } finally {
      _active--;
      _updateMetrics();
    }
  }

  void _cancel() {
    _generation++;
    _reader.invalidate();
    setState(() {
      _items = const [];
      _loading = false;
      _error = null;
      _phase = '已取消';
    });
    _updateMetrics();
    _record('cancelled-by-user');
  }

  void _hide() {
    _cancel();
    setState(() => _visible = false);
  }

  void _record(String event) {
    final receipt = <String, Object?>{
      'event': event,
      'syntheticOnly': true,
      'scenario': _mode,
      'runId': Uri.base.queryParameters['run'] ?? 'manual',
      'variant': const String.fromEnvironment(
        'TABLE_STRESS_VARIANT',
        defaultValue: 'candidate',
      ),
      'targetRows': _total,
      'columns': _columns.length,
      'batchDelayMs': _delay,
      'phase': _phase,
      'loadedRows': _items.length,
      'firstBatchAcceptedMs': _firstMs,
      'completeReadMs': _completeMs,
      'layoutWaitReturnMs': _settledMs,
      'timingBoundary':
          'accepted/reader-return/bounded-layout-wait; not first paint, full layout stability, INP or production SLA',
      'generation': _generation,
      'syntheticBatchCalls': _requests,
      'transportScope': 'synthetic batch callbacks, not HTTP/NDJSON latency',
      'precisionScope':
          'exact display strings retained; numeric decoding/business calculations are separate regressions',
      'activeReads': _active,
      'maxActiveReads': _maxActive,
      'cancelledReads': _cancelled,
      'completeReads': _complete,
      'lateRepliesDelivered': _lateReplies,
      'expectedInterruptions': _expectedInterruptions,
      'successfulGeneration': _lastSuccessfulGeneration,
      'tableRows': _rowsController.items.length,
      'valueVisits': _valueVisits,
      'selectionIdentityVisits': _identityVisits,
      'maxEventLoopGapMs': _maxGap,
      'pulses': _pulses,
      'siblingInputRetained': _draft.text == _expectedInput,
      'errors': List<String>.of(_errors),
      'profiles': {
        for (final e in _profiles.entries)
          e.key: {
            'calls': e.value.calls,
            'micros': e.value.micros,
            'maxMicros': e.value.maxMicros,
          },
      },
    };
    _receipts.add(receipt);
    debugPrint('TABLE_READ_RECEIPT ${jsonEncode(receipt)}');
    if (kIsWeb && const {'localhost', '127.0.0.1'}.contains(Uri.base.host)) {
      // The companion local server stores numeric synthetic evidence only.
      // This endpoint is absent from the product and cannot reach the ERP.
      unawaited(
        Dio(BaseOptions(baseUrl: Uri.base.origin))
            .post<void>('/__table_read_receipt', data: receipt)
            .then<void>((_) {})
            .catchError((Object error) {
              debugPrint('TABLE_RECEIPT_WRITE_FAILED ${error.runtimeType}');
            }),
      );
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _reader.dispose();
    _pulse.cancel();
    debugUiWorkSliceObserver = _previousObserver;
    FlutterError.onError = _previousErrorHandler;
    _queryInput.dispose();
    _draft.dispose();
    _metrics.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Row(
        children: [
          Text('公共表格与完整读取验证'),
          UtenFieldHintIcon(info: '仅使用合成数据。查询回车开始新读取；取消和隐藏会退休旧结果。'),
        ],
      ),
    ),
    body: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 230,
                child: TextField(
                  key: const Key('table-stress-query'),
                  controller: _queryInput,
                  decoration: const InputDecoration(
                    labelText: '查询',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (value) {
                    if (!_visible) setState(() => _visible = true);
                    unawaited(_load(value));
                  },
                ),
              ),
              SizedBox(
                width: 270,
                child: TextField(
                  key: const Key('table-stress-draft'),
                  controller: _draft,
                  decoration: const InputDecoration(
                    labelText: '旁路输入',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (value) => _expectedInput = value,
                ),
              ),
              UtenButton(onPressed: _cancel, child: const Text('中断读取')),
              UtenButton(
                onPressed: () {
                  if (_visible) {
                    _hide();
                  } else {
                    setState(() => _visible = true);
                  }
                },
                child: Text(_visible ? '隐藏表格' : '显示表格'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ValueListenableBuilder<Map<String, Object?>>(
            valueListenable: _metrics,
            builder: (_, value, _) => Align(
              alignment: Alignment.centerLeft,
              child: SelectableText(
                '${value['phase'] ?? '启动'}  已读 ${value['rows'] ?? 0}/$_total  '
                '首批接收 ${value['firstMs'] ?? -1}ms  读取 ${value['completeMs'] ?? -1}ms  '
                '布局等待返回 ${value['settledMs'] ?? -1}ms  已取消 ${value['cancelled'] ?? 0}  '
                '已选 ${value['selected'] ?? 0}  错误 ${value['errors'] ?? 0}',
                key: const Key('table-stress-status'),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _visible
                ? MasterDataTableView<TableStressRow>(
                    key: const Key('table-stress-table'),
                    columns: _columns,
                    items: _items,
                    immutableRows: true, // OPTIMIZED_CONTRACT
                    presentationRevision:
                        _presentationRevision, // OPTIMIZED_CONTRACT
                    rowsController: _rowsController,
                    rowKeyOf: _rowKey,
                    idOf: _selectionId,
                    facets: const {},
                    nullCounts: const {},
                    filters: _filters,
                    onFilterChanged: (key, value) =>
                        setState(() => _filters = {..._filters, key: value}),
                    selectable: true,
                    selectedIds: _selected,
                    onSelectedIdsChanged: (ids) {
                      setState(() => _selected = ids);
                      _updateMetrics();
                    },
                    isLoading: _loading && _items.isEmpty,
                    error: _error,
                    paginationScope: _query,
                    virtualized: true,
                    showFullscreenToggle: true,
                  )
                : const Center(child: Text('表格已关闭')),
          ),
        ],
      ),
    ),
  );
}
