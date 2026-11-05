import 'dart:async';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/api_mutation_reload_safety.dart';
import 'package:uten_imp/core/network/request_reload_semantics.dart';
import 'package:uten_imp/core/web_update/web_update_safety.dart';

const _component = '11111111-1111-4111-8111-111111111111';
const _shipment = '22222222-2222-4222-8222-222222222222';
const _request = '33333333-3333-4333-8333-333333333333';
const _warehouseReceipt =
    '/warehouse/sales-outbound/$_shipment/delivery-requests/$_request';
const _workshopReceipt =
    '/production/delivery-processing-tasks/$_component/requests/$_request';

void main() {
  test(
    'only exact preview paths are body-carried reads; neighboring handover/report routes stay writes',
    () {
      for (final path in [
        '/sales/orders/delivery-preview',
        '/api/sales/orders/delivery-preview',
        '/sales/orders/delivery-preview?fixture=true',
      ]) {
        expect(isReadOnlyPost(path), isTrue, reason: path);
      }
      for (final path in [
        '/sales/orders/delivery-preview/submit',
        '/sales/orders/delivery-preview-save',
        '/sales/orders/delivery-Preview',
        '/api/api/sales/orders/delivery-preview',
        '/sales/orders/delivery-bom/rules/$_component',
        '/warehouse/sales-outbound/$_shipment/delivery-components/$_component/processing-issue',
        '/warehouse/sales-outbound/$_shipment/delivery-components/$_component/processing-receive',
        '/warehouse/sales-outbound/$_shipment/delivery-components/$_component/processing-cancel-issue',
        '/production/delivery-processing-tasks/$_component/assignment',
        '/production/delivery-processing-tasks/$_component/start',
        '/production/delivery-processing-tasks/$_component/reports',
        '/production/delivery-processing-tasks/$_component/cancel-start',
        _warehouseReceipt,
        _workshopReceipt,
      ]) {
        expect(isReadOnlyPost(path), isFalse, reason: path);
        expect(isNoticePresentationReceipt(path), isFalse, reason: path);
      }
    },
  );

  for (final path in [_warehouseReceipt, _workshopReceipt]) {
    test(
      'GET receipt $path is cancellable read work and cannot create or clear a commit fence',
      () async {
        final registry = WebUpdateSafetyRegistry()..setReady(true);
        addTearDown(registry.dispose);
        final safety = ApiMutationReloadSafety(registry: registry),
            adapter = _Adapter();
        final api = ApiClient(
          Dio(BaseOptions(baseUrl: 'https://fixture.test/api'))
            ..httpClientAdapter = adapter,
          reloadSafety: safety,
        );
        final failedRead = api.get(path);
        final readFailure = expectLater(
          failedRead,
          throwsA(isA<ApiException>()),
        );
        await adapter.ready(1);
        expect(safety.pendingReadCount, 1);
        expect(safety.pendingCount, 0);
        adapter.respond(0, '{}', status: 503);
        await readFailure;
        expect(safety.pendingReadCount, 0);
        expect(safety.hasUncertainCommit, isFalse);
        final wrongMethod = api.post(path);
        final writeFailure = expectLater(
          wrongMethod,
          throwsA(isA<ApiException>()),
        );
        await adapter.ready(2);
        expect(safety.pendingCount, 1);
        adapter.respond(1, '{}', status: 503);
        await writeFailure;
        expect(safety.hasUncertainCommit, isTrue);
        final receipt = api.get(path);
        await adapter.ready(3);
        adapter.respond(2, '{"found":true,"recorded":true}');
        await receipt;
        expect(
          safety.hasUncertainCommit,
          isTrue,
          reason: 'a receipt cannot acknowledge unrelated earlier writes',
        );
      },
    );
  }
  test(
    'delivery preview failure remains read-only while an adjacent failed report remains uncertain',
    () async {
      final registry = WebUpdateSafetyRegistry()..setReady(true);
      addTearDown(registry.dispose);
      final safety = ApiMutationReloadSafety(registry: registry),
          adapter = _Adapter();
      final api = ApiClient(
        Dio(BaseOptions(baseUrl: 'https://fixture.test/api'))
          ..httpClientAdapter = adapter,
        reloadSafety: safety,
      );
      final preview = api.post(
        '/sales/orders/delivery-preview',
        body: {'qty': '0.1250'},
      );
      final previewFailure = expectLater(preview, throwsA(isA<ApiException>()));
      await adapter.ready(1);
      expect(safety.pendingReadCount, 1);
      expect(safety.pendingCount, 0);
      adapter.respond(0, '{}', status: 503);
      await previewFailure;
      expect(safety.hasUncertainCommit, isFalse);
      final report = api.post(
        '/production/delivery-processing-tasks/$_component/reports',
        body: {'quantity': '0.1250'},
      );
      final reportFailure = expectLater(report, throwsA(isA<ApiException>()));
      await adapter.ready(2);
      adapter.respond(1, '{}', status: 503);
      await reportFailure;
      expect(safety.hasUncertainCommit, isTrue);
    },
  );
}

class _Adapter implements HttpClientAdapter {
  final sent = <RequestOptions>[];
  final responses = <Completer<ResponseBody>>[];
  Future<void> ready(int count) async {
    for (var i = 0; i < 100 && sent.length < count; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(sent.length, count);
  }

  void respond(int index, String body, {int status = 200}) =>
      responses[index].complete(
        ResponseBody.fromString(
          body,
          status,
          headers: {
            Headers.contentTypeHeader: ['application/json'],
          },
        ),
      );
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    sent.add(options);
    final response = Completer<ResponseBody>();
    responses.add(response);
    return response.future;
  }

  @override
  void close({bool force = false}) {}
}
