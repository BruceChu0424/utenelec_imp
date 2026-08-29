// 主档名称解析（钱流单据展示用）。
//
// 单据 DTO 只带 UUID（客户/供应商/账户/币种均无名称）。本服务懒加载并缓存小表全量 dict
// （客户/供应商/账户/币种），收付款类别（payment_styles）按 category 懒加载子树提供分摊项目选项。
// 仿采购 MasterNameService，但客户/供应商用主档 dict 端点（/master/clients|suppliers/dict 等）。
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../core/utils/currency_display.dart';
import '../../basic_data/models/payment_style_node.dart';
import '../../basic_data/repositories/account_repository.dart';
import '../../../shared/providers/master_name_provider.dart'
    show masterDataSessionKeyProvider;
import '../../basic_data/repositories/payment_style_repository.dart';

/// 分摊项目选项（费用/收入）。
class FinanceStyleOption {
  const FinanceStyleOption({required this.id, this.code, this.name});
  final String id;
  final String? code;
  final String? name;
}

class FinanceAccountReference {
  const FinanceAccountReference({
    required this.id,
    this.code,
    this.name,
    this.currencyId,
    this.currencyCode,
    this.currencyName,
    this.baseCurrency = false,
    this.status,
  });

  final String id;
  final String? code;
  final String? name;
  final String? currencyId;
  final String? currencyCode;
  final String? currencyName;
  final bool baseCurrency;
  final String? status;
}

class FinanceNameService extends ChangeNotifier {
  FinanceNameService(this.api, this._paymentStyleRepo);
  final ApiClient api;
  final PaymentStyleRepository _paymentStyleRepo;

  Map<String, String> _clients = {};
  Map<String, String> _suppliers = {};
  Map<String, String> _accounts = {};
  Map<String, String> _accountEntries = {};
  Map<String, String> _accountCurrencies = {};
  Map<String, bool> _accountBaseCurrencies = {};
  Map<String, FinanceAccountReference> _accountReferences = {};
  String? _accountLoadError;
  Map<String, String> _currencies = {};
  Future<void>? _load;

  // 收付款类别：按 category 缓存（EXPENSE/INCOME）。
  // 可选项与历史名称分开缓存：禁用或已变成上级的类别不能再被新单据选中，
  // 但旧单据仍必须能显示当时关联类别的名称。
  final Map<String, List<FinanceStyleOption>> _stylesByCategory = {};
  final Map<String, Map<String, FinanceStyleOption>> _styleNamesByCategory = {};
  final Map<String, int> _styleRequestIds = {};
  final Set<String> _requestedStyleCategories = {};
  bool _disposed = false;

  Future<void> ensureLoaded({bool refreshAccounts = false}) async {
    final alreadyLoaded = _load != null;
    await (_load ??= _ensureLoaded());
    if (refreshAccounts && alreadyLoaded) {
      await _refreshAccounts();
    }
  }

  Future<void> _ensureLoaded() async {
    // 各 dict 独立加载、独立容错：单个端点失败不影响其它。
    Future<Map<String, String>> loadDict(String dictUrl) async {
      try {
        final list = await api.getList(dictUrl);
        return {
          for (final e in list)
            (e['id'] as String): ((e['name'] ?? '') as String),
        };
      } catch (_) {
        return const {};
      }
    }

    final accountsFuture = _loadAccounts();
    final results = await Future.wait<Map<String, String>>([
      loadDict(ApiEndpoints.clientsDict),
      loadDict(ApiEndpoints.suppliersDict),
      loadDict(ApiEndpoints.currenciesDict),
    ]);
    final accounts = await accountsFuture;
    _clients = results[0];
    _suppliers = results[1];
    _currencies = results[2];
    _accounts = accounts.names;
    _accountEntries = accounts.entries;
    _accountCurrencies = accounts.currencies;
    _accountBaseCurrencies = accounts.baseCurrencies;
    _accountReferences = accounts.references;
    _accountLoadError = accounts.error;
  }

  Future<_FinanceAccountDictionaries> _loadAccounts() async {
    try {
      final list = await api.getList(AccountEndpoints.dict);
      final names = <String, String>{};
      final entries = <String, String>{};
      final currencies = <String, String>{};
      final baseCurrencies = <String, bool>{};
      final references = <String, FinanceAccountReference>{};
      for (final item in list) {
        final id = item['id'] as String;
        final name = (item['name'] ?? '') as String;
        final code = item['code']?.toString().trim();
        final currencyId = item['currencyId']?.toString().trim();
        final currencyCode = item['currencyCode']?.toString().trim();
        final currencyName = item['currencyName']?.toString().trim();
        final status = item['status']?.toString().trim();
        final baseCurrency = item['baseCurrency'] as bool? ?? false;
        final currency = financeCurrencyDisplayLabel(
          name: currencyName,
          code: currencyCode,
        );
        names[id] = name;
        if (currency != null) currencies[id] = currency;
        baseCurrencies[id] = baseCurrency;
        references[id] = FinanceAccountReference(
          id: id,
          code: code,
          name: name,
          currencyId: currencyId,
          currencyCode: currencyCode,
          currencyName: currencyName,
          baseCurrency: baseCurrency,
          status: status,
        );
        entries[id] = [
          if (code != null && code.isNotEmpty) code,
          if (name.isNotEmpty) name,
          ?currency,
        ].join(' · ');
      }
      return _FinanceAccountDictionaries(
        names,
        entries,
        currencies,
        baseCurrencies,
        references,
        null,
      );
    } catch (_) {
      return const _FinanceAccountDictionaries(
        {},
        {},
        {},
        {},
        {},
        '账户资料加载失败，请刷新后重试',
      );
    }
  }

