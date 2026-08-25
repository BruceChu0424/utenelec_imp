import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_endpoints.dart';
import '../providers/session_provider.dart';

/// Server-whitelisted document owner scopes. Keep values aligned with
/// DocumentScopeCapabilityService; arbitrary caller-provided scopes are not accepted.
enum DocumentDataScope {
  sales('sales'),
  finance('finance'),
  purchase('purchase'),
  subcontract('subcontract'),
  productionPlan('production_plan'),
  stockDocument('stock_doc');

  const DocumentDataScope(this.apiValue);
  final String apiValue;
}

const documentScopeReadOnlyMessage = '该单据当前仅可查看；如需修改，请由负责人操作或先完成正式数据交接';

class DocumentScopeCapability {
  const DocumentScopeCapability({
    required this.scope,
    required this.writeAll,
    required this.writableOwnerIds,
  });

  final String scope;
  final bool writeAll;
  final Set<String> writableOwnerIds;

  bool canWrite(String? ownerEmployeeId) {
    final owner = ownerEmployeeId?.trim();
    if (owner == null || owner.isEmpty) return false;
    return writeAll || writableOwnerIds.contains(owner);
  }

  factory DocumentScopeCapability.fromJson(Map<String, dynamic> json) {
    final scope = json['scope'];
    final writeAll = json['writeAll'];
    final rawOwners = json['writableOwnerIds'];
    if (scope is! String ||
        scope.trim().isEmpty ||
        writeAll is! bool ||
        rawOwners is! List) {
      throw const FormatException('Malformed document scope capability');
    }
    final owners = <String>{};
    for (final value in rawOwners) {
      if (value is! String || value.trim().isEmpty) {
        throw const FormatException('Malformed writable owner id');
      }
      owners.add(value.trim());
    }
    return DocumentScopeCapability(
      scope: scope.trim(),
      writeAll: writeAll,
      writableOwnerIds: Set.unmodifiable(owners),
    );
  }
}

abstract interface class DocumentScopeCapabilityRepository {
  Future<DocumentScopeCapability> current(DocumentDataScope scope);
}

class DioDocumentScopeCapabilityRepository
    implements DocumentScopeCapabilityRepository {
  const DioDocumentScopeCapabilityRepository(this._api);

  final ApiClient _api;

  @override
  Future<DocumentScopeCapability> current(DocumentDataScope scope) async {
    final json = await _api.get(
      ApiEndpoints.documentScopeCapability(scope.apiValue),
    );
    final capability = DocumentScopeCapability.fromJson(json);
    if (capability.scope != scope.apiValue) {
      throw const FormatException('Document scope capability mismatch');
    }
    return capability;
  }
}

final documentScopeCapabilityRepositoryProvider =
    Provider<DocumentScopeCapabilityRepository>(
      (ref) =>
          DioDocumentScopeCapabilityRepository(ref.watch(apiClientProvider)),
    );

/// Cached per scope and invalidated whenever the visible login/impersonation
/// subject changes. Callers must treat loading and error states as read-only.
final documentScopeCapabilityProvider = FutureProvider.autoDispose
    .family<DocumentScopeCapability, DocumentDataScope>((ref, scope) {
      ref.watch(sessionProvider.select((state) => state.user));
      return ref
          .watch(documentScopeCapabilityRepositoryProvider)
          .current(scope);
    });

bool documentOwnerCanWrite(
  AsyncValue<DocumentScopeCapability> capability,
  String? ownerEmployeeId,
) => capability.maybeWhen(
  data: (value) => value.canWrite(ownerEmployeeId),
  orElse: () => false,
);

/// Direct edit routes must not render an editable fallback while capability is
/// loading or unavailable. A failed capability request is therefore read-only.
Future<bool> loadDocumentOwnerCanWrite(
  WidgetRef ref,
  DocumentDataScope scope,
  String? ownerEmployeeId,
) async {
  try {
    final capability = await ref.read(
      documentScopeCapabilityProvider(scope).future,
    );
    return capability.canWrite(ownerEmployeeId);
  } catch (_) {
    return false;
  }
}
