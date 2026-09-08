import 'dart:async';
import 'package:dio/dio.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/shared/models/task_claim_view.dart';
import 'package:uten_imp/shared/repositories/task_claim_repository.dart';

/// Explicit live lease fixture; negative cases fail each RPC independently.
class FinanceClaimFixture extends TaskClaimRepository {
  FinanceClaimFixture() : super(ApiClient(Dio()));
  bool failClaim = false;
  String? failClaimKey;
  bool failHeartbeat = false;
  bool loseLease = false;
  Completer<TaskClaimView?>? pendingClaim;
  final Map<String, TaskClaimView> leases = {};
  final List<String> acquired = [];
  final List<String> renewed = [];
  final List<String> released = [];
  int _sequence = 0;
  TaskClaimView lease(String type, String key, {String? id}) => TaskClaimView(
    claimId: id ?? 'lease-$type-$key-${++_sequence}',
    targetType: type,
    targetKey: key,
    claimedBy: 'finance-reviewer',
    claimedByName: '财务审核员',
    claimedByMe: true,
    claimedAt: DateTime.now().toUtc(),
    leaseUntil: DateTime.now().toUtc().add(const Duration(minutes: 30)),
  );
  @override
  Future<TaskClaimView?> claimRequired(String type, String key) async {
    acquired.add(key);
    if (failClaim || failClaimKey == key) {
      throw StateError('claim network failure');
    }
    if (pendingClaim case final pending?) return pending.future;
    return leases.putIfAbsent(key, () => lease(type, key));
  }

  @override
  Future<TaskClaimView?> heartbeatRequired(
    String type,
    String key, {
    required String expectedClaimId,
  }) async {
    renewed.add(key);
    if (failHeartbeat) throw StateError('heartbeat network failure');
    if (loseLease) return lease(type, key, id: 'replacement-lease');
    final held = leases[key];
    if (held?.claimId != expectedClaimId) throw StateError('old lease');
    return held;
  }

  @override
  Future<void> releaseRequired(
    String type,
    String key, {
    required String expectedClaimId,
  }) async {
    released.add(expectedClaimId);
    if (leases[key]?.claimId == expectedClaimId) leases.remove(key);
  }
}
