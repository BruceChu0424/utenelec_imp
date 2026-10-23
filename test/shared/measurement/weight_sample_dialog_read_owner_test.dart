import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/measurement/weight_params.dart';
import 'package:uten_imp/shared/measurement/weight_predictor.dart';
import 'package:uten_imp/shared/measurement/weight_prefs.dart';
import 'package:uten_imp/shared/measurement/widgets/weight_sample_dialog.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/export_context_epoch_provider.dart';

class _Owner extends Notifier<AuthenticatedScope?> {
  @override
  AuthenticatedScope? build() => const AuthenticatedScope(userId: 'A');
  void change(AuthenticatedScope? value) => state = value;
}

class _Permissions extends Notifier<Set<String>> {
  @override
  Set<String> build() => {Perm.stockDocEdit};
  void change(Set<String> value) => state = value;
}

class _Server extends Notifier<String> {
  @override
  String build() => '';
  void change(String value) => state = value;
}

final _owner = NotifierProvider<_Owner, AuthenticatedScope?>(_Owner.new);
final _permissions = NotifierProvider<_Permissions, Set<String>>(
  _Permissions.new,
);
final _server = NotifierProvider<_Server, String>(_Server.new);

class _MemoryPrefs extends WarehouseWeightUnitsPrefsNotifier {
  @override
  WeightUnitsPrefs build() => const WeightUnitsPrefs();
  @override
  void persist() {}
}

class _DelayedApi extends ApiClient {
  _DelayedApi() : super(Dio());

  final params = Completer<Map<String, dynamic>>();
  int paramsCalls = 0;
  final saves = <Completer<Map<String, dynamic>>>[];
  final bodies = <Map<String, Object?>>[];

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) {
    if (path == ApiEndpoints.stockWeightParams) {
      paramsCalls++;
      return params.future;
    }
    expect(path, ApiEndpoints.stockWeightGoodsSamples('private-goods'));
    bodies.add(body! as Map<String, Object?>);
    final result = Completer<Map<String, dynamic>>();
    saves.add(result);
    return result.future;
  }
}

const _params = WeightParams(
  goodsId: 'private-goods',
  basis: WeightBasis.learned,
  supplierSpecific: true,
  logMean: -6.214979467174846,
  lotPrior: 3.869930380683166e-05,
  df: 15,
  tier: WeightTier.yellow,
  nInliers: 12,
  unitWeightKg: 0.0019992574,
  suggestedSampleSize: 16,
);

Map<String, dynamic> _detail() => {
  'goodsId': 'private-goods',
  'resolved': {
    'goodsId': 'private-goods',
    'basis': 'LEARNED',
    'tier': 'GREEN',
    'unitWeightKg': 0.002005,
  },
  'supplierRows': [
    {'supplierId': 'private-supplier', 'supplierName': '敏感供应商', 'nRef': 3},
  ],
};

class _Harness {
  bool closed = false;
  GoodsWeightDetail? result;
}

Future<(_DelayedApi, _Harness, ProviderContainer)> _open(
  WidgetTester tester, {
  bool loadParams = false,
  bool changeBeforeFirstFrame = false,
}) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final api = _DelayedApi();
  final harness = _Harness();
  final container = ProviderContainer(
    overrides: [
      authenticatedScopeProvider.overrideWith((ref) => ref.watch(_owner)),
      currentPermissionsProvider.overrideWith((ref) => ref.watch(_permissions)),
      apiBaseUrlProvider.overrideWith((ref) => ref.watch(_server)),
      warehouseWeightUnitsPrefsProvider.overrideWith(_MemoryPrefs.new),
      weightRepositoryProvider.overrideWithValue(WeightRepository(api)),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              key: const Key('open'),
              onPressed: () async {
                harness.result = await showWeightSampleDialog(
                  context,
                  goodsId: 'private-goods',
                  goodsTitle: '敏感货品',
                  supplierId: 'private-supplier',
                  supplierName: '敏感供应商',
                  remark: '敏感备注',
                  params: loadParams ? null : _params,
                );
                harness.closed = true;
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const Key('open')));
  if (changeBeforeFirstFrame) _aba(container, 'account');
  await tester.pumpAndSettle();
  return (api, harness, container);
}

