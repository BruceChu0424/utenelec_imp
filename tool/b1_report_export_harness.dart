import 'b1_harness/post_evidence.dart';
// Explicit synthetic UI entry point. All business API methods stay in memory;
// only the optional measurement collector contacts the loopback web server.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/theme/uten_tokens.dart';
import 'package:uten_imp/features/sales/config/sales_report_config.dart';
import 'package:uten_imp/features/sales/pages/sales_report_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final api = _SyntheticApi();
  runApp(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        apiBaseUrlProvider.overrideWithValue(
          Uri.base.resolve('/b1-synthetic-api').toString(),
        ),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'b1-synthetic-reader'),
        ),
        currentPermissionsProvider.overrideWithValue({
          Perm.salesReportView,
          Perm.salesReportExport,
        }),
        isSuperAdminProvider.overrideWithValue(false),
        sharedPreferencesProvider.overrideWithValue(
          InMemorySharedPreferences(),
        ),
      ],
      child: MaterialApp(
        theme: buildLightTheme(),
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: _Harness(api),
      ),
    ),
  );
}

class _SyntheticApi extends ApiClient {
  _SyntheticApi()
    : super(
        Dio(
          BaseOptions(
            baseUrl: Uri.base.resolve('/b1-synthetic-api').toString(),
          ),
        ),
      );

  final clock = Stopwatch()..start();
  final requests = <Map<String, dynamic>>[];
  final jobs = <String, _SyntheticJob>{};
  bool loseNextCreate = false;
  bool failNextDownload = true;

  void event(String action, {Map<String, dynamic>? query, String? id}) {
    requests.add({
      'action': action,
      'atMs': clock.elapsedMilliseconds,
      'query': ?query,
      'id': ?id,
    });
  }

  List<int> indices(Map<String, dynamic> query) {
    final keyword = query['keyword']?.toString().toLowerCase() ?? '';
    final client = query['f.clientName'];
    var values = List.generate(1000, (index) => index + 1).where((index) {
      final row = rowFor(index);
      return (keyword.isEmpty ||
              row.values.any(
                (value) => '$value'.toLowerCase().contains(keyword),
              )) &&
          (client == null || row['__clientId'] == client);
    }).toList();
    if (query['sort'] != null && query['order'] == 'desc') {
      values = values.reversed.toList();
    }
    return values;
  }

