import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/production/pages/production_plan_detail_page.dart';
import 'package:uten_imp/features/warehouse/models/stock_doc.dart';
import 'package:uten_imp/features/warehouse/pages/stock_doc_detail_page.dart';
import 'package:uten_imp/shared/auth/document_scope_capability.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../support/document_scope_capability_overrides.dart';

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(id: 'dialog-test', code: 'T001', name: '弹窗测试员'),
  );
}

void main() {
  for (final production in [true, false]) {
    for (final confirm in [false, true]) {
      testWidgets('${production ? 'planning package' : 'finished inbound'} '
          '${confirm ? 'confirm' : 'cancel'} retains controllers until its exit ends', (
        tester,
      ) async {
        await tester.binding.setSurfaceSize(const Size(1600, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance();
        final api = _Api();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              sessionProvider.overrideWith(_Session.new),
              apiClientProvider.overrideWithValue(api),
              sharedPreferencesProvider.overrideWithValue(preferences),
              currentPermissionsProvider.overrideWithValue(const {
                Perm.productionPlanView,
                Perm.productionPlanningPackageCancel,
                Perm.stockDocView,
                Perm.stockDocApprove,
              }),
              isSuperAdminProvider.overrideWithValue(true),
              writeAllDocumentScope(DocumentDataScope.productionPlan),
              writeAllDocumentScope(DocumentDataScope.stockDocument),
            ],
            child: MaterialApp(
              theme: buildLightTheme(),
              locale: const Locale('zh'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: production
                  ? const ProductionPlanDetailPage(id: 'dialog-plan')
                  : const StockDocDetailPage(
                      docType: StockDocType.finishedIn,
                      id: 'dialog-stock',
                    ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        if (production) {
          // Invoke the page's existing action to isolate the dialog lifecycle
          // from the collapsing header's scroll layout in this minimal fixture.
          tester
              .widget<UtenButton>(
                find.byKey(const Key('production-open-execution-documents')),
              )
              .onPressed!
              .call();
          await tester.pumpAndSettle();
          await tester.tap(find.text('取消计划包'));
        } else {
          await tester.tap(find.text('确认实收并入库'));
        }
        await tester.pumpAndSettle();
        final dialog = find.byType(AlertDialog).last;
        final fields = find.descendant(
          of: dialog,
          matching: find.byType(TextField),
        );
        final controllers = tester
            .widgetList<TextField>(fields)
            .map((field) => field.controller!)
            .toList();
        expect(controllers, isNotEmpty);
        if (production && confirm) {
          await tester.enterText(fields.first, '原计划已撤回');
        }
        final route = ModalRoute.of(tester.element(dialog))!;
        var exited = false;
        route.completed.then((_) => exited = true);
        final label = production
            ? (confirm ? '确认取消' : '返回核对')
            : (confirm ? '确认实收并入库' : '取消');
        await tester.tap(
          find.descendant(of: dialog, matching: find.text(label)),
        );
        await tester.pump();
        expect(
          exited,
          isFalse,
          reason: 'the pop result precedes the reverse animation',
        );
        void listener() {}
        for (final controller in controllers) {
          expect(
            () => controller.addListener(listener),
            returnsNormally,
            reason:
                'a visible TextField may still receive focus/IME updates during exit',
          );
          controller.removeListener(listener);
        }
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump();
        expect(exited, isTrue);
        for (final controller in controllers) {
          expect(
            () => controller.addListener(listener),
            throwsFlutterError,
            reason: 'controllers must be released after the overlay disappears',
          );
        }
        expect(api.writes.length, confirm ? 1 : 0);
        if (confirm) {
          api.command.complete(
            production ? <String, dynamic>{} : _stock(status: 1),
          );
          await tester.pumpAndSettle();
        }
        expect(tester.takeException(), isNull);
      });
    }
  }
}

Map<String, dynamic> _stock({int status = 0}) => {
  'id': 'dialog-stock',
  'billNo': 'FI-DIALOG',
  'docType': 'FINISHED_IN',
  'status': status,
  'productionLinked': true,
  'makerId': 'maker',
  'warehouseId': 'warehouse',
  'items': [
    {'id': 'line-1', 'goodsId': 'goods', 'unitId': 'unit', 'qty': 10},
  ],
  'finishedLots': [
    {
      'lotId': 'lot-1',
      'goodsId': 'goods',
      'unitId': 'unit',
      'qty': 10,
      'itemIds': ['line-1'],
    },
  ],
};

class _Api extends ApiClient {
  _Api() : super(Dio());
  final command = Completer<Map<String, dynamic>>();
  final writes = <String>[];
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/production/plans/dialog-plan') {
      return {
        'id': 'dialog-plan',
        'billNo': 'P-DIALOG',
        'status': 1,
        'allowedActions': ['VIEW'],
        'items': [
          {'id': 'plan-item', 'goodsId': 'goods', 'unitId': 'unit', 'qty': 1},
        ],
      };
    }
    if (path.endsWith('/mrp/planning-package-result')) {
      return {
        'packageId': 'package-1',
        'status': 'CONFIRMED',
        'replayed': false,
      };
    }
    if (path == '/stock/docs/dialog-stock') return _stock();
    return {};
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => [];
  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) {
    writes.add(path);
    return command.future;
  }
}
