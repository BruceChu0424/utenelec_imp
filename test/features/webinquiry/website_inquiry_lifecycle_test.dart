import 'package:flutter/gestures.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:uten_imp/components/layout/uten_app_bar.dart';
import 'package:uten_imp/components/layout/uten_filter_toolbar.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/webinquiry/models/website_inquiry.dart';
import 'package:uten_imp/features/webinquiry/pages/website_inquiry_list_page.dart';
import 'package:uten_imp/features/webinquiry/providers/website_inquiry_providers.dart';
import 'package:uten_imp/features/webinquiry/repositories/website_inquiry_repository.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  for (final terminal in [
    WebsiteInquiryStatus.converted,
    WebsiteInquiryStatus.closed,
  ]) {
    test(
      'complete active inquiries remove a finished row without a navigation read: ${terminal.name}',
      () async {
        final repo = _MutableRepository(history: false);
        final actual = _container(repo);
        final first = await actual.read(websiteInquiryListProvider.future);
        expect(first.items.map((row) => row.id), ['first', 'second']);
        expect(first.page, 1);
        expect(first.totalPages, 1);
        final reads = repo.requests.length;
        actual
            .read(websiteInquiryListProvider.notifier)
            .replaceIfPresent(repo.change('second', terminal));
        final changed = actual.read(websiteInquiryListProvider).requireValue;
        expect(changed.items.single.id, 'first');
        expect(changed.total, 1);
        expect(repo.requests.length, reads);
        await actual.read(websiteInquiryListProvider.notifier).refresh();
        expect(repo.requests.last, ('new', 1));
      },
    );
  }
  test(
    'complete history removes a reopened row and refresh retains HISTORY',
    () async {
      final repo = _MutableRepository(history: true);
      final actual = _container(repo, history: true);
      await actual.read(websiteInquiryListProvider.future);
      actual
          .read(websiteInquiryListProvider.notifier)
          .replaceIfPresent(
            repo.change('second', WebsiteInquiryStatus.following),
          );
      expect(
        actual.read(websiteInquiryListProvider).requireValue.items.single.id,
        'first',
      );
      await actual.read(websiteInquiryListProvider.notifier).refresh();
      expect(repo.requests.last, ('HISTORY', 1));
    },
  );
  testWidgets(
    'active and history are complete continuous lists with no page controls or scroll reads',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final repo = _Repository();
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            websiteInquiryRepositoryProvider.overrideWithValue(repo),
            sharedPreferencesProvider.overrideWithValue(preferences),
            masterDataSessionKeyProvider.overrideWithValue('test'),
          ],
          child: const MaterialApp(
            locale: Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: WebsiteInquiryListPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(WebsiteInquiryListPage)),
      );
      expect(
        container.read(websiteInquiryListProvider).requireValue.items,
        hasLength(2),
      );
      expect(
        find.byKey(const ValueKey('master-table-page-next')),
        findsNothing,
      );
      expect(
        tester.getTopLeft(find.byType(UtenFilterToolbar<String>)).dy,
        greaterThanOrEqualTo(tester.getBottomLeft(find.byType(UtenAppBar)).dy),
      );
      await tester.tap(find.text('跟进中'));
      await tester.pumpAndSettle();
      expect(
        container
            .read(websiteInquiryListProvider)
            .requireValue
            .items
            .every((row) => row.status == WebsiteInquiryStatus.following),
        true,
      );
      await tester.tap(find.text('历史单据'));
      await tester.pumpAndSettle();
      expect(find.text('history-1'), findsOneWidget);
      expect(find.text('history-2'), findsOneWidget);
      final reads = repo.requests.length;
      final wheelTarget = find
          .byWidgetPredicate(
            (widget) =>
                widget is Scrollable &&
                widget.axisDirection == AxisDirection.down,
          )
          .first;
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: tester.getCenter(wheelTarget),
          scrollDelta: const Offset(0, 250),
        ),
      );
      await tester.pumpAndSettle();
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: tester.getCenter(wheelTarget),
          scrollDelta: const Offset(0, -250),
        ),
      );
      await tester.pumpAndSettle();
      expect(repo.requests.length, reads);
      await container.read(websiteInquiryListProvider.notifier).refresh();
      await tester.pumpAndSettle();
      expect(repo.requests.last, ('HISTORY', 2));
      expect(tester.takeException(), isNull);
    },
  );
  test(
    'a retired active continuation cannot replace the complete history query',
    () async {
      final repo = _Repository();
      final actual = _container(repo);
      await actual.read(websiteInquiryListProvider.future);
      repo.delayedActive = Completer();
      final old = actual.read(websiteInquiryListProvider.notifier).refresh();
      await Future<void>.delayed(Duration.zero);
      actual.read(websiteInquiryHistoryProvider.notifier).state = true;
      final history = await actual.read(websiteInquiryListProvider.future);
      expect(history.items, hasLength(2));
      repo.delayedActive!.complete(_page('new', 2));
      await old;
      expect(
        actual
            .read(websiteInquiryListProvider)
            .requireValue
            .items
            .map((row) => row.id),
        ['history-1', 'history-2'],
      );
    },
  );
}

