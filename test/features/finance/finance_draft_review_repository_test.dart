import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/finance/models/finance_doc.dart';
import 'package:uten_imp/features/finance/repositories/finance_repository.dart';

void main() {
  for (final type in FinanceDocType.values) {
    test(
      '${type.name} review preserves snapshot, version and exact financial inputs',
      () async {
        final api = _ReviewApi();
        final repository = FinanceRepository(api, type);
        final review = await repository.review('draft-1');
        expect(api.getPath, '/finance/${type.pathSegment}/draft-1/review');
        expect(review.snapshot, 'a' * 64);
        expect(review.detail.id, 'draft-1');
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
        final approved = await repository.saveReviewed(
          'draft-1',
          input,
          review.snapshot,
        );
        expect(api.postPath, api.getPath);
        expect(api.postBody, {
          'expectedSnapshot': review.snapshot,
          'document': input,
          'approveNow': true,
        });
        expect(approved.status, kFinanceStatusApproved);
      },
    );
  }
}

class _ReviewApi extends ApiClient {
  _ReviewApi() : super(Dio());
  String? getPath;
  String? postPath;
  Object? postBody;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    getPath = path;
    return {
      'snapshot': 'a' * 64,
      'detail': {
        'id': 'draft-1',
        'status': 0,
        'version': 7,
        'items': <Object>[],
      },
    };
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
