// Explicit local performance entry point. It cannot submit business writes.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:uten_imp/core/performance/responsive_data_codec.dart';
import 'package:uten_imp/core/performance/json_value_snapshot.dart';
import 'package:uten_imp/shared/attachments/pending_attachment_controller.dart';
import 'package:uten_imp/shared/drafts/form_draft.dart';
import 'package:uten_imp/shared/drafts/form_draft_storage.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/responsive_json_decoder.dart';
import 'package:uten_imp/core/performance/ui_work_budget.dart';
import 'package:uten_imp/core/print/isolated_print_pdf.dart';
import 'package:uten_imp/shared/attachments/attachment_preview_parser.dart';
import 'package:uten_imp/shared/attachments/attachment_file_rules.dart';
import 'package:uten_imp/components/layout/uten_segment_row.dart';
import 'package:uten_imp/components/layout/uten_ancestor_row_window.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/department/repositories/department_repository.dart';
import 'package:uten_imp/features/production/models/production_material_analysis.dart';
import 'package:uten_imp/features/production/pages/production_material_analysis_page.dart';
import 'package:uten_imp/features/production/providers/material_analysis_warehouse_prefs_provider.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'b0_editable_grid_fixture.dart';
import 'b0_widget_probe.dart';
import 'b0_storage_checks.dart';
import 'b0_editor_row_probe.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  if (Uri.base.queryParameters['trace'] == 'widgets') {
    debugProfileBuildsEnabled = true;
  }
  final data = materialFixture();
  final dio = Dio()
    ..interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) async {
          if (request.method != 'GET') {
            handler.reject(
              DioException(
                requestOptions: request,
                message: 'Harness forbids business writes',
              ),
            );
            return;
          }
          final Object result =
              request.path == '/production/material-analyses/b0-analysis'
              ? data
              : <Object>[];
          await Future<void>.delayed(const Duration(seconds: 2));
          handler.resolve(
            Response<dynamic>(
              requestOptions: request,
              statusCode: 200,
              data: result,
            ),
          );
        },
      ),
    );
  final api = ApiClient(dio);
  runApp(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        productionPlanRepositoryProvider.overrideWithValue(
          ProductionPlanRepository(api),
        ),
        departmentRepositoryProvider.overrideWithValue(
          DioDepartmentRepository(api),
        ),
        masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
        materialAnalysisWarehousePrefsProvider.overrideWith(
          _HarnessWarehousePrefs.new,
        ),
        sessionProvider.overrideWith(_HarnessSession.new),
        currentPermissionsProvider.overrideWithValue({
          Perm.productionMaterialAnalysisView,
        }),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: buildLightTheme(),
        home: const _Harness(),
      ),
    ),
  );
}

class _HarnessSession extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(
      id: 'b0-user',
      code: 'B0',
      name: '隔离验证',
      permissions: [Perm.productionMaterialAnalysisView],
    ),
  );
}

class _HarnessWarehousePrefs extends MaterialAnalysisWarehousePrefsNotifier {
  @override
  MaterialAnalysisWarehousePrefs build() =>
      const MaterialAnalysisWarehousePrefs(
        primaryWarehouseId: 'b0-warehouse',
        warehouseIds: ['b0-warehouse'],
      );
}

class _Harness extends StatefulWidget {
  const _Harness();
  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final _clock = Stopwatch()..start();
  final _gaps = <double>[];
  final _input = TextEditingController();
  int? _previousFrame;
  bool _sampling = false;
  bool _busy = false;
  bool _material = Uri.base.queryParameters['auto'] != 'grid';
  bool _showGrid = Uri.base.queryParameters['view'] == 'grid';
  final _gridHost = GlobalKey<B0EditableGridFixtureState>();
  int _maxMountedGridRows = 0;
  int _materialGeneration = 0;
  String _status = '500 产品 / 2000 物料，固定两秒只读接口延迟';
  final _decoder = ResponsiveJsonDecoder();
  Timer? _finish;
  final _materialHost = GlobalKey();
  final _buildTimes = <double>[];
  final _rasterTimes = <double>[];
  final _sliceMaxima = <String, double>{};
  final _sliceTotals = <String, double>{};
  final _sliceCounts = <String, int>{};
  final _widgetProbe = B0WidgetProbe();
  double? _coldStartToFirstTickMs;
  Map<String, Object?>? _firstApplicationFrame;
  Map<String, Object?>? _firstSampleFrame;
  int _sampleAfterFrameTimestamp = 0;
  String _phase = 'application-startup';
  final _phases = <Map<String, Object?>>[];
  Map<String, Object?>? _largestGap;

