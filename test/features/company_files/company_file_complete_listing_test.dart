import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/authenticated_request_scope.dart';
import 'package:uten_imp/core/performance/ui_work_budget.dart';
import 'package:uten_imp/features/company_files/models/company_file.dart';
import 'package:uten_imp/features/company_files/repositories/company_file_repository.dart';
import 'package:uten_imp/features/company_files/repositories/company_file_complete_listing.dart';
import 'package:uten_imp/features/company_files/widgets/company_file_dialogs.dart';
import 'package:uten_imp/components/layout/uten_pagination.dart';

import '../../support/complete_read_plan_batches.dart';

const _actions = {'view', 'move', 'create', 'upload'};
CompanyFile _folder(int index) => CompanyFile(
  id: 'folder-$index',
  name: '完整目录$index',
  kind: 'FOLDER',
  version: 4,
  allowedActions: _actions,
);

/// One directory just past the second aligned batch: its last entry arrives
/// alone in the final batch.
const _total = 101;

/// The library API is zero-based: the shared plan's requests one page lower,
/// (0,50) (1,50) (1,100) for this directory.
final _batches = [
  for (final batch in completeReadPlanBatches(_total))
    (page: batch.page - 1, size: batch.size),
];

class _Repository extends CompanyFileRepository {
  _Repository()
    : super(ApiClient(Dio(BaseOptions(baseUrl: 'https://library.test/api'))));
  final reads = <({int page, int size})>[];
  final requests =
      <
        ({
          String? parent,
          String search,
          bool trash,
          Map<String, String?> filters,
        })
      >[];
  // Holds the first continuation batch (the second request).
  Completer<CompanyFileListing>? continuation;
  bool changeAcl = false;

  /// The server's zero-based slice: entries [page * size, page * size + size).
  CompanyFileListing response(int page, int size) => CompanyFileListing(
    entries: [
      for (var index = page * size; index < (page + 1) * size; index++)
        if (index < _total) _folder(index),
    ],
    folder: const CompanyFile(
      id: 'parent',
      name: '原目录',
      kind: 'FOLDER',
      version: 7,
      allowedActions: _actions,
    ),
    breadcrumbs: const [CompanyFileBreadcrumb(id: 'parent', name: '原目录')],
    allowedActions: changeAcl && page > 0 ? const {'view'} : _actions,
    total: _total,
    page: page,
    size: size,
    readScopeVersion: 'scope-a',
  );
  @override
  Future<CompanyFileListing> list({
    String? parentId,
    String search = '',
    String sort = 'name',
    String direction = 'asc',
    bool trash = false,
    int page = 0,
    int size = 100,
    Map<String, String?> columnFilters = const {},
  }) async {
    reads.add((page: page, size: size));
    requests.add((
      parent: parentId,
      search: search,
      trash: trash,
      filters: Map.of(columnFilters),
    ));
    if (reads.length == 2 && continuation != null) {
      return continuation!.future;
    }
    return response(page, size);
  }
}

void main() {
  test(
    'complete listing adapts zero-based batches and retains first directory ACL/path facts',
    () async {
      final repo = _Repository();
      final result = await repo.readCompleteListing(
        isCurrent: () => true,
        parentId: 'parent',
        search: '单字',
        trash: true,
        columnFilters: const {'search.name': '图纸'},
      );
      expect(repo.reads, _batches);
      expect(result.entries, hasLength(_total));
      expect(result.entries.last.id, 'folder-${_total - 1}');
      expect(result.page, 0);
      expect(result.total, _total);
      expect(result.folder?.version, 7);
      expect(result.breadcrumbs.single.id, 'parent');
      expect(result.allowedActions, _actions);
      expect(result.readScopeVersion, 'scope-a');
      expect(result.canReorder, isFalse);
      expect(
        repo.requests.every(
          (query) =>
              query.parent == 'parent' &&
              query.search == '单字' &&
              query.trash &&
              query.filters['search.name'] == '图纸',
        ),
        isTrue,
      );
      expect(
        () => result.entries.add(_folder(_total + 1)),
        throwsUnsupportedError,
      );
    },
  );

  test(
    'later ACL facts cannot silently overwrite the first directory scope',
    () async {
      final repo = _Repository()..changeAcl = true;
      await expectLater(
        repo.readCompleteListing(isCurrent: () => true),
        throwsA(
          isA<ApiException>().having(
            (error) => error.code,
            'code',
            'SNAPSHOT_CHANGED',
          ),
        ),
      );
      // The first batch with changed ACL facts retires the whole query.
      expect(repo.reads, _batches.take(2));
    },
  );

  test(
    'late continuation after identity retirement publishes nothing and starts no further read',
    () async {
      // The held continuation must leave at least one more batch to start.
      expect(_batches.length, greaterThan(2));
      var current = true;
      final repo = _Repository()
        ..continuation = Completer<CompanyFileListing>();
      final future = repo.readCompleteListing(isCurrent: () => current);
      while (repo.reads.length < 2) {
        await Future<void>.delayed(Duration.zero);
      }
      final assertion = expectLater(future, throwsA(isA<UiWorkCancelled>()));
      current = false;
      repo.continuation!.complete(
        repo.response(_batches[1].page, _batches[1].size),
      );
      await assertion;
      expect(repo.reads, _batches.take(2));
    },
  );

  testWidgets(
    'move destination includes the last batch and scrolling keeps the accepted directory local',
    (tester) async {
      final repo = _Repository();
      final scope = await AuthenticatedRequestScope.capture(
        baseUrl: 'https://library.test/api',
        storage: null,
        isCurrent: () => true,
      );
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: CompanyFileMoveDialog(
              source: const CompanyFile(
                id: 'source',
                parentId: 'old',
                name: '原资料',
                kind: 'FILE',
                version: 1,
                allowedActions: _actions,
              ),
              repository: repo,
              scope: scope,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(repo.reads, _batches);
      expect(find.byType(UtenPagination), findsNothing);
      final scrollable = find
          .descendant(
            of: find.byType(CompanyFileMoveDialog),
            matching: find.byType(Scrollable),
          )
          .first;
      final last = find.text('完整目录${_total - 1}');
      await tester.scrollUntilVisible(
        last,
        240,
        scrollable: scrollable,
        maxScrolls: 60,
      );
      await tester.pumpAndSettle();
      expect(last, findsOneWidget);
      expect(repo.reads, _batches);
      expect(tester.takeException(), isNull);
    },
  );
}
