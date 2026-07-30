// 跨业务模块共用的主档名称解析。
//
// 单据 DTO 只带 UUID（供应商/仓库/币种/颜色/单位/货品均无名称）。本服务懒加载并缓存小表
// 全量 dict（供应商386/仓库6/币种3/颜色/单位），货品(3.5万)按 id 批量 lookup（带本地缓存）。
// 货品选择（编辑新增行）用 search（关键词 → 列表）。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_endpoints.dart';

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

class MasterNameService {
  MasterNameService(this.api);
  final ApiClient api;

  Map<String, String> _suppliers = {};
  Map<String, String> _warehouses = {};
  Map<String, String> _currencies = {};
  Map<String, String> _colors = {};
  Map<String, String> _units = {};

  /// legacy id → 新库 UUID（选货品后按 goods.colorLegacyId 回填 colorId/unitId 用）。
  /// colors/units dict 接口实际带 legacyId，之前解析时丢了，此处补建。
  Map<int, String> _colorByLegacy = {};
  Map<int, String> _unitByLegacy = {};
  final Map<String, String> _goods = {};

  /// 部门（车间=部门）id→名（ensureLoaded 时从部门树展平）。
  Map<String, String> _departments = {};

  /// 员工 id→名（按需 N+1 getById 缓存；员工无 dict 端点）。
  final Map<String, String> _employees = {};
  bool _loaded = false;

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    try {
      final results = await Future.wait([
        api.getList(ApiEndpoints.suppliersDict),
        api.getList(ApiEndpoints.warehousesDict),
        api.getList(ApiEndpoints.currenciesDict),
        api.getList(ApiEndpoints.colorsDict),
        api.getList(ApiEndpoints.unitsDict),
      ]);
      _suppliers = {
        for (final e in results[0])
          e['id'] as String: (e['name'] ?? '') as String,
      };
      _warehouses = {
        for (final e in results[1])
          e['id'] as String: (e['name'] ?? '') as String,
      };
      _currencies = {
        for (final e in results[2])
          e['id'] as String: (e['name'] ?? '') as String,
      };
      final colorMap = <String, String>{};
      final colorByLegacy = <int, String>{};
      for (final e in results[3]) {
        final id = e['id'] as String;
        colorMap[id] = (e['name'] ?? '') as String;
        final legacy = e['legacyId'];
        if (legacy is num) colorByLegacy[legacy.toInt()] = id;
      }
      _colors = colorMap;
      _colorByLegacy = colorByLegacy;
      final unitMap = <String, String>{};
      final unitByLegacy = <int, String>{};
      for (final e in results[4]) {
        final id = e['id'] as String;
        unitMap[id] = (e['name'] ?? '') as String;
        final legacy = e['legacyId'];
        if (legacy is num) unitByLegacy[legacy.toInt()] = id;
      }
      _units = unitMap;
      _unitByLegacy = unitByLegacy;
    } catch (_) {
      // 静默降级：解析不到显示 '—'，不阻塞列表
    }
    // 部门树（车间=部门）：全量小表，展平成 id→名供列表/详情解析。
    try {
      _departments = _flattenDeptTree(
        await api.getList(ApiEndpoints.departmentsTree),
      );
    } catch (_) {
      // 静默降级
    }
    _loaded = true;
  }

  /// 货品名按 id 批量解析（只查本地未缓存的 id，带缓存）。
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
      for (final e in list) {
        _goods[e['id'] as String] = ((e['name'] ?? '') as String);
      }
    } catch (_) {
      /* 静默 */
    }
  }

  /// 员工名按 id 批量解析（N+1 getById 缓存；员工无 dict 端点）。失败静默。
  Future<void> loadEmployeeNames(Iterable<String?> ids) async {
    final need = ids
        .whereType<String>()
        .where((id) => id.isNotEmpty && !_employees.containsKey(id))
        .toSet();
    if (need.isEmpty) return;
    try {
      await Future.wait(
        need.map((id) async {
          final e = await api.get(ApiEndpoints.employee(id));
          _employees[id] = (e['fullName'] as String?) ?? '';
        }),
      );
    } catch (_) {
      // 静默
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
    final out = items
        .map((e) => GoodsOption.fromJson(e as Map<String, dynamic>))
        .toList();
    // 顺手缓存命中的货品名
    for (final g in out) {
      if (g.name != null && g.name!.isNotEmpty) _goods[g.id] = g.name!;
    }
    return out;
  }

  String supplier(String? id) => _resolve(_suppliers, id);
  Map<String, String> get supplierEntries => _suppliers;
  Map<String, String> get warehouseEntries => _warehouses;
  Map<String, String> get currencyEntries => _currencies;
  Map<String, String> get colorEntries => _colors;
  Map<String, String> get unitEntries => _units;
  String warehouse(String? id) => _resolve(_warehouses, id);
  String currency(String? id) => _resolve(_currencies, id);
  String color(String? id) => _resolve(_colors, id);
  String unit(String? id) => _resolve(_units, id);
  String goods(String? id) => _resolve(_goods, id);
  String department(String? id) => _resolve(_departments, id);
  String employee(String? id) => _resolve(_employees, id);
  Map<String, String> get departmentEntries => _departments;

  /// 由 legacy id 查颜色新库 UUID（选货品后回填用）；查不到返回 null。
  String? colorIdByLegacy(int? legacy) =>
      (legacy == null) ? null : _colorByLegacy[legacy];
  String? unitIdByLegacy(int? legacy) =>
      (legacy == null) ? null : _unitByLegacy[legacy];

  String _resolve(Map<String, String> map, String? id) =>
      (id != null && id.isNotEmpty && map[id]?.isNotEmpty == true)
      ? map[id]!
      : '—';

  /// 部门树（嵌套 children）展平成 id→名（递归）。
  static Map<String, String> _flattenDeptTree(List<dynamic> nodes) {
    final out = <String, String>{};
    void walk(List<dynamic> list) {
      for (final raw in list) {
        final m = raw as Map<String, dynamic>;
        final id = m['id'] as String?;
        if (id != null) out[id] = (m['name'] ?? '') as String;
        final kids = m['children'];
        if (kids is List) walk(kids);
      }
    }

    walk(nodes);
    return out;
  }
}

final masterNameServiceProvider = Provider<MasterNameService>(
  (ref) => MasterNameService(ref.watch(apiClientProvider)),
);
