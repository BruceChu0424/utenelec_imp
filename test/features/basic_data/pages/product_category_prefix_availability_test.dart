import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';
import 'package:uten_imp/features/basic_data/pages/product_category_page.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/category_edit_dialog.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('货品分类编辑实时检查占用，换用可用前缀后才保存并刷新详情', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1600, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final server = _CategoryServer();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(
            await SharedPreferences.getInstance(),
          ),
          apiClientProvider.overrideWithValue(ApiClient(server.dio)),
          currentPermissionsProvider.overrideWithValue({
            Perm.goodsView,
            Perm.materialCategoryView,
            Perm.materialCategoryEdit,
          }),
          isSuperAdminProvider.overrideWithValue(false),
          goodsRepositoryProvider.overrideWithValue(_EmptyGoodsRepository()),
        ],
        child: const MaterialApp(
          locale: Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ProductCategoryPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('成品类'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    expect(find.byType(CategoryEditDialog), findsOneWidget);

    final prefixField = find.byWidgetPredicate(
      (widget) => widget is TextField && widget.decoration?.hintText == '编号前缀',
    );
    final saveButton = find.widgetWithText(UtenButton, '保存');
    await tester.enterText(prefixField, 'ug');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    expect(find.text('编号前缀“UG”已被占用，请更换后再保存。'), findsOneWidget);
    expect(tester.widget<UtenButton>(saveButton).onPressed, isNull);
    final occupiedField = tester.widget<TextField>(prefixField);
    final errorColor = Theme.of(tester.element(prefixField)).colorScheme.error;
    expect(
      occupiedField.decoration!.enabledBorder!.borderSide.color,
      errorColor,
    );
    expect(
      occupiedField.decoration!.focusedBorder!.borderSide.color,
      errorColor,
    );
    expect(server.savedBodies, isEmpty);
    expect(
      server.prefixChecks,
      contains(equals({'prefix': 'UG', 'categoryId': 'finished'})),
    );

    await tester.enterText(prefixField, 'ugx');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(find.textContaining('已被占用'), findsNothing);
    expect(tester.widget<UtenButton>(saveButton).onPressed, isNotNull);

    await tester.tap(saveButton);
    await tester.pumpAndSettle();

    expect(find.byType(CategoryEditDialog), findsNothing);
    expect(server.savedBodies, hasLength(1));
    expect(server.savedBodies.single['codePrefix'], 'UGX');
    expect(server.savedBodies.single['version'], 4);
    expect(server.prefixChecks.last, {
      'prefix': 'UGX',
      'categoryId': 'finished',
    });
    expect(
      server.prefixChecks.where((query) => query['prefix'] == 'UGX'),
      hasLength(2),
    );
    expect(server.prefixPreviews, [
      {'prefix': 'UGX'},
    ]);
    expect(server.prefix, 'UGX');
    expect(server.detailReads, 2);
    expect(find.textContaining('编号前缀 UGX'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

/// In-memory responses exercise the real page, shell and Dio repository together.
class _CategoryServer {
  _CategoryServer() {
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          final path = request.path;
          late final Object data;
          if (path == '/master/material-categories/tree') {
            data = [
              {
                'id': 'finished',
                'code': 'C-FIN',
                'name': '成品类',
                'level': 0,
                'codePrefix': prefix,
                'children': <Object>[],
              },
            ];
          } else if (path ==
              '/master/material-categories/prefix-availability') {
            prefixChecks.add(
              Map<String, dynamic>.from(request.queryParameters),
            );
            final requested = request.queryParameters['prefix'] as String;
            data = {
              'normalizedPrefix': requested,
              'available': requested != 'UG',
              'message': requested == 'UG' ? '该编号前缀已被占用' : null,
            };
          } else if (path ==
              '/master/material-categories/finished/prefix-preview') {
            prefixPreviews.add(
              Map<String, dynamic>.from(request.queryParameters),
            );
            data = {
              'categoryId': 'finished',
              'currentPrefix': prefix,
              'requestedPrefix': request.queryParameters['prefix'],
              'resultingEffectivePrefix': request.queryParameters['prefix'],
              'affectedRecords': 0,
              'customOrLegacyRecords': 0,
              'descendantOverrides': 0,
              'conflicts': 0,
              'conflictSamples': <String>[],
            };
          } else if (path == '/master/material-categories/finished') {
            if (request.method == 'PUT') {
              final body = Map<String, dynamic>.from(request.data as Map);
              savedBodies.add(body);
              prefix = body['codePrefix'] as String;
            } else {
              detailReads++;
            }
            data = {
              'id': 'finished',
              'code': 'C-FIN',
              'name': '成品类',
              'level': 0,
              'path': '成品类',
              'childCount': 0,
              'codePrefix': prefix,
              'effectivePrefix': prefix,
              'version': 4,
            };
          } else if (path == '/platform-columns/scopes') {
            data = <Object>[];
          } else {
            handler.reject(
              DioException(
                requestOptions: request,
                error: StateError(
                  'Unexpected request: ${request.method} $path',
                ),
              ),
            );
            return;
          }
          handler.resolve(
            Response<dynamic>(
              requestOptions: request,
              statusCode: 200,
              data: data,
            ),
          );
        },
      ),
    );
  }

  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  final prefixChecks = <Map<String, dynamic>>[];
  final prefixPreviews = <Map<String, dynamic>>[];
  final savedBodies = <Map<String, dynamic>>[];
  String prefix = 'CP';
  int detailReads = 0;
}

class _EmptyGoodsRepository implements GoodsRepository {
  @override
  Future<PagedResult<GoodsListItem>> list(
    String? categoryId, {
    int page = 1,
    int size = 20,
    String? keyword,
    Map<String, String?> filters = const {},
    String? sort,
    String? order,
    bool excludeDisabled = false,
    bool excludeStub = false,
    bool disabledOnly = false,
    bool stubOnly = false,
    bool includeRelated = false,
  }) async => PagedResult(
    items: const [],
    page: page,
    size: size,
    total: 0,
    totalPages: 0,
  );

  @override
  Future<GoodsFacets> facets(
    String categoryId, {
    String? keyword,
    bool includeRelated = false,
    Map<String, String?> filters = const {},
    bool excludeDisabled = false,
    bool excludeStub = false,
  }) async => const GoodsFacets(fields: {}, nullCounts: {});

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
