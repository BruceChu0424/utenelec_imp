import '../../subcontract/models/subcontract_doc.dart';
import '../models/subcontract_outbound.dart';

class SubcontractOutboundReadBundle {
  const SubcontractOutboundReadBundle({
    required this.task,
    required this.documents,
  });
  final OutboundTaskDetail task;
  final List<SubcontractDocDetail> documents;
}

/// Independent reads share a fixed concurrency limit. No generation or write
/// belongs in this loader; submission still rechecks each reviewed document.
Future<List<SubcontractOutboundReadBundle>> loadSubcontractOutboundDetails({
  required Iterable<String> planIds,
  required Future<OutboundTaskDetail> Function(String) taskDetail,
  required Future<SubcontractDocDetail> Function(String) documentDetail,
}) async {
  final tasks = await readOutboundInBatches(
    planIds.toSet().toList(),
    taskDetail,
  );
  final ids = {
    for (final task in tasks)
      for (final draft in task.drafts)
        if (draft.status == 0) draft.issueId,
  };
  final documents = await readOutboundInBatches(ids.toList(), documentDetail);
  final byId = {for (final document in documents) document.id: document};
  return [
    for (final task in tasks)
      SubcontractOutboundReadBundle(
        task: task,
        documents: [
          for (final draft in task.drafts)
            if (draft.status == 0) byId[draft.issueId]!,
        ],
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
