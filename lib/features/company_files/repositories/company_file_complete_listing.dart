import 'dart:convert';

import '../../../shared/models/paged_result.dart';
import '../../../shared/paging/complete_paged_snapshot.dart';
import '../models/company_file.dart';
import 'company_file_repository.dart';

/// Keeps the library's zero-based API and directory ACL facts at its boundary.
extension CompanyFileCompleteListing on CompanyFileRepository {
  Future<CompanyFileListing> readCompleteListing({
    required bool Function() isCurrent,
    String? parentId,
    String search = '',
    String sort = 'name',
    String direction = 'asc',
    bool trash = false,
    Map<String, String?> columnFilters = const {},
  }) async {
    CompanyFileListing? first;
    final filters = Map<String, String?>.unmodifiable(columnFilters);
    final result = await loadCompletePagedResult<CompanyFile>(
      isCurrent: isCurrent,
      idOf: (entry) => entry.id,
      loadPage: (page, size) async {
        final listing = await list(
          parentId: parentId,
          search: search,
          sort: sort,
          direction: direction,
          trash: trash,
          page: page - 1,
          size: size,
          columnFilters: filters,
        );
        first ??= listing;
        return _CompanyListingPage(listing);
      },
    );
    return first!.withEntries(result.items);
  }
}

/// An ACL/path change retires the whole query, including an otherwise valid
/// later batch. No missing server publication version is invented locally.
class _CompanyListingPage extends PagedResult<CompanyFile>
    implements PagedResultRevision {
  _CompanyListingPage(CompanyFileListing value)
    : snapshotRevision = jsonEncode([
        value.folder?.id,
        value.folder?.version,
        value.folder?.locked,
        value.folder?.deleted,
        value.folder?.allowedActions.toList()?..sort(),
        value.breadcrumbs.map((entry) => [entry.id, entry.name]).toList(),
        value.allowedActions.toList()..sort(),
        value.canReorder,
      ]),
      super(
        items: value.entries,
        page: value.page + 1,
        size: value.size,
        total: value.total,
        totalPages: value.size <= 0 ? -1 : (value.total / value.size).ceil(),
        readScopeVersion: value.readScopeVersion,
      );

  @override
  final Object snapshotRevision;
}
