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
import 'package:uten_imp/features/basic_data/repositories/mould_repository.dart';

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
  test('客户和供应商敏感列关键词只进 body，普通列关键词保留在 query', () async {
    final sent = <RequestOptions>[];
    final api = ApiClient(_capturing(sent));
    const filters = {
      'search.mobile': '13800',
      'search.bankAccount': '6222',
      'search.name': '电器 开关',
      'place': '广东',
    };
    await DioClientRepository(api).listGlobal(filters: filters);
    await DioSupplierRepository(api).listGlobal(filters: filters);
    for (final request in sent) {
      expect(request.method, 'POST');
      expect(request.queryParameters['search.name'], '电器 开关');
      expect(request.queryParameters['place'], '广东');
      expect(request.queryParameters.containsKey('search.mobile'), isFalse);
      expect(
        request.queryParameters.containsKey('search.bankAccount'),
        isFalse,
      );
      expect(request.data, {
        'columnSearch': {'mobile': '13800', 'bankAccount': '6222'},
      });
      expect(request.uri.toString(), isNot(contains('13800')));
      expect(request.uri.toString(), isNot(contains('6222')));
    }
    expect(masterFilterQueryParams(filters), {
      'search.name': '电器 开关',
      'place': '广东',
    });
  });

  test('全局主档表头选项省略分类，客户默认仍排除旧财务占位', () async {
    final sent = <RequestOptions>[];
    final api = ApiClient(_capturing(sent));
    await DioClientRepository(api).globalFacets();
    await DioClientRepository(
      api,
    ).globalFacets(excludeLegacyFinanceStub: false);
    await DioSupplierRepository(api).globalFacets();
    await DioMouldRepository(api).globalFacets();
    expect(sent.map((r) => r.method), everyElement('GET'));
    expect(sent.map((r) => r.path), [
      '/master/clients/facets',
      '/master/clients/facets',
      '/master/suppliers/facets',
      '/master/moulds/facets',
    ]);
    expect(sent.map((r) => r.queryParameters), [
      {'excludeLegacyFinanceStub': true},
      {'excludeLegacyFinanceStub': false},
      <String, dynamic>{},
      <String, dynamic>{},
    ]);
  });

  test('客户全局结果不传分类，分页排序/可选范围保留且敏感条件仍只进body', () async {
    final sent = <RequestOptions>[];
    await DioClientRepository(ApiClient(_capturing(sent))).listGlobal(
      page: 3,
      size: 37,
      keyword: ' 13800138000 ',
      sort: 'name',
      order: 'asc',
      excludeLegacyFinanceStub: false,
      selectableOnly: true,
      filters: const {
        'mobile': '13900139000',
        'phone2': kMasterFilterNullValue,
        'region': '华东',
      },
    );
    final request = sent.single;
    expect(request.method, 'POST');
    expect(request.queryParameters, {
      'page': 3,
      'size': 37,
      'sort': 'name',
      'order': 'asc',
      'excludeLegacyFinanceStub': false,
      'selectableOnly': true,
      'region': '华东',
      'nullFields': ['phone2'],
    });
    expect(request.data, {'keyword': '13800138000', 'mobile': '13900139000'});
    expect(request.uri.toString(), isNot(contains('13800138000')));
    expect(request.uri.toString(), isNot(contains('13900139000')));
  });

  test('供应商全局结果保留筛选排序，电话和关键词不进入URL', () async {
    final sent = <RequestOptions>[];
    await DioSupplierRepository(ApiClient(_capturing(sent))).listGlobal(
      page: 2,
      size: 25,
      keyword: ' 测试供应商 ',
      sort: 'name',
      order: 'desc',
      selectableOnly: true,
      filters: const {
        'phone': '021-88886666',
        'place': '杭州',
        'bankAccount': kMasterFilterNullValue,
      },
    );
    final request = sent.single;
    expect(request.queryParameters, {
      'page': 2,
      'size': 25,
      'sort': 'name',
      'order': 'desc',
      'selectableOnly': true,
      'place': '杭州',
      'nullFields': ['bankAccount'],
    });
    expect(request.data, {'keyword': '测试供应商', 'phone': '021-88886666'});
    expect(request.uri.toString(), isNot(contains('测试供应商')));
    expect(request.uri.toString(), isNot(contains('88886666')));
  });

  test('模具全局结果与原分类列表共用过滤参数，仅分类范围不同', () async {
    final sent = <RequestOptions>[];
    final repo = DioMouldRepository(ApiClient(_capturing(sent)));
    await repo.listGlobal(
      page: 2,
      size: 35,
      keyword: ' 模具 ',
      sort: 'name',
      order: 'asc',
      filters: const {
        'manufacturer': '制造商甲',
        'mstatus': kMasterFilterNullValue,
      },
    );
    expect(sent.single.queryParameters, {
      'page': 2,
      'size': 35,
      'keyword': '模具',
      'sort': 'name',
      'order': 'asc',
      'manufacturer': '制造商甲',
      'nullFields': ['mstatus'],
    });
    await repo.list(
      'cat-1',
      page: 2,
      size: 35,
      keyword: ' 模具 ',
      sort: 'name',
      order: 'asc',
      filters: const {
        'manufacturer': '制造商甲',
        'mstatus': kMasterFilterNullValue,
      },
    );
    expect(sent.last.queryParameters, {
      ...sent.first.queryParameters,
      'categoryId': 'cat-1',
    });
  });

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
