/// A library entry keeps its immutable identity when renamed or moved.
class CompanyFile {
  const CompanyFile({
    required this.id,
    required this.name,
    required this.kind,
    required this.version,
    required this.allowedActions,
    this.parentId,
    this.description = '',
    this.position = 0,
    this.passwordProtected = false,
    this.locked = false,
    this.deleted = false,
    this.pending = false,
    this.attachmentId,
    this.sizeBytes = 0,
    this.contentType,
    this.createdAt,
    this.updatedAt,
    this.deletedAt,
    this.createdByName,
    this.updatedByName,
  });

  final String id;
  final String? parentId;
  final String name;
  final String kind;
  final String description;
  final int version;
  final int position;
  final bool passwordProtected;
  final bool locked;
  final bool deleted;
  final bool pending;
  final String? attachmentId;
  final int sizeBytes;
  final String? contentType;
  final String? createdAt;
  final String? updatedAt;
  final String? deletedAt;
  final String? createdByName;
  final String? updatedByName;
  final Set<String> allowedActions;

  bool get isFolder => kind == 'FOLDER';
  bool allows(String action) => allowedActions.contains(action);

  factory CompanyFile.fromJson(Map<String, dynamic> json) => CompanyFile(
    id: json['id'] as String,
    parentId: json['parentId'] as String?,
    name: json['name'] as String,
    kind: json['kind'] as String,
    description: json['description'] as String? ?? '',
    version: (json['version'] as num?)?.toInt() ?? 0,
    position: (json['position'] as num?)?.toInt() ?? 0,
    passwordProtected: json['passwordProtected'] == true,
    locked: json['locked'] == true,
    deleted: json['deleted'] == true,
    pending: json['pending'] == true,
    attachmentId: json['attachmentId'] as String?,
    sizeBytes: (json['sizeBytes'] as num?)?.toInt() ?? 0,
    contentType: json['contentType'] as String?,
    createdAt: json['createdAt'] as String?,
    updatedAt: json['updatedAt'] as String?,
    deletedAt: json['deletedAt'] as String?,
    createdByName: json['createdByName'] as String?,
    updatedByName: json['updatedByName'] as String?,
    allowedActions: Set.unmodifiable(
      (json['allowedActions'] as List? ?? const []).cast<String>(),
    ),
  );
}

class CompanyFileBreadcrumb {
  const CompanyFileBreadcrumb({required this.id, required this.name});
  final String id;
  final String name;
  factory CompanyFileBreadcrumb.fromJson(Map<String, dynamic> json) =>
      CompanyFileBreadcrumb(
        id: json['id'] as String,
        name: json['name'] as String,
      );
}

class CompanyFileListing {
  const CompanyFileListing({
    this.folder,
    this.breadcrumbs = const [],
    this.entries = const [],
    this.allowedActions = const {},
    this.total = 0,
    this.page = 0,
    this.size = 100,
    this.canReorder = false,
  });
  final CompanyFile? folder;
  final List<CompanyFileBreadcrumb> breadcrumbs;
  final List<CompanyFile> entries;
  final Set<String> allowedActions;
  final int total;
  final int page;
  final int size;
  final bool canReorder;
  bool allows(String action) => allowedActions.contains(action);
  factory CompanyFileListing.fromJson(
    Map<String, dynamic> json,
  ) => CompanyFileListing(
    folder: json['folder'] is Map
        ? CompanyFile.fromJson(Map<String, dynamic>.from(json['folder'] as Map))
        : null,
    breadcrumbs: List.unmodifiable(
      (json['breadcrumbs'] as List? ?? const []).map(
        (e) =>
            CompanyFileBreadcrumb.fromJson(Map<String, dynamic>.from(e as Map)),
      ),
    ),
    entries: List.unmodifiable(
      (json['entries'] as List? ?? const []).map(
        (e) => CompanyFile.fromJson(Map<String, dynamic>.from(e as Map)),
      ),
    ),
    allowedActions: Set.unmodifiable(
      (json['allowedActions'] as List? ?? const []).cast<String>(),
    ),
    total: (json['total'] as num?)?.toInt() ?? 0,
    page: (json['page'] as num?)?.toInt() ?? 0,
    size: (json['size'] as num?)?.toInt() ?? 100,
    canReorder: json['canReorder'] == true,
  );
}

class CompanyFileAccessRule {
  const CompanyFileAccessRule({
    required this.subjectType,
    required this.subjectId,
    required this.subjectName,
    this.effect = 'ALLOW',
    this.actions = const {'view', 'download'},
  });
  final String subjectType;
  final String subjectId;
  final String subjectName;
  final String effect;
  final Set<String> actions;
  CompanyFileAccessRule copyWith({String? effect, Set<String>? actions}) =>
      CompanyFileAccessRule(
        subjectType: subjectType,
        subjectId: subjectId,
        subjectName: subjectName,
        effect: effect ?? this.effect,
        actions: Set.unmodifiable(actions ?? this.actions),
      );
  Map<String, dynamic> toJson() => {
    'subjectType': subjectType,
    'subjectId': subjectId,
    'effect': effect,
    'actions': actions.toList(),
  };
  factory CompanyFileAccessRule.fromJson(Map<String, dynamic> json) =>
      CompanyFileAccessRule(
        subjectType: json['subjectType'] as String,
        subjectId: json['subjectId'] as String,
        subjectName: json['subjectName'] as String? ?? '',
        effect: json['effect'] as String,
        actions: Set.unmodifiable((json['actions'] as List).cast<String>()),
      );
}

class CompanyFileAccess {
  const CompanyFileAccess({
    required this.inheritPermissions,
    required this.version,
    required this.rules,
  });
  final bool inheritPermissions;
  final int version;
  final List<CompanyFileAccessRule> rules;
  factory CompanyFileAccess.fromJson(Map<String, dynamic> json) =>
      CompanyFileAccess(
        inheritPermissions: json['inheritPermissions'] == true,
        version: (json['version'] as num).toInt(),
        rules: List.unmodifiable(
          (json['rules'] as List? ?? const []).map(
            (e) => CompanyFileAccessRule.fromJson(
              Map<String, dynamic>.from(e as Map),
            ),
          ),
        ),
      );
}

class CompanyFilePrincipal {
  const CompanyFilePrincipal({
    required this.id,
    required this.name,
    required this.type,
    this.detail = '',
  });
  final String id;
  final String name;
  final String type;
  final String detail;
  factory CompanyFilePrincipal.fromJson(Map<String, dynamic> json) =>
      CompanyFilePrincipal(
        id: json['id'] as String,
        name: json['name'] as String,
        type: json['type'] as String,
        detail: json['detail'] as String? ?? '',
      );
}