ProviderContainer _container(
  WebsiteInquiryRepository repository, {
  bool history = false,
}) {
  final container = ProviderContainer(
    overrides: [
      websiteInquiryRepositoryProvider.overrideWithValue(repository),
      masterDataSessionKeyProvider.overrideWithValue('test'),
    ],
  );
  if (history) {
    container.read(websiteInquiryHistoryProvider.notifier).state = true;
  }
  final subscription = container.listen(
    websiteInquiryListProvider,
    (_, _) {},
    fireImmediately: true,
  );
  addTearDown(container.dispose);
  addTearDown(subscription.close);
  return container;
}

class _MutableRepository extends Fake implements WebsiteInquiryRepository {
  _MutableRepository({required bool history})
    : items = [
        _item(
          'first',
          history ? WebsiteInquiryStatus.closed : WebsiteInquiryStatus.newOne,
        ),
        _item(
          'second',
          history
              ? WebsiteInquiryStatus.converted
              : WebsiteInquiryStatus.newOne,
        ),
      ];
  final List<WebsiteInquiry> items;
  final requests = <(String?, int)>[];
  WebsiteInquiry change(String id, WebsiteInquiryStatus status) {
    final index = items.indexWhere((item) => item.id == id);
    return items[index] = _item(id, status);
  }

  @override
  Future<PagedResult<WebsiteInquiry>> list({
    String? status,
    String keyword = '',
    int page = 1,
    int size = 20,
  }) async {
    requests.add((status, page));
    final matches = items.where((item) {
      final terminal =
          item.status == WebsiteInquiryStatus.closed ||
          item.status == WebsiteInquiryStatus.converted;
      return status == 'HISTORY' ? terminal : item.status.wireName == status;
    }).toList();
    return PagedResult(
      items: matches.skip(page - 1).take(1).toList(),
      page: page,
      size: 1,
      total: matches.length,
      totalPages: matches.length,
    );
  }
}

class _Repository extends Fake implements WebsiteInquiryRepository {
  final requests = <(String?, int)>[];
  Completer<PagedResult<WebsiteInquiry>>? delayedActive;
  @override
  Future<PagedResult<WebsiteInquiry>> list({
    String? status,
    String keyword = '',
    int page = 1,
    int size = 20,
  }) async {
    requests.add((status, page));
    if (status == 'new' && page == 2 && delayedActive != null) {
      return delayedActive!.future;
    }
    return _page(status!, page);
  }
}

WebsiteInquiry _item(String name, WebsiteInquiryStatus status) =>
    WebsiteInquiry(
      id: name,
      name: name,
      message: '询盘内容',
      status: status,
      receivedAt: DateTime(2026, 10, 15),
    );
PagedResult<WebsiteInquiry> _page(String scope, int page) => PagedResult(
  items: [
    _item(
      '${scope != 'HISTORY' ? 'active' : 'history'}-$page',
      scope != 'HISTORY'
          ? WebsiteInquiryStatus.fromName(scope)
          : page == 1
          ? WebsiteInquiryStatus.closed
          : WebsiteInquiryStatus.converted,
    ),
  ],
  page: page,
  size: 1,
  total: 2,
  totalPages: 2,
);
