import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_export_button.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  for (final jobsAvailable in [false, true]) {
    testWidgets(
      'where-used selected identities stay private with jobs=$jobsAvailable',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance();
        final api = _PrivateSelectionApi(jobsAvailable);
        final selected = {
          for (var index = 1; index <= 500; index++)
            '00000001-0000-0000-0000-${index.toRadixString(16).padLeft(12, '0')}',
        };
        await tester.binding.setSurfaceSize(const Size(1000, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              apiClientProvider.overrideWithValue(api),
              sharedPreferencesProvider.overrideWithValue(preferences),
              authenticatedScopeProvider.overrideWithValue(
                const AuthenticatedScope(userId: 'selection-reader'),
              ),
              currentPermissionsProvider.overrideWithValue({
                Perm.productionWhereUsedView,
                Perm.productionWhereUsedExport,
              }),
            ],
            child: MaterialApp(
              locale: const Locale('zh'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: UtenExportButton(
                  endpoint: '/production/reports/where-used/export',
                  report: 'where-used',
                  requiredPermission: Perm.productionWhereUsedExport,
                  queryParams: const {
                    'materialGoodsId': '11111111-1111-4111-8111-111111111111',
                    'source': 'history',
                    'f.categoryId': '22222222-2222-4222-8222-222222222222',
                  },
                  selectedIds: selected,
                  queryForSelection: (ids) => {
                    'f.selectedProductIds': jsonEncode(ids.toList()..sort()),
                  },
                  legacyPrivateQuery: const {
                    'f.selectedProductIds': 'selectedProductIds',
                  },
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.bySemanticsLabel('下载表格'));
        await tester.pumpAndSettle();
        expect(find.text('仅已选（500 项）'), findsOneWidget);
        await tester.tap(find.byKey(const Key('table-output-selected')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('直接下载'));
        await tester.pumpAndSettle();
        if (jobsAvailable) {
          expect(api.jobBody, isNotNull);
          final parameters = Map<String, dynamic>.from(
            api.jobBody!['parameters'] as Map,
          );
          expect(
            (jsonDecode(parameters['f.selectedProductIds'] as String) as List)
                .toSet(),
            selected,
          );
          expect(parameters['source'], 'history');
          expect(api.downloadBody, isNull);
        } else {
          expect(api.downloadBody, isNotNull);
          expect(
            api.downloadQuery!.containsKey('f.selectedProductIds'),
            isFalse,
          );
          expect(jsonEncode(api.downloadQuery).length, lessThan(500));
          expect(
            (jsonDecode(api.downloadBody!['selectedProductIds'] as String)
                    as List)
                .toSet(),
            selected,
          );
          expect(api.downloadQuery!['source'], 'history');
          expect(
            api.downloadQuery!['f.categoryId'],
            '22222222-2222-4222-8222-222222222222',
          );
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
}

class _PrivateSelectionApi extends ApiClient {
  _PrivateSelectionApi(this.jobsAvailable) : super(Dio());
  final bool jobsAvailable;
  Map<String, dynamic>? downloadBody, downloadQuery, jobBody;
  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => [];
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => {'available': jobsAvailable, 'selectionVersion': 1};
  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    jobBody = Map<String, dynamic>.from(body as Map);
    throw ApiException('FIXTURE_CAPTURE', 'Captured request', httpStatus: 400);
  }

  @override
  Future<Uint8List> downloadBytes(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
  }) async {
    downloadBody = Map<String, dynamic>.from(body as Map);
    downloadQuery = Map<String, dynamic>.from(query!);
    throw ApiException('FIXTURE_CAPTURE', 'Captured request', httpStatus: 400);
  }
}