  Map<String, dynamic> rowFor(int index) => {
    'id': 'synthetic-$index',
    '__clientId': 'client-${index % 20}',
    '__currencyId': index.isEven ? 'usd' : 'cny',
    'clientName': '合成客户${index % 20}',
    'billNo': 'SO-B1-${index.toString().padLeft(4, '0')}',
    'qty': '1.00000001',
    'amountLocal': '10.01',
    'currencyName': index.isEven ? '美元' : '人民币',
    'remark': '样本$index',
  };

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/report-export-jobs/capabilities') return {'available': true};
    if (path.endsWith('/download-authorization')) {
      final id = path.split('/')[2];
      event('job-download-authorization', id: id);
      if (!jobs.containsKey(id)) {
        throw ApiException('NOT_FOUND', '合成任务尚未查到', httpStatus: 404);
      }
      return {'authorized': true};
    }
    if (path.startsWith('/report-export-jobs/')) {
      final id = path.split('/').last;
      event('job-read', id: id);
      final job = jobs[id];
      if (job == null) {
        throw ApiException('NOT_FOUND', '合成任务尚未查到', httpStatus: 404);
      }
      return job.view();
    }
    if (!path.startsWith('/sales/reports/')) return {};
    final parameters = Map<String, dynamic>.of(query ?? {});
    final started = clock.elapsedMilliseconds;
    event('report-start', query: parameters);
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    final matches = indices(parameters);
    final page = parameters['page'] as int? ?? 1;
    final size = parameters['size'] as int? ?? 50;
    final selected = matches.skip((page - 1) * size).take(size).toList();
    event(
      'report-done',
      query: {
        'page': page,
        'rows': selected.length,
        'elapsedMs': clock.elapsedMilliseconds - started,
      },
    );
    return {
      'readScopeVersion': 'fixture-read-scope-v1',
      'statisticsGeneratedAt': parameters['includeCount'] == false
          ? null
          : DateTime.now().toUtc().toIso8601String(),
      'columns': [
        {'key': 'clientName', 'label': '客户', 'type': 'text', 'width': 180},
        {'key': 'billNo', 'label': '单号', 'type': 'text', 'width': 180},
        {'key': 'qty', 'label': '数量', 'type': 'number', 'width': 150},
        {'key': 'amountLocal', 'label': '金额', 'type': 'money', 'width': 160},
        {'key': 'currencyName', 'label': '币种', 'type': 'text', 'width': 120},
        {'key': 'remark', 'label': '备注', 'type': 'text', 'width': 180},
      ],
      'rows': selected.map(rowFor).toList(),
      'page': page,
      'size': size,
      'total': parameters['includeCount'] == false ? -1 : matches.length,
      'totalPages': parameters['includeCount'] == false
          ? -1
          : (matches.length / size).ceil(),
      'facets': parameters['includeFacets'] == false
          ? <String, dynamic>{}
          : {
              'clientName': [
                for (var client = 0; client < 20; client++)
                  {
                    'value': 'client-$client',
                    'label': '合成客户$client',
                    'count': matches
                        .where((index) => index % 20 == client)
                        .length,
                  },
              ],
            },
      'totals': parameters['includeTotals'] == false
          ? <dynamic>[]
          : [
              {
                'key': 'amountLocal',
                'label': '金额',
                'type': 'money',
                'groupKey': 'currencyName',
                'groups': [
                  for (final even in [true, false])
                    {
                      'unit': even ? '美元' : '人民币',
                      'identity': even ? 'usd' : 'cny',
                      'value': _amount(
                        matches.where((index) => index.isEven == even).length,
                      ),
                    },
                ],
              },
            ],
    };
  }

  static String _amount(int count) {
    final cents = count * 1001;
    return '${cents ~/ 100}.${(cents % 100).toString().padLeft(2, '0')}';
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/report-export-jobs') {
      return jobs.values.map((job) => job.view()).toList();
    }
    return [];
  }

  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async => {};

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    if (path == '/report-export-jobs') {
      final request = Map<String, dynamic>.from(body! as Map);
      final id = request['id'] as String;
      event('job-create', id: id);
      final old = jobs[id];
      if (old != null && jsonEncode(old.request) != jsonEncode(request)) {
        throw ApiException('CONFLICT', '合成任务编号内容冲突', httpStatus: 409);
      }
      final job = jobs.putIfAbsent(
        id,
        () => _SyntheticJob(
          request,
          indices(Map<String, dynamic>.from(request['parameters'] as Map)),
        ),
      );
      if (loseNextCreate) {
        loseNextCreate = false;
        throw NetworkTimeoutException();
      }
      return job.view();
    }
    if (path.startsWith('/report-export-jobs/') && path.endsWith('/cancel')) {
      final id = path.split('/')[2];
      event('job-cancel', id: id);
      jobs[id]!.cancelAt = DateTime.now();
      return {};
    }
    throw StateError('Harness forbids non-synthetic POST $path');
  }

  @override
  Future<Uint8List> downloadBytes(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
  }) async {
    final parts = path.split('/');
    if (parts.length != 4 ||
        parts[1] != 'report-export-jobs' ||
        parts[3] != 'download') {
      throw StateError('Harness forbids non-synthetic download');
    }
    event('job-download', id: parts[2]);
    if (failNextDownload) {
      failNextDownload = false;
      throw ApiException(
        'SIMULATED_DOWNLOAD_FAILURE',
        '合成下载首次失败，请重试原任务',
        httpStatus: 503,
      );
    }
    final job = jobs[parts[2]]!;
    return _workbook(job.indices);
  }

  Uint8List _workbook(List<int> values) {
    final archive = Archive();
    void file(String name, String value) =>
        archive.addFile(ArchiveFile.bytes(name, utf8.encode(value)));
    file(
      '[Content_Types].xml',
      '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>',
    );
    file(
      '_rels/.rels',
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>',
    );
    file(
      'xl/workbook.xml',
      '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="B1合成事实" sheetId="1" r:id="rId1"/></sheets></workbook>',
    );
    file(
      'xl/_rels/workbook.xml.rels',
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>',
    );
    file(
      'xl/worksheets/sheet1.xml',
      '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>${values.map((index) => '<row r="$index"><c t="inlineStr"><is><t>SO-B1-${index.toString().padLeft(4, '0')}</t></is></c><c t="inlineStr"><is><t>1.00000001</t></is></c><c t="inlineStr"><is><t>10.01</t></is></c></row>').join()}</sheetData></worksheet>',
    );
    return Uint8List.fromList(ZipEncoder().encode(archive));
  }
}

class _SyntheticJob {
  _SyntheticJob(this.request, this.indices);
  final Map<String, dynamic> request;
  final List<int> indices;
  final created = DateTime.now();
  DateTime? cancelAt;
  Map<String, dynamic> view() {
    final elapsed = DateTime.now().difference(created).inMilliseconds;
    final cancelled =
        cancelAt != null &&
        DateTime.now().difference(cancelAt!).inMilliseconds >= 1500;
    final status = cancelled
        ? 'CANCELLED'
        : elapsed >= 12000
        ? 'SUCCEEDED'
        : elapsed < 1000
        ? 'PENDING'
        : 'RUNNING';
    return {
      'id': request['id'],
      'domain': request['domain'],
      'report': request['report'],
      'status': status,
      'cancelRequested': cancelAt != null,
      'rows': status == 'SUCCEEDED'
          ? indices.length
          : (indices.length * elapsed / 12000).floor().clamp(0, indices.length),
      'createdAt': created.toUtc().toIso8601String(),
      'snapshotAt': created.toUtc().toIso8601String(),
    };
  }
}

