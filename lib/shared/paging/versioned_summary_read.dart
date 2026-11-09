import '../../core/network/api_exception.dart';
import '../models/paged_result.dart';
import 'complete_paged_snapshot.dart';

class _VersionedSummaryPage<T> extends PagedResult<T>
    implements VersionedPagedResultProof {
  _VersionedSummaryPage(
    PagedResult<T> page,
    this.readSnapshotRevision,
    this.readDataVersion,
  ) : super(
        items: page.items,
        page: page.page,
        size: page.size,
        total: page.total,
        totalPages: page.totalPages,
        totals: page.totals,
        facets: page.facets,
        facetNullCounts: page.facetNullCounts,
        readScopeVersion: page.readScopeVersion,
      );

  @override
  Object get snapshotRevision => (readSnapshotRevision, readDataVersion);
  @override
  final String readSnapshotRevision;
  @override
  final String? readDataVersion;
}

/// Accepted summary facts plus the server revision needed by an explicitly
/// opened detail/editor. A token belongs to this exact summary query only;
/// a separate options query must capture its own first revision.
class VersionedSummarySnapshot<T> {
  const VersionedSummarySnapshot({
    required this.page,
    required this.revision,
    required this.readScopeVersion,
    this.dataVersion,
    this.metadata = const {},
  });
  final PagedResult<T> page;
  List<T> get items => page.items;
  final String revision;
  final String? readScopeVersion;
  final String? dataVersion;
  final Map<String, dynamic> metadata;
}

/// Reads a complete immutable summary query through the existing bounded
/// reader. No money, units, business lifecycle or write intent is inferred.
///
/// The first data revision is sent with every subsequent page. Auth/query
/// ownership remains a separate caller fence. Legacy prefix-only responses
/// must fail clearly instead of being presented as complete summaries.
Future<List<T>> readCompleteVersionedSummaries<T>({
  required Future<Map<String, dynamic>> Function(
    int page,
    int size,
    String? snapshotRevision,
  )
  loadPage,
  required bool Function() isCurrent,
  int batchSize = 100,
  int maxConcurrentPages = 1,
  required T Function(Map<String, dynamic> row) decode,
  required Object? Function(T row) idOf,
}) async => (await readVersionedSummarySnapshot<T>(
  loadPage: loadPage,
  isCurrent: isCurrent,
  batchSize: batchSize,
  maxConcurrentPages: maxConcurrentPages,
  decode: decode,
  idOf: idOf,
)).items;

Future<VersionedSummarySnapshot<T>> readVersionedSummarySnapshot<T>({
  required Future<Map<String, dynamic>> Function(
    int page,
    int size,
    String? snapshotRevision,
  )
  loadPage,
  required bool Function() isCurrent,
  int batchSize = 100,
  // A stream transport places each frame by the shared progressive plan; the
  // fixed batch remains the default for paged summary endpoints.
  CompleteReadBatchPlan? plan,
  int maxConcurrentPages = 1,
  required T Function(Map<String, dynamic> row) decode,
  required Object? Function(T row) idOf,
  void Function(PagedResult<T> partial)? onProgressiveBatch,
}) async {
  String? snapshot;
  String? firstAuthority;
  String? firstDataVersion;
  Map<String, dynamic> firstMetadata = const {};
  final result = await loadCompletePagedResult<T>(
    isCurrent: isCurrent,
    batchSize: plan == null ? batchSize : null,
    plan: plan,
    maxConcurrentPages: maxConcurrentPages,
    idOf: idOf,
    onProgressiveBatch: onProgressiveBatch,
    loadPage: (page, size) async {
      final raw = await loadPage(page, size, snapshot);
      final revision = raw['readSnapshotRevision'];
      final authority = raw['readScopeVersion'];
      final dataVersion = raw['readDataVersion'];
      if (raw['items'] is! List ||
          raw['page'] is! int ||
          raw['size'] is! int ||
          raw['total'] is! int ||
          raw['totalPages'] is! int ||
          authority is! String ||
          authority.isEmpty ||
          (raw['readDataVersion'] != null &&
              raw['readDataVersion'] is! String) ||
          revision is! String ||
          revision.isEmpty) {
        throw ApiException(
          'INCOMPLETE_READ_PROTOCOL',
          '服务端尚未提供完整列表读取凭据，请更新服务端后重试',
        );
      }
      if (maxConcurrentPages > 1 &&
          (raw['page'] != page ||
              raw['size'] != size ||
              !RegExp(r'^[0-9a-f]{64}$').hasMatch(revision) ||
              dataVersion is! String ||
              !RegExp(r'^[0-9a-f]{64}$').hasMatch(dataVersion) ||
              authority.length > 256)) {
        throw ApiException('INCOMPLETE_READ_PROTOCOL', '完整列表并发读取凭据无效');
      }
      if (snapshot == null) {
        snapshot = revision;
        firstAuthority = authority;
        firstDataVersion = raw['readDataVersion'] as String?;
        firstMetadata = Map<String, dynamic>.unmodifiable(
          Map<String, dynamic>.of(raw)..remove('items'),
        );
      } else if (raw['readDataVersion'] != firstDataVersion) {
        throw ApiException('SNAPSHOT_CHANGED', '列表已变化，请重新读取');
      }
      final parsed = await PagedResult.fromJsonResponsive<T>(raw, decode);
      return _VersionedSummaryPage<T>(parsed, revision, dataVersion as String?);
    },
  );
  return VersionedSummarySnapshot<T>(
    page: result,
    revision: snapshot!,
    readScopeVersion: firstAuthority,
    dataVersion: firstDataVersion,
    metadata: firstMetadata,
  );
}
