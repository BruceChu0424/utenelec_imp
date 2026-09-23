// 会话级主档字典仓库(ADR-108) —— 仓库/币种/颜色/单位/供应商/客户/账户/部门等小表字典
// 在一个会话里只拉一份。
//
// 此前 Master/Sales/Finance 三个名称服务与颜色/单位两个 provider 各自缓存一份, 同一会话
// 重复拉取; 基础资料改了也不失效(只有 4 处手工 reloadXxx 补丁)。现在:
//   · 按字典端点(dictKey)单份缓存 + 单飞: 多个名称服务同时要同一份字典只发一次请求;
//   · 写后失效: 本端对某类主档的写请求成功后(网络层按路径识别, 见 [masterDictKeysForWrite]),
//     对应字典作废并推进 [masterDictionaryRevisionProvider], 已加载该字典的名称服务
//     与下拉 provider 随之重取;
//   · 会话隔离: 绑定 masterDataSessionKeyProvider, 换号/权限变化即整体丢弃。
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_endpoints.dart';
import '../../core/network/data_write_revision.dart';
import 'master_name_provider.dart' show masterDataSessionKeyProvider;

/// 账户字典端点(钱流账户; 定义在 basic_data 仓储里, 这里只需路径)。
const masterAccountsDictKey = '/master/accounts/dict';

class MasterDictionaryRepository {
  MasterDictionaryRepository(this._api);

  final ApiClient _api;
  final Map<String, List<Map<String, dynamic>>> _cache = {};
  final Map<String, Future<List<Map<String, dynamic>>>> _loads = {};
  final StreamController<String> _invalidations =
      StreamController<String>.broadcast();

  /// 某字典的原始行(单飞; 只缓存成功结果, 失败下次再拉)。
  Future<List<Map<String, dynamic>>> load(String dictKey) {
    final cached = _cache[dictKey];
    if (cached != null) return Future.value(cached);
    final pending = _loads[dictKey];
    if (pending != null) return pending;
    final completer = Completer<List<Map<String, dynamic>>>();
    final future = completer.future;
    _loads[dictKey] = future;
    unawaited(() async {
      try {
        final rows = List<Map<String, dynamic>>.unmodifiable(
          await _api.getList(dictKey),
        );
        // 在途期间被写后失效的结果不入缓存(下一次取会重新拉)。
        if (identical(_loads[dictKey], future)) _cache[dictKey] = rows;
        completer.complete(rows);
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      } finally {
        if (identical(_loads[dictKey], future)) _loads.remove(dictKey);
      }
    }());
    return future;
  }

  /// 已在内存里的字典(没拉过返回 null)。
  List<Map<String, dynamic>>? cached(String dictKey) => _cache[dictKey];

  /// 字典作废通知(已加载该字典的名称服务据此重取)。
  Stream<String> get invalidations => _invalidations.stream;

  /// 写后失效: 丢弃缓存与在途请求, 通知订阅方。
  void invalidate(String dictKey) {
    _cache.remove(dictKey);
    _loads.remove(dictKey);
    _invalidations.add(dictKey);
  }

  void dispose() => _invalidations.close();
}

final masterDictionaryRepositoryProvider = Provider<MasterDictionaryRepository>(
  (ref) {
    ref.watch(masterDataSessionKeyProvider);
    final repository = MasterDictionaryRepository(ref.watch(apiClientProvider));
    ref.onDispose(repository.dispose);
    // 本端对主档的写请求成功 → 作废对应字典(路径由网络层记下, 见 lastDataWriteProvider)。
    ref.listen(lastDataWriteProvider, (_, write) {
      if (write == null) return;
      final keys = masterDictKeysForWrite(write.path);
      if (keys.isEmpty) return;
      for (final key in keys) {
        repository.invalidate(key);
      }
      ref.read(masterDictionaryRevisionProvider.notifier).state++;
    });
    return repository;
  },
);

/// 主档字典修订号: 任一字典写后失效时 +1, 下拉类 provider watch 它随之重取。
final masterDictionaryRevisionProvider = StateProvider<int>((ref) => 0);

/// 写请求路径 → 需要作废的字典端点。只认主档写入口, 其它写请求返回空。
List<String> masterDictKeysForWrite(String path) {
  // 路径可能带部署前缀(如 /api), 按「以该段结尾或包含该段加斜杠」判断。
  bool under(String prefix) =>
      path.endsWith(prefix) || path.contains('$prefix/');
  return [
    if (under('/master/warehouses')) ApiEndpoints.warehousesDict,
    if (under('/master/currencies')) ApiEndpoints.currenciesDict,
    if (under('/master/colors')) ApiEndpoints.colorsDict,
    if (under('/master/units')) ApiEndpoints.unitsDict,
    if (under('/master/suppliers')) ApiEndpoints.suppliersDict,
    if (under('/master/clients')) ApiEndpoints.clientsDict,
    if (under('/master/accounts')) masterAccountsDictKey,
    if (under('/org/departments')) ApiEndpoints.departmentsTree,
  ];
}
