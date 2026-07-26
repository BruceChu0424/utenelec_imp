// 主档名称解析（销售单据展示用）。
//
// 与采购模块同形：单据 DTO 只带 UUID（客户/仓库/币种/颜色/单位/货品均无名称）。
// 本服务懒加载并缓存小表全量 dict（仓库/币种/颜色/单位），客户无 /dict 端点→
// 走 /master/clients?size=9999 一次性拉全量建 dict；货品(3.5万)按 id 批量 lookup。
//
// 与 purchase/providers/master_name_provider.dart 的差异：clients 替 suppliers；
// 其他端点（warehousesDict/currenciesDict/colorsDict/unitsDict/goodsLookup）复用。
// 货品搜索（编辑页 typeahead）复用 purchase 的 showGoodsPickerDialog（其内部用采购
// MasterNameService.searchGoods —— 货品搜索与模块无关，复用避免重复造）。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';

/// 货品搜索/选择用的轻量项（与采购 GoodsOption 同形，独立定义避免跨模块依赖）。
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

class SalesMasterNameService {
  SalesMasterNameService(this.api);
  final ApiClient api;

  Map<String, String> _clients = {};
  Map<String, String> _warehouses = {};
  Map<String, String> _currencies = {};
  Map<String, String> _colors = {};
  Map<String, String> _units = {};
  final Map<String, String> _goods = {};
  bool _loaded = false;

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    try {
      // 客户无 /dict 端点：拉全量（size=9999）后建 dict。其他主档走 dict（小表）。
      // Future.wait 混合返回类型 → 用显式 await 分别取（Future.wait 会把异型合并成 List<Object>）。
      final clientFut = api.get('/master/clients', query: {'page': 1, 'size': 9999});
      final warehouseFut = api.getList('/master/warehouses/dict');
      final currencyFut = api.getList('/master/currencies/dict');
      final colorFut = api.getList('/master/colors/dict');
      final unitFut = api.getList('/master/units/dict');
      final clientPage = await clientFut;
      final warehouses = await warehouseFut;
      final currencies = await currencyFut;
      final colors = await colorFut;
      final units = await unitFut;

      final clientItems = clientPage['items'];
      if (clientItems is List) {
        _clients = {
          for (final e in clientItems)
            if (e is Map<String, dynamic>)
              e['id'] as String: ((e['name'] ?? e['fullName'] ?? '') as String),
        };
      }
      _warehouses = {
        for (final e in warehouses) e['id'] as String: (e['name'] ?? '') as String
      };
      _currencies = {
        for (final e in currencies) e['id'] as String: (e['name'] ?? '') as String
      };
      _colors = {
        for (final e in colors) e['id'] as String: (e['name'] ?? '') as String
      };
      _units = {
        for (final e in units) e['id'] as String: (e['name'] ?? '') as String
      };
    } catch (_) {
      // 静默降级：解析不到显示 '—'，不阻塞列表
    }
    _loaded = true;
  }

  /// 货品名按 id 批量解析（只查本地未缓存的 id，带缓存）。
  Future<void> loadGoodsNames(Iterable<String> ids) async {
    final need =
        ids.where((id) => id.isNotEmpty && !_goods.containsKey(id)).toSet();
    if (need.isEmpty) return;
    try {
      final list = await api.getList('/master/goods/lookup',
          query: {'ids': need.join(',')});
      for (final e in list) {
        _goods[e['id'] as String] = ((e['name'] ?? '') as String);
      }
    } catch (_) {/* 静默 */}
  }

  /// 货品关键词搜索（编辑页 picker 用）。
  Future<List<GoodsOption>> searchGoods(String keyword, {int size = 20}) async {
    if (keyword.trim().isEmpty) return const [];
    final json = await api.get('/master/goods',
        query: {'keyword': keyword.trim(), 'page': 1, 'size': size});
    final items = json['items'];
    if (items is! List) return const [];
    final out = items
        .map((e) => GoodsOption.fromJson(e as Map<String, dynamic>))
        .toList();
    for (final g in out) {
      if (g.name != null && g.name!.isNotEmpty) _goods[g.id] = g.name!;
    }
    return out;
  }

  String client(String? id) => _resolve(_clients, id);
  String warehouse(String? id) => _resolve(_warehouses, id);
  String currency(String? id) => _resolve(_currencies, id);
  String color(String? id) => _resolve(_colors, id);
  String unit(String? id) => _resolve(_units, id);
  String goods(String? id) => _resolve(_goods, id);

  Map<String, String> get clientEntries => _clients;
  Map<String, String> get warehouseEntries => _warehouses;
  Map<String, String> get currencyEntries => _currencies;
  Map<String, String> get colorEntries => _colors;
  Map<String, String> get unitEntries => _units;

  String _resolve(Map<String, String> map, String? id) =>
      (id != null && id.isNotEmpty && map[id]?.isNotEmpty == true)
          ? map[id]!
          : '—';
}

final salesMasterNameServiceProvider = Provider<SalesMasterNameService>(
  (ref) => SalesMasterNameService(ref.watch(apiClientProvider)),
);
