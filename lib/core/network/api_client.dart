// API 客户端：基于 Dio，注入 AuthInterceptor；统一把 DioException 转成 ApiException。
// 基址由 api_base_url.dart 统一校验：Web release 默认同源 /api，
// 移动/桌面 release 必须显式传 HTTPS，避免误请求用户设备 localhost。
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../audit/device_audit_store.dart';
import '../diagnostics/diagnostic_log.dart';
import '../security/secure_storage.dart';
import 'server_config.dart';
import 'company_tls.dart';
import 'connection_recovery.dart';
import 'data_write_revision.dart';
import 'api_error.dart';
import 'business_precision_coordinator.dart';
import 'business_submission_headers.dart';
import 'interceptors/business_precision_interceptor.dart';
import 'api_exception.dart';
import 'api_mutation_reload_safety.dart';
import 'authenticated_request_scope.dart';
import 'native_facet_routes.dart';
import 'request_reload_semantics.dart';
import 'interceptors/auth_interceptor.dart';
import 'interceptors/automatic_request_interceptor.dart';
import 'interceptors/device_audit_interceptor.dart';
import 'interceptors/safe_request_retry_interceptor.dart';
import 'interceptors/step_up_interceptor.dart';
import 'interceptors/write_deadline_interceptor.dart';
import 'file_upload_contract.dart';
import 'network_policy.dart';
import 'responsive_json_decoder.dart';
import 'responsive_json_transformer.dart';
import 'streaming_download_adapter.dart';
import 'streaming_download_contract.dart';
import 'summary_stream_contract.dart';
import 'read_scope_revision.dart';
import 'interceptors/read_scope_revision_interceptor.dart';
import 'interceptors/page_read_priority_interceptor.dart';
import '../diagnostics/diagnostic_request_interceptor.dart';
import '../../shared/paging/paged_read_intent.dart';
import '../../shared/paging/complete_summary_stream.dart';

const _clientPackageSendTimeout = Duration(minutes: 30);
const _clientPackageReceiveTimeout = Duration(minutes: 5);

class ApiClient {
  ApiClient(
    this._dio, {
    this.streamingDownloads = false,
    this.summaryStreamChunkIdleTimeout = apiSummaryStreamChunkIdleTimeout,
    ApiMutationReloadSafety? reloadSafety,
    BusinessPrecisionCoordinator? precisionCoordinator,
    Object? Function(RequestOptions)? precisionIdentity,
    Future<bool> Function(RequestOptions)? precisionIsCurrent,
  }) : _reloadSafety = reloadSafety ?? apiMutationReloadSafety {
    if (!_dio.interceptors.any(
      (item) => item is DiagnosticRequestInterceptor,
    )) {
      // Observe each attempt before authentication consumes a recoverable 401.
      // A replay has its own begin/end pair and cannot overwrite a stuck clock.
      _dio.interceptors.insert(0, DiagnosticRequestInterceptor());
    }
    if (!_dio.interceptors.any(
      (interceptor) => interceptor is BusinessPrecisionInterceptor,
    )) {
      _dio.interceptors.add(
        BusinessPrecisionInterceptor(
          _dio,
          coordinator: precisionCoordinator,
          identity: precisionIdentity,
          isCurrent: precisionIsCurrent,
        ),
      );
    }
  }

  final Dio _dio;
  final bool streamingDownloads;

  /// 完整列表 NDJSON 流的帧间空闲上限；测试注入短值钉住超时行为。
  final Duration summaryStreamChunkIdleTimeout;
  final ApiMutationReloadSafety _reloadSafety;

  static const _retiredReadReason = 'Uten paged read retired';

