import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/finance/config/finance_doc_config.dart';
import 'package:uten_imp/features/purchase/config/purchase_doc_config.dart';
import 'package:uten_imp/features/sales/config/sales_doc_config.dart';
import 'package:uten_imp/features/subcontract/config/subcontract_doc_config.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft_catalog.dart';
import 'package:uten_imp/shared/drafts/form_draft_history_projection.dart';

FormDraft draft({
  String route = '/sales/orders/new',
  String permission = Perm.salesOrderCreate,
  BadgeModule module = BadgeModule.sales,
  Map<String, dynamic>? data,
}) => FormDraft(
  id: 'one',
  title: 'PRIVATE TITLE',
  module: module,
  route: route,
  permission: permission,
  updatedAt: DateTime.utc(2026, 10),
  data:
      data ??
      {
        'billDate': '2026-10-01',
        'rows': [
          {
            'documentItemId': 'line-123',
            'orderItemId': 'source-456',
            'goods': {'name': '铝合金', 'code': 'G001', 'price': 'NESTED_PRICE'},
            'text': {
              'qty': '12.',
              'price': 'SECRET_PRICE',
              'discount': 'SECRET_DISCOUNT',
              'machiningPrice': 'SECRET_FEE',
              'remark': 'PRIVATE NOTE',
            },
            'extraColumns': {'value': 'UNCONTROLLED_EXTENSION'},
          },
        ],
        'uncertainShipmentBody': {'price': 'FROZEN_SECRET'},
        'attachments': {'bytes': 'ATTACHMENT_SECRET'},
      },
);

String visible(FormDraftHistoryProjection? projection) => [
  projection?.title,
  for (final section in projection?.sections ?? <FormDraftHistorySection>[])
    for (final field in section.fields) '${field.label}:${field.value}',
].join('|');

