import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/basic_data/models/unit_node.dart';
import 'package:uten_imp/features/basic_data/pages/unit_page.dart';
import 'package:uten_imp/features/basic_data/repositories/unit_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/master_inline_edit.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

class _SlowSave {
  final write = Completer<void>();
  final readback = Completer<void>();
  int writes = 0;
  int readbacks = 0;
  String name = '个';
  late final api = () {
    final dio = Dio(BaseOptions(baseUrl: 'https://unit.invalid/api'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) async {
          Object body = <String, dynamic>{};
          if (request.path == '/master/inline-edit/units/unit-1') {
            writes++;
            await write.future;
            name = ((request.data as Map)['changes'] as Map)['name'] as String;
          } else if (request.path == '/master/units') {
            if (writes > 0) {
              readbacks++;
              await readback.future;
            }
            body = {
              'items': [
                {
                  'id': 'unit-1',
                  'code': 'DW0188',
                  'name': name,
                  'status': '使用',
                },
              ],
              'page': 1,
              'size': 20,
              'total': 1,
              'totalPages': 1,
            };
          } else if (request.path == '/master/units/facets') {
            body = {
              'fields': <String, Object>{},
              'nullCounts': <String, int>{},
            };
          }
          handler.resolve(
            Response<dynamic>(
              requestOptions: request,
              data: body,
              statusCode: 200,
            ),
          );
        },
      ),
    );
    return ApiClient(dio);
  }();
}

const _savingLabel = '正在保存资料。';

({int actions, int hosts, int cards, int semanticNodes}) _counts(
  WidgetTester tester,
) {
  var matchingSemantics = 0;
  void visit(SemanticsNode node) {
    if (node.getSemanticsData().label == _savingLabel) matchingSemantics++;
    node.visitChildren((child) {
      visit(child);
      return true;
    });
  }

  final root = tester
      .binding
      .renderViews
      .single
      .owner
      ?.semanticsOwner
      ?.rootSemanticsNode;
  if (root != null) visit(root);
  return (
    actions: find
        .byType(MasterInlineEditActions<UnitListItem>, skipOffstage: false)
        .evaluate()
        .length,
    hosts: find.byType(UtenBusyOverlay, skipOffstage: false).evaluate().length,
    cards: find
        .byType(UtenBusyOverlayCard, skipOffstage: false)
        .evaluate()
        .length,
    semanticNodes: matchingSemantics,
  );
}

Future<void> _pump(
  WidgetTester tester,
  _SlowSave transport,
  Size size,
  double scale,
) async {
  SharedPreferences.setMockInitialValues({});
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(transport.api),
        unitRepositoryProvider.overrideWithValue(
          DioUnitRepository(transport.api),
        ),
        sessionProvider.overrideWith(_Session.new),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'unit-owner'),
        ),
        currentPermissionsProvider.overrideWithValue({
          Perm.unitView,
          Perm.unitEdit,
        }),
        isSuperAdminProvider.overrideWithValue(false),
      ],
      child: MaterialApp(
        theme: buildLightTheme(),
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: const UnitPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final scenario in [
    (
      name: 'desktop',
      size: const Size(1269, 900),
      scale: 1.0,
      fullscreen: false,
    ),
    (
      name: 'compact-large',
      size: const Size(390, 900),
      scale: 1.5,
      fullscreen: false,
    ),
    (
      name: 'fullscreen',
      size: const Size(1269, 900),
      scale: 1.0,
      fullscreen: true,
    ),
  ]) {
    testWidgets(
      'pending unit inline save has one root busy card and semantic node ${scenario.name}',
      (tester) async {
        final semantics = tester.ensureSemantics();
        try {
          final transport = _SlowSave();
          await _pump(tester, transport, scenario.size, scenario.scale);
          if (scenario.fullscreen) {
            await tester.tap(find.text('全屏'));
            await tester.pumpAndSettle();
          }
          await tester.tap(find.text('编辑模式'));
          await tester.pumpAndSettle();
          await tester.tap(
            find.byKey(const ValueKey('inline-activate-unit-1-name')),
          );
          await tester.pumpAndSettle();
          await tester.enterText(
            find.byWidgetPredicate(
              (widget) => widget is TextField && widget.controller?.text == '个',
            ),
            '件',
          );
          await tester.pump();
          final samples =
              <({int actions, int hosts, int cards, int semanticNodes})>[];
          try {
            await tester.tap(find.text('保存 1 行修改'));
            for (var frame = 0; frame < 20; frame++) {
              await tester.pump(const Duration(milliseconds: 20));
              samples.add(_counts(tester));
            }
            expect(transport.writes, 1);
            await tester.binding.setSurfaceSize(
              Size(scenario.size.width - 20, scenario.size.height),
            );
            for (var frame = 0; frame < 20; frame++) {
              await tester.pump(const Duration(milliseconds: 20));
              samples.add(_counts(tester));
            }
            transport.write.complete();
            for (var frame = 0; frame < 20; frame++) {
              await tester.pump(const Duration(milliseconds: 20));
              samples.add(_counts(tester));
            }
            expect(transport.readbacks, 1);
            int maxOf(
              int Function(
                ({int actions, int hosts, int cards, int semanticNodes}),
              )
              value,
            ) => samples.map(value).reduce((a, b) => a > b ? a : b);
            debugPrint(
              'UNIT-BUSY ${scenario.name} frames=${samples.length} '
              'maxActions=${maxOf((value) => value.actions)} '
              'maxHosts=${maxOf((value) => value.hosts)} '
              'maxRootCards=${maxOf((value) => value.cards)} '
              'maxSemanticNodes=${maxOf((value) => value.semanticNodes)}',
            );
            expect(samples.map((value) => value.actions), everyElement(1));
            expect(
              samples.map((value) => value.hosts),
              everyElement(lessThanOrEqualTo(1)),
            );
            expect(
              samples.map((value) => value.cards),
              everyElement(lessThanOrEqualTo(1)),
            );
            expect(
              samples.map((value) => value.semanticNodes),
              everyElement(lessThanOrEqualTo(1)),
            );
            expect(
              samples.any(
                (value) => value.cards == 1 && value.semanticNodes == 1,
              ),
              isTrue,
            );
          } finally {
            if (!transport.write.isCompleted) transport.write.complete();
            if (!transport.readback.isCompleted) transport.readback.complete();
            await tester.pumpAndSettle();
          }
          expect(_counts(tester).hosts, 0);
          expect(_counts(tester).cards, 0);
          expect(_counts(tester).semanticNodes, 0);
          expect(transport.writes, 1);
          expect(tester.takeException(), isNull);
        } finally {
          semantics.dispose();
        }
      },
    );
  }
}
