import '../../../shared/models/paged_result.dart';

/// Complete master reads keep the existing repository API available to bounded
/// consumers while page owners use one authenticated transport request.
abstract interface class FlatMasterSummaryGateway<T> {
  Future<PagedResult<T>> completeList({
    String? keyword,
    Map<String, String?> filters = const {},
    String? sort,
    String? order,
  });
}

Future<PagedResult<T>> Function()? completeFlatMasterList<T>(
  Object repository, {
  String? keyword,
  Map<String, String?> filters = const {},
  String? sort,
  String? order,
}) {
  if (repository is! FlatMasterSummaryGateway<T>) return null;
  final captured = Map<String, String?>.unmodifiable(filters);
  return () => repository.completeList(
    keyword: keyword,
    filters: captured,
    sort: sort,
    order: order,
  );
}