  Future<T> _read<T>(
    Future<T> Function(CancelToken?) action, {
    CancelToken? cancelToken,
  }) => _reloadSafety.trackRead(() async {
    final pagedCurrent = PagedReadIntent.currentRead;
    final readActivity = PagedReadIntent.currentActivity;
    final transportActivity = PagedReadIntent.currentTransportActivity;
    final operation = AuthenticatedRequestScope.current;
    if (pagedCurrent == null && readActivity == null && operation == null) {
      return action(cancelToken);
    }
    bool pagedAlive() {
      try {
        return pagedCurrent?.call() ?? true;
      } catch (_) {
        return false;
      }
    }

    bool activityAlive(bool Function()? activity) {
      try {
        return activity?.call() ?? true;
      } catch (_) {
        return false;
      }
    }

    bool current() =>
        pagedAlive() &&
        activityAlive(transportActivity) &&
        (operation?.isCurrent ?? true);
    void ensureCurrent() {
      operation?.checkCurrent();
      if (!pagedAlive()) {
        throw ApiException('REQUEST_STALE', '搜索条件或读取页面已变化');
      }
    }

    ensureCurrent();
    if (!activityAlive(transportActivity)) {
      throw ApiException('REQUEST_STALE', '读取页面已离开');
    }
    final cancellation = cancelToken ?? CancelToken();
    final retirement = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (!current()) cancellation.cancel(_retiredReadReason);
    });
    try {
      final result = await action(cancellation);
      ensureCurrent();
      if (!activityAlive(readActivity)) {
        throw ApiException('REQUEST_STALE', '读取页面已离开');
      }
      return result;
    } catch (_) {
      // Logical ownership decides whether an actually received401/403 still
      // belongs to this request. Visibility only cancels transport/publication;
      // it must not replace a current access rejection with REQUEST_STALE.
      ensureCurrent();
      rethrow;
    } finally {
      retirement.cancel();
    }
  });

  Future<T> _trackPost<T>(
    String path,
    Future<T> Function(CancelToken?) action,
  ) => isReadOnlyPost(path)
      ? _read(action)
      : _reloadSafety.track(
          () => action(null),
          retainUncertainty:
              !isNoticePresentationReceipt(path) && !isEphemeralSignIn(path),
        );

  /// Read one already-authorized export artifact, without accumulating its body.
  Stream<Uint8List> downloadExportStream(
    String path, {
    Object? body,
    bool Function()? stillCurrent,
  }) => _reloadSafety.trackReadStream(
    () => _downloadExportStream(path, body: body, stillCurrent: stillCurrent),
  );

  Stream<Uint8List> _downloadExportStream(
    String path, {
    Object? body,
    bool Function()? stillCurrent,
  }) async* {
    if (!RegExp(
      r'^/report-export-jobs/[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}/download$',
    ).hasMatch(path)) {
      throw const FormatException('Invalid export artifact path');
    }
    final cancellation = CancelToken();
    final guard = stillCurrent == null
        ? null
        : Timer.periodic(const Duration(milliseconds: 200), (_) {
            if (!stillCurrent()) cancellation.cancel('Export identity retired');
          });
    try {
      final response = await _dio.post<dynamic>(
        path,
        data: body,
        cancelToken: cancellation,
        options: Options(
          responseType: ResponseType.stream,
          followRedirects: false,
          receiveTimeout: apiDownloadReceiveTimeout,
          extra: const {
            safeRequestRetryDisabledKey: true,
            streamingDownloadRequestKey: true,
          },
        ),
      );
      final value = response.data;
      if (value is! ResponseBody) {
        throw const FormatException('Empty export artifact');
      }
      final declared = int.tryParse(
        value.headers[Headers.contentLengthHeader]?.first ?? '',
      );
      final encoded = value.headers['content-encoding']?.first;
      var bytes = 0;
      await for (final chunk in value.stream) {
        bytes += chunk.length;
        if (bytes > maxExportDownloadBytes) throw StateError('导出文件超过本机保存上限');
        yield chunk;
      }
      if (declared != null && encoded == null && bytes != declared) {
        throw const FormatException('导出下载不完整，请重试原任务');
      }
    } on DioException catch (error) {
      throw _convert(error);
    } finally {
      guard?.cancel();
      cancellation.cancel('Export reader closed');
    }
  }

  Future<AuthenticatedRequestScope> captureRequestScope({
    required bool Function() isCurrent,
  }) {
    final auth = _dio.interceptors.whereType<AuthInterceptor>().firstOrNull;
    return AuthenticatedRequestScope.capture(
      baseUrl: _dio.options.baseUrl,
      storage: auth?.storage,
      isCurrent: isCurrent,
    );
  }

  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) => _read((cancellation) async {
    try {
      final r = await _dio.get<dynamic>(
        path,
        queryParameters: query,
        cancelToken: cancellation,
      );
      return _objectResponse(r);
    } on DioException catch (e) {
      throw _convert(e);
    }
  });

  /// One cancellable session watch. The caller owns reconnect/backoff; it must
  /// not occupy a page-read slot or extend the session's idle deadline.
  Future<Map<String, dynamic>> watchSession({
    required CancelToken cancelToken,
    bool fallbackProbe = false,
  }) async {
    try {
      final response = await _dio.get<dynamic>(
        fallbackProbe ? '/auth/me' : '/auth/session/watch',
        cancelToken: cancelToken,
        options: Options(
          receiveTimeout: fallbackProbe
              ? const Duration(seconds: 10)
              : const Duration(seconds: 35),
          extra: const {
            safeRequestRetryDisabledKey: true,
            AutomaticRequestInterceptor.forceAutomaticKey: true,
          },
        ),
      );
      return _objectResponse(response);
    } on DioException catch (error) {
      throw _convert(error);
    }
  }

  /// 用于后端直接返回 JSON 数组的接口（如部门树）。
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) => _read((cancellation) async {
    try {
      final r = await _dio.get<dynamic>(
        path,
        queryParameters: query,
        cancelToken: cancellation,
      );
      return _asMapList(r.data);
    } on DioException catch (e) {
      throw _convert(e);
    }
  });

  /// Optional enrichment read with one bounded attempt and real cancellation.
  ///
  /// Use this for data that must never keep a page or dialog alive through the
  /// normal safe-read retry window. Business-critical reads continue to use
  /// [getList] and its standard retry policy.
  Future<List<Map<String, dynamic>>> getListOnce(
    String path, {
    Map<String, dynamic>? query,
    required Duration receiveTimeout,
    CancelToken? cancelToken,
  }) => _read((cancellation) async {
    try {
      final r = await _dio.get<dynamic>(
        path,
        queryParameters: query,
        cancelToken: cancellation,
        options: Options(
          receiveTimeout: receiveTimeout,
          extra: const {safeRequestRetryDisabledKey: true},
        ),
      );
      return _asMapList(r.data);
    } on DioException catch (e) {
      throw _convert(e);
    }
  }, cancelToken: cancelToken);

  /// Reads endpoints that return a JSON string array, such as UUID/code lists.
  ///
  /// This stays separate from the object-array contract in [getList] so a
  /// `List<String>` cannot be silently converted or unsafely cast by callers.
  Future<List<String>> getStringList(
    String path, {
    Map<String, dynamic>? query,
  }) => _read((cancellation) async {
    try {
      final r = await _dio.get<dynamic>(
        path,
        queryParameters: query,
        cancelToken: cancellation,
      );
      final data = r.data;
      final raw = data is List
          ? data
          : data is Map && data['data'] is List
          ? data['data'] as List<dynamic>
          : null;
      if (raw == null) {
        throw const FormatException('Response is not a string array');
      }
      return raw
          .map((item) {
            if (item is! String) {
              throw const FormatException(
                'String array contains a non-string item',
              );
            }
            return item;
          })
          .toList(growable: false);
    } on DioException catch (e) {
      throw _convert(e);
    }
  });

  /// Typed array counterpart of the two JSON-body goods search reads.
  /// A strict allowlist keeps commands out of read cancellation/reload policy.
  Future<List<String>> postStringList(String path, {required Object body}) =>
      _read((cancellation) async {
        if (!isGoodsSearchRead(path)) {
          throw ArgumentError.value(
            path,
            'path',
            'Not a string-array search read',
          );
        }
        try {
          final response = await _dio.post<dynamic>(
            path,
            data: body,
            cancelToken: cancellation,
          );
          final data = response.data;
          final raw = data is List
              ? data
              : data is Map && data['data'] is List
              ? data['data'] as List<dynamic>
              : null;
          if (raw == null || raw.any((item) => item is! String)) {
            throw const FormatException('Response is not a string array');
          }
          return raw.cast<String>().toList(growable: false);
        } on DioException catch (error) {
          throw _convert(error);
        }
      });

  /// Read-only POST computation (a preview that carries a request body) that
  /// the caller can abandon: [cancelToken] aborts the transport when the page
  /// goes away. Never use it for commands; a cancelled command may still have
  /// committed on the server.
  Future<Map<String, dynamic>> postCancellable(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    CancelToken? cancelToken,
  }) => _read((cancellation) async {
    try {
      final r = await _dio.post<dynamic>(
        path,
        data: body,
        queryParameters: query,
        cancelToken: cancellation,
      );
      return _objectResponse(r);
    } on DioException catch (e) {
      throw _convert(e);
    }
  }, cancelToken: cancelToken);

  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) => _trackPost(path, (cancellation) async {
    try {
      final r = await _dio.post<dynamic>(
        path,
        data: body,
        queryParameters: query,
        cancelToken: cancellation,
        options: headers == null ? null : Options(headers: headers),
      );
      return _objectResponse(r);
    } on DioException catch (e) {
      throw _convert(e);
    }
  });

  /// One authenticated summary read, owned until its final frame and EOF.
  /// The consumer retains the shared complete-result validator; exposing the
  /// response stream outside this read would prematurely release cancellation
  /// and application-update guards at response headers.
  Future<T> postSummaryStream<T>(
    String path, {
    required Object body,
    required Future<T> Function(Stream<Map<String, dynamic>>) consume,
  }) => _read((readCancellation) async {
    if (!isSummaryStreamPath(path)) {
      throw const FormatException('Invalid complete summary path');
    }
    final cancellation = readCancellation ?? CancelToken();
    final clock = Stopwatch()..start();
    var completed = false;
    RequestOptions? streamedRequest;
    final transformer = _dio.transformer;
    final decoder = transformer is ResponsiveJsonTransformer
        ? transformer.decoder
        : ResponsiveJsonDecoder();
    try {
      final response = await _dio.post<dynamic>(
        path,
        data: body,
        queryParameters: const {'complete': true},
        cancelToken: cancellation,
        options: Options(
          responseType: ResponseType.stream,
          followRedirects: false,
          // 帧间空闲预算不能放 receiveTimeout——dio 的 handleResponseStream 会在
          // 字节流上武装秒表+计时器，fake-async 测试环境里即时流会被卡死（丢
          // done 事件），而继承的通用 45s 分块守卫又会误杀合法的首帧后长静默
          // （服务端内部扫描最长接近 60s 完整读取预算）。这里显式置零关闭 dio
          // 层分块守卫，预算改由 CompleteSummaryStream 在帧的 moveNext 上用
          // Future.timeout 独立裁决（见 complete_summary_stream.dart）。
          receiveTimeout: Duration.zero,
          headers: const {'Accept': summaryStreamContentType},
          extra: const {
            summaryStreamRequestKey: true,
            safeRequestRetryDisabledKey: true,
          },
        ),
      );
      final stream = response.data;
      streamedRequest = response.requestOptions;
      final contentType = response.headers
          .value(Headers.contentTypeHeader)
          ?.split(';')
          .first
          .trim()
          .toLowerCase();
      if (stream is! ResponseBody || contentType != summaryStreamContentType) {
        throw ApiException(
          'INCOMPLETE_READ_PROTOCOL',
          '服务端尚未提供完整列表传输，请更新服务端后重试',
        );
      }
      // 字节流保持原始直通：Stream.timeout/控制器包装会让 utf8/LineSplitter
      // 变换链在 fake-async 测试里丢 done 事件。帧间空闲预算由
      // CompleteSummaryStream 在帧的 moveNext 上用 Future.timeout 裁决，超时
      // 以 TimeoutException 冒泡，下方统一转成接收超时并取消请求。
      final bytes = stream.stream;
      final headerScope = response.headers.value('X-Uten-Read-Scope-Version');
      final result = await consume(
        decodeSummaryFrames(
          bytes,
          isCurrent: () => !cancellation.isCancelled,
          decode: (frame) => decoder.decodeBytes(
            frame,
            isCurrent: () => !cancellation.isCancelled,
          ),
        ).map((frame) {
          final value = frame['type'] == 'page' ? frame['value'] : frame;
          if (headerScope != null &&
              (frame['type'] == 'page' || frame['type'] == 'complete') &&
              value is Map &&
              value['readScopeVersion'] != headerScope) {
            throw ApiException(
              'READ_SCOPE_CHANGED',
              '数据访问范围已变化，请重新读取',
              httpStatus: 403,
            );
          }
          return frame;
        }),
      );
      completed = true;
      return result;
    } on TimeoutException {
      // 帧间空闲超预算：等价于接收超时，按同一合同冒泡并中止底层请求。
      cancellation.cancel('Summary stream receive timeout');
      throw _convert(
        DioException.receiveTimeout(
          timeout: summaryStreamChunkIdleTimeout,
          requestOptions:
              streamedRequest ??
              RequestOptions(
                path: path,
                method: 'POST',
                baseUrl: _dio.options.baseUrl,
              ),
        ),
      );
    } on DioException catch (error) {
      throw _convert(error);
    } on ApiException catch (error) {
      if (error.code == 'READ_SCOPE_CHANGED' && streamedRequest != null) {
        for (final observer
            in _dio.interceptors.whereType<ReadScopeRevisionInterceptor>()) {
          await observer.observeScopeRejection(streamedRequest);
        }
      }
      rethrow;
    } finally {
      AppDiagnostics.record(
        completed ? 'summary.read.complete' : 'summary.read.failed',
        level: completed ? 'info' : 'warning',
        fields: {
          'method': 'POST',
          'path': path,
          'durationMs': clock.elapsedMilliseconds,
        },
      );
      cancellation.cancel('Complete summary reader closed');
      if (transformer is! ResponsiveJsonTransformer) decoder.dispose();
    }
  });

  /// Exact read-only candidate endpoints retain their typed legacy form filters.
  Future<Map<String, dynamic>> postForm(
    String path, {
    required Map<String, dynamic> body,
  }) => _read((cancellation) async {
    if (!isNativeFacetPath(path)) {
      throw ApiException('VALIDATION_FAILED', '只读候选接口无效');
    }
    final encoded = jsonEncode(body);
    if (utf8.encode(encoded).length > 65536) {
      throw ApiException('VALIDATION_FAILED', '候选筛选条件过大');
    }
    final frozen = jsonDecode(encoded) as Map<String, dynamic>;
    try {
      final response = await _dio.post<dynamic>(
        path,
        data: frozen,
        cancelToken: cancellation,
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          followRedirects: false,
        ),
      );
      return _objectResponse(response);
    } on DioException catch (error) {
      throw _convert(error);
    }
  });

  /// 已知的长事务端点（如人事对账）用：同 [post]，但用 [receiveTimeout] 覆盖
  /// network_policy.dart 的全局 45s 接收超时。单独成方法而非给 [post] 加可选参数，
  /// 是为了让既有覆写 [post] 的测试/API 子类保持源码兼容（同 [putWithQuery]）。
  /// 非幂等写请求，不走安全重试拦截器（POST 本就不重试）。
  Future<Map<String, dynamic>> postLongRunning(
    String path, {
    Object? body,
    required Duration receiveTimeout,
  }) => _reloadSafety.track(() async {
    try {
      final r = await _dio.post<dynamic>(
        path,
        data: body,
        options: Options(receiveTimeout: receiveTimeout),
      );
      return _objectResponse(r);
    } on DioException catch (e) {
      throw _convert(e);
    }
  });

  /// POST 且响应为 JSON 数组（如批量生成结果列表）。
  Future<List<Map<String, dynamic>>> postList(String path, {Object? body}) =>
      _trackPost(path, (cancellation) async {
        try {
          final r = await _dio.post<dynamic>(
            path,
            data: body,
            cancelToken: cancellation,
          );
          final data = r.data;
          if (data is List) {
            return data.cast<Map<String, dynamic>>();
          }
          if (data is Map && data['data'] is List) {
            return (data['data'] as List).cast<Map<String, dynamic>>();
          }
          return const [];
        } on DioException catch (e) {
          throw _convert(e);
        }
      });

  /// PUT 且响应为 JSON 数组（整体替换后回读列表）。
  Future<List<Map<String, dynamic>>> putList(String path, {Object? body}) =>
      _reloadSafety.track(() async {
        try {
          final r = await _dio.put<dynamic>(path, data: body);
          final data = r.data;
          if (data is List) return data.cast<Map<String, dynamic>>();
          if (data is Map && data['data'] is List) {
            return (data['data'] as List).cast<Map<String, dynamic>>();
          }
          return const [];
        } on DioException catch (e) {
          throw _convert(e);
        }
      });

  Future<Map<String, dynamic>> put(String path, {Object? body}) =>
      _reloadSafety.track(() async {
        try {
          final r = await _dio.put<dynamic>(path, data: body);
          return _objectResponse(r);
        } on DioException catch (e) {
          throw _convert(e);
        }
      });

  /// PUT with explicit query parameters. Kept separate so existing test/API
  /// subclasses overriding [put] remain source-compatible.
  Future<Map<String, dynamic>> putWithQuery(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
  }) => _reloadSafety.track(() async {
    try {
      final r = await _dio.put<dynamic>(
        path,
        data: body,
        queryParameters: query,
      );
      return _objectResponse(r);
    } on DioException catch (e) {
      throw _convert(e);
    }
  });

  /// 上传原始字节（附件直传本地后端 raw 端点；OSS 由调用方用独立 Dio 直传预签名 URL）。
  Future<void> putBytes(
    String path,
    Uint8List bytes,
    String contentType, {
    Map<String, String>? headers,
  }) => _reloadSafety.track(() async {
    try {
      await _dio.put<dynamic>(
        path,
        data: bytes,
        options: Options(headers: {'Content-Type': contentType, ...?headers}),
      );
    } on DioException catch (e) {
      throw _convert(e);
    }
  });

  /// 上传原始字节(POST, octet-stream)并返回 JSON——货品导入 detect/commit、
  /// 公共 AI 作业提交(ADR-133)用。
  ///
  /// [headers] 追加请求头(如 AI 作业的 X-Uten-File-Name，值须调用方先编码为 ASCII)；
  /// [sendTimeout] 覆盖全局 30s 上传时限(IO 端是整段上传的总时长，大文件慢网要放宽)；
  /// [receiveTimeout] 覆盖全局 45s 接收时限。均为可选，既有调用方不受影响。
  /// Web显式文件使用有效send+receive的有限整体预算；IO保留原分阶段值。
  Future<Map<String, dynamic>> postBytes(
    String path,
    Uint8List bytes, {
    Map<String, dynamic>? query,
    Map<String, String>? headers,
    Duration? sendTimeout,
    Duration? receiveTimeout,
  }) => _reloadSafety.track(() async {
    try {
      final r = await _dio.post<dynamic>(
        path,
        data: bytes,
        queryParameters: query,
        options: Options(
          contentType: 'application/octet-stream',
          responseType: ResponseType.json,
          headers: headers,
          sendTimeout: sendTimeout,
          receiveTimeout: receiveTimeout,
          extra: {
            safeRequestRetryDisabledKey: true,
            fileUploadOverallTimeoutKey: fileUploadOverallTimeout(
              sendTimeout: sendTimeout ?? _dio.options.sendTimeout,
              receiveTimeout: receiveTimeout ?? _dio.options.receiveTimeout,
            ),
          },
        ),
      );
      return _objectResponse(r);
    } on DioException catch (e) {
      throw _convert(e);
    }
  });

  /// multipart 文件上传并返回 JSON（报销发票 OCR 识别等单文件直传后端端点）。
  /// 与原始文件/客户端包共用有限Web整体上传合同，不扩大普通JSON请求预算。
  Future<Map<String, dynamic>> postMultipartFile(
    String path,
    Uint8List bytes,
    String filename,
    String contentType, {
    Duration? receiveTimeout,
    Map<String, Object?> jsonParts = const {},
    Map<String, dynamic>? headers,
  }) => _reloadSafety.track(() async {
    try {
      if (jsonParts.containsKey('file') ||
          jsonParts.keys.any((key) => key.trim().isEmpty)) {
        throw ArgumentError(
          'JSON multipart fields must have distinct non-file names',
        );
      }
      final form = FormData.fromMap({
        for (final entry in jsonParts.entries)
          entry.key: MultipartFile.fromString(
            jsonEncode(entry.value),
            contentType: DioMediaType.parse('application/json'),
          ),
        'file': MultipartFile.fromBytes(
          bytes,
          filename: filename,
          contentType: DioMediaType.parse(contentType),
        ),
      });
      final r = await _dio.post<dynamic>(
        path,
        data: form,
        options: Options(
          responseType: ResponseType.json,
          headers: businessSubmissionHeaders(headers),
          receiveTimeout: receiveTimeout,
          extra: {
            safeRequestRetryDisabledKey: true,
            fileUploadOverallTimeoutKey: fileUploadOverallTimeout(
              sendTimeout: _dio.options.sendTimeout,
              receiveTimeout: receiveTimeout ?? _dio.options.receiveTimeout,
            ),
          },
        ),
      );
      return _objectResponse(r);
    } on DioException catch (e) {
      throw _convert(e);
    }
  });

  /// 下载原始字节（附件本地后端 raw 端点流式下载）。
  ///
  /// [cancelToken] 让进度弹窗的「取消」真正停下传输；[onReceiveProgress] 汇报
  /// 已收/总字节（服务端未给 Content-Length 时 total 为 -1）。
  Future<Uint8List> getBytes(
    String path, {
    CancelToken? cancelToken,
    ProgressCallback? onReceiveProgress,
  }) => _reloadSafety.trackRead(() async {
    try {
      final r = await _dio.get<List<int>>(
        path,
        cancelToken: cancelToken,
        onReceiveProgress: onReceiveProgress,
        options: Options(responseType: ResponseType.bytes),
      );
      return Uint8List.fromList(r.data ?? const []);
    } on DioException catch (e) {
      throw _convert(e);
    }
  });

  /// 以 POST 下载原始字节。文档字节端点读取时会落安检/审计记录，属于
  /// 服务端 CSRF 要求下的写方法端点；语义仍是读取，沿用读安全语义。
  Future<Uint8List> postForBytes(
    String path, {
    CancelToken? cancelToken,
    ProgressCallback? onReceiveProgress,
  }) => _reloadSafety.trackRead(() async {
    try {
      final r = await _dio.post<List<int>>(
        path,
        cancelToken: cancelToken,
        onReceiveProgress: onReceiveProgress,
        options: Options(responseType: ResponseType.bytes),
      );
      return Uint8List.fromList(r.data ?? const []);
    } on DioException catch (e) {
      throw _convert(e);
    }
  });

  /// Client packages stay in a stream instead of retaining a desktop bundle in
  /// memory. Only API-relative paths are accepted; credentials never follow an
  /// update manifest to a different origin.
  Future<Stream<Uint8List>> getPackageStream(
    String path, {
    required CancelToken cancelToken,
  }) async {
    final packageUri = Uri.tryParse(path);
    final rawPath = path.split('?').first;
    final queryStart = path.indexOf('?');
    final rawQuery = queryStart < 0 ? null : path.substring(queryStart + 1);
    if (packageUri == null ||
        path.codeUnits.any((unit) => unit <= 0x20 || unit > 0x7e) ||
        packageUri.hasScheme ||
        packageUri.hasAuthority ||
        packageUri.hasFragment ||
        packageUri.path != rawPath ||
        !RegExp(
          r'^/client-updates/[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}/download$',
        ).hasMatch(rawPath) ||
        (packageUri.hasQuery &&
            rawQuery != 'runtimeFamily=flutter' &&
            rawQuery != 'runtimeFamily=wpf_legacy')) {
      throw const FormatException('Invalid client package path');
    }
    final lease = _reloadSafety.beginRead();
    try {
      final response = await _dio.get<ResponseBody>(
        packageUri.path,
        queryParameters: packageUri.hasQuery
            ? {'runtimeFamily': packageUri.queryParameters['runtimeFamily']!}
            : null,
        cancelToken: cancelToken,
        options: Options(
          responseType: ResponseType.stream,
          followRedirects: false,
          receiveTimeout: const Duration(minutes: 15),
          extra: const {
            safeRequestRetryDisabledKey: true,
            streamingDownloadRequestKey: true,
          },
        ),
      );
      if (response.data == null) throw const FormatException('Empty package');
      return lease.hold(
        response.data!.stream,
        cancelled: cancelToken.whenCancel,
      );
    } on DioException catch (e) {
      lease.complete();
      throw _convert(e);
    } catch (_) {
      lease.complete();
      rethrow;
    }
  }

  Future<void> uploadClientPackage(
    String path,
    Uint8List bytes, {
    required void Function(int, int) onProgress,
  }) => _reloadSafety.track(() async {
    try {
      await _dio.put<dynamic>(
        path,
        data: bytes,
        onSendProgress: onProgress,
        options: Options(
          contentType: 'application/octet-stream',
          headers: {'Content-Length': bytes.length},
          sendTimeout: _clientPackageSendTimeout,
          receiveTimeout: _clientPackageReceiveTimeout,
          extra: {
            safeRequestRetryDisabledKey: true,
            fileUploadOverallTimeoutKey: fileUploadOverallTimeout(
              sendTimeout: _clientPackageSendTimeout,
              receiveTimeout: _clientPackageReceiveTimeout,
            ),
          },
        ),
      );
    } on DioException catch (e) {
      throw _convert(e);
    }
  });

  Future<Map<String, dynamic>> patch(String path, {Object? body}) =>
      _reloadSafety.track(() async {
        try {
          final r = await _dio.patch<dynamic>(path, data: body);
          return _objectResponse(r);
        } on DioException catch (e) {
          throw _convert(e);
        }
      });

  /// 后端 200 空体（void 接口）时 Dio 给的是 '' 而不是 null，
  /// 直接 `as Map` 会抛 TypeError —— 保存其实成功了却提示失败。
  /// 只对真正的 JSON 对象做转换，其余（null/空串/数组）一律视为空 Map。
  static Map<String, dynamic> _asMap(dynamic data) {
    if (data is Map<String, dynamic>) return data;
    return <String, dynamic>{};
  }

  static Map<String, dynamic> _objectResponse(Response<dynamic> response) {
    final data = _asMap(response.data);
    final version = response.headers.value('X-Uten-Read-Scope-Version');
    if (version == null || version.isEmpty || version.length > 256) return data;
    if (data['readScopeVersion'] != null &&
        data['readScopeVersion'] != version) {
      throw ApiException(
        'READ_SCOPE_CHANGED',
        '数据访问范围已变化，请重新打开页面后核对',
        httpStatus: 403,
      );
    }
    return {...data, 'readScopeVersion': version};
  }

  /// [query] 作为查询参数发送(例如乐观锁版本号 `?version=`)。
  Future<void> delete(String path, {Map<String, dynamic>? query}) =>
      _deleteResponse(path, query: query).then((_) {});

  /// A reviewed DELETE command has an immutable body and a result receipt.
  /// Legacy void deletes keep their existing wrapper and the same transport.
  Future<Map<String, dynamic>> deleteObject(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
  }) async =>
      _objectResponse(await _deleteResponse(path, body: body, query: query));

  Future<Response<dynamic>> _deleteResponse(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
  }) => _reloadSafety.track(() async {
    try {
      return await _dio.delete<dynamic>(
        path,
        data: body,
        queryParameters: query,
      );
    } on DioException catch (e) {
      throw _convert(e);
    }
  });

  /// 下载二进制（Excel 导出用）：POST [path]，可选密码走 [body]，过滤/排序走 [query]，
  /// 以 bytes 接收。AuthInterceptor 自动管 401 刷新。错误体（bytes）尝试解 JSON 取业务消息。
  ///
  /// [headers] 供同步导出带上进度操作号（X-Uten-Export-Operation），服务端据此登记
  /// 可轮询的生成进度。
  Future<Uint8List> downloadBytes(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    CancelToken? cancelToken,
    ProgressCallback? onReceiveProgress,
    Map<String, String>? headers,
  }) => _reloadSafety.trackRead(() async {
    try {
      final r = await _dio.post<List<int>>(
        path,
        data: body,
        queryParameters: query,
        cancelToken: cancelToken,
        onReceiveProgress: onReceiveProgress,
        options: Options(
          responseType: ResponseType.bytes,
          receiveTimeout: apiDownloadReceiveTimeout,
          headers: headers,
        ),
      );
      return Uint8List.fromList(r.data ?? const []);
    } on DioException catch (e) {
      throw _convertBytes(e);
    }
  });

  /// bytes 响应的错误转换：业务错误体可能是 UTF-8 JSON 字节，尝试解出 ApiError 取消息。
  ApiException _convertBytes(DioException e) {
    if (e.error is ApiException) {
      return e.error! as ApiException;
    }
    final connectionFailure = _connectionException(e);
    if (connectionFailure != null) return connectionFailure;
    final data = e.response?.data;
    ApiError? body;
    if (data is List<int>) {
      try {
        final decoded = jsonDecode(utf8.decode(data));
        if (decoded is Map<String, dynamic>) body = ApiError.fromJson(decoded);
      } catch (_) {}
    } else if (data is Map<String, dynamic>) {
      body = ApiError.fromJson(data);
    }
    return ApiExceptionFactory.fromDioStatusCode(e.response?.statusCode, body);
  }

  /// Current transport target, including runtime server selection.
  String get baseUrl => _dio.options.baseUrl;

  ApiException _convert(DioException e) {
    if (e.error is ApiException) {
      return e.error! as ApiException;
    }
    if (e.type == DioExceptionType.cancel && e.error == _retiredReadReason) {
      return ApiException('REQUEST_STALE', '搜索条件或读取页面已变化');
    }
    final certificateFailure = companyTlsFailure(e);
    if (certificateFailure != null) return certificateFailure;
    final connectionFailure = _connectionException(e);
    if (connectionFailure != null) return connectionFailure;
    ApiError? body;
    final data = e.response?.data;
    if (data is Map<String, dynamic>) {
      body = ApiError.fromJson(data);
    }
    return ApiExceptionFactory.fromDioStatusCode(e.response?.statusCode, body);
  }

  ApiException? _connectionException(DioException e) {
    final type = e.type;
    if (type == DioExceptionType.connectionTimeout ||
        type == DioExceptionType.sendTimeout ||
        type == DioExceptionType.receiveTimeout) {
      return NetworkTimeoutException();
    }
    if (type == DioExceptionType.connectionError ||
        type == DioExceptionType.unknown && e.response == null) {
      return NetworkException();
    }
    return null;
  }

  static List<Map<String, dynamic>> _asMapList(dynamic data) {
    if (data is List) {
      return data.cast<Map<String, dynamic>>();
    }
    if (data is Map && data['data'] is List) {
      return (data['data'] as List).cast<Map<String, dynamic>>();
    }
    return const [];
  }
}