class _Harness extends StatefulWidget {
  const _Harness(this.api);
  final _SyntheticApi api;
  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness>
    with SingleTickerProviderStateMixin {
  late final Ticker ticker;
  final clock = Stopwatch()..start();
  final gaps = <double>[];
  final builds = <double>[];
  final rasters = <double>[];
  bool sampling = false;
  int? lastTick;
  int sampleStart = 0;
  String message = '纯合成1000行；每次查询等待1.5秒；无业务网络或数据库连接。';

  @override
  void initState() {
    super.initState();
    ticker = createTicker((_) {
      final now = clock.elapsedMicroseconds;
      if (sampling && lastTick != null) {
        gaps.add((now - lastTick!) / 1000);
      }
      lastTick = now;
    })..start();
    SchedulerBinding.instance.addTimingsCallback(_frames);
  }

  void _frames(List<ui.FrameTiming> timings) {
    if (!sampling) return;
    for (final frame in timings) {
      if (frame.timestampInMicroseconds(ui.FramePhase.buildStart) <=
          sampleStart) {
        continue;
      }
      builds.add(frame.buildDuration.inMicroseconds / 1000);
      rasters.add(frame.rasterDuration.inMicroseconds / 1000);
    }
  }

  void _start() {
    gaps.clear();
    builds.clear();
    rasters.clear();
    lastTick = null;
    sampleStart =
        SchedulerBinding.instance.currentSystemFrameTimeStamp.inMicroseconds;
    setState(() {
      sampling = true;
      message = '正在采样：可搜索、翻页、滚动并在独立输入框输入。';
    });
  }

  double percentile(List<double> values, double p) {
    if (values.isEmpty) return 0;
    final sorted = List<double>.of(values)..sort();
    return sorted[((sorted.length - 1) * p).ceil()];
  }

  Future<void> _save() async {
    setState(() => sampling = false);
    final metrics = {
      'kind': 'b1-report-export-synthetic-ui',
      'build': const String.fromEnvironment(
        'B1_BUILD_ID',
        defaultValue: 'unidentified',
      ),
      'run': Uri.base.queryParameters['run'],
      'fixtureRows': 1000,
      'reportDelayMs': 1500,
      'businessNetwork': false,
      'viewport': {
        'width': MediaQuery.sizeOf(context).width,
        'height': MediaQuery.sizeOf(context).height,
        'dpr': MediaQuery.devicePixelRatioOf(context),
      },
      'frameGapsMs': {
        'count': gaps.length,
        'p95': percentile(gaps, .95),
        'p99': percentile(gaps, .99),
        'max': percentile(gaps, 1),
        'atLeast200ms': gaps.where((value) => value >= 200).length,
      },
      'buildMs': {
        'p95': percentile(builds, .95),
        'p99': percentile(builds, .99),
        'max': percentile(builds, 1),
      },
      'rasterMs': {
        'p95': percentile(rasters, .95),
        'p99': percentile(rasters, .99),
        'max': percentile(rasters, 1),
      },
      'requests': widget.api.requests,
    };
    await postB1HarnessEvidence(metrics);
    if (mounted) {
      setState(
        () => message =
            '证据已保存；帧p95 ${percentile(gaps, .95).toStringAsFixed(1)}ms / p99 ${percentile(gaps, .99).toStringAsFixed(1)}ms。',
      );
    }
  }

  @override
  void dispose() {
    ticker.dispose();
    SchedulerBinding.instance.removeTimingsCallback(_frames);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(UtenSpacing.s8),
            child: Wrap(
              spacing: UtenSpacing.s8,
              runSpacing: UtenSpacing.s8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton(
                  onPressed: sampling ? null : _start,
                  child: const Text('开始采样'),
                ),
                FilledButton.tonal(
                  onPressed: sampling ? _save : null,
                  child: const Text('停止并保存证据'),
                ),
                OutlinedButton(
                  onPressed: () => setState(() {
                    widget.api.loseNextCreate = true;
                    message = '下一次合成创建将丢失回执，核查会沿原编号恢复。';
                  }),
                  child: const Text('模拟创建回执丢失'),
                ),
                const SizedBox(
                  width: 240,
                  child: TextField(
                    decoration: InputDecoration(
                      labelText: '加载期间独立输入',
                      isDense: true,
                    ),
                  ),
                ),
                Text(message),
              ],
            ),
          ),
          const Expanded(child: SalesReportPage(kind: SalesReportKind.detail)),
        ],
      ),
    ),
  );
}
