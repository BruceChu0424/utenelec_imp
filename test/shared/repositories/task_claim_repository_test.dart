import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/shared/repositories/task_claim_repository.dart';

class _ClaimApi extends ApiClient {
  _ClaimApi() : super(Dio());
  Object? failure;
  Map<String, dynamic> response = {};
  String? path;
  Map<String, dynamic>? query;
  int reads = 0;
  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    this.path = path;
    this.query = query;
    if (failure case final error?) throw error;
    return response;
  }

  @override
  Future<void> delete(String path) async {
    this.path = path;
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    reads++;
    return response;
  }
}

void main() {
  test(
    'strict claim propagates conflict without falling back to a possibly different lease',
    () async {
      final api = _ClaimApi()..failure = ApiException('CONFLICT', 'held');
      final repo = TaskClaimRepository(api);
      await expectLater(
        repo.claimRequired('SALES_ORDER_FINANCE_CONFIRM', 'a'),
        throwsA(isA<ApiException>()),
      );
      expect(api.reads, 0);
    },
  );
  test(
    'strict heartbeat propagates transport failures and carries the exact lease UUID',
    () async {
      final api = _ClaimApi()..failure = StateError('offline');
      final repo = TaskClaimRepository(api);
      await expectLater(
        repo.heartbeatRequired(
          'PROCUREMENT_FINANCE_APPROVE',
          'case-a',
          expectedClaimId: 'lease-a',
        ),
        throwsStateError,
      );
      expect(
        api.path,
        '/task-claims/PROCUREMENT_FINANCE_APPROVE/case-a/heartbeat',
      );
      expect(api.query, {'expectedClaimId': 'lease-a'});
    },
  );
  test(
    'empty heartbeat is not evidence of ownership; release carries expected UUID',
    () async {
      final api = _ClaimApi();
      final repo = TaskClaimRepository(api);
      expect(
        await repo.heartbeatRequired(
          'SALES_ORDER_FINANCE_CONFIRM',
          'a',
          expectedClaimId: 'lease-a',
        ),
        isNull,
      );
      await repo.releaseRequired(
        'SALES_ORDER_FINANCE_CONFIRM',
        'a',
        expectedClaimId: 'lease-a',
      );
      expect(Uri.parse(api.path!).queryParameters, {
        'expectedClaimId': 'lease-a',
      });
    },
  );
}
