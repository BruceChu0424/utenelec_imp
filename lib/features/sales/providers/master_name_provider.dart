// 销售单据名称解析：复用跨模块字典缓存，仅补充客户主档。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../shared/providers/master_name_provider.dart';

export '../../../shared/providers/master_name_provider.dart' show GoodsOption;

class SalesMasterNameService extends MasterDictionaryService {
  SalesMasterNameService(super.api);

  Map<String, String> _clients = {};
  Map<String, String> _selectableClients = {};
  Future<void> ensureLoaded() =>
      Future.wait([ensureCommonLoaded(), _loadClients()]);

  Future<void> _loadClients() => ensureDictionaryLoaded(
    ApiEndpoints.clientsDict,
    () => api.getList(ApiEndpoints.clientsDict),
    (items) {
      // 专用字典只返回 id/code/name，避免分页截断和批量下发联系方式、银行账号等敏感字段。
      final clients = <String, String>{};
      final selectableClients = <String, String>{};
      for (final entry in items) {
        final id = entry['id'] as String;
        final name = (entry['name'] ?? '') as String;
        final code = (entry['code'] ?? '') as String;
        final selectable = entry['selectable'];
        clients[id] = name;
        if (selectable == true ||
            selectable == null && !code.startsWith('LEGACY-FIN-CL-')) {
          selectableClients[id] = name;
        }
      }
      _clients = clients;
      _selectableClients = selectableClients;
    },
  );

  String client(String? id) =>
      MasterDictionaryService.resolveName(_clients, id);
  Map<String, String> get clientEntries => _clients;
  Map<String, String> get selectableClientEntries => _selectableClients;
}

final salesMasterNameServiceProvider = Provider<SalesMasterNameService>((ref) {
  ref.watch(masterDataSessionKeyProvider);
  return SalesMasterNameService(ref.watch(apiClientProvider));
});
