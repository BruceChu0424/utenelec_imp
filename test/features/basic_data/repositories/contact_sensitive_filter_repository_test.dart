// 客户/供应商列表的手机、电话、银行账号筛选值不进 URL (security-19)。
//
// 钉住：带这些筛选或搜索关键字 (会匹配手机号) 时改走 POST /search，值只在请求体；
// 「筛为空」哨兵只暴露字段名，仍随 nullFields 走查询串；不带敏感检索值时列表仍是普通 GET。
// 导出同理：关键字与敏感值进 sensitiveFilter 请求体，查询串里没有。
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/models/master_facet.dart';
import 'package:uten_imp/features/basic_data/repositories/client_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/supplier_repository.dart';

const _emptyPage = {'items': <Object>[], 'total': 0, 'page': 1, 'size': 20};

Dio _capturing(List<RequestOptions> sink) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        sink.add(request);
        handler.resolve(
          Response<dynamic>(
            requestOptions: request,
            statusCode: 200,
            data: _emptyPage,
          ),
        );
      },
    ),
  );
  return dio;
}

void main() {
  test('客户：手机/银行账号筛选值只在 POST /search 请求体里', () async {
    final sent = <RequestOptions>[];
    await DioClientRepository(ApiClient(_capturing(sent))).list(
      'cat-1',
      filters: const {
        'mobile': '13800138000',
        'bankAccount': '6222020200112233',
        'phone2': kMasterFilterNullValue,
        'region': '华东',
      },
    );

    final request = sent.single;
    expect(request.method, 'POST');
    expect(request.path, '/master/clients/search');
    expect(request.data, {
      'mobile': '13800138000',
      'bankAccount': '6222020200112233',
    });
    final url = request.uri.toString();
    expect(url, isNot(contains('13800138000')));
    expect(url, isNot(contains('6222020200112233')));
    expect(request.queryParameters['region'], '华东');
    expect(request.queryParameters['nullFields'], ['phone2']);
  });

  test('客户：没有敏感筛选时仍是普通 GET 列表', () async {
    final sent = <RequestOptions>[];
    await DioClientRepository(
      ApiClient(_capturing(sent)),
    ).list('cat-1', filters: const {'region': '华东'});

    expect(sent.single.method, 'GET');
    expect(sent.single.path, '/master/clients');
    expect(sent.single.data, isNull);
  });

  test('供应商：电话筛选值只在 POST /search 请求体里', () async {
    final sent = <RequestOptions>[];
    await DioSupplierRepository(
      ApiClient(_capturing(sent)),
    ).list('cat-9', filters: const {'phone': '021-88886666'});

    final request = sent.single;
    expect(request.method, 'POST');
    expect(request.path, '/master/suppliers/search');
    expect(request.data, {'phone': '021-88886666'});
    expect(request.uri.toString(), isNot(contains('88886666')));
  });

  test('客户：搜索框关键字会匹配手机号，也只在 POST /search 请求体里', () async {
    final sent = <RequestOptions>[];
    final repository = DioClientRepository(ApiClient(_capturing(sent)));
    await repository.list(
      'cat-1',
      keyword: ' 13800138000 ',
      filters: const {'region': '华东'},
    );
    await repository.search('13900139000');
    await repository.search('  ');

    expect(sent[0].method, 'POST');
    expect(sent[0].path, '/master/clients/search');
    expect(sent[0].data, {'keyword': '13800138000'});
    expect(sent[0].uri.toString(), isNot(contains('13800138000')));
    expect(sent[0].queryParameters['region'], '华东');
    expect(sent[1].method, 'POST');
    expect(sent[1].path, '/master/clients/search');
    expect(sent[1].data, {'keyword': '13900139000'});
    expect(sent[1].uri.toString(), isNot(contains('13900139000')));
    // 空关键字：普通 GET，查询串里也没有 keyword
    expect(sent[2].method, 'GET');
    expect(sent[2].queryParameters.containsKey('keyword'), isFalse);
  });

  test('供应商：选择器搜索关键字只在请求体里', () async {
    final sent = <RequestOptions>[];
    await DioSupplierRepository(
      ApiClient(_capturing(sent)),
    ).search('021-88886666', selectableOnly: true);

    final request = sent.single;
    expect(request.method, 'POST');
    expect(request.path, '/master/suppliers/search');
    expect(request.data, {'keyword': '021-88886666'});
    expect(request.queryParameters['selectableOnly'], true);
    expect(request.uri.toString(), isNot(contains('88886666')));
  });

  test('导出：关键字与敏感筛选值一起进请求体', () {
    expect(
      contactSensitiveFilterBody(const {
        'mobile': '13800138000',
      }, keyword: ' 张三 '),
      {'keyword': '张三', 'mobile': '13800138000'},
    );
    expect(contactSensitiveFilterBody(const {}, keyword: '  '), isEmpty);
  });

  test('导出查询串不带敏感筛选值，请求体单独给出', () {
    const filters = {
      'mobile': '13800138000',
      'phone': kMasterFilterNullValue,
      'linkman': '张三',
    };

    final query = masterFilterQueryParams(filters);
    expect(query.containsKey('mobile'), isFalse);
    expect(query['linkman'], '张三');
    expect(query['nullFields'], ['phone']);
    expect(contactSensitiveFilterBody(filters), {'mobile': '13800138000'});
  });
}
