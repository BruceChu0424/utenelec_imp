import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/admin/models/ai_usage_dashboard_models.dart';
import 'package:uten_imp/features/admin/repositories/ai_usage_dashboard_repository.dart';
import 'package:uten_imp/shared/paging/paged_read_intent.dart';

void main() {
  for (final badSummary in [false, true]) {
    test(
      'malformed ${badSummary ? 'window' : 'page'} response cannot masquerade as a complete empty dashboard',
      () async {
        final api = _Api()
          ..badPage = !badSummary
          ..badSummary = badSummary;
        await expectLater(
          DioAiUsageDashboardRepository(api).dashboard(AiUsageWindow.year),
          throwsA(
            isA<ApiException>().having(
              (error) => error.code,
              'code',
              'INVALID_RESPONSE',
            ),
          ),
        );
        expect(api.reads, hasLength(badSummary ? 1 : 2));
      },
    );
  }
  test(
    'dashboard reads all 501 people in bounded batches and retains authoritative summary and limits',
    () async {
      final api = _Api();
      final result = await DioAiUsageDashboardRepository(
        api,
      ).dashboard(AiUsageWindow.day);
      expect(result.people, hasLength(501));
      expect(result.people.map((row) => row.userId).toSet(), hasLength(501));
      expect(result.todayTokens, 123456);
      expect(result.people.last.userId, 'person-500');
      expect(result.people.last.deleted, isTrue);
      expect(result.people.last.disabled, isTrue);
      expect(result.people.last.dailyTokenLimit, isNull);
      expect(result.people.last.rowVersion, 13);
      expect(api.reads.first.$2, {'window': 'day', 'includePeople': false});
      expect(api.reads.skip(1).map((read) => read.$2['page']), [
        1,
        2,
        3,
        4,
        5,
        6,
      ]);
      expect(api.reads.skip(1).every((read) => read.$2['size'] == 100), isTrue);
    },
  );

  test(
    'retiring an incomplete dashboard read prevents subsequent batches',
    () async {
      final api = _Api()..second = Completer<Map<String, dynamic>>();
      var current = true;
      final read = PagedReadIntent.scopedRead(
        () => current,
        () => DioAiUsageDashboardRepository(api).dashboard(AiUsageWindow.hour),
      );
      final failure = expectLater(read, throwsA(anything));
      while (api.reads.length < 3) {
        await Future<void>.delayed(Duration.zero);
      }
      current = false;
      api.second!.complete(api.page(2));
      await failure;
      expect(api.reads, hasLength(3));
    },
  );

  test(
    'overlapping person identities cannot publish a partial complete dashboard',
    () async {
      final api = _Api()..overlap = true;
      await expectLater(
        DioAiUsageDashboardRepository(api).dashboard(AiUsageWindow.year),
        throwsA(
          isA<ApiException>().having(
            (error) => error.code,
            'code',
            'SNAPSHOT_CHANGED',
          ),
        ),
      );
      expect(api.reads, hasLength(3));
    },
  );
}

class _Api extends ApiClient {
  _Api() : super(Dio());
  final reads = <(String, Map<String, dynamic>)>[];
  Completer<Map<String, dynamic>>? second;
  bool overlap = false;
  bool badPage = false, badSummary = false;

  Map<String, dynamic> page(int page) => {
    'items': [
      for (
        var index = (page - 1) * 100;
        index < page * 100 && index < 501;
        index++
      )
        {
          'userId': overlap && page == 2 && index == 100
              ? 'person-0'
              : 'person-$index',
          'name': '员工$index',
          'code': '$index',
          'deleted': index == 500,
          'disabled': index == 500,
          'dailyTokenLimit': null,
          'dailyJobLimit': 5,
          'todayTokens': 7,
          'windowTokens': 9,
          'windowCalls': 2,
          'rowVersion': 13,
        },
    ],
    'page': page,
    'size': 100,
    'total': 501,
    'totalPages': 6,
  };

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    reads.add((path, {...?query}));
    if (path.endsWith('/people')) {
      if (badPage) return {};
      final number = query!['page'] as int;
      if (number == 2 && second != null) return second!.future;
      return page(number);
    }
    return {
      'window': badSummary ? 'day' : query!['window'],
      'todayTokens': 123456,
      'dailyTokenBudget': 3000000,
      'todayCalls': 42,
      'activeUsersToday': 2,
      'disabledCount': 1,
      'series': <Object?>[],
      'people': <Object?>[],
    };
  }
}
