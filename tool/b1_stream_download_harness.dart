// Synthetic, loopback-only diagnostic entry point. No business API, credentials,
// database or in-memory full-file substitute is used by this harness.
// Build this target explicitly; it is never imported by the application.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/io/file_saver.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/streaming_download_adapter.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/theme/uten_tokens.dart';

import 'b1_harness/interaction_collector.dart';
import 'b1_harness/post_evidence.dart';

const _fixtureId = 'b1000000-0000-4000-8000-000000000001';
const _apiPath = '/report-export-jobs/$_fixtureId/download';
const _expectedBytes = 128 * 1024 * 1024;
const _expectedSha256 =
    'a626d17da2e502f5b4b8e3ebd23f0bf9daef6255688d8e0bb482b3ae3794a682';
const _buildId = String.fromEnvironment(
  'B1_HARNESS_BUILD_ID',
  defaultValue: 'unrecorded-build',
);
const _modes = <String, String>{
  'ok': '完整慢流 · 128 MiB',
  '503': '服务暂不可用 · 503',
  'truncate': '8 MiB 后提前结束',
  'disconnect': '1 MiB 后断开连接',
  'corrupt': '完整长度、错误内容',
};

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildLightTheme(),
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const _Harness(),
    ),
  );
}

class _DigestReceiver implements Sink<Digest> {
  Digest? digest;

  @override
  void add(Digest value) => digest = value;

  @override
  void close() {}
}

class _Harness extends StatefulWidget {
  const _Harness();

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  final _input = TextEditingController();
  final _interaction = B1InteractionCollector();
  final _appClock = Stopwatch()..start();
  final _clock = Stopwatch();
  final _runs = <Map<String, Object?>>[];
  final _inputFrames = <Map<String, Object?>>[];
  final _scopeEvents = <Map<String, Object?>>[];
  late final Dio _dio;
  late final ApiClient _api;
  Timer? _refresh;
  Timer? _abaReturn;
  bool? _canSave;
  bool _originAllowed = false;
  bool _busy = false;
  bool _published = false;
  bool _streamComplete = false;
  String _mode = 'ok';
  String _scope = 'A';
  String _status = '等待开始';
  String? _digest;
  String? _savedName;
  int _epoch = 0;
  int _runNumber = 0;
  int _bytes = 0;
  int _chunks = 0;
  int _maxChunk = 0;
  int _scopeChecks = 0;
  double? _firstChunkMs;
  Map<String, Object?>? _lastRun;