  Map<String, Object?> _frameTiming(ui.FrameTiming timing) => {
    'buildMs': timing.buildDuration.inMicroseconds / 1000,
    'rasterMs': timing.rasterDuration.inMicroseconds / 1000,
    'totalSpanMs': timing.totalSpan.inMicroseconds / 1000,
    'buildStartMicros': timing.timestampInMicroseconds(
      ui.FramePhase.buildStart,
    ),
  };

  void _markPhase(String phase) {
    _phase = phase;
    _phases.add({
      'phase': phase,
      'sinceInitMs': _clock.elapsedMicroseconds / 1000,
    });
  }

  void _recordFrames(List<ui.FrameTiming> timings) {
    if (timings.isNotEmpty) {
      _firstApplicationFrame ??= _frameTiming(timings.first);
    }
    if (!_sampling) return;
    for (final timing in timings) {
      // Timing callbacks are batched. Do not include a completed frame from
      // before this sample merely because its callback arrived afterwards.
      if (timing.timestampInMicroseconds(ui.FramePhase.buildStart) <=
          _sampleAfterFrameTimestamp) {
        continue;
      }
      _firstSampleFrame ??= _frameTiming(timing);
      _buildTimes.add(timing.buildDuration.inMicroseconds / 1000);
      _rasterTimes.add(timing.rasterDuration.inMicroseconds / 1000);
    }
  }

