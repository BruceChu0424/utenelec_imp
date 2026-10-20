import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/repositories/mould_manufacturer_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/mould_manufacturer_field.dart';

MouldManufacturerRepository _repository(
  List<RequestOptions> requests,
  Object payload,
) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        requests.add(options);
        handler.resolve(
          Response(requestOptions: options, statusCode: 200, data: payload),
        );
      },
    ),
  );
  return MouldManufacturerRepository(ApiClient(dio));
}

void main() {
  test(
    'manufacturer history consumes the actual JSON string-array contract',
    () async {
      final requests = <RequestOptions>[];
      final repository = _repository(requests, ['UAT博睿精密', 'UAT鸿发']);
      expect(await repository.suggestions(''), ['UAT博睿精密', 'UAT鸿发']);
      expect(await repository.suggestions('  UAT博  '), ['UAT博睿精密', 'UAT鸿发']);
      expect(requests.map((request) => request.queryParameters['q']), [
        '',
        'UAT博',
      ]);
      expect(
        requests.every(
          (request) => request.path.endsWith('/manufacturer-suggestions'),
        ),
        isTrue,
      );
    },
  );

  test(
    'manufacturer history rejects an unexpected object-array schema',
    () async {
      final repository = _repository([], [
        {'value': 'UAT博睿精密'},
      ]);
      await expectLater(repository.suggestions(''), throwsFormatException);
    },
  );

  testWidgets(
    'actual repository string candidates reach the manufacturer field',
    (tester) async {
      final requests = <RequestOptions>[];
      final repository = _repository(requests, ['UAT博睿精密', 'UAT鸿发']);
      var selected = '';
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            mouldManufacturerRepositoryProvider.overrideWithValue(repository),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 480,
                child: MouldManufacturerField(
                  onChanged: (value) => selected = value,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      expect(find.text('候选加载失败，仍可直接输入'), findsNothing);
      expect(find.text('UAT博睿精密'), findsOneWidget);
      await tester.tap(find.text('UAT鸿发'));
      await tester.pumpAndSettle();
      expect(selected, 'UAT鸿发');
      expect(requests.first.queryParameters['q'], '');
      expect(tester.takeException(), isNull);
    },
  );
}
