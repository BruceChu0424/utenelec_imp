import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/models/account_node.dart';
import 'package:uten_imp/features/basic_data/models/payment_style_node.dart';
import 'package:uten_imp/features/expense/models/expense_claim.dart';
import 'package:uten_imp/features/expense/models/expense_item.dart';
import 'package:uten_imp/features/expense/models/expense_payment.dart';
import 'package:uten_imp/features/expense/providers/expense_providers.dart';
import 'package:uten_imp/features/expense/repositories/expense_repository.dart';
import 'package:uten_imp/features/payroll/models/payroll_batch.dart';
import 'package:uten_imp/features/payroll/models/payroll_download.dart';
import 'package:uten_imp/features/payroll/models/payroll_slip.dart';
import 'package:uten_imp/features/payroll/repositories/payroll_repository.dart';

void main() {
  group('payroll JSON and status mapping', () {
    test('derives viewed/downloaded behavior from timestamps', () {
      expect(
        PayrollSlip.fromJson(_slipJson()).status,
        PayrollSlipStatus.published,
      );
      expect(
        PayrollSlip.fromJson(
          _slipJson(viewedAt: '2026-07-09T08:00:00Z'),
        ).status,
        PayrollSlipStatus.viewed,
      );
      expect(
        PayrollSlip.fromJson(
          _slipJson(
            viewedAt: '2026-07-09T08:00:00Z',
            downloadedAt: '2026-07-10T08:00:00Z',
          ),
        ).status,
        PayrollSlipStatus.downloaded,
      );
    });

    test('maps batch response and exact generation request body', () {
      final batch = PayrollBatch.fromJson(_batchJson());
      expect(batch.status, PayrollBatchStatus.draft);
      expect(batch.slips.single.netIncome, 9000);
      expect(batch.scopeLabel, '财务部');

      const input = PayrollBatchCreateInput(
        year: 2026,
        month: 7,
        departmentId: 'dept-fin',
        includeOvertime: true,
        includeBonus: false,
        includeSocialInsurance: true,
        includeTax: true,
      );
      expect(input.toJson(), {
        'year': 2026,
        'month': 7,
        'departmentId': 'dept-fin',
        'includeOvertime': true,
        'includeBonus': false,
        'includeSocialInsurance': true,
        'includeTax': true,
      });
    });

    test('flattens only selectable real department UUIDs', () {
      final options = PayrollDepartmentOption.fromTree([
        {
          'id': 'root',
          'name': '优腾公司',
          'level': '公司',
          'children': [
            {
              'id': 'dept-fin',
              'name': '财务部',
              'level': '一级部门',
              'children': const <Map<String, dynamic>>[],
            },
          ],
        },
      ]);
      expect(options, hasLength(1));
      expect(options.single.id, 'dept-fin');
      expect(options.single.path, '财务部');
    });

    test('validates PDF signature and sanitizes download filename', () {
      expect(
        hasPdfSignature(
          Uint8List.fromList([0x25, 0x50, 0x44, 0x46, 0x2D, 0x31]),
        ),
        isTrue,
      );
      expect(hasPdfSignature(Uint8List.fromList([1, 2, 3])), isFalse);
      expect(
        payrollPdfFilename(period: '2026-07', employeeCode: r'..\..\E001:PAY?'),
        '工资条_2026-07_E001_PAY.pdf',
      );
    });
  });

  group('payroll repository contract', () {
    test(
      'uses slip filter, batch body/action, and binary download endpoints',
      () async {
        final requests = <RequestOptions>[];
        final repository = DioPayrollRepository(
          _api((request) {
            requests.add(request);
            if (request.path == '/payroll/slips') {
              return _pageJson([_slipJson()]);
            }
            if (request.path == '/payroll/batches') return _batchJson();
            if (request.path.endsWith('/reject')) {
              return {..._batchJson(), 'status': 'REJECTED'};
            }
            if (request.path.endsWith('/download')) return <int>[1, 2, 3];
            throw StateError('unexpected request: ${request.path}');
          }),
        );

        final slips = await repository.listSlips(status: 'PUBLISHED');
        expect(slips.items, hasLength(1));
        expect(requests.last.queryParameters, {
          'page': 1,
          'size': 24,
          'status': 'PUBLISHED',
        });

        await repository.createBatch(
          const PayrollBatchCreateInput(
            year: 2026,
            month: 7,
            includeOvertime: true,
            includeBonus: false,
            includeSocialInsurance: true,
            includeTax: true,
          ),
        );
        expect(requests.last.method, 'POST');
        expect(requests.last.data, {
          'year': 2026,
          'month': 7,
          'includeOvertime': true,
          'includeBonus': false,
          'includeSocialInsurance': true,
          'includeTax': true,
        });

        final rejected = await repository.rejectBatch('batch-1', '金额异常');
        expect(rejected?.status, PayrollBatchStatus.rejected);
        expect(requests.last.path, '/payroll/batches/batch-1/reject');
        expect(requests.last.data, {'reason': '金额异常'});

        final bytes = await repository.downloadSlip('slip-1');
        expect(bytes, Uint8List.fromList([1, 2, 3]));
        expect(requests.last.path, '/payroll/slips/slip-1/download');
      },
    );

    test('can request the sixth page so the 501st slip is not lost', () async {
      late RequestOptions captured;
      final repository = DioPayrollRepository(
        _api((request) {
          captured = request;
          return _pageJson(
            [_slipJson()],
            page: 6,
            size: 100,
            total: 501,
            totalPages: 6,
          );
        }),
      );

      final page = await repository.listSlips(page: 6, size: 100);

      expect(page.items.single.id, 'slip-1');
      expect(page.page, 6);
      expect(page.total, 501);
      expect(captured.queryParameters, {'page': 6, 'size': 100});
    });
  });

  group('expense JSON and repository contract', () {
    test('maps enums and emits exact create body without client total/id', () {
      final claim = ExpenseClaim.fromJson(_claimJson());
      expect(claim.status, ExpenseClaimStatus.submitted);
      expect(claim.items.single.category, ExpenseCategory.transport);

      final input = ExpenseClaimCreateInput(
        title: '客户拜访',
        remark: '上海',
        items: [
          ExpenseItem(
            id: 'local-only',
            category: ExpenseCategory.transport,
            amount: 128.5,
            date: DateTime(2026, 7, 30),
            description: '高铁',
          ),
        ],
      );
      expect(input.toJson(), {
        'title': '客户拜访',
        'remark': '上海',
        'items': [
          {
            'category': 'TRANSPORT',
            'amount': 128.5,
            'date': '2026-07-30',
            'description': '高铁',
          },
        ],
      });
    });

    test('builds payment input and filters disabled master data', () {
      final options = buildExpensePaymentOptions(
        const [
          AccountListItem(
            id: 'account-active',
            code: 'A001',
            name: '基本户',
            status: '使用',
          ),
          AccountListItem(id: 'account-disabled', name: '旧账户', status: '禁用'),
        ],
        [
          PaymentStyleNode(
            id: 'style-active',
            code: 'E001',
            name: '交通费',
            category: 'EXPENSE',
            status: '使用',
            children: const [],
          ),
          PaymentStyleNode(
            id: 'style-disabled',
            code: 'E999',
            name: '停用费用',
            category: 'EXPENSE',
            status: '禁用',
            children: const [],
          ),
        ],
      );

      expect(options.accounts.map((option) => option.id), ['account-active']);
      expect(options.accounts.single.label, 'A001 · 基本户');
      expect(options.styles.map((option) => option.id), ['style-active']);

      expect(
        ExpensePaymentInput(
          accountId: 'account-active',
          expenseStyleId: 'style-active',
          paymentDate: DateTime(2026, 7, 30, 23, 59),
        ).toJson(),
        {
          'accountId': 'account-active',
          'expenseStyleId': 'style-active',
          'paymentDate': '2026-07-30',
        },
      );
    });

    test('uses separate queues plus exact reject and payment bodies', () async {
      final requests = <RequestOptions>[];
      final repository = DioExpenseRepository(
        _api((request) {
          requests.add(request);
          if (request.path.endsWith('/mine') ||
              request.path.endsWith('/pending') ||
              request.path.endsWith('/payable')) {
            return _pageJson([_claimJson()]);
          }
          if (request.path == '/expense-claims') return _claimJson();
          if (request.path.endsWith('/reject')) {
            return {..._claimJson(), 'status': 'REJECTED'};
          }
          if (request.path.endsWith('/pay')) {
            return {
              ..._claimJson(),
              'status': 'PAID',
              'paidAt': '2026-07-30T10:00:00Z',
            };
          }
          throw StateError('unexpected request: ${request.path}');
        }),
      );

      await repository.listMine(statuses: const [ExpenseClaimStatus.submitted]);
      expect(requests.last.path, '/expense-claims/mine');
      expect(requests.last.queryParameters, {
        'page': 1,
        'size': 24,
        'status': 'SUBMITTED',
      });

      await repository.listPending();
      expect(requests.last.path, '/expense-claims/pending');
      expect(requests.last.queryParameters, {'page': 1, 'size': 24});

      await repository.listPayable();
      expect(requests.last.path, '/expense-claims/payable');
      expect(requests.last.queryParameters, {'page': 1, 'size': 24});

      await repository.create(
        ExpenseClaimCreateInput(
          title: '客户拜访',
          items: [
            ExpenseItem(
              id: 'local-only',
              category: ExpenseCategory.transport,
              amount: 128.5,
              date: DateTime(2026, 7, 30),
            ),
          ],
        ),
      );
      expect(requests.last.method, 'POST');
      expect(
        (requests.last.data as Map<String, dynamic>).containsKey('totalAmount'),
        isFalse,
      );

      final rejected = await repository.reject('claim-1', '票据不完整');
      expect(rejected?.status, ExpenseClaimStatus.rejected);
      expect(requests.last.path, '/expense-claims/claim-1/reject');
      expect(requests.last.data, {'reason': '票据不完整'});

      final paid = await repository.pay(
        'claim-1',
        ExpensePaymentInput(
          accountId: 'account-active',
          expenseStyleId: 'style-active',
          paymentDate: DateTime(2026, 7, 30),
        ),
      );
      expect(paid?.status, ExpenseClaimStatus.paid);
      expect(requests.last.path, '/expense-claims/claim-1/pay');
      expect(requests.last.data, {
        'accountId': 'account-active',
        'expenseStyleId': 'style-active',
        'paymentDate': '2026-07-30',
      });
    });
  });
}

