// Explicit local performance entry point. It cannot submit business writes.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/responsive_json_decoder.dart';
import 'package:uten_imp/core/performance/ui_work_budget.dart';
import 'package:uten_imp/core/print/isolated_print_pdf.dart';
import 'package:uten_imp/shared/attachments/attachment_preview_parser.dart';
import 'package:uten_imp/shared/attachments/attachment_file_rules.dart';
import 'package:uten_imp/components/layout/uten_segment_row.dart';
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

void main() {
  WidgetsFlutterBinding.ensureInitialized();
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
  bool _material = true;
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

  void _recordFrames(List<ui.FrameTiming> timings) {
    if (!_sampling) return;
    for (final timing in timings) {
      _buildTimes.add(timing.buildDuration.inMicroseconds / 1000);
      _rasterTimes.add(timing.rasterDuration.inMicroseconds / 1000);
    }
  }

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((_) {
      final now = _clock.elapsedMicroseconds;
      if (_sampling && _previousFrame != null) {
        _gaps.add((now - _previousFrame!) / 1000);
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
      }
    });
  }

  void _visitMaterial(void Function(Element) action) {
    void visit(Element element) {
      action(element);
      element.visitChildren(visit);
    }

    _materialHost.currentContext?.visitChildElements(visit);
  }

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
      await Future<void>.delayed(const Duration(milliseconds: 900));
      if (query == '验证物料499-3') {
        _visitMaterial((element) {
          if (element.widget case Text(data: '验证物料499-3')) {
            lastMaterialFound = true;
          }
        });
      }
      if (query == 'B0-no-matching-material') {
        emptyQueryHasRows = false;
        _visitMaterial((element) {
          if (element.widget case Text(data: final text?)) {
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
        if (control == null) {
          await _report(
            'material-quiet-switches',
            extra: {'error': 'mode-control-missing'},
          );
          return;
        }
        control.onSelectionChanged?.call({aggregate});
        switches++;
        await Future<void>.delayed(const Duration(seconds: 2));
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

  void _beginMetrics() {
    _gaps.clear();
    _buildTimes.clear();
    _rasterTimes.clear();
    _sliceMaxima.clear();
    _sliceTotals.clear();
    _sliceCounts.clear();
    _previousFrame = null;
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
      'frameSamples': gaps.length,
      'frameGapP95Ms': percentile(.95),
      'frameGapP99Ms': percentile(.99),
      'maxFrameGapMs': gaps.isEmpty ? 0 : gaps.last,
      'gapsOver200Ms': gaps.where((value) => value >= 200).length,
      'inputCharacters': _input.text.length,
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
                      onPressed: () => setState(() => _material = true),
                      child: const Text('物料页面'),
                    ),
                    TextButton(
                      onPressed: () => setState(() {
                        _material = true;
                        _materialGeneration++;
                      }),
                      child: const Text('重载'),
                    ),
                  ],
                ),
                SelectableText(_status, key: const Key('b0-visible-results')),
              ],
            ),
          ),
          Expanded(
            child: _material
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
