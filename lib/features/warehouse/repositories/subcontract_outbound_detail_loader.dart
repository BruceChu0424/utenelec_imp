import '../../subcontract/models/subcontract_doc.dart';
import '../models/subcontract_outbound.dart';

/// 一张委外领料单的拣货视图 [task] 与它自己的出仓单草稿 [document]
/// (同一个 issueId, 拣货明细按 issueItemId 对上草稿明细)。
class SubcontractOutboundReadBundle {
  const SubcontractOutboundReadBundle({
    required this.task,
    required this.document,
  });
  final OutboundTaskDetail task;
  final SubcontractDocDetail document;
}

/// Independent reads share a fixed concurrency limit. No generation or write
/// belongs in this loader; submission still rechecks each reviewed document.
Future<List<SubcontractOutboundReadBundle>> loadSubcontractOutboundDetails({
  required Iterable<String> issueIds,
  required Future<OutboundTaskDetail> Function(String) taskDetail,
  required Future<SubcontractDocDetail> Function(String) documentDetail,
}) async {
  final ids = issueIds.toSet().toList();
  final tasks = await readOutboundInBatches(ids, taskDetail);
  final documents = await readOutboundInBatches(ids, documentDetail);
  return [
    for (var index = 0; index < ids.length; index++)
      SubcontractOutboundReadBundle(
        task: tasks[index],
        document: documents[index],
      ),
  ];
}

Future<List<T>> readOutboundInBatches<K, T>(
  List<K> keys,
  Future<T> Function(K) read,
) async {
  final result = <T>[];
  for (var offset = 0; offset < keys.length; offset += 4) {
    result.addAll(await Future.wait(keys.skip(offset).take(4).map(read)));
  }
  return result;
}
