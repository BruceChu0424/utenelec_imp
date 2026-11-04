import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/measurement/weight_params.dart';
import 'package:uten_imp/shared/measurement/weight_prefs.dart';
import 'package:uten_imp/shared/measurement/widgets/weigh_count_dialog.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import '../drafts/memory_form_draft_storage.dart';

class _Prefs extends WarehouseWeightUnitsPrefsNotifier {
  @override
  WeightUnitsPrefs build() => const WeightUnitsPrefs();
  @override
  void persist() {}
}

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

class _Server implements HttpClientAdapter {
  final requests = <Map<String, dynamic>>[];
  final headers = <Object?>[];
  int committed = 0;
  String? key;
  @override
  Future<ResponseBody> fetch(
    RequestOptions request,
    Stream<Uint8List>? body,
    Future<void>? cancel,
  ) async {
    final value = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(request.data)) as Map,
    );
    requests.add(value);
    headers.add(request.headers['X-Uten-Precision-Choices']);
    if (key == null) {
      key = value['idempotencyKey'] as String;
      committed++;
      throw DioException(
        requestOptions: request,
        type: DioExceptionType.receiveTimeout,
      );
    }
    expect(value['idempotencyKey'], key);
    expect(value, requests.first);
    return ResponseBody.fromString(
      jsonEncode({
        'goodsId': 'g1',
        'resolved': {'goodsId': 'g1', 'basis': 'NONE'},
      }),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

const _request = WeighCountRequest(
  mode: WeighCountContext.count,
  goodsId: 'g1',
  goodsTitle: '匿名称重物料',
  params: WeightParams(
    goodsId: 'g1',
    basis: WeightBasis.exact,
    massFactorKg: 1,
    massFactorKgExact: '1',
  ),
  supplierId: 's1',
  warehouseId: 'w1',
  currentQty: 1,
  baseUnitName: '个',
);

class _Result {
  WeighCountResult? value;
}

Future<ProviderContainer> _mount(
  WidgetTester tester,
  ApiClient api,
  MemoryFormDraftStorage storage,
  _Result result, {
  String? resume,
}) async {
  final container = ProviderContainer(
    overrides: [
      apiClientProvider.overrideWithValue(api),
      apiBaseUrlProvider.overrideWithValue('https://weight.test/api'),
      authenticatedScopeProvider.overrideWithValue(
        const AuthenticatedScope(userId: 'same-owner'),
      ),
      sessionProvider.overrideWith(_Session.new),
      currentPermissionsProvider.overrideWithValue({Perm.stockDocEdit}),
      formDraftStorageProvider.overrideWithValue(storage),
      warehouseWeightUnitsPrefsProvider.overrideWith(_Prefs.new),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 700,
            height: 900,
            child: WeighCountPanel(
              request: _request,
              resumeDraftId: resume,
              onSubmit: (v) => result.value = v,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

Future<void> _drain(WidgetTester tester) async {
  for (var i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 20));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 2)),
    );
  }
}

void main() {
  testWidgets(
    'exact weighing and one sample survive committed response loss then hard restore and identical replay',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final network = _Server(),
          dio = Dio(BaseOptions(baseUrl: 'https://weight.test/api'));
      dio.httpClientAdapter = network;
      final api = ApiClient(dio),
          storage = MemoryFormDraftStorage(),
          result = _Result();
      var container = await _mount(tester, api, storage, result);
      await tester.enterText(
        find.byKey(const ValueKey('weigh-count-gross-0')),
        '1.123456789012345678901234',
      );
      if (find
          .byKey(const ValueKey('weigh-count-sample-qty'))
          .evaluate()
          .isEmpty) {
        await tester.tap(
          find
              .descendant(
                of: find.byKey(const ValueKey('weigh-count-sampling-options')),
                matching: find.byType(ListTile),
              )
              .first,
        );
        await tester.pumpAndSettle();
      }
      await tester.enterText(
        find.byKey(const ValueKey('weigh-count-sample-qty')),
        '20',
      );
      await tester.enterText(
        find.byKey(const ValueKey('weigh-count-sample-weight')),
        '0.040123456789012345678901234 kg',
      );
      await tester.pump();
      const actual = '12345678901234567890.000000000000000000000001';
      await tester.ensureVisible(
        find.byKey(const ValueKey('weigh-count-quantity')),
      );
      await tester.enterText(
        find.byKey(const ValueKey('weigh-count-quantity')),
        actual,
      );
      await tester.pump();
      await tester.ensureVisible(
        find.byKey(const ValueKey('weigh-count-primary')),
      );
      await tester.tap(find.byKey(const ValueKey('weigh-count-primary')));
      await _drain(tester);
      expect(network.requests, hasLength(1));
      expect(network.committed, 1);
      expect(
        network.requests.single['weight'],
        '0.040123456789012345678901234',
      );
      final draft = container.read(formDraftsProvider).single;
      expect(draft.hasUnknownSubmission, isTrue);
      expect((draft.data['result'] as Map)['qty'], actual);
      expect(draft.data['adoptedOriginalInput'], actual);
      expect(
        (draft.data['result'] as Map)['net'],
        '1.123456789012345678901234',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
      await tester.pumpAndSettle();
      container = await _mount(tester, api, storage, result, resume: draft.id);
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('weigh-count-gross-0')),
            )
            .enabled,
        isFalse,
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('weigh-count-recover')),
      );
      await tester.tap(find.byKey(const ValueKey('weigh-count-recover')));
      await _drain(tester);
      expect(network.requests, hasLength(2));
      expect(network.requests[0], network.requests[1]);
      expect(network.headers[0], network.headers[1]);
      expect(network.committed, 1);
      expect(result.value!.netKgText, '1.123456789012345678901234');
      expect(result.value!.qtyExact, actual);
      expect(result.value!.sample!.saved, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
      dio.close(force: true);
    },
  );
}
