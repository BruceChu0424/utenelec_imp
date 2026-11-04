import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import '../../performance/json_value_snapshot.dart';
import '../api_exception.dart';
import '../api_error.dart';
import '../api_mutation_reload_safety.dart';
import '../authenticated_request_scope.dart';
import '../business_precision.dart';
import '../business_precision_coordinator.dart';
import '../request_reload_semantics.dart';

class _PrecisionBinding {
  _PrecisionBinding(
    this.transport,
    this.fingerprint,
    this.semanticFingerprint,
    this.data,
    this.query,
    this.mutating,
    this.scope,
  );
  final BusinessPrecisionTransport transport;
  final String fingerprint, semanticFingerprint;
  final Object? data;
  final Map<String, dynamic> query;
  final bool mutating;
  final AuthenticatedRequestScope? scope;
  int rounds = 0;
}

/// Only a structured 422 notWritten response may open a precision dialog or
/// replay. Every replay owns the same detached business body and query.
class BusinessPrecisionInterceptor extends Interceptor {
  BusinessPrecisionInterceptor(
    this.dio, {
    BusinessPrecisionCoordinator? coordinator,
    this.identity,
    this.isCurrent,
  }) : coordinator = coordinator ?? BusinessPrecisionCoordinator.instance;
  final Dio dio;
  final BusinessPrecisionCoordinator coordinator;
  final Object? Function(RequestOptions)? identity;
  final Future<bool> Function(RequestOptions)? isCurrent;
  static const _bindingKey = '_utenBusinessPrecisionBinding';
  final _unknown = <(Object?, String), BusinessPrecisionTransport>{};
  Object? _identity(RequestOptions options) => identity?.call(options) ?? dio;
  bool _mutating(RequestOptions options) =>
      !const {'GET', 'HEAD', 'OPTIONS'}.contains(options.method) &&
      !isReadOnlyPost(options.uri.path);
  Future<bool> _current(
    RequestOptions options,
    _PrecisionBinding binding,
  ) async =>
      binding.transport.currentIdentity &&
      (binding.scope?.isCurrent ?? true) &&
      (isCurrent == null || await isCurrent!(options));
  Object? _freeze(Object? data) {
    if (data is FormData) {
      return data.clone();
    }
    if (data is Uint8List) {
      return Uint8List.fromList(data);
    }
    return snapshotJsonValue(data);
  }

  Object? _fingerprintData(Object? data) {
    if (data is FormData) {
      return {
        'fields': [
          for (final field in data.fields) [field.key, field.value],
        ],
        'files': [
          for (final file in data.files)
            [
              file.key,
              file.value.filename,
              file.value.length,
              file.value.contentType?.toString(),
            ],
        ],
      };
    }
    if (data is Uint8List) {
      return {'binarySha256': sha256.convert(data).toString()};
    }
    return data;
  }

  String _hash(Object? value) =>
      sha256.convert(utf8.encode(jsonEncode(value))).toString();
  String _semantic(
    RequestOptions options,
    Object? data,
    Map<String, dynamic> query,
  ) {
    final body = data is Map<String, dynamic>
        ? Map<String, dynamic>.from(data)
        : data;
    if (body is Map<String, dynamic>) {
      body.remove('requestId');
    }
    return _hash([
      options.method,
      options.uri.path,
      query,
      _fingerprintData(body),
    ]);
  }