/// 全局 API 客户端 Provider。
///
/// Dio 实例在会话内保持稳定(ADR-108): 断网恢复不再重建它——此前约 93 个 watch 本
/// provider 的仓库/名称服务会随之整体重建、字典缓存全丢、全站重拉。恢复后只让当前
/// 可见页重拉一次(见 SessionRehydrateGate 对 pageRefreshRequestProvider 的推进)。
final apiClientProvider = Provider<ApiClient>((ref) {
  final recovery = ref.read(connectionRecoveryProvider.notifier);
  final storage = ref.watch(secureStorageProvider);
  final deviceAuditStore = ref.watch(deviceAuditStoreProvider);
  final baseUrl = ref.watch(apiBaseUrlProvider);
  final realmPolicy = ref.watch(authBackendRealmPolicyProvider);
  final jsonDecoder = ResponsiveJsonDecoder();
  ref.onDispose(jsonDecoder.dispose);
  late final AuthInterceptor authInterceptor;
  final readScope = ReadScopeRevisionInterceptor(
    currentRevision: () =>
        ref.mounted ? ref.read(readScopeRevisionProvider) : -1,
    retire: () {
      if (ref.mounted) ref.read(readScopeRevisionProvider.notifier).state++;
    },
    identity: AuthInterceptor.retainedIdentity,
    isCurrent: (options) async =>
        ref.mounted &&
        ref.read(apiBaseUrlProvider) == baseUrl &&
        await authInterceptor.requestBelongsToCurrentIdentity(options),
  );
  Dio auditedDioFactory() {
    final client = createCompanyDio(buildApiBaseOptions(baseUrl));
    installStreamingDownloadAdapter(client);
    client.transformer = ResponsiveJsonTransformer(jsonDecoder);
    client.interceptors.add(DeviceAuditInterceptor(deviceAuditStore));
    client.interceptors.add(DiagnosticRequestInterceptor());
    client.interceptors.add(readScope);
    return client;
  }

  final dio = createCompanyDio(buildApiBaseOptions(baseUrl));
  final pageReads = PageReadPriorityInterceptor(
    isCurrent: (options) async =>
        ref.mounted &&
        await authInterceptor.requestBelongsToCurrentIdentity(options),
  );
  ref.onDispose(pageReads.close);
  installStreamingDownloadAdapter(dio);
  ref.onDispose(dio.close);
  // Large responses use a native isolate or a same-origin Web Worker. Web's
  // ordinary compute/BackgroundTransformer does not create a worker; model
  // conversion after JSON decoding must also keep its own bounded UI budget.
  dio.transformer = ResponsiveJsonTransformer(jsonDecoder);
  // 最先挂：后面的重试/刷新都复用同一份 RequestOptions，截止时间要先矫正好。
  dio.interceptors.add(const WriteDeadlineInterceptor());
  dio.interceptors.add(DeviceAuditInterceptor(deviceAuditStore));
  // 用户没在操作时发出的请求 (轮询/定时刷新) 声明为自动请求，服务端不据此续期会话 (ADR-110)。
  dio.interceptors.add(const AutomaticRequestInterceptor());
  authInterceptor = AuthInterceptor(
    storage: storage,
    baseUrl: baseUrl,
    dioFactory: auditedDioFactory,
    replay: dio.fetch<dynamic>,
    realmPolicy: realmPolicy,
  );
  dio.interceptors.add(authInterceptor);
  dio.interceptors.add(readScope);
  // 敏感操作被要求再认证 (403 REAUTH_REQUIRED) 时弹统一密码框、带凭证重发一次 (ADR-110)。
  dio.interceptors.add(
    StepUpInterceptor(
      dio,
      identity: AuthInterceptor.retainedIdentity,
      isCurrent: authInterceptor.requestBelongsToCurrentIdentity,
    ),
  );
  dio.interceptors.add(SafeRequestRetryInterceptor(dio, recovery: recovery));
  // 写请求成功推进本端写修订号: 「返回即刷新」据此判断数据变没变(ADR-108)。
  dio.interceptors.add(
    DataWriteRevisionInterceptor((options) => recordDataWrite(ref, options)),
  );
  final client = ApiClient(
    dio,
    streamingDownloads: true,
    precisionIdentity: AuthInterceptor.retainedIdentity,
    precisionIsCurrent: (options) async =>
        ref.mounted &&
        ref.read(apiBaseUrlProvider) == baseUrl &&
        await authInterceptor.requestBelongsToCurrentIdentity(options),
  );
  // ApiClient installs diagnostics/precision too. Queue only after all request
  // checks, and release before authentication can consume a 401 during refresh.
  pageReads.installOn(dio);
  return client;
});
