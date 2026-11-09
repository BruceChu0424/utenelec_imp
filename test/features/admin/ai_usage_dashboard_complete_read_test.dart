import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/admin/models/ai_usage_dashboard_models.dart';
import 'package:uten_imp/features/admin/repositories/ai_usage_dashboard_repository.dart';
import 'package:uten_imp/shared/paging/complete_paged_snapshot.dart'
    show CompleteReadBatchPlan;
import 'package:uten_imp/shared/paging/paged_read_intent.dart';

import '../../support/complete_read_plan_batches.dart';

const _people = 501;

final _batches = completeReadPlanBatches(_people);

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
      expect(
        api.reads
            .skip(1)
            .map(
              (read) =>
                  (page: read.$2['page'] as int, size: read.$2['size'] as int),
            ),
        _batches,
      );
    },
  );

  test(
    'retiring an incomplete dashboard read prevents subsequent batches',
    () async {
      // The held continuation must leave at least one more batch to start.
      expect(_batches.length, greaterThan(2));
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
      api.second!.complete(api.page(_batches[1].page, _batches[1].size));
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
      // The summary, the first batch and the overlapping continuation.
      expect(api.reads, hasLength(3));
    },
  );
}

class _Api extends ApiClient {
  _Api() : super(Dio());
  final reads = <(String, Map<String, dynamic>)>[];
  // Holds the first continuation batch (the second people request).
  Completer<Map<String, dynamic>>? second;
  // The first row of the first continuation batch repeats person-0.
  bool overlap = false;
  bool badPage = false, badSummary = false;
  int _peopleReads = 0;

  /// The server's exact slice: people [(page - 1) * size, page * size).
  Map<String, dynamic> page(int page, int size) => {
    'items': [
      for (
        var index = (page - 1) * size;
        index < page * size && index < _people;
        index++
      )
        {
          'userId':
              overlap &&
                  index == CompleteReadBatchPlan.progressive.firstBatchSize
              ? 'person-0'
              : 'person-$index',
          'name': '员工$index',
          'code': '$index',
          'deleted': index == _people - 1,
          'disabled': index == _people - 1,
          'dailyTokenLimit': null,
          'dailyJobLimit': 5,
          'todayTokens': 7,
          'windowTokens': 9,
          'windowCalls': 2,
          'rowVersion': 13,
        },
    ],
    'page': page,
    'size': size,
    'total': _people,
    'totalPages': (_people + size - 1) ~/ size,
  };

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    reads.add((path, {...?query}));
    if (path.endsWith('/people')) {
      if (badPage) return {};
      if (++_peopleReads == 2 && second != null) return second!.future;
      return page(query!['page'] as int, query['size'] as int);
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
