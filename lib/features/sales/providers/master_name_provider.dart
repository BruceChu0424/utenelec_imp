// 销售单据名称解析：复用跨模块字典缓存，仅补充客户主档。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../shared/providers/master_dictionary_repository.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../../../shared/providers/master_party_lookup.dart';

export '../../../shared/providers/master_name_provider.dart' show GoodsOption;

class SalesMasterNameService extends MasterDictionaryService {
  SalesMasterNameService(
    super.api, [
    super.dictionaries,
    super.partyReferences,
  ]);

  Future<void> ensureLoaded() => ensureCommonLoaded();

  String client(String? id) =>
      MasterDictionaryService.resolveName(clientReferenceNames, id);
  Map<String, String> get clientEntries => clientReferenceNames;

  /// Only already-resolved references; real choices use the paged client picker.
  Map<String, String> get selectableClientEntries => {
    for (final entry in clientReferenceNames.entries)
      if (_selectableReference(entry.key)) entry.key: entry.value,
  };
  bool _selectableReference(String id) {
    final row = partyReferences.reference(MasterPartyKind.client, id);
    return row?['selectable'] == true ||
        row?['selectable'] == null &&
            !(row?['code']?.toString().startsWith('LEGACY-FIN-CL-') ?? false);
  }
}

final salesMasterNameServiceProvider = Provider<SalesMasterNameService>((ref) {
  ref.watch(masterDataSessionKeyProvider);
  final service = SalesMasterNameService(
    ref.watch(apiClientProvider),
    ref.watch(masterDictionaryRepositoryProvider),
    ref.watch(masterPartyLookupProvider),
  );
  void changed() {
    if (ref.mounted) ref.notifyListeners();
  }

  service.addListener(changed);
  ref.onDispose(() {
    service.removeListener(changed);
    service.dispose();
  });
  return service;
}, dependencies: [masterPartyLookupProvider]);