  Future<void> _refreshAccounts() async {
    final accounts = await _loadAccounts();
    _accounts = accounts.names;
    _accountEntries = accounts.entries;
    _accountCurrencies = accounts.currencies;
    _accountBaseCurrencies = accounts.baseCurrencies;
    _accountReferences = accounts.references;
    _accountLoadError = accounts.error;
    if (!_disposed) notifyListeners();
  }

  /// 加载某大类的收付款类别（EXPENSE/INCOME）。
  ///
  /// [stylesFor] 只返回状态为“使用”的叶子节点；[styleName] 保留全树解析能力。
  Future<void> loadStyleCategory(String category, {bool force = false}) async {
    if (!force && _stylesByCategory.containsKey(category)) return;
    _requestedStyleCategories.add(category);
    final requestId = (_styleRequestIds[category] ?? 0) + 1;
    _styleRequestIds[category] = requestId;
    try {
      final tree = await _paymentStyleRepo.tree(category: category);
      final flat = <FinanceStyleOption>[];
      final names = <String, FinanceStyleOption>{};
      void walk(List<PaymentStyleNode> nodes) {
        for (final n in nodes) {
          final option = FinanceStyleOption(
            id: n.id,
            code: n.code,
            name: n.name,
          );
          names[n.id] = option;
          if (n.status == '使用' && !n.hasChildren) {
            flat.add(option);
          }
          if (n.hasChildren) walk(n.children);
        }
      }

      walk(tree);
      if (_styleRequestIds[category] != requestId) return;
      _stylesByCategory[category] = flat;
      _styleNamesByCategory[category] = names;
      if (!_disposed) notifyListeners();
    } catch (_) {
      // 刷新失败时保留上一份可用缓存，不让已打开单据的选项突然变空。
    }
  }

  /// 主档写入后只刷新已加载的收付款大类。
  /// 加载期间保留旧选项，成功后通知已打开的财务页重建。
  Future<void> refreshLoadedStyleCategories() async {
    final categories = _requestedStyleCategories.toList(growable: false);
    await Future.wait(
      categories.map((category) => loadStyleCategory(category, force: true)),
    );
  }

  List<FinanceStyleOption> stylesFor(String category) =>
      _stylesByCategory[category] ?? const [];
  String styleName(String? id, String category) {
    if (id == null || id.isEmpty) return '—';
    final hit = _styleNamesByCategory[category]?[id];
    return hit?.name ?? '—';
  }

  String client(String? id) => _resolve(_clients, id);
  String supplier(String? id) => _resolve(_suppliers, id);
  String account(String? id) => _resolve(_accounts, id);
  String? accountCurrency(String? id) =>
      id == null || id.isEmpty ? null : _accountCurrencies[id];
  String? accountCurrencyId(String? id) =>
      id == null || id.isEmpty ? null : _accountReferences[id]?.currencyId;
  String? accountStatus(String? id) =>
      id == null || id.isEmpty ? null : _accountReferences[id]?.status;
  FinanceAccountReference? accountReference(String? id) =>
      id == null || id.isEmpty ? null : _accountReferences[id];
  bool? accountIsBaseCurrency(String? id) =>
      id == null || id.isEmpty ? null : _accountBaseCurrencies[id];
  String? get accountLoadError => _accountLoadError;
  bool get accountMetadataAvailable =>
      _accountLoadError == null && _accountReferences.isNotEmpty;
  String currency(String? id) => _resolve(_currencies, id);

  Map<String, String> get clientEntries => _clients;
  Map<String, String> get supplierEntries => _suppliers;
  Map<String, String> get accountEntries => _accountEntries;
  Map<String, String> get currencyEntries => _currencies;

  String _resolve(Map<String, String> map, String? id) =>
      (id != null && id.isNotEmpty && map[id]?.isNotEmpty == true)
      ? map[id]!
      : '—';

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

class _FinanceAccountDictionaries {
  const _FinanceAccountDictionaries(
    this.names,
    this.entries,
    this.currencies,
    this.baseCurrencies,
    this.references,
    this.error,
  );

  final Map<String, String> names;
  final Map<String, String> entries;
  final Map<String, String> currencies;
  final Map<String, bool> baseCurrencies;
  final Map<String, FinanceAccountReference> references;
  final String? error;
}

final financeNameServiceProvider = ChangeNotifierProvider<FinanceNameService>((
  ref,
) {
  ref.watch(masterDataSessionKeyProvider);
  final service = FinanceNameService(
    ref.watch(apiClientProvider),
    ref.watch(paymentStyleRepositoryProvider),
  );
  ref.listen<int>(paymentStyleRevisionProvider, (_, _) {
    unawaited(service.refreshLoadedStyleCategories());
  });
  return service;
});