  @override
  void initState() {
    super.initState();
    final uri = Uri.base;
    _originAllowed =
        uri.scheme == 'http' &&
        {'127.0.0.1', 'localhost'}.contains(uri.host) &&
        uri.port == 53881;
    _dio = Dio(
      BaseOptions(
        baseUrl: '${uri.origin}/api',
        connectTimeout: const Duration(seconds: 5),
        sendTimeout: const Duration(seconds: 5),
        headers: {'Content-Type': 'application/json'},
      ),
    );
    // The production streaming adapter remains the transport. This interceptor
    // fails closed before transport for every other host, method and endpoint.
    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (!_originAllowed ||
              options.uri.origin != uri.origin ||
              options.uri.path != '/api$_apiPath' ||
              options.uri.hasQuery ||
              options.method != 'POST' ||
              options.headers.keys.any(
                (key) =>
                    {'authorization', 'cookie'}.contains(key.toLowerCase()),
              )) {
            handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.cancel,
                error: 'Synthetic harness rejected non-fixture network request',
              ),
            );
            return;
          }
          handler.next(options);
        },
      ),
    );
    installStreamingDownloadAdapter(_dio);
    _api = ApiClient(_dio, streamingDownloads: true);
    unawaited(_checkCapability());
  }

  Future<void> _checkCapability() async {
    final supported = _originAllowed && await canSaveStream();
    if (mounted) setState(() => _canSave = supported);
  }

  void _recordInput(String value) {
    if (!_busy || _inputFrames.length >= 512) return;
    final at = _appClock.elapsedMicroseconds;
    final run = _runNumber;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted || run != _runNumber || _inputFrames.length >= 512) return;
      _inputFrames.add({
        'characters': value.length,
        'atMs': at / 1000,
        'nextFrameMs': (_appClock.elapsedMicroseconds - at) / 1000,
      });
    });
  }

  void _changeScope(String next, String reason) {
    setState(() {
      _scope = next;
      _epoch++;
      if (_busy) _status = '范围已变化，正在中止本次保存';
      if (_scopeEvents.length < 64) {
        _scopeEvents.add({
          'scope': next,
          'epoch': _epoch,
          'reason': reason,
          'atMs': _clock.elapsedMicroseconds / 1000,
        });
      }
    });
  }

  void _cancel() => _changeScope(_scope, 'cancel');

  void _aba() {
    _abaReturn?.cancel();
    final initial = _scope;
    _changeScope(initial == 'A' ? 'B' : 'A', 'ABA-leave');
    _abaReturn = Timer(const Duration(milliseconds: 250), () {
      if (mounted) _changeScope(initial, 'ABA-return');
    });
  }

  Future<void> _start() async {
    if (_busy || !_originAllowed || _canSave != true) return;
    _abaReturn?.cancel();
    final capturedEpoch = ++_epoch;
    final capturedMode = _mode;
    final inputStart = _input.text;
    final started = DateTime.now().toUtc().toIso8601String();
    final receiver = _DigestReceiver();
    final hasher = sha256.startChunkedConversion(receiver);
    var hasherClosed = false;
    bool current() => mounted && _epoch == capturedEpoch;

    setState(() {
      _busy = true;
      _runNumber++;
      _published = false;
      _streamComplete = false;
      _bytes = 0;
      _chunks = 0;
      _maxChunk = 0;
      _scopeChecks = 0;
      _firstChunkMs = null;
      _digest = null;
      _savedName = null;
      _lastRun = null;
      _inputFrames.clear();
      _scopeEvents.clear();
      _status = '接收并保存中';
    });
    _clock
      ..reset()
      ..start();
    _interaction.start();
    _refresh = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (mounted) setState(() {});
    });

    Stream<Uint8List> checkedChunks() async* {
      await for (final chunk in _api.downloadExportStream(
        _apiPath,
        body: {'fixtureMode': capturedMode},
        stillCurrent: current,
      )) {
        if (!current()) throw StateError('合成授权版本已退休');
        _firstChunkMs ??= _clock.elapsedMicroseconds / 1000;
        _bytes += chunk.length;
        _chunks++;
        if (chunk.length > _maxChunk) _maxChunk = chunk.length;
        hasher.add(chunk);
        yield chunk;
      }
      hasher.close();
      hasherClosed = true;
      _digest = receiver.digest?.toString();
      if (_bytes != _expectedBytes || _digest != _expectedSha256) {
        throw StateError('完整性校验失败，禁止发布文件');
      }
      _streamComplete = true;
    }

    Future<void> verifyScope() async {
      _scopeChecks++;
      if (!current()) throw StateError('合成授权版本已退休');
      if (_streamComplete &&
          (_bytes != _expectedBytes || _digest != _expectedSha256)) {
        throw StateError('完整性校验失败，禁止发布文件');
      }
    }

    Object? failure;
    try {
      _savedName = await saveStream(
        checkedChunks(),
        'b1-stream-128MiB-${started.replaceAll(RegExp(r'[:.]'), '-')}.bin',
        stillCurrent: current,
        verifyScope: verifyScope,
        maxBytes: _expectedBytes,
      );
      _published = true;
      _status = '校验通过，已交给浏览器保存';
    } catch (error) {
      failure = error;
      _status = current() ? '下载失败，未发布文件' : '已中止，未发布文件';
    } finally {
      if (!hasherClosed) {
        hasher.close();
        _digest = receiver.digest?.toString();
      }
      _clock.stop();
      _refresh?.cancel();
      if (mounted) _interaction.stop();
      _lastRun = {
        'fixture': 'B1-real-stream-128MiB',
        'build': _buildId,
        'startedUtc': started,
        'origin': Uri.base.origin,
        'mode': capturedMode,
        'expectedBytes': _expectedBytes,
        'expectedSha256': _expectedSha256,
        'bytes': _bytes,
        'chunks': _chunks,
        'maxChunkBytes': _maxChunk,
        'firstChunkMs': _firstChunkMs,
        'elapsedMs': _clock.elapsedMicroseconds / 1000,
        'sha256': _digest,
        'streamComplete': _streamComplete,
        'published': _published,
        'savedName': _savedName,
        'failure': failure?.toString(),
        'scopeChecks': _scopeChecks,
        'epochStart': capturedEpoch,
        'epochEnd': _epoch,
        'scopeEvents': List<Map<String, Object?>>.of(_scopeEvents),
        'inputStart': inputStart,
        'inputEnd': _input.text,
        'inputFrames': List<Map<String, Object?>>.of(_inputFrames),
        'interaction': _interaction.snapshot(),
        'publicationMeaning':
            'saveStream resolved; browser disk result requires verification',
      };
      if (_runs.length == 20) _runs.removeAt(0);
      _runs.add(_lastRun!);
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveEvidence() async {
    if (_busy || _runs.isEmpty) return;
    await postB1HarnessEvidence({
      'kind': 'b1-stream-download-synthetic-ui',
      'build': _buildId,
      'runs': _runs,
    });
    final bytes = Uint8List.fromList(
      utf8.encode(const JsonEncoder.withIndent('  ').convert({'runs': _runs})),
    );
    await saveBytes(bytes, 'b1-stream-browser-evidence.json');
  }

  Widget _metric(String label, String value) => SizedBox(
    width: 205,
    child: Padding(
      padding: const EdgeInsets.only(bottom: UtenSpacing.s16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: UtenSpacing.s4),
          Text(value, style: Theme.of(context).textTheme.titleLarge),
        ],
      ),
    ),
  );

  Widget _downloadPane() {
    final theme = Theme.of(context);
    final frames = _interaction.snapshot();
    final gaps = frames['frameGapsMs']! as Map<String, Object>;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('真实流式下载', style: theme.textTheme.headlineSmall),
        const SizedBox(height: UtenSpacing.s8),
        const Text('固定 128 MiB 合成文件；按块校验后才允许保存。'),
        const SizedBox(height: UtenSpacing.s24),
        DropdownButtonFormField<String>(
          initialValue: _mode,
          decoration: const InputDecoration(labelText: '网络情形'),
          items: _modes.entries
              .map(
                (entry) => DropdownMenuItem(
                  value: entry.key,
                  child: Text(entry.value),
                ),
              )
              .toList(),
          onChanged: _busy ? null : (value) => setState(() => _mode = value!),
        ),
        const SizedBox(height: UtenSpacing.s16),
        Wrap(
          spacing: UtenSpacing.s8,
          runSpacing: UtenSpacing.s8,
          children: [
            UtenButton(
              onPressed: !_busy && _originAllowed && _canSave == true
                  ? _start
                  : null,
              icon: Icons.download_outlined,
              child: const Text('开始下载'),
            ),
            UtenButton(
              type: UtenButtonType.secondary,
              onPressed: _busy ? _cancel : null,
              child: const Text('取消下载'),
            ),
            UtenButton(
              type: UtenButtonType.secondary,
              onPressed: _busy ? _aba : null,
              child: const Text('范围 A → B → A'),
            ),
          ],
        ),
        const SizedBox(height: UtenSpacing.s24),
        LinearProgressIndicator(value: _bytes / _expectedBytes),
        const SizedBox(height: UtenSpacing.s8),
        Text(_status, style: theme.textTheme.titleMedium),
        Text('当前范围 $_scope · 版本 $_epoch · 保存能力 ${_canSave ?? "检查中"}'),
        if (!_originAllowed)
          Text(
            '只允许 http://127.0.0.1:53881 或 localhost:53881',
            style: TextStyle(color: theme.colorScheme.error),
          ),
        const SizedBox(height: UtenSpacing.s24),
        Wrap(
          children: [
            _metric('收到字节', '$_bytes / $_expectedBytes'),
            _metric('首块到达', '${_firstChunkMs?.toStringAsFixed(1) ?? "—"} ms'),
            _metric(
              '耗时',
              '${(_clock.elapsedMilliseconds / 1000).toStringAsFixed(1)} s',
            ),
            _metric('最大接收块', '$_maxChunk bytes'),
            _metric(
              '帧间隔 p95 / p99',
              '${(gaps['p95']! as num).toStringAsFixed(1)} / ${(gaps['p99']! as num).toStringAsFixed(1)} ms',
            ),
            _metric('发布文件', _published ? '是，请核对磁盘文件' : '否'),
          ],
        ),
        SelectableText(
          'SHA-256\n${_digest ?? "接收结束后计算完成"}',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: UtenSpacing.s16),
        UtenButton(
          type: UtenButtonType.secondary,
          onPressed: !_busy && _runs.isNotEmpty ? _saveEvidence : null,
          child: const Text('保存本页验证记录'),
        ),
        if (_lastRun != null) ...[
          const SizedBox(height: UtenSpacing.s16),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('本次详细记录'),
            children: [
              SelectableText(
                const JsonEncoder.withIndent('  ').convert(_lastRun),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _inputPane() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('下载中继续操作', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: UtenSpacing.s8),
      const Text('持续输入并滚动下方列表，检查内容、焦点和帧响应。'),
      const SizedBox(height: UtenSpacing.s16),
      TextField(
        key: const ValueKey('stream-harness-input'),
        controller: _input,
        maxLength: 200,
        minLines: 2,
        maxLines: 3,
        onChanged: _recordInput,
        decoration: const InputDecoration(
          labelText: '输入验证文字',
          hintText: '下载期间保持可编辑',
        ),
      ),
      const SizedBox(height: UtenSpacing.s16),
      SizedBox(
        height: 360,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
            borderRadius: UtenRadius.tableAll,
          ),
          child: ListView.builder(
            key: const ValueKey('stream-harness-scroll'),
            itemExtent: 44,
            itemCount: 500,
            itemBuilder: (context, index) => ListTile(
              dense: true,
              title: Text('合成记录 ${index + 1}'),
              trailing: const Text('仅本地界面'),
            ),
          ),
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('B1 下载与输入验证')),
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(UtenSpacing.s24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1180),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '隔离合成环境 · $_buildId',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: UtenSpacing.s24),
              LayoutBuilder(
                builder: (context, constraints) => constraints.maxWidth >= 900
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(flex: 4, child: _inputPane()),
                          const SizedBox(width: UtenSpacing.s32),
                          Expanded(flex: 6, child: _downloadPane()),
                        ],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _downloadPane(),
                          const SizedBox(height: UtenSpacing.s32),
                          _inputPane(),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  @override
  void dispose() {
    _epoch++;
    _refresh?.cancel();
    _abaReturn?.cancel();
    _dio.close(force: true);
    _input.dispose();
    _interaction.dispose();
    super.dispose();
  }
}