void main() {
  test(
    'public history snapshots use the same typed field policy and are detached',
    () {
      final original = draft();
      final before = jsonEncode(original.toJson());
      final snapshot = projectFormDraftHistorySnapshot(original, {
        Perm.salesOrderView,
      })!;
      final publicJson = jsonEncode(snapshot.toJson());
      expect(snapshot.data[formDraftHistoryReadOnlyProjectionKey], isTrue);
      for (final hidden in [
        'SECRET',
        'PRIVATE',
        'UNCONTROLLED_EXTENSION',
        'FROZEN_SECRET',
        'ATTACHMENT_SECRET',
      ]) {
        expect(publicJson, isNot(contains(hidden)));
      }
      expect(publicJson, contains('12.'));
      expect(
        visible(projectFormDraftHistory(snapshot, {Perm.salesOrderView})),
        visible(projectFormDraftHistory(original, {Perm.salesOrderView})),
      );
      expect(
        projectFormDraftHistorySnapshot(snapshot, {
          Perm.salesOrderView,
        })!.toJson(),
        snapshot.toJson(),
      );
      expect(jsonEncode(original.toJson()), before);
      expect(projectFormDraftHistorySnapshot(original, {}), isNull);
    },
  );

  test('public history snapshot separately prunes PII and compensation', () {
    final value = draft(
      module: BadgeModule.people,
      route: '/employee/onboarding',
      permission: Perm.employeeCreate,
      data: {
        'fields': {
          'name': '员工',
          'phone': 'PRIVATE_PHONE',
          'baseSalary': 'PRIVATE_SALARY',
          'futureField': {'raw': 'PRIVATE_FUTURE'},
        },
      },
    );
    final snapshot = projectFormDraftHistorySnapshot(value, {
      Perm.employeeCreate,
      Perm.employeeCompensationView,
    })!;
    final publicJson = jsonEncode(snapshot.toJson());
    expect(publicJson, contains('PRIVATE_SALARY'));
    expect(publicJson, isNot(contains('PRIVATE_PHONE')));
    expect(publicJson, isNot(contains('PRIVATE_FUTURE')));
  });
  test(
    'daily report history is view-gated metadata, never private command data',
    () {
      final spec = FormDraftCatalog.dailyReport.spec();
      final value = draft(
        route: spec.route,
        module: spec.module,
        permission: spec.permission,
        data: {
          dailyReportCreateCommandKey: {'bodyJson': 'PRIVATE_BODY'},
          'rows': [
            {'price': 'SECRET_PRICE'},
          ],
        },
      );
      final projection = projectFormDraftHistory(value, {
        Perm.productionDailyReportView,
      });
      expect(projection?.title, spec.title);
      expect(projection?.sections, isEmpty);
      expect(visible(projection), isNot(contains('PRIVATE_BODY')));
      expect(projectFormDraftHistory(value, {}), isNull);
    },
  );
  test(
    'material increment never projects segment content without live scope',
    () {
      final value = draft(
        route: '/production/material-increment-requests/new?segmentId=secret',
        module: BadgeModule.workshop,
        permission: 'production_execution:request_material_increment',
        data: {'segmentId': 'SECRET', 'quantity': 321, 'reason': 'PRIVATE'},
      );
      for (final permission in [
        Perm.productionExecutionView,
        Perm.productionPlanApprove,
      ]) {
        final projection = projectFormDraftHistory(value, {permission});
        expect(projection?.title, '申请追加用料');
        expect(projection?.sections, isEmpty);
      }
      expect(projectFormDraftHistory(value, {}), isNull);
    },
  );
  test(
    'finance history remains discoverable without exposing unreviewed payload',
    () {
      for (final config in const [
        FinanceDocConfig.receipt,
        FinanceDocConfig.payment,
        FinanceDocConfig.expense,
        FinanceDocConfig.otherIncome,
        FinanceDocConfig.bankTransfer,
      ]) {
        final value = draft(
          route: '${config.listLocation}/new',
          permission: config.createPerm!,
          module: BadgeModule.finance,
          data: {
            'amountOriginal': 'PRIVATE_BALANCE',
            'rows': [
              {'amount': 'SECRET'},
            ],
          },
        );
        final projection = projectFormDraftHistory(value, {config.listPerm});
        expect(projection?.title, config.label);
        expect(projection?.sections, isEmpty);
        expect(projectFormDraftHistory(value, {}), isNull);
      }
    },
  );
  test('history reads require current view, not an old create grant', () {
    final value = draft();
    expect(canReadFormDraftHistory(value, {Perm.salesOrderCreate}), isFalse);
    expect(canReadFormDraftHistory(value, {Perm.salesOrderView}), isTrue);
    expect(canReadFormDraftHistory(value, {}), isFalse);
    expect(
      canReadFormDraftHistory(draft(permission: ''), {Perm.salesOrderView}),
      isFalse,
    );
    expect(
      canReadFormDraftHistory(draft(module: BadgeModule.people), {
        Perm.salesOrderView,
      }),
      isFalse,
    );
    expect(
      canReadFormDraftHistory(draft(route: '//external/orders/new'), {
        Perm.salesOrderView,
      }),
      isFalse,
    );
  });

  test(
    'revoking price removes every sensitive projection without changing raw data',
    () {
      final value = draft();
      final withPrice = visible(
        projectFormDraftHistory(value, {
          Perm.salesOrderView,
          Perm.salesOrderPriceView,
        }),
      );
      expect(withPrice, contains('SECRET_PRICE'));
      expect(withPrice, contains('SECRET_DISCOUNT'));
      expect(withPrice, contains('SECRET_FEE'));
      final withoutPrice = visible(
        projectFormDraftHistory(value, {Perm.salesOrderView}),
      );
      for (final hidden in [
        'SECRET',
        'PRIVATE',
        'NESTED_PRICE',
        'UNCONTROLLED_EXTENSION',
        'FROZEN_SECRET',
        'ATTACHMENT_SECRET',
      ]) {
        expect(withoutPrice, isNot(contains(hidden)));
      }
      expect(withoutPrice, contains('数量:12.'));
      expect(withoutPrice, contains('line-123'));
      expect(withoutPrice, contains('source-456'));
      final row = (value.data['rows'] as List).first as Map;
      expect((row['text'] as Map)['price'], 'SECRET_PRICE');
      expect(withPrice, isNot(contains('UNCONTROLLED_EXTENSION')));
      expect(withPrice, isNot(contains('ATTACHMENT_SECRET')));
    },
  );

  test('known commercial routes use their current config permission', () {
    for (final config in [
      SalesDocConfig.quote,
      SalesDocConfig.order,
      SalesDocConfig.shipment,
      SalesDocConfig.otherShipment,
      SalesDocConfig.customerShipment,
      SalesDocConfig.returnDoc,
    ]) {
      if (config.createPerm == null) continue;
      expect(
        canReadFormDraftHistory(
          draft(
            route: '/sales/${config.type.pathSegment}/new',
            permission: config.createPerm!,
          ),
          {config.listPerm},
        ),
        isTrue,
      );
    }
    for (final config in [
      PurchaseDocConfig.request,
      PurchaseDocConfig.order,
      PurchaseDocConfig.receipt,
      PurchaseDocConfig.returnDoc,
    ]) {
      if (config.createPerm == null) continue;
      final value = draft(
        route: '/purchase/${config.type.pathSegment}/new',
        permission: config.createPerm!,
        module: BadgeModule.purchase,
      );
      expect(canReadFormDraftHistory(value, {config.listPerm}), isTrue);
      expect(
        visible(projectFormDraftHistory(value, {config.listPerm})),
        isNot(contains('SECRET_PRICE')),
      );
    }
    for (final config in [
      SubcontractDocConfig.order,
      SubcontractDocConfig.receipt,
      SubcontractDocConfig.returnDoc,
      SubcontractDocConfig.materialReturn,
      SubcontractDocConfig.waste,
    ]) {
      if (config.createPerm == null) continue;
      final value = draft(
        route: '/subcontract/${config.type.pathSegment}/new',
        permission: config.createPerm!,
        module: BadgeModule.subcontract,
      );
      expect(canReadFormDraftHistory(value, {config.listPerm}), isTrue);
      expect(
        visible(projectFormDraftHistory(value, {config.listPerm})),
        isNot(contains('SECRET_PRICE')),
      );
    }
  });

  test(
    'PII and compensation are separately granted; edit does not imply view',
    () {
      final value = draft(
        module: BadgeModule.people,
        route: '/employee/onboarding',
        permission: Perm.employeeCreate,
        data: {
          'fields': {
            'name': '测试员工',
            'idNumber': 'SECRET_ID',
            'phone': 'SECRET_PHONE',
            'bankAccount': 'SECRET_BANK',
            'baseSalary': 'SECRET_SALARY',
          },
        },
      );
      final hidden = visible(
        projectFormDraftHistory(value, {
          Perm.employeeCreate,
          Perm.employeePiiEdit,
          Perm.employeeCompensationEdit,
        }),
      );
      expect(hidden, contains('测试员工'));
      expect(hidden, isNot(contains('SECRET')));
      final pii = visible(
        projectFormDraftHistory(value, {
          Perm.employeeCreate,
          Perm.employeePiiView,
        }),
      );
      expect(pii, contains('SECRET_PHONE'));
      expect(pii, isNot(contains('SECRET_SALARY')));
      final salary = visible(
        projectFormDraftHistory(value, {
          Perm.employeeCreate,
          Perm.employeeCompensationView,
        }),
      );
      expect(salary, contains('SECRET_SALARY'));
      expect(salary, isNot(contains('SECRET_BANK')));
    },
  );

  test('unknown nested payloads never fall back to raw JSON', () {
    final spec = FormDraftCatalog.suggestion.spec();
    final value = draft(
      route: spec.route,
      module: spec.module,
      permission: spec.permission,
      data: {'body': 'PRIVATE_BODY'},
    );
    final projection = projectFormDraftHistory(value, {spec.permission});
    expect(projection, isNotNull);
    expect(projection!.sections, isEmpty);
    expect(visible(projection), isNot(contains('PRIVATE_BODY')));
  });

  test('missing or malformed fields do not invent zero or stringify JSON', () {
    final value = draft(
      data: {
        'rows': [
          {
            'text': {
              'qty': {'price': 'SECRET'},
              'weight': null,
            },
          },
          null,
        ],
      },
    );
    final projection = projectFormDraftHistory(value, {Perm.salesOrderView})!;
    expect(projection.sections, hasLength(2));
    expect(
      projection.sections.every((section) => section.fields.isEmpty),
      isTrue,
    );
  });
}
