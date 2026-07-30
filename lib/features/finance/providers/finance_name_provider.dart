// 主档名称解析（钱流单据展示用）。
//
// 单据 DTO 只带 UUID（客户/供应商/账户/币种均无名称）。本服务懒加载并缓存小表全量 dict
// （客户/供应商/账户/币种），收付款类别（payment_styles）按 category 懒加载子树提供分摊项目选项。
// 仿采购 MasterNameService，但客户/供应商用主档 dict 端点（/master/clients|suppliers/dict 等）。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../basic_data/models/payment_style_node.dart';
import '../../basic_data/repositories/account_repository.dart';
import '../../basic_data/repositories/payment_style_repository.dart';

/// 分摊项目选项（费用/收入）。
class FinanceStyleOption {
  const FinanceStyleOption({required this.id, this.code, this.name});
  final String id;
  final String? code;
  final String? name;
}

class FinanceNameService {
  FinanceNameService(this.api, this._paymentStyleRepo);
  final ApiClient api;
  final PaymentStyleRepository _paymentStyleRepo;

  Map<String, String> _clients = {};
  Map<String, String> _suppliers = {};
  Map<String, String> _accounts = {};
  Map<String, String> _currencies = {};
  Future<void>? _load;

  // 收付款类别：按 category 缓存（EXPENSE/INCOME）。
  final Map<String, List<FinanceStyleOption>> _stylesByCategory = {};

  Future<void> ensureLoaded() => _load ??= _ensureLoaded();

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

    final results = await Future.wait<Map<String, String>>([
      loadDict(ApiEndpoints.clientsDict),
      loadDict(ApiEndpoints.suppliersDict),
      loadDict(AccountEndpoints.dict),
      loadDict(ApiEndpoints.currenciesDict),
    ]);
    _clients = results[0];
    _suppliers = results[1];
    _accounts = results[2];
    _currencies = results[3];
  }

  /// 加载某大类的收付款类别（EXPENSE/INCOME）扁平化选项（含子节点）。
  Future<void> loadStyleCategory(String category) async {
    if (_stylesByCategory.containsKey(category)) return;
    try {
      final tree = await _paymentStyleRepo.tree(category: category);
      final flat = <FinanceStyleOption>[];
      void walk(List<PaymentStyleNode> nodes) {
        for (final n in nodes) {
          flat.add(FinanceStyleOption(id: n.id, code: n.code, name: n.name));
          if (n.hasChildren) walk(n.children);
        }
      }

      walk(tree);
      _stylesByCategory[category] = flat;
    } catch (_) {
      // 静默
    }
  }

  List<FinanceStyleOption> stylesFor(String category) =>
      _stylesByCategory[category] ?? const [];
  String styleName(String? id, String category) {
    if (id == null || id.isEmpty) return '—';
    final list = _stylesByCategory[category];
    final hit = list?.firstWhere(
      (s) => s.id == id,
      orElse: () => const FinanceStyleOption(id: ''),
    );
    return hit?.name ?? '—';
  }

  String client(String? id) => _resolve(_clients, id);
  String supplier(String? id) => _resolve(_suppliers, id);
  String account(String? id) => _resolve(_accounts, id);
  String currency(String? id) => _resolve(_currencies, id);

  Map<String, String> get clientEntries => _clients;
  Map<String, String> get supplierEntries => _suppliers;
  Map<String, String> get accountEntries => _accounts;
  Map<String, String> get currencyEntries => _currencies;

  String _resolve(Map<String, String> map, String? id) =>
      (id != null && id.isNotEmpty && map[id]?.isNotEmpty == true)
      ? map[id]!
      : '—';
}

final financeNameServiceProvider = Provider<FinanceNameService>(
  (ref) => FinanceNameService(
    ref.watch(apiClientProvider),
    ref.watch(paymentStyleRepositoryProvider),
  ),
);
