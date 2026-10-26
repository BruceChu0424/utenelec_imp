import 'package:dio/dio.dart';
import '../authenticated_request_scope.dart';

/// Observes an opaque server proof, never infers permissions from result rows.
/// Late errors/replies cannot retire a different reader or roll a scope backward.
class ReadScopeRevisionInterceptor extends Interceptor {
  ReadScopeRevisionInterceptor({
    required this.currentRevision,
    required this.retire,
    required this.isCurrent,
    required this.identity,
  });
  final int Function() currentRevision;
  final void Function() retire;
  final Future<bool> Function(RequestOptions) isCurrent;
  final AuthenticatedRequestIdentity? Function(RequestOptions) identity;
  static const _sequenceKey = '_utenReadScopeSequence';
  static const _revisionKey = '_utenReadScopeRevision';
  static const _handledKey = '_utenReadScopeHandled';
  final _versions = <(AuthenticatedRequestIdentity, String), (int, String)>{};
  int _sequence = 0;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.extra.putIfAbsent(_sequenceKey, () => ++_sequence);
    options.extra.putIfAbsent(_revisionKey, currentRevision);
    handler.next(options);
  }

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) async {
    final body = response.data;
    final headerVersion = response.headers.value('X-Uten-Read-Scope-Version');
    final providedDomain = response.headers.value('X-Uten-Read-Scope-Domain');
    final nativeDomain =
        providedDomain != null &&
            RegExp(
              r'^native_(sales_owner|purchase_owner|subcontract_owner|production_owner|fqc_records|workshop_tasks|warehouse_tasks|feature):(task|browse)$',
            ).hasMatch(providedDomain)
        ? providedDomain
        : null;
    final bodyVersion = body is Map ? body['readScopeVersion'] : null;
    final version = headerVersion ?? bodyVersion;
    final options = response.requestOptions;
    final subject = identity(options);
    final reportDomain = RegExp(
      r'^/(?:api/)?(sales|purchase|subcontract|production|stock|finance)/reports(?:/|$)',
    ).firstMatch(options.path)?.group(1);
    final master = RegExp(
      r'^/(?:api/)?master/(clients|suppliers|goods|accounts|currencies|colors|units|moulds|warehouses)(?:/|$)',
    ).firstMatch(options.path)?.group(1);
    final domain =
        nativeDomain ??
        (RegExp(
              r'^/(?:api/)?master/reference-methods/settlement-admin(?:/page)?$',
            ).hasMatch(options.path)
            ? 'master_settlement_method'
            : null) ??
        reportDomain ??
        const {
          'clients': 'client',
          'suppliers': 'supplier',
          'goods': 'master_goods',
          'accounts': 'master_account',
          'currencies': 'master_currency',
          'colors': 'master_color',
          'units': 'master_unit',
          'moulds': 'master_mould',
          'warehouses': 'master_warehouse',
        }[master];
    if (version is! String ||
        version.isEmpty ||
        version.length > 256 ||
        subject == null ||
        domain == null) {
      handler.next(response);
      return;
    }
    if (!await isCurrent(options)) {
      handler.reject(_changed(options, response));
      return;
    }
    if (options.extra[_revisionKey] != currentRevision() ||
        providedDomain?.startsWith('native_') == true && nativeDomain == null) {
      handler.reject(_changed(options, response));
      return;
    }
    if (headerVersion != null &&
        bodyVersion != null &&
        headerVersion != bodyVersion) {
      if (options.extra[_revisionKey] == currentRevision()) {
        retire();
      }
      handler.reject(_changed(options, response));
      return;
    }
    final key = (subject, domain);
    final sequence = options.extra[_sequenceKey] as int;
    final prior = _versions[key];
    if (prior != null && sequence < prior.$1) {
      if (version != prior.$2) {
        handler.reject(_changed(options, response));
        return;
      }
      handler.next(response);
      return;
    }
    if (_versions.length >= 128 && !_versions.containsKey(key)) {
      _versions.clear();
      _versions[key] = (sequence, version);
      if (options.extra[_revisionKey] == currentRevision()) retire();
      handler.reject(_changed(options, response));
      return;
    }
    _versions[key] = (sequence, version);
    if (prior != null && prior.$2 != version) {
      options.extra[_handledKey] = true;
      if (options.extra[_revisionKey] == currentRevision()) {
        retire();
      }
      handler.reject(_changed(options, response));
      return;
    }
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    final body = err.response?.data;
    final options = err.requestOptions;
    if (body is Map &&
        body['code'] == 'READ_SCOPE_CHANGED' &&
        options.extra[_handledKey] != true &&
        await isCurrent(options) &&
        options.extra[_revisionKey] == currentRevision()) {
      options.extra[_handledKey] = true;
      retire();
    }
    handler.next(err);
  }

  static DioException _changed(
    RequestOptions options,
    Response<dynamic> original,
  ) {
    options.extra[_handledKey] = true;
    return DioException(
      requestOptions: options,
      type: DioExceptionType.badResponse,
      response: Response<dynamic>(
        requestOptions: options,
        statusCode: 403,
        data: {'code': 'READ_SCOPE_CHANGED', 'message': '数据访问范围已变化，请重新打开页面后核对'},
      ),
    );
  }
}
