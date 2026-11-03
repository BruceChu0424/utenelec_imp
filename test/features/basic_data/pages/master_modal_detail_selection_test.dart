import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/models/color_node.dart';
import 'package:uten_imp/features/basic_data/models/currency_node.dart';
import 'package:uten_imp/features/basic_data/models/unit_node.dart';
import 'package:uten_imp/features/basic_data/pages/color_page.dart';
import 'package:uten_imp/features/basic_data/pages/currency_page.dart';
import 'package:uten_imp/features/basic_data/pages/unit_page.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

void main() {
  _detailSelectionTest<UnitListItem>('单位', 'units', const UnitPage());
  _detailSelectionTest<ColorListItem>('颜色', 'colors', const ColorPage());
  _detailSelectionTest<CurrencyListItem>(
    '币种',
    'currencies',
    const CurrencyPage(),
  );
}

void _detailSelectionTest<T>(String name, String domain, Widget page) {
  testWidgets('$name业务详情成功打开才清多选，失败保留并可重试', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.binding.setSurfaceSize(const Size(1440, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final preferences = await SharedPreferences.getInstance();
    final wire = _Wire(domain);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionProvider.overrideWith(_Session.new),
          authenticatedScopeProvider.overrideWithValue(
            const AuthenticatedScope(userId: 'modal-detail-selection'),
          ),
          currentPermissionsProvider.overrideWithValue({
            Perm.unitView,
            Perm.colorView,
            Perm.currencyView,
          }),
          isSuperAdminProvider.overrideWithValue(false),
          sharedPreferencesProvider.overrideWithValue(preferences),
          apiClientProvider.overrideWithValue(wire.api),
        ],
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: page,
        ),
      ),
    );
    await tester.pumpAndSettle();
    MasterDataTableView<T> table() =>
        tester.widget(find.byType(MasterDataTableView<T>));
    final tableState = tester.state(find.byType(MasterDataTableView<T>));
    table().onSelectedIdsChanged!(<String>{'item-1', 'item-2'});
    await tester.pump();
    wire.detailGate = Completer<void>();
    wire.failDetail = true;
    table().onRowTap!(table().items.first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(table().selectedIds, {'item-1', 'item-2'}, reason: '读取等待不清操作对象');
    wire.detailGate!.complete();
    await tester.pumpAndSettle();
    expect(table().selectedIds, {'item-1', 'item-2'}, reason: '读取失败未进入详情');

    wire.detailGate = null;
    wire.failDetail = false;
    for (var visit = 0; visit < 3; visit++) {
      table().onSelectedIdsChanged!(<String>{'item-1', 'item-2'});
      await tester.pump();
      table().onRowTap!(table().items.first);
      await tester.pumpAndSettle();
      expect(find.text('编号'), findsWidgets);
      expect(table().selectedIds, isEmpty, reason: '详情已准备并打开');
      Navigator.of(
        tester.element(find.byType(page.runtimeType)),
        rootNavigator: true,
      ).pop();
      await tester.pumpAndSettle();
      expect(table().selectedIds, isEmpty, reason: '关闭业务详情不恢复旧选中');
      expect(table().items, hasLength(2));
      expect(
        tester.state(find.byType(MasterDataTableView<T>)),
        same(tableState),
      );
    }
    expect(wire.detailReads, 4);
    expect(wire.writes, 0);
    expect(tester.takeException(), isNull);
  });
}

class _Wire {
  _Wire(this.domain);
  final String domain;
  Completer<void>? detailGate;
  bool failDetail = false;
  int detailReads = 0, writes = 0;
  Map<String, dynamic> row(int index) => {
    'id': 'item-$index',
    'code': 'QA00$index',
    'name': '样例$index',
    'status': '使用',
    'exchangeRate': 1,
  };
  late final api = () {
    final dio = Dio(
      BaseOptions(baseUrl: 'https://modal-selection.invalid/api'),
    );
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) async {
          if (request.method != 'GET') writes++;
          Object response;
          if (request.path == '/master/$domain') {
            response = {
              'items': [row(1), row(2)],
              'page': 1,
              'size': 20,
              'total': 2,
              'totalPages': 1,
            };
          } else if (request.path == '/master/$domain/item-1') {
            detailReads++;
            await detailGate?.future;
            if (failDetail) {
              handler.reject(
                DioException(
                  requestOptions: request,
                  type: DioExceptionType.badResponse,
                  response: Response<dynamic>(
                    requestOptions: request,
                    statusCode: 503,
                    data: {
                      'code': 'SERVICE_UNAVAILABLE',
                      'message': 'fixture detail unavailable',
                    },
                  ),
                ),
              );
              return;
            }
            response = row(1);
          } else {
            response = <String, dynamic>{};
          }
          handler.resolve(
            Response<dynamic>(
              requestOptions: request,
              statusCode: 200,
              data: response,
            ),
          );
        },
      ),
    );
    return ApiClient(dio);
  }();
}
