// 跨业务模块共用的主档名称解析。
//
// 单据 DTO 只带 UUID。MasterDictionaryService 统一缓存仓库、币种、颜色、单位和货品；
// 各业务服务只补充自己的往来单位（供应商/客户）及领域专属名称，避免复制整套缓存逻辑。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_endpoints.dart';
import 'session_provider.dart';

/// 货品搜索/选择用的轻量项。
class GoodsOption {
  const GoodsOption({required this.id, this.code, this.name});

  final String id;
  final String? code;
  final String? name;

  factory GoodsOption.fromJson(Map<String, dynamic> json) => GoodsOption(
    id: json['id'] as String,
    code: json['code'] as String?,
    name: json['name'] as String?,
  );
}

/// 各单据域共用的小主档与货品名称缓存。
///
/// [_commonLoad] 同时承担并发去重：同一页面树中多个组件并发请求时只发一组 HTTP 请求。
/// 加载失败时保留占位符，不阻塞业务列表；显式编辑/保存仍由各 Repository 返回真实错误。
class MasterDictionaryService {
  MasterDictionaryService(this.api);

  final ApiClient api;

  Map<String, String> _warehouses = {};
  Map<String, String> _currencies = {};
  Map<String, String> _colors = {};
  Map<String, String> _units = {};
  final Map<String, String> _goods = {};
  final Map<String, String> _employees = {};
  Future<void>? _commonLoad;

  Future<void> ensureCommonLoaded() =>
      _commonLoad ??= _loadCommonDictionaries();

  Future<void> _loadCommonDictionaries() async {
    try {
      final results = await Future.wait([
        api.getList(ApiEndpoints.warehousesDict),
        api.getList(ApiEndpoints.currenciesDict),
        api.getList(ApiEndpoints.colorsDict),
        api.getList(ApiEndpoints.unitsDict),
      ]);
      _warehouses = _nameMap(results[0]);
      _currencies = _nameMap(results[1]);

      _colors = _nameMap(results[2]);
      _units = _nameMap(results[3]);
    } catch (_) {
      // 名称解析是辅助信息，失败时显示占位符，避免一张字典表拖垮整张单据列表。
    }
  }

  /// 货品名按 id 批量解析，只查询尚未缓存的 id。
  Future<void> loadGoodsNames(Iterable<String> ids) async {
    final need = ids
        .where((id) => id.isNotEmpty && !_goods.containsKey(id))
        .toSet();
    if (need.isEmpty) return;
    try {
      final list = await api.getList(
        ApiEndpoints.goodsLookup,
        query: {'ids': need.join(',')},
      );
      for (final entry in list) {
        _goods[entry['id'] as String] = (entry['name'] ?? '') as String;
      }
    } catch (_) {
      // 同上：列表可降级为占位符。
    }
  }

  /// 货品关键词搜索（编辑页 typeahead）。
  Future<List<GoodsOption>> searchGoods(String keyword, {int size = 20}) async {
    if (keyword.trim().isEmpty) return const [];
    final json = await api.get(
      ApiEndpoints.goods,
      query: {'keyword': keyword.trim(), 'page': 1, 'size': size},
    );
    final items = json['items'];
    if (items is! List) return const [];
    final result = items
        .map((entry) => GoodsOption.fromJson(entry as Map<String, dynamic>))
        .toList();
    for (final goods in result) {
      if (goods.name?.isNotEmpty == true) _goods[goods.id] = goods.name!;
    }
    return result;
  }

  String warehouse(String? id) => resolveName(_warehouses, id);
  String currency(String? id) => resolveName(_currencies, id);
  String color(String? id) => resolveName(_colors, id);
  String unit(String? id) => resolveName(_units, id);
  String goods(String? id) => resolveName(_goods, id);

  /// 员工无字典端点，按 id 逐个查询并缓存（业务员/发货人/制单/审批等人员字段展示用）。
  Future<void> loadEmployeeNames(Iterable<String?> ids) async {
    final need = ids
        .whereType<String>()
        .where((id) => id.isNotEmpty && !_employees.containsKey(id))
        .toSet();
    if (need.isEmpty) return;
    try {
      await Future.wait(
        need.map((id) async {
          final employee = await api.get(ApiEndpoints.employee(id));
          _employees[id] = (employee['fullName'] as String?) ?? '';
        }),
      );
    } catch (_) {
      // 名称解析可降级为占位符，不阻塞展示。
    }
  }

  String employee(String? id) => resolveName(_employees, id);

  Map<String, String> get warehouseEntries => _warehouses;
  Map<String, String> get currencyEntries => _currencies;
  Map<String, String> get colorEntries => _colors;
  Map<String, String> get unitEntries => _units;

  static String resolveName(Map<String, String> map, String? id) =>
      id != null && id.isNotEmpty && map[id]?.isNotEmpty == true
      ? map[id]!
      : '—';

  static Map<String, String> _nameMap(List<dynamic> entries) => {
    for (final entry in entries.whereType<Map<String, dynamic>>())
      entry['id'] as String: (entry['name'] ?? '') as String,
  };
}

/// 采购、委外、仓库和生产域使用的名称服务。
class MasterNameService extends MasterDictionaryService {
  MasterNameService(super.api);

  Map<String, String> _suppliers = {};
  Map<String, String> _departments = {};
  Future<void>? _load;

  Future<void> ensureLoaded() => _load ??= Future.wait([
    ensureCommonLoaded(),
    _loadSuppliers(),
    _loadDepartments(),
  ]);

  Future<void> _loadSuppliers() async {
    try {
      final entries = await api.getList(ApiEndpoints.suppliersDict);
      _suppliers = {
        for (final entry in entries)
          entry['id'] as String: (entry['name'] ?? '') as String,
      };
    } catch (_) {
      // 列表名称解析可降级。
    }
  }

  Future<void> _loadDepartments() async {
    try {
      _departments = _flattenDeptTree(
        await api.getList(ApiEndpoints.departmentsTree),
      );
    } catch (_) {
      // 列表名称解析可降级。
    }
  }

  String supplier(String? id) =>
      MasterDictionaryService.resolveName(_suppliers, id);
  String department(String? id) =>
      MasterDictionaryService.resolveName(_departments, id);

  Map<String, String> get supplierEntries => _suppliers;
  Map<String, String> get departmentEntries => _departments;

  static Map<String, String> _flattenDeptTree(List<dynamic> nodes) {
    final result = <String, String>{};

    void walk(List<dynamic> list) {
      for (final raw in list) {
        final node = raw as Map<String, dynamic>;
        final id = node['id'] as String?;
        if (id != null) result[id] = (node['name'] ?? '') as String;
        final children = node['children'];
        if (children is List) walk(children);
      }
    }

    walk(nodes);
    return result;
  }
}

/// 主档缓存必须绑定当前账号和权限快照，避免 A 登出后 B 继续看到 A 的 UUID/名称。
String masterDataSessionCacheKey(SessionState session) {
  final user = session.user;
  final permissions = [...?user?.permissions]..sort();
  final roles = user?.roles.map((role) => role.name).toList() ?? <String>[];
  roles.sort();
  return <Object?>[
    session.status.name,
    user?.id,
    user?.employeeId,
    user?.name,
    user?.superAdmin,
    roles.join(','),
    permissions.join(','),
  ].join('|');
}

final masterDataSessionKeyProvider = Provider<String>(
  (ref) => masterDataSessionCacheKey(ref.watch(sessionProvider)),
);

final masterNameServiceProvider = Provider<MasterNameService>((ref) {
  ref.watch(masterDataSessionKeyProvider);
  return MasterNameService(ref.watch(apiClientProvider));
});
