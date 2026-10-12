import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/finance/models/finance_doc.dart';
import 'package:uten_imp/features/finance/repositories/finance_repository.dart';

void main() {
  for (final type in FinanceDocType.values) {
    test('${type.name} 普通草稿保存保持精确金额，审核只提交决定', () async {
      final api = _ReviewApi();
      final repository = FinanceRepository(api, type);
      final detail = await repository.detail('draft-1');
      expect(api.getPath, '/finance/${type.pathSegment}/draft-1');
      expect(detail.id, 'draft-1');
      final input = <String, dynamic>{
        'expectedVersion': 7,
        'amountOriginal': '9007199254740993.123456789',
        'accountAmount': '9007199254740993.123456789',
        'items': [
          {
            'appliedLedgerId': 'source-1',
            'amountOriginal': '0.000000123456789',
          },
        ],
      };
      await repository.update('draft-1', input);
      expect(api.putPath, api.getPath);
      expect(api.putBody, input);
      final approved = await repository.approve('draft-1');
      expect(api.postPath, '/finance/${type.pathSegment}/draft-1/approve');
      expect(api.postBody, isNull);
      expect(approved.status, kFinanceStatusApproved);
    });
  }
}

class _ReviewApi extends ApiClient {
  _ReviewApi() : super(Dio());
  String? getPath;
  String? postPath;
  Object? postBody;
  String? putPath;
  Object? putBody;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    getPath = path;
    return {'id': 'draft-1', 'status': 0, 'version': 7, 'items': <Object>[]};
  }

  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async {
    putPath = path;
    putBody = body;
    return {'id': 'draft-1', 'status': 0, 'items': <Object>[]};
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    Map<String, dynamic>? headers,
  }) async {
    postPath = path;
    postBody = body;
    return {'id': 'draft-1', 'status': 1, 'items': <Object>[]};
  }
}