void _aba(ProviderContainer container, String dimension) {
  final initialEpoch = container.read(exportContextEpochProvider);
  void change(bool original) {
    switch (dimension) {
      case 'account':
        container
            .read(_owner.notifier)
            .change(AuthenticatedScope(userId: original ? 'A' : 'B'));
      case 'permission':
        container
            .read(_permissions.notifier)
            .change(original ? {Perm.stockDocEdit} : {});
      case 'server':
        container
            .read(_server.notifier)
            .change(original ? '' : 'https://b.invalid/api');
    }
  }

  change(false);
  container.read(exportContextEpochProvider);
  change(true);
  expect(
    container.read(exportContextEpochProvider),
    greaterThan(initialEpoch + 1),
  );
}

Future<void> _startSave(WidgetTester tester) async {
  for (final entry in {'qty': '20', 'weight': '40.1'}.entries) {
    final field = find.byKey(ValueKey('weight-sample-${entry.key}'));
    await tester.ensureVisible(field);
    await tester.enterText(field, entry.value);
    await tester.pump();
  }
  await tester.tap(find.byKey(const ValueKey('weight-sample-save')));
  await tester.pump();
}

void _expectScrubbed() {
  expect(find.textContaining('敏感货品'), findsNothing);
  expect(find.textContaining('敏感供应商'), findsNothing);
  expect(find.textContaining('敏感备注'), findsNothing);
  expect(find.byType(EditableText), findsNothing);
  expect(find.byKey(const ValueKey('weight-sample-save')), findsNothing);
  expect(find.byType(CircularProgressIndicator), findsNothing);
  expect(find.text('称样窗口已失效'), findsOneWidget);
}

void main() {
  testWidgets('owner ABA before the dialog first frame never shows old data', (
    tester,
  ) async {
    final (api, _, _) = await _open(
      tester,
      loadParams: true,
      changeBeforeFirstFrame: true,
    );
    _expectScrubbed();
    expect(api.paramsCalls, 0);
    expect(api.saves, isEmpty);
  });

  for (final dimension in ['account', 'permission', 'server']) {
    for (final lateError in [false, true]) {
      testWidgets(
        '$dimension ABA during save drops late ${lateError ? 'failure' : 'success'}',
        (tester) async {
          final (api, harness, container) = await _open(tester);
          await _startSave(tester);
          expect(api.saves, hasLength(1));
          _aba(container, dimension);
          await tester.pumpAndSettle();
          _expectScrubbed();
          expect(find.textContaining('保存请求可能已完成'), findsOneWidget);
          if (lateError) {
            api.saves.single.completeError(ApiException('OLD', '敏感服务端错误'));
          } else {
            api.saves.single.complete(_detail());
          }
          await tester.pumpAndSettle();
          _expectScrubbed();
          expect(find.textContaining('敏感服务端错误'), findsNothing);
          expect(harness.closed, isFalse);
          expect(harness.result, isNull);
          expect(
            api.saves,
            hasLength(1),
            reason: 'invalidating cannot replay a command',
          );
          await tester.tap(
            find.byKey(const ValueKey('weight-sample-close-invalid')),
          );
          await tester.pumpAndSettle();
          expect(harness.closed, isTrue);
          expect(harness.result, isNull);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final lateError in [false, true]) {
    testWidgets(
      'dialog account ABA drops late params ${lateError ? 'error' : 'data'}',
      (tester) async {
        final (api, harness, container) = await _open(tester, loadParams: true);
        expect(api.paramsCalls, 1);
        _aba(container, 'account');
        await tester.pumpAndSettle();
        _expectScrubbed();
        expect(find.textContaining('保存请求可能已完成'), findsNothing);
        if (lateError) {
          api.params.completeError(ApiException('OLD', '敏感参数错误'));
        } else {
          api.params.complete({
            'items': [_detail()['resolved']],
          });
        }
        await tester.pumpAndSettle();
        _expectScrubbed();
        expect(find.textContaining('敏感参数错误'), findsNothing);
        expect(api.paramsCalls, 1);
        expect(api.saves, isEmpty);
        expect(harness.closed, isFalse);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('same owner can retry failure with the same idempotency key', (
    tester,
  ) async {
    final (api, harness, _) = await _open(tester);
    await _startSave(tester);
    api.saves.single.completeError(ApiException('RETRY', '请重试'));
    await tester.pumpAndSettle();
    expect(find.text('请重试'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('weight-sample-save')));
    await tester.pump();
    expect(api.saves, hasLength(2));
    expect(api.bodies[0]['idempotencyKey'], isNotEmpty);
    expect(api.bodies[1]['idempotencyKey'], api.bodies[0]['idempotencyKey']);
    api.saves.last.complete(_detail());
    await tester.pumpAndSettle();
    expect(harness.closed, isTrue);
    expect(harness.result?.goodsId, 'private-goods');
  });
}
