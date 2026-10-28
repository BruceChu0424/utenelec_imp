import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/security/pages/security_blacklist_page.dart';
import 'package:uten_imp/features/visitor/repositories/visitor_staff_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

class _Api extends ApiClient {
  _Api() : super(Dio());
  final reads = <Map<String, dynamic>>[];
  final bodies = <Object?>[];

  Map<String, dynamic> page(Map<String, dynamic> criteria) => {
    'items': [
      for (final name in ['甲访客', '乙访客'])
        if (name.contains(
          criteria['search.name']?.toString() ??
              criteria['name']?.toString() ??
              '',
        ))
          {
            'id': name,
            'visitorNo': 'V-$name',
            'name': name,
            'phone': '13800138000',
            'blockedReason': '核对中',
            'blockedAt': '2026-10-28T00:30:00Z',
            'blockedByName': '门岗甲',
          },
    ],
    'page': 1,
    'size': 20,
    'total': 1,
    'totalPages': 1,
  };

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path != '/security/blacklist') return {};
    reads.add({...?query});
    return page({...?query});
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    expect(path, '/security/blacklist/search');
    reads.add({...?query});
    bodies.add(body);
    return page((body! as Map).cast<String, dynamic>());
  }
}

void main() {
  testWidgets(
    'blacklist headers send full query and keep phone out of the URL',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1500, 950));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final api = _Api();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(api),
            sharedPreferencesProvider.overrideWithValue(preferences),
            currentPermissionsProvider.overrideWithValue({
              Perm.visitorBlacklist,
            }),
            isSuperAdminProvider.overrideWithValue(false),
          ],
          child: const MaterialApp(
            locale: Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: SecurityBlacklistPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final table = find.byType(MasterDataTableView<VisitorBlacklistItem>);
      final name = tester
          .widget<MasterDataTableView<VisitorBlacklistItem>>(table)
          .columns
          .singleWhere((column) => column.key == 'name');
      await tester.tap(find.text(name.label));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('uten-column-keyword-input')),
        '甲',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(api.reads.last['search.name'], '甲');
      expect(find.text('乙访客'), findsNothing);
      final phone = tester
          .widget<MasterDataTableView<VisitorBlacklistItem>>(table)
          .columns
          .singleWhere((column) => column.key == 'phone');
      await tester.tap(find.text(phone.label));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('uten-column-keyword-input')),
        '13800138000',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(api.bodies.last, {'name': '甲', 'phone': '13800138000'});
      expect(
        api.reads.last.keys.where((key) => key.startsWith('search.')),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
