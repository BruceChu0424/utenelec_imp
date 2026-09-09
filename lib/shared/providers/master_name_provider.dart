// 跨业务模块共用的主档名称解析。
//
// 单据 DTO 只带 UUID。MasterDictionaryService 统一缓存仓库、币种、颜色、单位和货品；
// 各业务服务只补充自己的往来单位（供应商/客户）及领域专属名称，避免复制整套缓存逻辑。
import 'dart:async';

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

/// 货品字典详情（lookup 端点）：名称 + 编号 + 系列 + 库位号，仓库单据明细展示用。
class GoodsDictEntry {
  const GoodsDictEntry({
    required this.name,
    this.code,
    this.series,
    this.stockPlace,
    this.unitId,
  });

  final String name;
  final String? code;
  final String? series;
  final String? stockPlace;
  final String? unitId;

  factory GoodsDictEntry.fromJson(Map<String, dynamic> json) => GoodsDictEntry(
    name: (json['name'] ?? '') as String,
    code: json['code'] as String?,
    series: json['series'] as String?,
    stockPlace: json['stockPlace'] as String?,
    unitId: json['unitId'] as String?,
  );
}

/// 仓库字典项（V476 主/子层级）：id/名称 + 上级仓库引用，供层级下拉分组展示。
class WarehouseDictEntry {
  const WarehouseDictEntry({
    required this.id,
    required this.name,
    this.code,
    this.parentId,
    this.parentName,
    this.status,
    this.isAccountable = true,
  });

  final String id;
  final String name;
  final String? code;
  final String? parentId;
  final String? parentName;
  final String? status;
  final bool isAccountable;

  factory WarehouseDictEntry.fromJson(Map<String, dynamic> json) =>
      WarehouseDictEntry(
        id: json['id'] as String,
        name: (json['name'] ?? '') as String,
        code: json['code'] as String?,
        parentId: json['parentId'] as String?,
        parentName: json['parentName'] as String?,
        status: json['status'] as String?,
        isAccountable:
            (json['accountable'] ?? json['isAccountable']) as bool? ?? true,
      );
}

/// 各单据域共用的小主档与货品名称缓存。
///
/// [ensureDictionaryLoaded] 合并同一字典的并发请求，并仅缓存成功结果。
/// 加载失败时保留占位符，不阻塞业务列表；显式编辑/保存仍由各 Repository 返回真实错误。
class MasterDictionaryService {
  MasterDictionaryService(this.api);

  final ApiClient api;

  Map<String, String> _warehouses = {};
  List<WarehouseDictEntry> _warehouseList = [];
  Map<String, WarehouseDictEntry> _warehouseById = {};
  final Map<String, WarehouseDictEntry?> _mainWarehouseCache = {};
  Map<String, String> _currencies = {};
  Map<String, String> _colors = {};
  Map<String, String> _units = {};
  final Map<String, String> _goods = {};
  final Map<String, GoodsDictEntry> _goodsInfo = {};
  final Map<String, String> _employees = {};
  final Map<String, Future<void>> _dictionaryLoads = {};

  /// Cache successful dictionaries independently and merge concurrent requests.
  /// Failure remains a display fallback, but the next explicit load can retry it.
  Future<void> ensureDictionaryLoaded<T>(
    String key,
    Future<T> Function() fetch,
    void Function(T) apply, {
    bool reload = false,
  }) {
    final existing = _dictionaryLoads[key];
    if (!reload && existing != null) return existing;
    final completion = Completer<void>();
    final pending = completion.future;
    _dictionaryLoads[key] = pending;
    unawaited(() async {
      try {
        final result = await fetch();
        if (identical(_dictionaryLoads[key], pending)) apply(result);
      } catch (_) {
        if (identical(_dictionaryLoads[key], pending)) {
          _dictionaryLoads.remove(key);
        }
      } finally {
        completion.complete();
      }
    }());
    return pending;
  }

