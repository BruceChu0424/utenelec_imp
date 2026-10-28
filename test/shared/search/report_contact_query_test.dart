import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/shared/search/report_contact_query.dart';

void main() {
  for (final key in ['search.phone', 'f.search.phone']) {
    test(
      'typed contact sentinel stays a literal body value for $key, never an exact-null URL operation',
      () async {
        final requests = <RequestOptions>[];
        final dio = Dio(BaseOptions(baseUrl: 'http://localhost/api'));
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (request, handler) {
              requests.add(request);
              handler.resolve(
                Response<dynamic>(
                  requestOptions: request,
                  statusCode: 200,
                  data: {'rows': <Object>[]},
                ),
              );
            },
          ),
        );
        final query = ReportContactQuery({
          key: '__null__',
          'f.search.name': '客户',
        });
        await query.fetch(ApiClient(dio), '/finance/reports/ar-ap/overview');
        expect(requests.single.method, 'POST');
        expect(requests.single.queryParameters.containsKey(key), isFalse);
        expect(requests.single.uri.toString(), isNot(contains('__null__')));
        expect(requests.single.data, {
          'columnSearch': {'phone': '__null__'},
        });
        expect(
          ReportContactQuery.hasContactUrlValues({key: '__null__'}),
          isTrue,
        );
      },
    );
  }
  test(
    'report contact reads keep full identity terms in body and never put phone or keyword in a URL',
    () async {
      final calls = <RequestOptions>[];
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost/api'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            calls.add(request);
            handler.resolve(
              Response<dynamic>(
                requestOptions: request,
                statusCode: 200,
                data: {'rows': <Object>[]},
              ),
            );
          },
        ),
      );
      final original = <String, dynamic>{
        'keyword': '私有关键字',
        'f.search.phone': '013_% 号码',
        'f.search.name': '客户_%',
        'page': 2,
        'size': 50,
        'includeCount': false,
        'sort': 'amount',
        'order': 'desc',
      };
      final query = ReportContactQuery(original);
      original['f.search.phone'] = 'later mutation';
      await query.fetch(ApiClient(dio), '/finance/reports/ar-ap/overview');
      expect(calls.single.method, 'POST');
      expect(calls.single.path, '/finance/reports/ar-ap/overview/search');
      expect(
        calls.single.queryParameters,
        containsPair('f.search.name', '客户_%'),
      );
      expect(calls.single.queryParameters, containsPair('page', 2));
      expect(calls.single.queryParameters, containsPair('includeCount', false));
      expect(calls.single.uri.toString(), isNot(contains('013_')));
      expect(calls.single.queryParameters.containsKey('keyword'), isFalse);
      expect(calls.single.data, {
        'keyword': '私有关键字',
        'columnSearch': {'phone': '013_% 号码'},
      });
      expect(query.exportBody, {'sensitiveFilter': query.body});
      expect(() => query.body['new'] = 'no', throwsUnsupportedError);
    },
  );
  test(
    'ordinary report reads retain the GET contract and do not add an empty sensitive body',
    () async {
      final calls = <RequestOptions>[];
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost/api'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            calls.add(request);
            handler.resolve(
              Response<dynamic>(
                requestOptions: request,
                statusCode: 200,
                data: {'rows': <Object>[]},
              ),
            );
          },
        ),
      );
      final query = ReportContactQuery({
        'f.search.amount': '>=0.0001',
        'page': 1,
      });
      await query.fetch(ApiClient(dio), '/finance/reports/ar-ap/overview');
      expect(calls.single.method, 'GET');
      expect(calls.single.queryParameters, {
        'f.search.amount': '>=0.0001',
        'page': 1,
      });
      expect(query.exportBody, isEmpty);
    },
  );
  test(
    'durable private report parameters retain contact headers, ordinary criteria and exact decimals without a second envelope',
    () {
      final query = ReportContactQuery({
        'f.search.phone': '013_%',
        'f.search.amount': '>90071992547409.0001',
        'keyword': '私有关键字',
        'sort': 'amount',
        'order': 'desc',
      });
      final parameters = reportContactExportJobParameters(
        query.query,
        query.exportBody,
      );
      expect(parameters, {
        'f.search.phone': '013_%',
        'f.search.amount': '>90071992547409.0001',
        'keyword': '私有关键字',
        'sort': 'amount',
        'order': 'desc',
      });
      expect(parameters.containsKey('sensitiveFilter'), isFalse);
      expect(
        () => reportContactExportJobParameters({
          'f.search.phone': 'unsafe-url',
        }, {}),
        throwsFormatException,
      );
      expect(
        () => reportContactExportJobParameters({}, {
          'sensitiveFilter': {
            'columnSearch': {'amount': 'unapproved'},
          },
        }),
        throwsFormatException,
      );
    },
  );
}
