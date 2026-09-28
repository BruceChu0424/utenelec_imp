// ADR-134 customer goods cross reference: repository wire contract
// (SPEC v2 section 5.8, GET/DELETE /master/clients/{id}/goods-aliases).
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/models/client_goods_alias.dart';
import 'package:uten_imp/features/basic_data/repositories/client_goods_alias_repository.dart';

void main() {
  late List<RequestOptions> requests;
  late Object? Function(RequestOptions) respond;

  DioClientGoodsAliasRepository repository() {
    requests = <RequestOptions>[];
    final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          requests.add(request);
          handler.resolve(
            Response<dynamic>(
              requestOptions: request,
              statusCode: 200,
              data: respond(request),
            ),
          );
        },
      ),
    );
    return DioClientGoodsAliasRepository(ApiClient(dio));
  }

  setUp(() {
    respond = (_) => <String, dynamic>{
      'items': <Object?>[],
      'page': 1,
      'size': 20,
      'total': 0,
      'totalPages': 0,
    };
  });

  test(
    'list sends page, size and trimmed keyword on the client path',
    () async {
      respond = (_) => {
        'items': [
          {
            'id': 'alias-1',
            'scope': 'CLIENT',
            'aliasKind': 'PART_NO',
            'aliasText': 'GZ23/D',
            'contextText': 'Z9 | 白',
            'goods': {
              'id': 'goods-1',
              'code': '280235165',
              'name': '两开多功能三极插座',
              'colorName': '白色',
            },
            'confirmCount': 3,
            'explicitCount': 1,
            'lastConfirmedAt': '2026-09-20T02:30:00Z',
            'lastConfirmedByName': '李销售',
            'canDelete': true,
          },
        ],
        'page': 2,
        'size': 20,
        'total': 21,
        'totalPages': 2,
      };
      final repo = repository();

      final page = await repo.list(' client-1 ', page: 2, keyword: '  gz23 ');

      expect(requests.single.method, 'GET');
      expect(requests.single.path, '/master/clients/client-1/goods-aliases');
      expect(requests.single.queryParameters, {
        'page': 2,
        'size': 20,
        'keyword': 'gz23',
      });
      expect(page.total, 21);
      expect(page.page, 2);
      final alias = page.items.single;
      expect(alias.aliasText, 'GZ23/D');
      expect(alias.isPartNo, isTrue);
      expect(alias.hasContext, isTrue);
      expect(alias.goods?.label, '两开多功能三极插座(280235165) · 白色');
      expect(alias.confirmCount, 3);
      expect(alias.explicitCount, 1);
      expect(alias.lastConfirmedByName, '李销售');
      expect(alias.canDelete, isTrue);
    },
  );

  test(
    'blank keyword is not sent and size is capped by the server limit',
    () async {
      final repo = repository();

      await repo.list('client-1', page: 0, size: 1000, keyword: '   ');

      expect(requests.single.queryParameters, {
        'page': 1,
        'size': kClientGoodsAliasMaxPageSize,
      });
    },
  );

  test('delete targets the alias under its customer', () async {
    final repo = repository();

    await repo.delete('client-1', ' alias-9 ');

    expect(requests.single.method, 'DELETE');
    expect(
      requests.single.path,
      '/master/clients/client-1/goods-aliases/alias-9',
    );
  });

  test('blank ids are refused before any request is sent', () async {
    final repo = repository();

    await expectLater(repo.list('  '), throwsArgumentError);
    await expectLater(repo.delete('client-1', ' '), throwsArgumentError);
    await expectLater(repo.delete('', 'alias-1'), throwsArgumentError);
    expect(requests, isEmpty);
  });

  test('row parsing fails closed and tolerates a missing goods', () {
    final alias = ClientGoodsAlias.fromJson({
      'id': 'alias-2',
      'aliasKind': 'DESCRIPTION',
      'aliasText': 'DOUBLE 3 PIN SOCKET',
      'canDelete': 'yes',
    });

    expect(alias.scope, ClientGoodsAliasScope.client);
    expect(alias.isPartNo, isFalse);
    expect(alias.goods, isNull);
    expect(alias.hasContext, isFalse);
    expect(alias.confirmCount, 0);
    // Only an explicit JSON true enables deletion.
    expect(alias.canDelete, isFalse);
  });

  test('goods label follows the name(code) · colour format', () {
    expect(
      const ClientGoodsAliasGoods(id: 'g', name: '插座', code: 'P1').label,
      '插座(P1)',
    );
    expect(const ClientGoodsAliasGoods(id: 'g', code: 'P1').label, 'P1');
    expect(
      const ClientGoodsAliasGoods(id: 'g', name: '插座', colorName: '白').label,
      '插座 · 白',
    );
  });
}
