// 识别客户文件的两个小接口: 用文件信息新建客户(409 已存在 → 可见时带 id), 货品英文名批量查。
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_error.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/sales/intake/sales_intake_models.dart';
import 'package:uten_imp/features/sales/intake/sales_intake_repository.dart';

class _Api extends ApiClient {
  _Api({this.postResult, this.postError}) : super(Dio());

  final Map<String, dynamic>? postResult;
  final ApiException? postError;
  String? postPath;
  Object? postBody;
  final lookupQueries = <Map<String, dynamic>?>[];

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    postPath = path;
    postBody = body;
    final e = postError;
    if (e != null) throw e;
    return postResult ?? const {};
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    expect(path, '/master/goods/lookup');
    lookupQueries.add(query);
    final ids = '${query!['ids']}'.split(',');
    return [
      for (final id in ids)
        {
          'id': id,
          'code': 'C-$id',
          if (id.endsWith('1')) 'nameEn': ' ONE GANG SWITCH ',
          if (id.endsWith('2')) 'nameEn': '',
        },
    ];
  }
}

const _proposal = SalesIntakeNewClientProposal(
  name: 'ALDAR',
  fullName: 'ALDAR FOR ELECTRICAL INDUSTRIES CO. LTD.',
  email: 'info@aldar.example',
  placeId: '约旦',
);

void main() {
  test('新建客户: 提交文件信息, 返回新客户 id', () async {
    final api = _Api(postResult: {'clientId': 'c-new'});
    final id = await DioSalesIntakeRepository(
      api,
    ).createClientFromDocument(_proposal);
    expect(id, 'c-new');
    expect(api.postPath, '/master/clients/from-document');
    expect(api.postBody, {
      'name': 'ALDAR',
      'fullName': 'ALDAR FOR ELECTRICAL INDUSTRIES CO. LTD.',
      'email': 'info@aldar.example',
      'placeId': '约旦',
    });
  });

  test('新建客户: 409 且客户对我可见 → 带回已有客户 id', () async {
    final api = _Api(
      postError: ApiException(
        'CONFLICT',
        '这个客户已经存在',
        httpStatus: 409,
        fieldErrors: const [
          ApiFieldError(
            field: 'existingClientId',
            message: '0b9f3a52-7c1e-4b8e-9e61-2f1a1c2d3e4f',
          ),
        ],
      ),
    );
    await expectLater(
      DioSalesIntakeRepository(api).createClientFromDocument(_proposal),
      throwsA(
        isA<SalesIntakeClientExists>().having(
          (e) => e.existingClientId,
          'existingClientId',
          '0b9f3a52-7c1e-4b8e-9e61-2f1a1c2d3e4f',
        ),
      ),
    );
  });

  test('新建客户: 409 且客户不可见 → 不带 id, 只给大白话', () async {
    final api = _Api(
      postError: ApiException(
        'CONFLICT',
        '这个客户可能已由其他业务员负责, 请联系主管分配',
        httpStatus: 409,
      ),
    );
    await expectLater(
      DioSalesIntakeRepository(api).createClientFromDocument(_proposal),
      throwsA(
        isA<SalesIntakeClientExists>()
            .having((e) => e.existingClientId, 'existingClientId', isNull)
            .having((e) => e.message, 'message', contains('联系主管')),
      ),
    );
  });

  test('新建客户: 其它错误原样抛出; 没有返回 id 视为格式错误', () async {
    final forbidden = _Api(
      postError: ApiException('FORBIDDEN', '无权限访问', httpStatus: 403),
    );
    await expectLater(
      DioSalesIntakeRepository(forbidden).createClientFromDocument(_proposal),
      throwsA(isA<ApiException>()),
    );
    await expectLater(
      DioSalesIntakeRepository(_Api()).createClientFromDocument(_proposal),
      throwsFormatException,
    );
  });

  test('货品英文名: 每批最多 100 个 id, 空英文名不返回, 去首尾空格', () async {
    final api = _Api();
    final ids = [for (var i = 0; i < 205; i++) 'g$i'];
    final result = await DioSalesIntakeRepository(
      api,
    ).goodsNameEn([...ids, 'g1', '']);
    expect(api.lookupQueries, hasLength(3));
    expect('${api.lookupQueries.first!['ids']}'.split(','), hasLength(100));
    expect(result['g1'], 'ONE GANG SWITCH');
    expect(result.containsKey('g2'), isFalse);
    expect(result.containsKey('g0'), isFalse);
  });
}
