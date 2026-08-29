import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/models/payment_style_node.dart';
import 'package:uten_imp/features/basic_data/repositories/payment_style_repository.dart';
import 'package:uten_imp/features/finance/providers/finance_name_provider.dart';

void main() {
  test(
    'new document options only contain active leaves but history names remain',
    () async {
      final repository = _FakePaymentStyleRepository([
        PaymentStyleNode(
          id: 'parent',
          code: 'E100',
          name: '销售费用',
          category: 'EXPENSE',
          status: '使用',
          children: [
            PaymentStyleNode(
              id: 'active-leaf',
              code: 'E101',
              name: '运输费',
              category: 'EXPENSE',
              status: '使用',
              children: const [],
            ),
            PaymentStyleNode(
              id: 'disabled-leaf',
              code: 'E102',
              name: '旧广告费',
              category: 'EXPENSE',
              status: '禁用',
              children: const [],
            ),
          ],
        ),
        PaymentStyleNode(
          id: 'root-leaf',
          code: 'E200',
          name: '手续费',
          category: 'EXPENSE',
          status: '使用',
          children: const [],
        ),
      ]);
      final service = FinanceNameService(ApiClient(Dio()), repository);

      await service.loadStyleCategory('EXPENSE');

      expect(repository.requestedCategories, ['EXPENSE']);
      expect(service.stylesFor('EXPENSE').map((item) => item.id), [
        'active-leaf',
        'root-leaf',
      ]);
      expect(service.styleName('parent', 'EXPENSE'), '销售费用');
      expect(service.styleName('disabled-leaf', 'EXPENSE'), '旧广告费');
      expect(service.styleName('missing', 'EXPENSE'), '—');

      repository.nodes = [
        PaymentStyleNode(
          id: 'replacement',
          code: 'E300',
          name: '新运输费',
          category: 'EXPENSE',
          status: '使用',
          children: const [],
        ),
      ];
      await service.refreshLoadedStyleCategories();

      expect(repository.requestedCategories, ['EXPENSE', 'EXPENSE']);
      expect(service.stylesFor('EXPENSE').map((item) => item.id), [
        'replacement',
      ]);
      expect(service.styleName('replacement', 'EXPENSE'), '新运输费');
    },
  );

  test(
    'revision refresh supersedes an in-flight initial category load',
    () async {
      final repository = _FakePaymentStyleRepository(const [])
        ..deferRequests = true;
      final service = FinanceNameService(ApiClient(Dio()), repository);

      final initial = service.loadStyleCategory('EXPENSE');
      await Future<void>.delayed(Duration.zero);
      expect(repository.pendingRequests, hasLength(1));

      final refresh = service.refreshLoadedStyleCategories();
      await Future<void>.delayed(Duration.zero);
      expect(repository.pendingRequests, hasLength(2));

      repository.pendingRequests[0].complete([
        PaymentStyleNode(
          id: 'stale',
          code: 'E001',
          name: '旧类别',
          category: 'EXPENSE',
          status: '使用',
          children: const [],
        ),
      ]);
      repository.pendingRequests[1].complete([
        PaymentStyleNode(
          id: 'fresh',
          code: 'E002',
          name: '新类别',
          category: 'EXPENSE',
          status: '使用',
          children: const [],
        ),
      ]);

      await Future.wait([initial, refresh]);
      expect(service.stylesFor('EXPENSE').map((item) => item.id), ['fresh']);
    },
  );

  test(
    'a category response may finish safely after service disposal',
    () async {
      final repository = _FakePaymentStyleRepository(const [])
        ..deferRequests = true;
      final service = FinanceNameService(ApiClient(Dio()), repository);

      final load = service.loadStyleCategory('EXPENSE');
      await Future<void>.delayed(Duration.zero);
      service.dispose();
      repository.pendingRequests.single.complete(const []);

      await expectLater(load, completes);
    },
  );

  test(
    'opening another finance document refreshes account currency authority',
    () async {
      final api = _FinanceNameApi()
        ..accounts = [
          {
            'id': 'account-1',
            'code': 'ZH000001',
            'name': '测试账户',
            'currencyId': 'currency-cny',
            'currencyCode': 'CNY',
            'currencyName': '人民币',
            'baseCurrency': true,
            'status': '使用',
          },
        ];
      final service = FinanceNameService(
        api,
        _FakePaymentStyleRepository(const []),
      );

      await service.ensureLoaded(refreshAccounts: true);
      expect(service.accountCurrency('account-1'), '人民币');
      expect(service.accountCurrencyId('account-1'), 'currency-cny');
      expect(service.accountIsBaseCurrency('account-1'), isTrue);
      expect(service.accountStatus('account-1'), '使用');
      expect(service.accountLoadError, isNull);

      api.accounts = [
        {
          'id': 'account-1',
          'code': 'ZH000001',
          'name': '测试账户',
          'currencyId': 'currency-usd',
          'currencyCode': 'USD',
          'currencyName': '美元',
          'baseCurrency': false,
          'status': '使用',
        },
      ];
      await service.ensureLoaded(refreshAccounts: true);

      expect(service.accountCurrency('account-1'), '美元');
      expect(service.accountCurrencyId('account-1'), 'currency-usd');
      expect(service.accountIsBaseCurrency('account-1'), isFalse);
      service.dispose();
    },
  );

  test(
    'account authority load failure remains observable and fail closed',
    () async {
      final api = _FinanceNameApi()..failAccounts = true;
      final service = FinanceNameService(
        api,
        _FakePaymentStyleRepository(const []),
      );

      await service.ensureLoaded();

      expect(service.accountMetadataAvailable, isFalse);
      expect(service.accountLoadError, isNotNull);
      expect(service.accountCurrencyId('account-1'), isNull);
      service.dispose();
    },
  );
}

class _FinanceNameApi extends ApiClient {
  _FinanceNameApi() : super(Dio());

  List<Map<String, dynamic>> accounts = const [];
  bool failAccounts = false;

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/master/accounts/dict') {
      if (failAccounts) throw StateError('offline');
      return accounts;
    }
    return const [];
  }
}

class _FakePaymentStyleRepository implements PaymentStyleRepository {
  _FakePaymentStyleRepository(this.nodes);

  List<PaymentStyleNode> nodes;
  final List<String?> requestedCategories = [];
  bool deferRequests = false;
  final List<Completer<List<PaymentStyleNode>>> pendingRequests = [];

  @override
  Future<List<PaymentStyleNode>> tree({String? category}) async {
    requestedCategories.add(category);
    if (deferRequests) {
      final request = Completer<List<PaymentStyleNode>>();
      pendingRequests.add(request);
      return request.future;
    }
    return nodes;
  }

  @override
  Future<PaymentStyleDetail> create(PaymentStyleSaveInput input) =>
      throw UnimplementedError();

  @override
  Future<void> delete(String id) => throw UnimplementedError();

  @override
  Future<PaymentStyleDetail> detail(String id) => throw UnimplementedError();

  @override
  Future<List<PaymentStyleNode>> subtree(String id) =>
      throw UnimplementedError();

  @override
  Future<PaymentStyleDetail> update(String id, PaymentStyleUpdateInput input) =>
      throw UnimplementedError();
}
