import 'dart:collection';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_endpoints.dart';
import '../providers/session_provider.dart';
import 'measurement_capture_profile.dart';

class MeasurementProfileBatchRequest {
  MeasurementProfileBatchRequest({
    required this.operationFamily,
    required Iterable<String> goodsIds,
  }) : goodsIds = _normalizeGoodsIds(goodsIds);

  final OperationFamily operationFamily;
  final List<String> goodsIds;

  static List<String> _normalizeGoodsIds(Iterable<String> values) {
    final ids = values.map((value) => value.trim()).toSet().toList()..sort();
    if (ids.isEmpty || ids.any((id) => !MeasurementCaptureProfile.isUuid(id))) {
      throw ArgumentError.value(values, 'goodsIds', 'must contain valid UUIDs');
    }
    return List.unmodifiable(ids);
  }

  String get identity => '${operationFamily.code}|${goodsIds.join(',')}';

  @override
  bool operator ==(Object other) =>
      other is MeasurementProfileBatchRequest && other.identity == identity;

  @override
  int get hashCode => identity.hashCode;
}

abstract interface class MeasurementCaptureRepository {
  Future<Map<String, MeasurementCaptureProfile>> resolveBatch(
    MeasurementProfileBatchRequest request,
  );

  Future<MeasurementCaptureProfile> overridePreference({
    required String goodsId,
    required OperationFamily operationFamily,
    required String commandId,
    required String idempotencyKey,
    required int expectedVersion,
    required PrimaryInput primaryInput,
    required String reason,
    String? actualWeightUnitId,
  });

  Future<MeasurementCaptureProfile> clearOverride({
    required String goodsId,
    required OperationFamily operationFamily,
    required String commandId,
    required String idempotencyKey,
    required int expectedVersion,
    required String reason,
  });
}

class DioMeasurementCaptureRepository implements MeasurementCaptureRepository {
  const DioMeasurementCaptureRepository(this._api);

  final ApiClient _api;

  @override
  Future<Map<String, MeasurementCaptureProfile>> resolveBatch(
    MeasurementProfileBatchRequest request,
  ) async {
    final json = await _api.post(
      ApiEndpoints.measurementProfilesResolveBatch,
      body: {
        'operationFamily': request.operationFamily.code,
        'goodsIds': request.goodsIds,
      },
    );
    final rawItems = json['items'];
    if (rawItems is! List) {
      throw const FormatException('Malformed measurement profile batch');
    }
    final parsed = <String, MeasurementCaptureProfile>{};
    for (final raw in rawItems) {
      if (raw is! Map) {
        throw const FormatException('Malformed measurement profile item');
      }
      final profile = MeasurementCaptureProfile.fromJson(
        Map<String, dynamic>.from(raw),
      );
      if (profile.operationFamily != request.operationFamily ||
          !request.goodsIds.contains(profile.goodsId) ||
          parsed.containsKey(profile.goodsId)) {
        throw const FormatException('Measurement profile identity mismatch');
      }
      parsed[profile.goodsId] = profile;
    }
    if (parsed.length != request.goodsIds.length) {
      throw const FormatException('Measurement profile batch is incomplete');
    }
    return UnmodifiableMapView({
      for (final goodsId in request.goodsIds) goodsId: parsed[goodsId]!,
    });
  }

  @override
  Future<MeasurementCaptureProfile> overridePreference({
    required String goodsId,
    required OperationFamily operationFamily,
    required String commandId,
    required String idempotencyKey,
    required int expectedVersion,
    required PrimaryInput primaryInput,
    required String reason,
    String? actualWeightUnitId,
  }) async {
    _requireCommand(goodsId, commandId, expectedVersion, reason);
    final json = await _api.post(
      ApiEndpoints.measurementProfileOverride(goodsId, operationFamily.code),
      body: {
        'commandId': commandId,
        'idempotencyKey': idempotencyKey,
        'expectedVersion': expectedVersion,
        'preference': primaryInput.code,
        'actualWeightUnitId': ?actualWeightUnitId,
        'reason': reason.trim(),
      },
    );
    return _parseSingle(json, goodsId, operationFamily);
  }

  @override
  Future<MeasurementCaptureProfile> clearOverride({
    required String goodsId,
    required OperationFamily operationFamily,
    required String commandId,
    required String idempotencyKey,
    required int expectedVersion,
    required String reason,
  }) async {
    _requireCommand(goodsId, commandId, expectedVersion, reason);
    final json = await _api.post(
      ApiEndpoints.measurementProfileClearOverride(
        goodsId,
        operationFamily.code,
      ),
      body: {
        'commandId': commandId,
        'idempotencyKey': idempotencyKey,
        'expectedVersion': expectedVersion,
        'reason': reason.trim(),
      },
    );
    return _parseSingle(json, goodsId, operationFamily);
  }

  static MeasurementCaptureProfile _parseSingle(
    Map<String, dynamic> json,
    String goodsId,
    OperationFamily operationFamily,
  ) {
    final profile = MeasurementCaptureProfile.fromJson(json);
    if (profile.goodsId != goodsId ||
        profile.operationFamily != operationFamily) {
      throw const FormatException('Measurement profile identity mismatch');
    }
    return profile;
  }

  static void _requireCommand(
    String goodsId,
    String commandId,
    int expectedVersion,
    String reason,
  ) {
    if (!MeasurementCaptureProfile.isUuid(goodsId) ||
        !MeasurementCaptureProfile.isUuid(commandId) ||
        expectedVersion < 0 ||
        reason.trim().length < 2) {
      throw ArgumentError('Invalid measurement profile command');
    }
  }
}

final measurementCaptureRepositoryProvider =
    Provider<MeasurementCaptureRepository>(
      (ref) => DioMeasurementCaptureRepository(ref.watch(apiClientProvider)),
    );

final measurementCaptureProfilesProvider = FutureProvider.autoDispose
    .family<
      Map<String, MeasurementCaptureProfile>,
      MeasurementProfileBatchRequest
    >((ref, request) {
      ref.watch(sessionProvider.select((state) => state.user));
      return ref
          .watch(measurementCaptureRepositoryProvider)
          .resolveBatch(request);
    });
