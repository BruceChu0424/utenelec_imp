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
      'last active page returns to a valid page after ${terminal.name}',
      () async {
        final repository = _MutableRepository(history: false);
        final container = ProviderContainer(
          overrides: [
            websiteInquiryRepositoryProvider.overrideWithValue(repository),
            masterDataSessionKeyProvider.overrideWithValue('test'),
          ],
        );
        addTearDown(container.dispose);
        final subscription = container.listen(
          websiteInquiryListProvider,
          (_, _) {},
          fireImmediately: true,
        );
        addTearDown(subscription.close);
        await container.read(websiteInquiryListProvider.future);
        await container.read(websiteInquiryListProvider.notifier).nextPage();
        expect(container.read(websiteInquiryListProvider).requireValue.page, 2);
        final updated = repository.change('second', terminal);
        container
            .read(websiteInquiryListProvider.notifier)
            .replaceIfPresent(updated);
        final repaired = await container.read(
          websiteInquiryListProvider.future,
        );
        expect(repaired.page, 1);
        expect(repaired.totalPages, 1);
        expect(repaired.total, 1);
        expect(repaired.items.single.id, 'first');
        expect(repository.requests.last, ('new', 1));
        await container.read(websiteInquiryListProvider.notifier).refresh();
        expect(repository.requests.last, ('new', 1));
      },
    );
  }

  test(
    'an empty last history page retreats within HISTORY and refresh stays there',
    () async {
      final repository = _MutableRepository(history: true);
      final container = ProviderContainer(
        overrides: [
          websiteInquiryRepositoryProvider.overrideWithValue(repository),
          masterDataSessionKeyProvider.overrideWithValue('test'),
        ],
      );
      addTearDown(container.dispose);
      container.read(websiteInquiryHistoryProvider.notifier).state = true;
      final subscription = container.listen(
        websiteInquiryListProvider,
        (_, _) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);
      await container.read(websiteInquiryListProvider.future);
      await container.read(websiteInquiryListProvider.notifier).nextPage();
      container
          .read(websiteInquiryListProvider.notifier)
          .replaceIfPresent(
            repository.change('second', WebsiteInquiryStatus.following),
          );
      final repaired = await container.read(websiteInquiryListProvider.future);
      expect(repaired.page, 1);
      expect(repaired.totalPages, 1);
      expect(repaired.items.single.id, 'first');
      expect(repository.requests.last, ('HISTORY', 1));
      await container.read(websiteInquiryListProvider.notifier).refresh();
      expect(repository.requests.last, ('HISTORY', 1));
    },
  );

  testWidgets(
    'active and history scopes retain pagination, clearing and refresh semantics',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final repository = _Repository();
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            websiteInquiryRepositoryProvider.overrideWithValue(repository),
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
      expect(repository.requests.last, ('new', 1));
      expect(find.text('active-1'), findsOneWidget);
      expect(find.text('全部进行中'), findsNothing);
      expect(
        tester.getTopLeft(find.byType(UtenFilterToolbar<String>)).dy,
        greaterThanOrEqualTo(tester.getBottomLeft(find.byType(UtenAppBar)).dy),
      );
      await tester.tap(find.text('跟进中'));
      await tester.pumpAndSettle();
      expect(repository.requests.last, ('following', 1));
      expect(
        container
            .read(websiteInquiryListProvider)
            .requireValue
            .items
            .single
            .status,
        WebsiteInquiryStatus.following,
      );
      await tester.tap(find.text('历史单据'));
      await tester.pumpAndSettle();
      expect(repository.requests.last, ('HISTORY', 1));
      expect(find.text('active-1'), findsNothing);
      expect(find.text('history-1'), findsOneWidget);
      container.read(websiteInquiryStatusFilterProvider.notifier).state =
          WebsiteInquiryStatus.closed;
      await tester.pumpAndSettle();
      container.read(websiteInquiryStatusFilterProvider.notifier).state = null;
      await tester.pumpAndSettle();
      expect(repository.requests.last, ('HISTORY', 1));
      await container.read(websiteInquiryListProvider.notifier).nextPage();
      await tester.pumpAndSettle();
      expect(repository.requests.last, ('HISTORY', 2));
      expect(find.text('history-2'), findsOneWidget);
      await container.read(websiteInquiryListProvider.notifier).refresh();
      await tester.pumpAndSettle();
      expect(repository.requests.last, ('HISTORY', 2));
      await tester.tap(find.text('未处理'));
      await tester.pumpAndSettle();
      expect(repository.requests.last, ('new', 1));
      final current = container
          .read(websiteInquiryListProvider)
          .requireValue
          .items
          .single;
      container
          .read(websiteInquiryListProvider.notifier)
          .replaceIfPresent(_item(current.id, WebsiteInquiryStatus.converted));
      expect(
        container.read(websiteInquiryListProvider).requireValue.items,
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'a stale active page cannot replace the selected history scope',
    () async {
      final repository = _Repository()..delayedActive = Completer();
      final container = ProviderContainer(
        overrides: [
          websiteInquiryRepositoryProvider.overrideWithValue(repository),
          masterDataSessionKeyProvider.overrideWithValue('test'),
        ],
      );
      addTearDown(container.dispose);
      final subscription = container.listen(
        websiteInquiryListProvider,
        (_, _) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);
      await container.read(websiteInquiryListProvider.future);
      final oldPage = container
          .read(websiteInquiryListProvider.notifier)
          .nextPage();
      await Future<void>.delayed(Duration.zero);
      container.read(websiteInquiryHistoryProvider.notifier).state = true;
      await container.read(websiteInquiryListProvider.future);
      repository.delayedActive!.complete(_page('new', 2));
      await oldPage;
      expect(
        container
            .read(websiteInquiryListProvider)
            .requireValue
            .items
            .single
            .status,
        WebsiteInquiryStatus.closed,
      );
    },
  );
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
