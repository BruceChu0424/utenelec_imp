import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_error.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/shared/measurement/weight_params.dart';
import 'package:uten_imp/shared/measurement/widgets/weight_params_load_notice.dart';

class _FlakyRepository extends WeightRepository {
  _FlakyRepository() : super(ApiClient(Dio()));
  int failures = 1;
  final requests = <List<WeightParamsLine>>[];

  @override
  Future<WeightParamsResult> params(Iterable<WeightParamsLine> lines) async {
    requests.add(lines.toList());
    if (failures-- > 0) {
      // 2026-10-04 的真实回包: 拼接 key 超长被逐行校验拒绝。
      throw ApiException(
        'VALIDATION_FAILED',
        '填写的内容有误',
        httpStatus: 422,
        fieldErrors: const [
          ApiFieldError(field: 'lines[0].key', message: '个数必须在0和100之间'),
        ],
      );
    }
    return WeightParamsResult(
      params: {
        for (final line in lines)
          line.paramsIdentity: WeightParams(goodsId: line.goodsId),
      },
    );
  }
}

void main() {
  testWidgets('取参失败在页面上可见(带真实原因), 点重试只重取失败行后消失', (tester) async {
    final repository = _FlakyRepository();
    final cache = WeightParamsCache(repository);
    addTearDown(cache.dispose);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: Scaffold(body: WeightParamsLoadNotice(cache: cache)),
      ),
    );
    expect(find.byKey(const Key('weight-params-load-notice')), findsNothing);

    const line = WeightParamsLine(
      goodsId: 'g',
      supplierId: 's',
      warehouseId: 'w',
      colorId: 'c',
    );
    await cache.ensure([line]);
    await tester.pump();
    expect(find.byKey(const Key('weight-params-load-notice')), findsOneWidget);
    expect(find.textContaining('单重设置读取失败'), findsOneWidget);
    expect(find.textContaining('个数必须在0和100之间'), findsOneWidget);

    await tester.tap(find.byKey(const Key('weight-params-load-retry')));
    await tester.pumpAndSettle();
    expect(repository.requests, hasLength(2));
    expect(repository.requests.last, [line]);
    expect(find.byKey(const Key('weight-params-load-notice')), findsNothing);
    expect(
      cache.of('g', supplierId: 's', warehouseId: 'w', colorId: 'c'),
      isNotNull,
    );
  });

  testWidgets('页面没有用到单重缓存时不占位', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: WeightParamsLoadNotice(cache: null)),
    );
    expect(find.byType(SizedBox), findsWidgets);
    expect(find.byKey(const Key('weight-params-load-notice')), findsNothing);
  });
}
