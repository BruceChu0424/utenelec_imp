import '../../core/network/api_client.dart';
import '../models/procurement_commercial_terms.dart';

/// Keeps large order defaults within URL limits and bounds concurrent reads.
Future<Map<String, ProcurementLastTerms>> loadProcurementTerms(
  ApiClient api,
  String path,
  Set<String> goodsIds,
) async {
  final ids = goodsIds.toList(growable: false);
  final result = <String, ProcurementLastTerms>{};
  const batchSize = 100;
  const concurrency = 2;
  for (var offset = 0; offset < ids.length; offset += batchSize * concurrency) {
    final requests = <Future<void>>[];
    for (var worker = 0; worker < concurrency; worker++) {
      final start = offset + worker * batchSize;
      if (start >= ids.length) break;
      final batch = ids.skip(start).take(batchSize).toSet();
      requests.add(() async {
        final json = await api.get(path, query: {'goodsIds': batch.join(',')});
        for (final entry in json.entries) {
          if (batch.contains(entry.key) &&
              entry.value is Map<String, dynamic>) {
            result[entry.key] = ProcurementLastTerms.fromJson(
              entry.value as Map<String, dynamic>,
            );
          }
        }
      }());
    }
    await Future.wait(requests);
  }
  return result;
}
