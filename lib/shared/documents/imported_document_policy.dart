/// Original business documents remain readable evidence. Master data and current
/// stock do not use this policy merely because they retain an old identifier.
enum BusinessDocumentOrigin {
  current('CURRENT'),
  legacy('LEGACY'),
  all('ALL');

  const BusinessDocumentOrigin(this.apiValue);
  final String apiValue;
}

const importedBusinessHistoryLabel = '历史已结案 · 只读';
const importedBusinessReadOnlyReason = '旧系统历史单据仅供查询，不再办理业务。';

bool importedBusinessDocument(Map<String, dynamic> json) =>
    json['historyReadOnly'] == true ||
    json['legacyImported'] == true ||
    json['legacyId'] != null ||
    json['legacyImportRunId'] != null;

bool importedDocumentPermissionAllowed(String permission, bool readOnly) =>
    !readOnly ||
    permission.endsWith(':view') ||
    permission.contains(':view:') ||
    permission.endsWith(':print') ||
    permission.endsWith(':export') ||
    permission.endsWith(':download');

/// An archive is independent of the original workflow status. A caller can
/// still apply an explicit business date/search filter without hiding raw0/-1.
Map<String, dynamic> businessDocumentOriginQuery({
  required BusinessDocumentOrigin origin,
  int? status,
  String? financeApproval,
  bool? closed,
}) => {
  'originScope': origin.apiValue,
  if (origin != BusinessDocumentOrigin.legacy) ...{
    'status': ?status,
    'financeApproval': ?financeApproval,
    'closed': ?closed,
  },
};
