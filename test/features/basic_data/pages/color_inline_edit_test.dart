import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/pages/color_page.dart';
import 'package:uten_imp/features/basic_data/repositories/color_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/basic_data/models/color_node.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

final _colorPermissions = StateProvider<Set<String>>((_) => {Perm.colorEdit});

void main() {
  testWidgets('a permission boundary change discards the old pending list', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    SharedPreferences.setMockInitialValues({});
    final reads = <Completer<String>>[];
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) async {
            Object response = <String, dynamic>{};
            if (request.path == '/master/colors') {
              final pending = Completer<String>();
              reads.add(pending);
              final name = await pending.future;
              response = {
                'items': [
                  {'id': 'color-1', 'name': name, 'code': 'C001'},
                ],
                'page': 1,
                'size': 20,
                'total': 1,
                'totalPages': 1,
              };
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
    final api = ApiClient(dio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          colorRepositoryProvider.overrideWithValue(DioColorRepository(api)),
          currentPermissionsProvider.overrideWith(
            (ref) => ref.watch(_colorPermissions),
          ),
        ],
        child: const MaterialApp(
          locale: Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ColorPage(),
        ),
      ),
    );
    for (var frame = 0; frame < 50 && reads.isEmpty; frame++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(reads, hasLength(1));
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ColorPage)),
    );
    container.read(_colorPermissions.notifier).state = {Perm.colorView};
    for (var frame = 0; frame < 50 && reads.length < 2; frame++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(reads, hasLength(2));
    reads.last.complete('Current authority');
    await tester.pumpAndSettle();
    reads.first.complete('Old authority');
    await tester.pumpAndSettle();
    final table = tester.widget<MasterDataTableView<ColorListItem>>(
      find.byType(MasterDataTableView<ColorListItem>),
    );
    expect(table.items.single.name, 'Current authority');
    expect(find.text('Old authority'), findsNothing);
    expect(find.text('编辑模式'), findsNothing);
  });
  testWidgets(
    'saved rows are not resent when readback fails before the next row',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      SharedPreferences.setMockInitialValues({});
      final names = <String, String>{'first': 'Blue', 'second': 'Green'};
      final writes = <String>[];
      var failReadback = false;
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (request, handler) {
              Object response = <String, dynamic>{};
              if (request.method == 'PATCH') {
                final id = request.path.split('/').last;
                writes.add(id);
                names[id] =
                    ((request.data as Map)['changes'] as Map)['name'] as String;
                if (id == 'first') failReadback = true;
              } else if (request.path == '/master/colors') {
                if (failReadback) {
                  failReadback = false;
                  handler.reject(
                    DioException(
                      requestOptions: request,
                      type: DioExceptionType.badResponse,
                      response: Response<dynamic>(
                        requestOptions: request,
                        statusCode: 500,
                        data: {'message': 'readback failed'},
                      ),
                    ),
                  );
                  return;
                }
                response = {
                  'items': [
                    for (final entry in names.entries)
                      {
                        'id': entry.key,
                        'name': entry.value,
                        'code': entry.key,
                        'status': '使用',
                      },
                  ],
                  'page': 1,
                  'size': 20,
                  'total': 2,
                  'totalPages': 1,
                };
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
      final api = ApiClient(dio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(api),
            colorRepositoryProvider.overrideWithValue(DioColorRepository(api)),
            currentPermissionsProvider.overrideWithValue({Perm.colorEdit}),
          ],
          child: const MaterialApp(
            locale: Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: ColorPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('编辑模式'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Blue'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byWidgetPredicate(
          (widget) => widget is TextField && widget.controller?.text == 'Blue',
        ),
        'Sky blue',
      );
      await tester.tap(find.text('Green'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byWidgetPredicate(
          (widget) => widget is TextField && widget.controller?.text == 'Green',
        ),
        'Leaf green',
      );
      await tester.pump();
      await tester.tap(find.text('保存 2 行修改'));
      await tester.pumpAndSettle();
      expect(writes, ['first']);
      expect(find.text('保存 1 行修改'), findsOneWidget);
      final table = tester.widget<MasterDataTableView<ColorListItem>>(
        find.byType(MasterDataTableView<ColorListItem>),
      );
      table.onRetry!();
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存 1 行修改'));
      await tester.pumpAndSettle();
      expect(writes, ['first', 'second']);
      expect(names, {'first': 'Sky blue', 'second': 'Leaf green'});
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'color table edits ordinary name with CAS while code and status stay read only',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      SharedPreferences.setMockInitialValues({});
      var name = 'Blue';
      final writes = <RequestOptions>[];
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (request, handler) {
              Object response = <String, dynamic>{};
              if (request.method == 'PATCH') {
                writes.add(request);
                name =
                    ((request.data as Map)['changes'] as Map)['name'] as String;
              } else if (request.path == '/master/colors') {
                response = {
                  'items': [
                    {
                      'id': 'color-1',
                      'name': name,
                      'code': 'C001',
                      'status': '使用',
                    },
                  ],
                  'page': 1,
                  'size': 20,
                  'total': 1,
                  'totalPages': 1,
                };
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
      final api = ApiClient(dio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(api),
            colorRepositoryProvider.overrideWithValue(DioColorRepository(api)),
            currentPermissionsProvider.overrideWithValue({Perm.colorEdit}),
          ],
          child: const MaterialApp(
            locale: Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: ColorPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('编辑模式'), findsOneWidget);
      await tester.tap(find.text('编辑模式'));
      await tester.pumpAndSettle();
      final table = tester.widget<MasterDataTableView<ColorListItem>>(
        find.byType(MasterDataTableView<ColorListItem>),
      );
      expect(
        table.columns.singleWhere((column) => column.key == 'code').cellBuilder,
        isNull,
      );
      expect(
        table.columns
            .singleWhere((column) => column.key == 'status')
            .cellBuilder,
        isNull,
      );
      expect(table.onRowTap, isNull);
      final nameInput = find.byWidgetPredicate(
        (widget) => widget is TextField && widget.controller?.text == 'Blue',
      );
      expect(nameInput, findsNothing);
      await tester.tap(find.text('Blue'));
      await tester.pumpAndSettle();
      expect(nameInput, findsOneWidget);
      await tester.enterText(nameInput, 'Sky blue');
      await tester.pump();
      await tester.tap(find.text('保存 1 行修改'));
      await tester.pumpAndSettle();
      expect(writes.single.path, '/master/inline-edit/colors/color-1');
      expect(writes.single.data, {
        'expected': {'name': 'Blue'},
        'changes': {'name': 'Sky blue'},
      });
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is TextField && widget.controller?.text == 'Sky blue',
        ),
        findsOneWidget,
      );
      await tester.enterText(
        find.byWidgetPredicate(
          (widget) =>
              widget is TextField && widget.controller?.text == 'Sky blue',
        ),
        'Sea blue',
      );
      await tester.pump();
      await tester.tap(find.text('保存 1 行修改'));
      await tester.pumpAndSettle();
      expect(writes, hasLength(2));
      expect(writes.last.data, {
        'expected': {'name': 'Sky blue'},
        'changes': {'name': 'Sea blue'},
      });
      expect(tester.takeException(), isNull);
    },
  );
}
