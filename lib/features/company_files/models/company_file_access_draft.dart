import 'company_file.dart';

/// Initial access is saved atomically with a new entry, never as a system grant.
/// Passwords are ephemeral command input and deliberately have no debug rendering.
final class CompanyFileInitialAccessDraft {
  CompanyFileInitialAccessDraft({
    this.inheritPermissions = true,
    List<CompanyFileAccessRule> rules = const [],
    this.password,
  }) : rules = List.unmodifiable(
         rules.map(
           (rule) => CompanyFileAccessRule(
             subjectType: rule.subjectType,
             subjectId: rule.subjectId,
             subjectName: rule.subjectName,
             effect: rule.effect,
             actions: Set.unmodifiable(rule.actions),
           ),
         ),
       );

  const CompanyFileInitialAccessDraft.inherited()
    : inheritPermissions = true,
      rules = const [],
      password = null;

  final bool inheritPermissions;
  final List<CompanyFileAccessRule> rules;
  final String? password;

  Map<String, dynamic> toJson() => {
    'inheritPermissions': inheritPermissions,
    'rules': rules.map((rule) => rule.toJson()).toList(growable: false),
    'password': password,
  };
}

final class CompanyFileCreateFolderDraft {
  const CompanyFileCreateFolderDraft({
    required this.name,
    required this.description,
    required this.access,
  });

  final String name;
  final String description;
  final CompanyFileInitialAccessDraft access;
}
