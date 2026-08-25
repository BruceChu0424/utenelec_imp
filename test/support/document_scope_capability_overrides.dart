import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uten_imp/shared/auth/document_scope_capability.dart';

Override writeAllDocumentScope(DocumentDataScope scope) =>
    documentScopeCapabilityProvider(scope).overrideWith(
      (ref) async => DocumentScopeCapability(
        scope: scope.apiValue,
        writeAll: true,
        writableOwnerIds: const <String>{},
      ),
    );

Override financeWriteAllDocumentScope() =>
    writeAllDocumentScope(DocumentDataScope.finance);

Override subcontractWriteAllDocumentScope() =>
    writeAllDocumentScope(DocumentDataScope.subcontract);

Override productionWriteAllDocumentScope() =>
    writeAllDocumentScope(DocumentDataScope.productionPlan);