  @override
  void onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    // Authentication has its own session-intent/issuer fences. It has no
    // financial projection and must never retain credentials as an unknown
    // business body, ask for precision, or retry them after a 422 response.
    final path = options.uri.path;
    final localPath = path.startsWith('/api/') ? path.substring(4) : path;
    if (options.method == 'POST' &&
        const {
          '/auth/login',
          '/auth/refresh',
          '/auth/logout',
          '/auth/change-password',
          '/auth/step-up',
          '/visitor/auth/send-code',
          '/visitor/auth/login',
          '/visitor/auth/refresh',
          '/visitor/auth/logout',
        }.contains(localPath)) {
      options.headers.remove(businessPrecisionHeader);
      handler.next(options);
      return;
    }
    try {
      var binding = options.extra[_bindingKey] as _PrecisionBinding?;
      if (binding == null) {
        final data = _freeze(options.data),
            query = Map<String, dynamic>.from(
              snapshotJsonValue(options.queryParameters) as Map,
            );
        final fingerprint = _hash([
          options.method,
          options.uri.toString(),
          _fingerprintData(data),
        ]);
        final scope = AuthenticatedRequestScope.attach(options);
        final transport =
            BusinessPrecisionTransport.current ??
            _unknown[(_identity(options), fingerprint)] ??
            BusinessPrecisionTransport(readOnly: !_mutating(options));
        binding = _PrecisionBinding(
          transport,
          fingerprint,
          _semantic(options, data, query),
          data,
          query,
          _mutating(options),
          scope,
        );
        options.extra[_bindingKey] = binding;
      }
      if (!await _current(options, binding)) {
        throw AuthenticatedRequestScope.changed();
      }
      await binding.transport.dispatch(
        binding.fingerprint,
        mutating: binding.mutating,
        semanticFingerprint: binding.semanticFingerprint,
      );
      final header = binding.transport.encodedHeader;
      options.data = _freeze(binding.data);
      options.queryParameters = Map<String, dynamic>.from(binding.query);
      if (header == null) {
        options.headers.remove(businessPrecisionHeader);
      } else {
        options.headers[businessPrecisionHeader] = header;
      }
      handler.next(options);
    } catch (error, stack) {
      handler.reject(
        DioException(
          requestOptions: options,
          type: DioExceptionType.cancel,
          error: error is ApiException
              ? error
              : ApiException(
                  'PRECISION_CHECKPOINT_FAILED',
                  '本次选择未能安全保留，本次未重新发送，请保留原输入',
                  httpStatus: 422,
                ),
          stackTrace: stack,
        ),
      );
    }
  }

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) async {
    final binding =
        response.requestOptions.extra[_bindingKey] as _PrecisionBinding?;
    if (binding != null) {
      await binding.transport.completed(
        binding.fingerprint,
        mutating: binding.mutating,
      );
      _unknown.remove((
        _identity(response.requestOptions),
        binding.fingerprint,
      ));
    }
    handler.next(response);
  }

  Map<String, dynamic>? _body(Object? value) {
    if (value is Map) {
      return Map<String, dynamic>.from(value);
    }
    if (value is List<int> && value.length <= 65536) {
      try {
        final decoded = jsonDecode(utf8.decode(value));
        if (decoded is Map) {
          return Map<String, dynamic>.from(decoded);
        }
      } catch (_) {}
    }
    return null;
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    final error = err;
    final options = error.requestOptions,
        binding = error.requestOptions.extra[_bindingKey] as _PrecisionBinding?;
    if (binding == null) {
      handler.next(error);
      return;
    }
    final body = _body(error.response?.data);
    final required =
        error.response?.statusCode == 422 &&
            body?['code'] == 'PRECISION_CHOICE_REQUIRED'
        ? BusinessPrecisionRequirement.parse(body?['details'])
        : null;
    if (required == null) {
      final rejection = error.error is ApiException
          ? error.error! as ApiException
          : ApiExceptionFactory.fromDioStatusCode(
              error.response?.statusCode,
              body == null ? null : ApiError.fromJson(body),
            );
      if (ApiMutationReloadSafety.isDefiniteRejection(rejection)) {
        try {
          await binding.transport.rejected(binding.fingerprint);
        } catch (_) {
          /* No business replay follows a failed local checkpoint. */
        }
      } else if (binding.mutating) {
        _unknown[(_identity(options), binding.fingerprint)] = binding.transport;
      }
      handler.next(error);
      return;
    }
    try {
      await binding.transport.required(binding.fingerprint, required);
      if (!binding.transport.canAsk || !await _current(options, binding)) {
        handler.next(error);
        return;
      }
      final replacing = binding.transport.choices.containsKey(required.key);
      if (replacing &&
          (!required.selectionRejected || !binding.transport.canReselect)) {
        handler.next(error);
        return;
      }
      if (binding.rounds >= 8 ||
          (!replacing && binding.transport.choices.length >= 32)) {
        await binding.transport.holdContinuation();
        handler.next(
          error.copyWith(
            error: ApiException(
              'PRECISION_CHOICE_REQUIRED',
              '本次已有精度选择已保留，请回到原操作继续处理其他计算',
              details: {
                ...Map<String, dynamic>.from(
                  body?['details'] as Map? ?? <String, dynamic>{},
                ),
                'continuation': true,
              },
              httpStatus: 422,
              hasResponseCode: true,
            ),
          ),
        );
        return;
      }
      final choice = await coordinator.ask(
        required,
        isCurrent: () =>
            binding.transport.currentIdentity &&
            (binding.scope?.isCurrent ?? true),
      );
      if (choice == null ||
          choice.scale > required.maxScale ||
          !await _current(options, binding)) {
        handler.next(error);
        return;
      }
      await binding.transport.select(required.key, choice);
      binding.rounds++;
      final replay = options.copyWith(
        data: _freeze(binding.data),
        queryParameters: Map<String, dynamic>.from(binding.query),
        headers: Map<String, dynamic>.from(options.headers),
        extra: Map<String, dynamic>.from(options.extra),
      );
      try {
        handler.resolve(await dio.fetch<dynamic>(replay));
      } on DioException catch (retry) {
        handler.next(retry);
      }
    } catch (failure, stack) {
      handler.next(
        error.copyWith(
          error: failure is ApiException
              ? failure
              : ApiException(
                  'PRECISION_CHECKPOINT_FAILED',
                  '原精度选择尚未安全保存，本次未重新发送，请保留原输入',
                  httpStatus: 422,
                ),
          stackTrace: stack,
        ),
      );
    }
  }
}