  @override
  void initState() {
    super.initState();
    if (Uri.base.queryParameters['trace'] == 'widgets') _widgetProbe.start();
    _ticker = createTicker((_) {
      if (_showGrid) {
        final count =
            _gridHost.currentState?.metrics['mountedRows'] as int? ?? 0;
        if (count > _maxMountedGridRows) _maxMountedGridRows = count;
      }
      final now = _clock.elapsedMicroseconds;
      _coldStartToFirstTickMs ??= now / 1000;
      if (_sampling && _previousFrame != null) {
        final gap = (now - _previousFrame!) / 1000;
        _gaps.add(gap);
        if (gap > ((_largestGap?['ms'] as double?) ?? 0)) {
          _largestGap = {
            'ms': gap,
            'ordinal': _gaps.length,
            'intervalEndPhase': _phase,
            'sinceInitMs': now / 1000,
          };
        }
      }
      _previousFrame = now;
    })..start();
    SchedulerBinding.instance.addTimingsCallback(_recordFrames);
    debugUiWorkSliceObserver = (label, elapsed) {
      if (!_sampling) return;
      final ms = elapsed.inMicroseconds / 1000;
      if (ms > (_sliceMaxima[label] ?? 0)) _sliceMaxima[label] = ms;
      _sliceTotals[label] = (_sliceTotals[label] ?? 0) + ms;
      _sliceCounts[label] = (_sliceCounts[label] ?? 0) + 1;
    };
    if (_showGrid || Uri.base.queryParameters['auto'] == 'grid') {
      _status = '1000 行大单据：完整数据保留，按视口挂载，验证搜索、滚动与输入';
      if (_showGrid) _beginMetrics();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (Uri.base.queryParameters['auto'] == 'json') {
        Future<void>.delayed(const Duration(seconds: 2), _decodeLarge);
      } else if (Uri.base.queryParameters['auto'] == 'material') {
        Future<void>.delayed(const Duration(seconds: 6), _quietMaterial);
      } else if (Uri.base.queryParameters['auto'] == 'pdf') {
        Future<void>.delayed(const Duration(seconds: 3), _pdfScenario);
      } else if (Uri.base.queryParameters['auto'] == 'csv') {
        Future<void>.delayed(const Duration(seconds: 3), _csvScenario);
      } else if (Uri.base.queryParameters['auto'] == 'material-actions') {
        Future<void>.delayed(const Duration(seconds: 6), _materialInteractions);
      } else if (Uri.base.queryParameters['auto'] == 'grid') {
        Future<void>.delayed(const Duration(seconds: 3), _gridScenario);
      } else if (Uri.base.queryParameters['auto'] == 'bounded-encode') {
        Future<void>.delayed(
          const Duration(seconds: 3),
          _boundedEncodeScenario,
        );
      } else if (Uri.base.queryParameters['auto'] == 'draft') {
        Future<void>.delayed(const Duration(seconds: 3), _draftScenario);
      } else if (Uri.base.queryParameters['auto'] == 'draft-migration') {
        Future<void>.delayed(
          const Duration(seconds: 3),
          _storageChecksScenario,
        );
      } else if (Uri.base.queryParameters['auto'] == 'editor-rows') {
        Future<void>.delayed(const Duration(seconds: 3), _editorRowsScenario);
      }
    });
  }

  Future<void> _boundedEncodeScenario() async {
    final bytes = Uint8List(10 * 1024 * 1024);
    final rows = List.generate(
      1000,
      (i) => {
        'id': '$i',
        'qty': '123456.0001',
        'note': '未保存原文 $i',
        for (var field = 0; field < 30; field++) 'field$field': '原始值 $field/$i',
      },
    );
    setState(() {
      _material = false;
      _showGrid = false;
      _status = '有界边界核查：10MiB导入编码与千行含附件草稿快照';
    });
    await Future<void>.delayed(const Duration(milliseconds: 300));
    _beginMetrics();
    await Future<void>.delayed(const Duration(milliseconds: 60));
    final clock = Stopwatch()..start();
    final encoded = await encodeBase64Responsive(bytes);
    final base64Ms = clock.elapsedMicroseconds / 1000;
    clock.reset();
    final cloned =
        await decodeJsonResponsive(
              await encodeJsonResponsive({'rows': rows, 'attachment': encoded}),
            )
            as Map<String, dynamic>;
    final snapshotMs = clock.elapsedMicroseconds / 1000;
    await Future<void>.delayed(const Duration(milliseconds: 80));
    await _report(
      'responsive-import-draft-encode',
      extra: {
        'sourceBytes': bytes.length,
        'base64Ms': base64Ms,
        'snapshotMs': snapshotMs,
        'rowsPreserved': (cloned['rows'] as List).length == 1000,
        'attachmentPreserved': cloned['attachment'] == encoded,
      },
    );
  }

  Future<bool> _sameBytes(Uint8List left, Uint8List right) async {
    if (left.length != right.length) return false;
    final work = UiWorkBudget(maxItems: 64, debugLabel: 'harness-byte-oracle');
    for (var start = 0; start < left.length; start += 4096) {
      final end = (start + 4096).clamp(0, left.length);
      for (var i = start; i < end; i++) {
        if (left[i] != right[i]) return false;
      }
      await work.checkpoint();
    }
    return true;
  }

  Future<void> _storageChecksScenario() async {
    setState(() {
      _material = false;
      _showGrid = false;
      _busy = true;
      _status = '真实 IndexedDB：迁移竞写、升级失败保留原文、原子回滚';
    });
    await Future<void>.delayed(const Duration(milliseconds: 300));
    _beginMetrics();
    try {
      await _report('draft-idb-migration', extra: await runB0StorageChecks());
    } catch (error) {
      await _report(
        'draft-idb-migration',
        extra: {'errorType': error.runtimeType.toString()},
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _editorRowsScenario() async {
    setState(() {
      _material = false;
      _showGrid = false;
      _busy = true;
      _status = '真实销售/财务明细行：控制器构造与原始输入核查';
    });
    await Future<void>.delayed(const Duration(milliseconds: 300));
    _beginMetrics(phase: 'editor-row-models');
    try {
      final result = await runB0EditorRowProbe();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await _report('editor-row-models', extra: result);
    } catch (error) {
      await _report(
        'editor-row-models',
        extra: {'errorType': error.runtimeType.toString()},
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _draftScenario() async {
    // A private synthetic namespace on the loopback harness origin only.
    final prefix =
        '${DateTime.now().microsecondsSinceEpoch.toRadixString(16).padLeft(64, '0')}_';
    final key = '${prefix}b0-draft';
    final first = createFormDraftStorage();
    final second = createFormDraftStorage();
    final pending = PendingAttachmentController(maxFileBytes: 25 * 1024 * 1024);
    final revived = PendingAttachmentController(maxFileBytes: 25 * 1024 * 1024);
    final bytes = Uint8List(25 * 1024 * 1024);
    bytes[0] = 91;
    bytes[bytes.length ~/ 2] = 173;
    bytes[bytes.length - 1] = 255;
    final failure = pending.add(
      PlatformFile(name: 'b0-original.txt', size: bytes.length, bytes: bytes),
    );
    setState(() {
      _material = false;
      _showGrid = false;
      _busy = true;
      _status = '25MiB真实待保存附件 / 千行草稿 / 两实例原子冲突核查';
    });
    await Future<void>.delayed(const Duration(milliseconds: 300));
    _beginMetrics();
    final elapsed = Stopwatch()..start();
    try {
      if (failure != null) throw StateError(failure);
      final data = captureDeferredJsonValues(
        () => <String, dynamic>{
          'rows': List.generate(
            1000,
            (i) => {'id': '$i', 'qty': '0001.', 'note': '原文 $i'},
          ),
          'attachments': pending.exportDraft(),
        },
      );
      final frozen = JsonValueSnapshot.capture(data);
      final materialized =
          await materializeJsonResponsive(frozen.data) as Map<String, dynamic>;
      final draft = FormDraft(
        id: 'b0-draft',
        title: 'B0合成草稿',
        module: BadgeModule.sales,
        route: '/sales/orders/new',
        permission: Perm.salesOrderCreate,
        updatedAt: DateTime.utc(2026, 10, 23),
        revision: 'initial',
        data: materialized,
      );
      final value = await encodeJsonResponsive(draft.toJson());
      final initialCreated = await first.compareAndSet(
        key,
        expectedValue: null,
        value: value,
      );
      final updates = await Future.wait([
        for (final revision in ['writer-a', 'writer-b'])
          encodeJsonResponsive({...draft.toJson(), 'revision': revision}),
      ]);
      final races = await Future.wait([
        first.compareAndSet(key, expectedValue: value, value: updates[0]),
        second.compareAndSet(key, expectedValue: value, value: updates[1]),
      ]);
      final stored = await first.read(key);
      final decoded =
          await decodeJsonResponsive(stored!) as Map<String, dynamic>;
      final rawData = decoded['data'] as Map<String, dynamic>;
      final items = (rawData['attachments'] as Map)['items'] as List;
      final attachment = (items.single as Map)['bytes'] as String;
      await revived.restoreDraftResponsive(
        Map<String, dynamic>.from(rawData['attachments'] as Map),
        isCurrent: () => mounted,
      );
      final restored = revived.items.single.bytes;
      final sourceHash = await sha256HexResponsive(restored);
      final history = first as FormDraftHistoryStorage;
      final page = await history.readHistoryPage(prefix);
      final original = await history.readHistoryRecord(
        prefix,
        page.entries.last.id,
      );
      final originalItems =
          (original!.draft.data['attachments'] as Map)['items'] as List;
      final originalBytes = (originalItems.single as Map)['bytes'];
      await _report(
        'large-draft-storage',
        extra: {
          'sourceBytes': bytes.length,
          'elapsedMs': elapsed.elapsedMilliseconds,
          'initialCreated': initialCreated,
          'atomicWinners': races.where((v) => v).length,
          'historyEntries': page.entries.length,
          'originalHistoryPreserved':
              originalBytes == attachment &&
              original.draft.revision == 'initial',
          'fullBytesPreserved': await _sameBytes(bytes, restored),
          'sourceFingerprintPreserved':
              sourceHash ==
              'cabbae410484dc11fa0e85847287ad5674fba762996bc71107512f18eb50384c',
          'rowsPreserved': (rawData['rows'] as List).length == 1000,
          'rawInputPreserved':
              ((rawData['rows'] as List).first as Map)['qty'] == '0001.',
          'immutableCapture': frozen.matches(data),
        },
      );
    } catch (error) {
      await _report(
        'large-draft-storage',
        extra: {'errorType': error.runtimeType.toString()},
      );
    } finally {
      pending.dispose();
      revived.dispose();
      // Clear only this run's disposable namespace, including its test history.
      // This never targets business data or another harness run's records.
      if (first is BusinessResetFormDraftStorage) {
        await (first as BusinessResetFormDraftStorage).synchronizeBusinessReset(
          prefix,
          1,
        );
      }
      if (first is ClosableFormDraftStorage) {
        await (first as ClosableFormDraftStorage).close();
      }
      if (second is ClosableFormDraftStorage) {
        await (second as ClosableFormDraftStorage).close();
      }
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _gridScenario() async {
    try {
      // Exercise opening a cold business module in an already running UI.
      // Include creation of all models/controllers and its first real frame;
      // report runApp/engine startup separately, never as a fabricated gap.
      _beginMetrics(phase: 'grid-first-mount');
      final mountClock = Stopwatch()..start();
      setState(() => _showGrid = true);
      await WidgetsBinding.instance.endOfFrame;
      final firstFrameEndMs = mountClock.elapsedMicroseconds / 1000;
      if (!mounted) return;
      _markPhase('grid-progressive-mount');
      await _gridHost.currentState?.waitUntilRowsReady();
      final mountToReadyMs = mountClock.elapsedMicroseconds / 1000;
      if (!mounted) return;
      _markPhase('grid-ready');
      final result = await _gridHost.currentState?.runActions(
        onPhase: _markPhase,
      );
      await _report(
        'large-editable-grid',
        extra: {
          ...?result,
          if (result == null) 'error': 'grid-missing',
          'gridMountToFirstFrameEndMs': firstFrameEndMs,
          'gridMountToSettledMs': mountToReadyMs,
        },
      );
    } catch (error) {
      await _report(
        'large-editable-grid',
        extra: {'errorType': error.runtimeType.toString()},
      );
    }
  }

  void _visitMaterial(void Function(Element) action) {
    void visit(Element element) {
      action(element);
      element.visitChildren(visit);
    }

    _materialHost.currentContext?.visitChildElements(visit);
  }

  Future<bool> _waitMaterialPresentation() async {
    // Include the real search debounce and wait for the actual UI completion
    // marker; a fixed sleep can cancel a still-running search in the test.
    await Future<void>.delayed(const Duration(milliseconds: 350));
    final deadline = Stopwatch()..start();
    while (mounted && deadline.elapsed < const Duration(seconds: 15)) {
      var pending = false;
      _visitMaterial((element) {
        if (element.widget.key == const Key('material-view-switch-progress')) {
          pending = true;
        }
      });
      if (!pending) {
        await _waitMaterialMounts();
        return mounted;
      }
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
    return false;
  }

  Future<void> _waitMaterialMounts() async {
    final windows = <Future<void>>[];
    _visitMaterial((element) {
      if (element.widget case final UtenAncestorRowWindow<Object> window) {
        windows.add(window.controller.settled);
      } else if (element.widget case final UtenDeferredRowMount row) {
        windows.add(row.controller.settled);
      }
    });
    await Future.wait(windows);
  }

  String? _visibleText(Widget widget) => switch (widget) {
    Text(:final data, :final textSpan) => data ?? textSpan?.toPlainText(),
    RichText(:final text) => text.toPlainText(),
    _ => null,
  };

  Future<void> _materialInteractions() async {
    _beginMetrics();
    var searches = 0;
    var scrolls = 0;
    var lastMaterialFound = false;
    var emptyQueryHasRows = true;
    var furthestOffset = 0.0;
    for (final query in ['验证物料499-3', '', 'B0-no-matching-material', '']) {
      TextField? input;
      _visitMaterial((element) {
        if (element.widget case final TextField field) {
          if (field.decoration?.hintText == '查找产品或物料') input = field;
        }
      });
      if (input?.controller == null || input?.onChanged == null) {
        await _report(
          'material-search-scroll',
          extra: {'error': 'search-control-missing'},
        );
        return;
      }
      input!.controller!.text = query;
      input!.onChanged!(query);
      searches++;
      if (!await _waitMaterialPresentation()) {
        await _report(
          'material-search-scroll',
          extra: {'error': 'presentation-timeout'},
        );
        return;
      }
      if (query == '验证物料499-3') {
        _visitMaterial((element) {
          if (_visibleText(element.widget)?.contains('验证物料499-3') == true) {
            lastMaterialFound = true;
          }
        });
      }
      if (query == 'B0-no-matching-material') {
        emptyQueryHasRows = false;
        _visitMaterial((element) {
          if (_visibleText(element.widget) case final text?) {
            if (text.startsWith('验证产品') || text.startsWith('验证物料')) {
              emptyQueryHasRows = true;
            }
          }
        });
      }
    }
    ScrollPosition? vertical;
    _visitMaterial((element) {
      if (element case StatefulElement(state: final ScrollableState state)) {
        final position = state.position;
        if (axisDirectionToAxis(position.axisDirection) == Axis.vertical &&
            position.hasContentDimensions &&
            position.maxScrollExtent > (vertical?.maxScrollExtent ?? 0)) {
          vertical = position;
        }
      }
    });
    if (vertical != null) {
      final target = vertical!.maxScrollExtent.clamp(0.0, 12000.0);
      for (var step = 1; step <= 8; step++) {
        await vertical!.animateTo(
          target * step / 8,
          duration: const Duration(milliseconds: 160),
          curve: Curves.linear,
        );
        scrolls++;
        if (vertical!.pixels > furthestOffset) {
          furthestOffset = vertical!.pixels;
        }
      }
      await vertical!.animateTo(
        0,
        duration: const Duration(milliseconds: 400),
        curve: Curves.linear,
      );
    }
    await _waitMaterialMounts();
    await _report(
      'material-search-scroll',
      extra: {
        'searches': searches,
        'scrollSteps': scrolls,
        'furthestOffset': furthestOffset,
        'lastMaterialFound': lastMaterialFound,
        'emptyQueryHasRows': emptyQueryHasRows,
        'automation':
            'real TextField callbacks and ScrollPosition; pointer/keyboard checked separately',
      },
    );
  }

  Future<void> _quietMaterial() async {
    if (!mounted) return;
    _beginMetrics();
    var switches = 0;
    for (var cycle = 0; cycle < 3; cycle++) {
      for (final aggregate in [true, false]) {
        UtenSegmentRow<bool>? target;
        void visit(Element element) {
          if (element.widget case final UtenSegmentRow<bool> row) {
            if (row.key == const Key('material-bom-layout-segments')) {
              target = row;
            }
          }
          element.visitChildren(visit);
        }

        _materialHost.currentContext?.visitChildElements(visit);
        final control = target;
        if (control == null || control.onSelectionChanged == null) {
          await _report(
            'material-quiet-switches',
            extra: {'error': 'mode-control-missing'},
          );
          return;
        }
        control.onSelectionChanged?.call({aggregate});
        switches++;
        await Future<void>.delayed(const Duration(seconds: 2));
        if (!await _waitMaterialPresentation()) {
          await _report(
            'material-quiet-switches',
            extra: {'error': 'mode-presentation-timeout'},
          );
          return;
        }
        var selected = false;
        _visitMaterial((element) {
          if (element.widget case final UtenSegmentRow<bool> row) {
            if (row.key == const Key('material-bom-layout-segments')) {
              selected =
                  row.selected.length == 1 && row.selected.contains(aggregate);
            }
          }
        });
        if (!selected) {
          await _report(
            'material-quiet-switches',
            extra: {'error': 'mode-selection-not-applied'},
          );
          return;
        }
      }
    }
    await _report(
      'material-quiet-switches',
      extra: {
        'switches': switches,
        'automation':
            'in-app widget callbacks; no accessibility snapshots during sampling',
      },
    );
  }

  Future<void> _pdfScenario() async {
    final request = PrintPdfRequest(
      title: 'B0 complete PDF generation',
      headers: ['Item', 'Exact quantity'],
      rows: List.generate(
        2800,
        (index) => ['$index - fixed source', '9876543210.1234567890'],
      ),
    );
    setState(() {
      _material = false;
      _busy = true;
      _status = 'PDF后台生成，界面应保持可输入';
    });
    await Future<void>.delayed(const Duration(milliseconds: 300));
    _beginMetrics();
    final started = _clock.elapsedMilliseconds;
    final generator = IsolatedPrintPdfGenerator();
    try {
      final bytes = await generator.generate(request);
      final valid = latin1.decode(bytes.sublist(0, 5)) == '%PDF-';
      await _report(
        'complete-pdf-worker',
        extra: {
          'elapsedMs': _clock.elapsedMilliseconds - started,
          'sourceRows': 2800,
          'pdfBytes': bytes.length,
          'validPdfHeader': valid,
        },
      );
    } catch (error) {
      await _report(
        'complete-pdf-worker',
        extra: {'errorType': error.runtimeType.toString()},
      );
    } finally {
      generator.dispose();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _csvScenario() async {
    final bytes = Uint8List.fromList(
      utf8.encode(
        '名称,数量,备注\r\n${List.generate(100000, (index) => '物料$index,123.456789,"跨行\r\n原文$index"').join('\r\n')}',
      ),
    );
    setState(() {
      _material = false;
      _busy = true;
      _status = '大CSV分片解析，界面应保持可输入';
    });
    await Future<void>.delayed(const Duration(milliseconds: 300));
    _beginMetrics();
    final started = _clock.elapsedMilliseconds;
    try {
      final parsed = await parseAttachmentPreview(
        AttachmentPreviewKind.csv,
        bytes,
      );
      await _report(
        'large-csv-preview',
        extra: {
          'elapsedMs': _clock.elapsedMilliseconds - started,
          'sourceBytes': bytes.length,
          'totalRows': parsed.table?.totalRows,
          'shownRows': parsed.table?.rows.length,
          'truncated': parsed.table?.truncated,
          'error': parsed.error,
        },
      );
    } catch (error) {
      await _report(
        'large-csv-preview',
        extra: {'errorType': error.runtimeType.toString()},
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _beginMetrics({String phase = 'scenario'}) {
    _gaps.clear();
    _buildTimes.clear();
    _rasterTimes.clear();
    _sliceMaxima.clear();
    _sliceTotals.clear();
    _sliceCounts.clear();
    _maxMountedGridRows = 0;
    _widgetProbe.reset();
    _previousFrame = null;
    _firstSampleFrame = null;
    _largestGap = null;
    _phases.clear();
    _markPhase(phase);
    _sampleAfterFrameTimestamp =
        SchedulerBinding.instance.currentSystemFrameTimeStamp.inMicroseconds;
    _sampling = true;
  }

  void _startSample() {
    _finish?.cancel();
    _beginMetrics();
    setState(() => _status = '正在采样：请切换物料视图、滚动并在上方输入');
    _finish = Timer(
      const Duration(seconds: 15),
      () => unawaited(_report('material-interaction')),
    );
  }

  Future<void> _decodeLarge() async {
    if (_busy) return;
    // Fixture generation is outside the measured decoding interval.
    final bytes = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'items': List.generate(
            30000,
            (index) => {
              'id': index,
              'name': '性能验证物料😀$index',
              'exact': '98765432109876.1234567890',
              'qty': index / 10,
              'values': [true, false, null, index],
            },
          ),
        }),
      ),
    );
    setState(() {
      _material = false;
      _busy = true;
      _status = '等待只读响应，界面应持续可输入';
    });
    await Future<void>.delayed(const Duration(seconds: 2));
    _beginMetrics();
    final started = _clock.elapsedMilliseconds;
    try {
      final decoded = await _decoder.decodeBytes(bytes) as Map<String, dynamic>;
      final rows = decoded['items'] as List;
      if (rows.length != 30000 ||
          (rows.last as Map)['exact'] != '98765432109876.1234567890') {
        throw StateError('Response facts changed');
      }
      await _report(
        'large-json-worker',
        extra: {
          'bytes': bytes.length,
          'rows': rows.length,
          'elapsedMs': _clock.elapsedMilliseconds - started,
          'factsEqual': true,
        },
      );
    } catch (error) {
      await _report(
        'large-json-worker',
        extra: {'errorType': error.runtimeType.toString()},
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _report(
    String scenario, {
    Map<String, Object?> extra = const {},
  }) async {
    if (!mounted) return;
    _sampling = false;
    final gaps = [..._gaps]..sort();
    double percentile(double p) =>
        gaps.isEmpty ? 0 : gaps[((gaps.length - 1) * p).round()];
    final result = <String, Object?>{
      'buildId': const String.fromEnvironment(
        'B0_BUILD_ID',
        defaultValue: 'exploratory',
      ),
      'run': Uri.base.queryParameters['run'] ?? 'exploratory',
      'scenario': scenario,
      'widgetTrace': _widgetProbe.summary(),
      'viewportWidth': MediaQuery.sizeOf(context).width,
      'viewportHeight': MediaQuery.sizeOf(context).height,
      'devicePixelRatio': MediaQuery.devicePixelRatioOf(context),
      'textScale': MediaQuery.textScalerOf(context).scale(14) / 14,
      'contentViewportHeight': switch ((_showGrid
              ? _gridHost.currentContext
              : _materialHost.currentContext)
          ?.findRenderObject()) {
        final RenderBox box when box.hasSize => box.size.height,
        _ => null,
      },
      'frameSamples': gaps.length,
      'frameGapP95Ms': percentile(.95),
      'frameGapP99Ms': percentile(.99),
      'maxFrameGapMs': gaps.isEmpty ? 0 : gaps.last,
      'gapsOver200Ms': gaps.where((value) => value >= 200).length,
      'coldStartToFirstTickMs': _coldStartToFirstTickMs,
      'firstApplicationFrame': _firstApplicationFrame,
      'firstSampleFrame': _firstSampleFrame,
      'largestGap': _largestGap,
      'phases': List<Map<String, Object?>>.of(_phases),
      'inputCharacters': _input.text.length,
      if (_showGrid) 'grid': _gridHost.currentState?.metrics,
      if (_showGrid) 'maxMountedGridRows': _maxMountedGridRows,
      ...extra,
      'frameTimingSamples': _buildTimes.length,
      'maxBuildMs': _buildTimes.isEmpty ? null : (_buildTimes..sort()).last,
      'maxRasterMs': _rasterTimes.isEmpty ? null : (_rasterTimes..sort()).last,
      'maxBudgetIntervalMs': Map<String, double>.from(_sliceMaxima),
      // Labels can be nested: totals are diagnostic per operation, not additive
      // elapsed time. Render row totals distinguish layout from factory work.
      'profileTotalMs': Map<String, double>.from(_sliceTotals),
      'profileCalls': Map<String, int>.from(_sliceCounts),
    };
    if (mounted) setState(() => _status = jsonEncode(result));
    try {
      await Dio().post<dynamic>(
        Uri.base.resolve('/b0-results').toString(),
        data: result,
      );
    } catch (_) {
      // The visible result is still available without the local collector.
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _finish?.cancel();
    _input.dispose();
    _decoder.dispose();
    _widgetProbe.dispose();
    SchedulerBinding.instance.removeTimingsCallback(_recordFrames);
    debugUiWorkSliceObserver = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                Row(
                  children: [
                    const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _input,
                        decoration: const InputDecoration(
                          labelText: '验证输入(加载期间也应能输入)',
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: _startSample,
                      child: const Text('采样15秒'),
                    ),
                    TextButton(
                      onPressed: _busy ? null : () => unawaited(_decodeLarge()),
                      child: const Text('验证大JSON'),
                    ),
                    TextButton(
                      onPressed: () => setState(() {
                        _showGrid = false;
                        _material = true;
                      }),
                      child: const Text('物料页面'),
                    ),
                    TextButton(
                      onPressed: () => setState(() {
                        _showGrid = false;
                        _material = true;
                        _materialGeneration++;
                      }),
                      child: const Text('重载'),
                    ),
                    TextButton(
                      onPressed: () => setState(() {
                        _showGrid = true;
                        _status = '1000 行大单据：完整数据保留，按视口挂载，验证搜索、滚动与输入';
                      }),
                      child: const Text('大单据'),
                    ),
                  ],
                ),
                SizedBox(
                  height: 60,
                  child: SingleChildScrollView(
                    child: SelectableText(
                      _status,
                      key: const Key('b0-visible-results'),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: _showGrid
                ? B0EditableGridFixture(key: _gridHost)
                : _material
                ? RepaintBoundary(
                    key: _materialHost,
                    child: ProductionMaterialAnalysisPage(
                      key: ValueKey(_materialGeneration),
                      seed: const ProductionMaterialAnalysisSeed(
                        analysisId: 'b0-analysis',
                        warehouseId: 'b0-warehouse',
                      ),
                    ),
                  )
                : Center(
                    child: _busy
                        ? const CircularProgressIndicator()
                        : const Text('数据校验完成'),
                  ),
          ),
        ],
      ),
    ),
  );
}

Map<String, dynamic> materialFixture() => {
  'analysisId': 'b0-analysis',
  'analysisNo': 'B0-READ-ONLY',
  'version': 1,
  'fingerprint': 'b0-fixture',
  'status': 'ACTIVE',
  'warehouseId': 'b0-warehouse',
  'warehouseIds': ['b0-warehouse'],
  'allowedActions': <String>[],
  'products': [
    for (var i = 0; i < 500; i++)
      {
        'analysisLineId': 'product-$i',
        'goodsId': 'product-goods-$i',
        'goodsCode': 'P$i',
        'goodsName': '验证产品$i',
        'rootMaterialLineId': 'root-$i',
        'requestedQty': 10,
        'remainingQty': 10,
        'unitId': 'unit',
        'unitName': '个',
      },
  ],
  'flatMaterials': [
    for (var i = 0; i < 500; i++)
      for (var level = 0; level < 4; level++)
        {
          'materialLineId': level == 0 ? 'root-$i' : 'material-$i-$level',
          'analysisLineId': 'product-$i',
          'nodeKey': 'node-$i-$level',
          'parentNodeKey': level == 0 ? null : 'node-$i-${level - 1}',
          'nodeRole': level == 0 ? 'PRODUCT_ROOT' : 'BOM_COMPONENT',
          'actionGroupKey': 'group-$i-$level',
          'level': level,
          'goodsId': 'goods-$i-$level',
          'goodsCode': 'M$i-$level',
          'goodsName': '验证物料$i-$level',
          'materialKey': 'goods-$i-$level|NONE|unit',
          'unitId': 'unit',
          'unitName': '个',
          'requiredQty': 10 * (level + 1),
          'sourceRequiredQty': 10 * (level + 1),
          'shortageQty': 10 * (level + 1),
          'availableQty': 0,
          'routeConfirmed': true,
          'sourceSuggestion': level == 0 ? 'MAKE' : 'BUY',
          'sourceConfirmed': level == 0 ? 'MAKE' : 'BUY',
          'path': [for (var j = 0; j <= level; j++) 'goods-$i-$j'],
        },
  ],
  'warehouses': [
    {
      'warehouseId': 'b0-warehouse',
      'warehouseName': '验证仓库',
      'selected': true,
      'primary': true,
    },
  ],
};
