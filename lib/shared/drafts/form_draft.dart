import '../badges/badge_module.dart';

export '../badges/badge_module.dart';

/// A recoverable editor snapshot, never a submitted business document.
class FormDraftSpec {
  const FormDraftSpec({
    required this.title,
    required this.module,
    required this.route,
    required this.permission,
    this.draftKind,
  });

  final String title;
  final BadgeModule module;
  final String route;
  final String permission;
  final String? draftKind;

  /// The active editor is the authority for legacy and catalog-created drafts.
  /// Same-page dialogs can share a permission yet have incompatible payloads.
  bool canRestore(FormDraft draft, {required String currentRoute}) {
    if (!formDraftRouteIsLocal(draft.route) ||
        !formDraftRouteIsLocal(currentRoute) ||
        !formDraftRouteIsLocal(route)) {
      return false;
    }
    final stored = Uri.parse(draft.route);
    final expected = Uri.parse(route);
    final current = Uri.parse(currentRoute);
    return stored.path == current.path &&
        stored.path == expected.path &&
        draft.permission == permission &&
        draft.module == module &&
        draft.draftKind == draftKind &&
        _singleDraftForm(stored) == _singleDraftForm(expected) &&
        (stored.queryParametersAll['draftForm']?.length ?? 0) <= 1;
  }
}

String? _singleDraftForm(Uri uri) => uri.queryParameters['draftForm'];

bool formDraftRouteIsLocal(String route) {
  final uri = Uri.tryParse(route);
  return uri != null &&
      route.startsWith('/') &&
      !route.startsWith('//') &&
      !uri.hasScheme &&
      !uri.hasAuthority &&
      !uri.hasFragment &&
      !uri.path.contains('\\');
}

class FormDraft {
  const FormDraft({
    required this.id,
    required this.title,
    required this.module,
    required this.route,
    required this.permission,
    required this.updatedAt,
    required this.data,
    this.draftKind,
    this.revision = '',
  });

  final String id;
  final String title;
  final BadgeModule module;
  final String route;
  final String permission;
  final String? draftKind;
  final DateTime updatedAt;
  final Map<String, dynamic> data;
  final String revision;

  String get resumeLocation {
    final uri = Uri.parse(route);
    return uri
        .replace(queryParameters: {...uri.queryParameters, 'draftId': id})
        .toString();
  }

  Map<String, dynamic> toJson() => {
    'version': 1,
    'id': id,
    'title': title,
    'module': module.name,
    'route': route,
    'permission': permission,
    'draftKind': draftKind,
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'data': data,
    'revision': revision,
  };

  factory FormDraft.fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1) throw const FormatException('草稿版本不受支持');
    final route = json['route'] as String;
    if (!formDraftRouteIsLocal(route)) {
      throw const FormatException('草稿路径无效');
    }
    return FormDraft(
      id: json['id'] as String,
      title: json['title'] as String,
      module: BadgeModule.values.byName(json['module'] as String),
      route: route,
      permission: json['permission'] as String,
      draftKind: json['draftKind'] as String?,
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      data: Map<String, dynamic>.from(json['data'] as Map),
      revision: json['revision'] as String? ?? '',
    );
  }
}