ApiClient _api(Object? Function(RequestOptions request) responder) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        handler.resolve(
          Response<dynamic>(
            requestOptions: request,
            statusCode: 200,
            data: responder(request),
          ),
        );
      },
    ),
  );
  return ApiClient(dio);
}

Map<String, dynamic> _slipJson({String? viewedAt, String? downloadedAt}) => {
  'id': 'slip-1',
  'employeeId': 'emp-1',
  'employeeName': '张三',
  'employeeCode': 'E001',
  'year': 2026,
  'month': 7,
  'items': [
    {'name': '基本工资', 'amount': 10000, 'type': 'EARNING', 'description': null},
    {'name': '社保', 'amount': 1000, 'type': 'DEDUCTION', 'description': null},
  ],
  'grossIncome': 10000,
  'totalDeduction': 1000,
  'netIncome': 9000,
  'status': 'PUBLISHED',
  'publishedAt': '2026-07-08T08:00:00Z',
  'viewedAt': viewedAt,
  'downloadedAt': downloadedAt,
  'remark': null,
};

Map<String, dynamic> _batchJson() => {
  'id': 'batch-1',
  'year': 2026,
  'month': 7,
  'departmentId': 'dept-fin',
  'departmentName': '财务部',
  'status': 'DRAFT',
  'headcount': 1,
  'grossIncome': 10000,
  'totalDeduction': 1000,
  'netIncome': 9000,
  'slips': [_slipJson()],
  'createdAt': '2026-07-30T08:00:00Z',
  'submittedAt': null,
  'approvedAt': null,
  'publishedAt': null,
  'rejectReason': null,
};

Map<String, dynamic> _claimJson() => {
  'id': 'claim-1',
  'applicantId': 'emp-1',
  'applicantName': '张三',
  'title': '客户拜访',
  'items': [
    {
      'id': 'item-1',
      'category': 'TRANSPORT',
      'amount': 128.5,
      'date': '2026-07-30',
      'description': '高铁',
    },
  ],
  'totalAmount': 128.5,
  'status': 'SUBMITTED',
  'createdAt': '2026-07-30T08:00:00Z',
  'submittedAt': '2026-07-30T09:00:00Z',
  'approvedAt': null,
  'paidAt': null,
  'remark': '上海',
  'rejectReason': null,
};

Map<String, dynamic> _pageJson(
  List<Map<String, dynamic>> items, {
  int page = 1,
  int size = 24,
  int? total,
  int? totalPages,
}) => {
  'items': items,
  'page': page,
  'size': size,
  'total': total ?? items.length,
  'totalPages': totalPages ?? (items.isEmpty ? 0 : 1),
};
