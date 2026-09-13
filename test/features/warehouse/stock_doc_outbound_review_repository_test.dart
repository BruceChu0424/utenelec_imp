import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/warehouse/models/stock_doc.dart';
import 'package:uten_imp/features/warehouse/repositories/stock_doc_repository.dart';

void main() {
  test(
    'review and approval preserve the server token and use distinct endpoints',
    () async {
      final requests = <RequestOptions>[];
      final token = List.filled(64, 'a').join();
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            requests.add(request);
            handler.resolve(
              Response<dynamic>(
                requestOptions: request,
                statusCode: 200,
                data: request.method == 'GET'
                    ? {
                        'document': {
                          'id': 'doc-1',
                          'docType': 'OTHER_OUT',
                          'status': 0,
                        },
                        'reviewToken': token,
                      }
                    : {'id': 'doc-1', 'docType': 'OTHER_OUT', 'status': 1},
              ),
            );
          },
        ),
      );
      final repo = StockDocRepository(ApiClient(dio), StockDocType.otherOut);
      final review = await repo.review('doc-1');
      expect(review.document.status, 0);
      final result = await repo.approveReviewed(
        'doc-1',
        expectedReviewToken: review.reviewToken,
      );
      expect(result.status, 1);
      expect(requests.map((r) => r.path), [
        '/stock/docs/doc-1/outbound-review',
        '/stock/docs/doc-1/approve-reviewed',
      ]);
      expect(requests.last.data, {'expectedReviewToken': token});
    },
  );

  test('malformed review responses fail closed', () {
    expect(
      () => StockDocOutboundReview.fromJson({
        'document': {'id': 'doc-1'},
      }),
      throwsFormatException,
    );
    expect(
      () => StockDocOutboundReview.fromJson({
        'document': {'id': 'doc-1'},
        'reviewToken': 'short',
      }),
      throwsFormatException,
    );
  });
}