  Future<void> ensureCommonLoaded() => Future.wait([
    ensureDictionaryLoaded(
      ApiEndpoints.warehousesDict,
      () => api.getList(ApiEndpoints.warehousesDict),
      (entries) {
        final hierarchy = entries.map(WarehouseDictEntry.fromJson).toList();
        _warehouses = warehouseDisplayNames(hierarchy);
        _warehouseList = hierarchy;
        _warehouseById = {for (final entry in hierarchy) entry.id: entry};
        _mainWarehouseCache.clear();
      },
    ),
    ensureDictionaryLoaded(
      ApiEndpoints.currenciesDict,
      () => api.getList(ApiEndpoints.currenciesDict),
      (entries) => _currencies = _nameMap(entries),
    ),
    ensureDictionaryLoaded(
      ApiEndpoints.colorsDict,
      () => api.getList(ApiEndpoints.colorsDict),
      (entries) => _colors = _nameMap(entries),
    ),
    ensureDictionaryLoaded(
      ApiEndpoints.unitsDict,
      () => api.getList(ApiEndpoints.unitsDict),
      (entries) => _units = _nameMap(entries),
    ),
  ]);

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
      for (final map in list) {
        final id = map['id'] as String;
        final info = GoodsDictEntry.fromJson(map);
        _goods[id] = info.name;
        _goodsInfo[id] = info;
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

  /// 单独重载币种字典（单据页内联新增币种后调用，让本实例的下拉选项立即含新值）。
  Future<void> reloadCurrencies() => ensureDictionaryLoaded(
    ApiEndpoints.currenciesDict,
    () => api.getList(ApiEndpoints.currenciesDict),
    (entries) => _currencies = _nameMap(entries),
    reload: true,
  );

  String warehouse(String? id) => resolveName(_warehouses, id);

  /// Build once per dictionary load, so document rows share a stable parent/child label.
  /// References remain UUIDs; names are never used to join or choose a warehouse.
  static Map<String, String> warehouseDisplayNames(
    List<WarehouseDictEntry> entries,
  ) {
    final byId = {for (final entry in entries) entry.id: entry};
    return {
      for (final entry in entries)
        entry.id: () {
          final labels = <String>[entry.name];
          final visited = <String>{entry.id};
          var current = entry;
          while (current.parentId != null) {
            final parentId = current.parentId!;
            if (!visited.add(parentId)) return '仓库层级异常';
            final parent = byId[parentId];
            if (parent == null) {
              final parentName = current.parentName?.trim();
              if (parentName != null && parentName.isNotEmpty) {
                labels.insert(0, parentName);
              }
              break;
            }
            labels.insert(0, parent.name);
            current = parent;
          }
          return labels.join(' - ');
        }(),
    };
  }

  /// Resolve only proven parent links. An orphan/cycle is not a new main warehouse.
  WarehouseDictEntry? mainWarehouseOf(String? id) {
    if (id == null) return null;
    if (_warehouseById.isEmpty) {
      return resolveMainWarehouse(warehouseHierarchy, id);
    }
    return _mainWarehouseCache.putIfAbsent(
      id,
      () => _mainWarehouseFromIndex(_warehouseById, id),
    );
  }

  static WarehouseDictEntry? resolveMainWarehouse(
    Iterable<WarehouseDictEntry> entries,
    String? id,
  ) {
    return _mainWarehouseFromIndex({
      for (final entry in entries) entry.id: entry,
    }, id);
  }

  static WarehouseDictEntry? _mainWarehouseFromIndex(
    Map<String, WarehouseDictEntry> byId,
    String? id,
  ) {
    var current = byId[id];
    final visited = <String>{};
    while (current != null && visited.add(current.id)) {
      final parentId = current.parentId;
      if (parentId == null || parentId.isEmpty) return current;
      current = byId[parentId];
    }
    return null;
  }

  String currency(String? id) => resolveName(_currencies, id);
  String color(String? id) => resolveName(_colors, id);
  String unit(String? id) => resolveName(_units, id);
  String goods(String? id) => resolveName(_goods, id);

  /// 货品字典详情（编号/系列/库位号；未加载时仅名称可用）。
  GoodsDictEntry? goodsInfo(String? id) =>
      id == null || id.isEmpty ? null : _goodsInfo[id];

  /// 补全货品详情缓存（编号/系列/库位号）：名称可能已由搜索缓存，但详情缺失时仍按需拉取。
  Future<void> loadGoodsDetails(Iterable<String> ids) async {
    final need = ids
        .where((id) => id.isNotEmpty && !_goodsInfo.containsKey(id))
        .toSet();
    if (need.isEmpty) return;
    try {
      final list = await api.getList(
        ApiEndpoints.goodsLookup,
        query: {'ids': need.join(',')},
      );
      for (final map in list) {
        final id = map['id'] as String;
        final info = GoodsDictEntry.fromJson(map);
        _goods.putIfAbsent(id, () => info.name);
        _goodsInfo[id] = info;
      }
    } catch (_) {
      // 同上：辅助信息可降级。
    }
  }

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

  /// 仓库层级列表（V476）：顶层仓在前、子仓紧随其后按编号排序；
  /// parentId 悬空（指向已删/未知仓）按顶层处理。旧后端无 parentId 时全为顶层。
  /// [_warehouseList] 为空但名称映射有值（测试 fake 只注名称映射）时按平铺退化。
  List<WarehouseDictEntry> get warehouseHierarchy {
    final source = _warehouseList.isNotEmpty
        ? _warehouseList
        : [
            for (final e in _warehouses.entries)
              WarehouseDictEntry(id: e.key, name: e.value),
          ];
    final byParent = <String, List<WarehouseDictEntry>>{};
    final known = source.map((e) => e.id).toSet();
    final roots = <WarehouseDictEntry>[];
    for (final e in source) {
      final parent = e.parentId;
      if (parent != null && parent.isNotEmpty && known.contains(parent)) {
        byParent.putIfAbsent(parent, () => []).add(e);
      } else {
        roots.add(e);
      }
    }
    int byCode(WarehouseDictEntry a, WarehouseDictEntry b) =>
        (a.code ?? '').compareTo(b.code ?? '');

    List<WarehouseDictEntry> flatten(List<WarehouseDictEntry> nodes) {
      final sorted = [...nodes]..sort(byCode);
      return [
        for (final n in sorted) ...[n, ...flatten(byParent[n.id] ?? const [])],
      ];
    }

    return flatten(roots);
  }

  /// 该仓库是否有子仓（V476）：即时库存页用它决定「含不良品仓」开关在
  /// 选父仓（多仓聚合）时仍可用、选叶子仓时置灰。
  bool warehouseHasChildren(String? id) {
    if (id == null || id.isEmpty) return false;
    return _warehouseList.any((e) => e.parentId == id);
  }

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

  /// 供应商状态（id → 使用/禁用；缺失视为启用，兼容旧后端未返回 status 的字典）。
  Map<String, String> _supplierStatus = {};

  /// 供应商默认结算方式（id → settlement_methods.id；V452。订货开单预填用，可空）。
  Map<String, String> _supplierDefaultSettlement = {};
  Map<String, String> _departments = {};
  Future<void> ensureLoaded() =>
      Future.wait([ensureCommonLoaded(), _loadSuppliers(), _loadDepartments()]);

  Future<void> _loadSuppliers({bool reload = false}) => ensureDictionaryLoaded(
    ApiEndpoints.suppliersDict,
    () => api.getList(ApiEndpoints.suppliersDict),
    (entries) {
      _suppliers = {
        for (final entry in entries)
          entry['id'] as String: (entry['name'] ?? '') as String,
      };
      _supplierStatus = {
        for (final entry in entries)
          if (entry['status'] != null)
            entry['id'] as String: entry['status'] as String,
      };
      _supplierDefaultSettlement = {
        for (final entry in entries)
          if (entry['defaultSettlementMethodId'] != null &&
              (entry['defaultSettlementMethodId'] as String).isNotEmpty)
            entry['id'] as String: entry['defaultSettlementMethodId'] as String,
      };
    },
    reload: reload,
  );

  /// 单据页内联新增供应商后重载字典（让本实例的下拉选项立即含新值）。
  Future<void> reloadSuppliers() => _loadSuppliers(reload: true);

  Future<void> _loadDepartments() => ensureDictionaryLoaded(
    ApiEndpoints.departmentsTree,
    () => api.getList(ApiEndpoints.departmentsTree),
    (entries) => _departments = _flattenDeptTree(entries),
  );

  String supplier(String? id) =>
      MasterDictionaryService.resolveName(_suppliers, id);
  String department(String? id) =>
      MasterDictionaryService.resolveName(_departments, id);

  Map<String, String> get supplierEntries => _suppliers;

  /// 启用中的供应商（单据表单下拉用）：禁用项不进选项，避免对禁用商下新单。
  /// 名称解析仍走 [supplierEntries] 全量（历史单据可能引用禁用商）。
  Map<String, String> get supplierActiveEntries => {
    for (final entry in _suppliers.entries)
      if (_supplierStatus[entry.key] != '禁用') entry.key: entry.value,
  };

  /// 供应商是否禁用（状态缺失视为启用）。
  bool isSupplierDisabled(String? id) =>
      id != null && _supplierStatus[id] == '禁用';

  /// 供应商主档默认结算方式 id（V452；未维护返回 null）。仅作开单预填，
  /// 单据保存/审核仍按各自必填与订单快照校验。
  String? supplierDefaultSettlement(String? id) =>
      id == null || id.isEmpty ? null : _supplierDefaultSettlement[id];

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
