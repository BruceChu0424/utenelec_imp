import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/repositories/mould_repository.dart';

void main() {
  test('模具名称和系列分类列关键词与子树、分页同时传给服务端', () async {
    RequestOptions? sent;
    final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          sent = request;
          handler.resolve(
            Response<dynamic>(
              requestOptions: request,
              statusCode: 200,
              data: {
                'items': [
                  {
                    'id': 'mould-1',
                    'name': '双联开关模具',
                    'categoryId': 'child-category',
                    'categoryName': 'Q7开关子系列',
                  },
                ],
                'total': 2,
                'page': 2,
                'size': 1,
              },
            ),
          );
        },
      ),
    );
    final result = await DioMouldRepository(ApiClient(dio)).list(
      'root-category',
      page: 2,
      size: 1,
      filters: const {'search.name': '开关', 'search.categoryName': 'Q7'},
    );
    expect(sent!.queryParameters, {
      'categoryId': 'root-category',
      'page': 2,
      'size': 1,
      'search.name': '开关',
      'search.categoryName': 'Q7',
    });
    expect(result.items.single.categoryName, 'Q7开关子系列');
    expect(result.items.single.categoryId, 'child-category');
    expect(result.total, 2);
  });
}
