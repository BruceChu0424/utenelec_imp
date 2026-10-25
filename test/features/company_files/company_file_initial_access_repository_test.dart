import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/company_files/models/company_file.dart';
import 'package:uten_imp/features/company_files/models/company_file_access_draft.dart';
import 'package:uten_imp/features/company_files/repositories/company_file_repository.dart';

class _CommandApi extends ApiClient {
  _CommandApi() : super(Dio(BaseOptions(baseUrl: 'https://library.test/api')));
  final calls =
      <
        ({
          String path,
          Map<String, dynamic> body,
          Map<String, dynamic>? headers,
          Map<String, dynamic>? query,
        })
      >[];

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    final command = Map<String, dynamic>.from(body! as Map);
    calls.add((path: path, body: command, headers: headers, query: query));
    return {
      'id': 'created-node',
      'name': command['name'],
      'kind': path.endsWith('/folders') ? 'FOLDER' : 'FILE',
      'version': 0,
      'allowedActions': ['view'],
    };
  }
}

void main() {
  CompanyFileInitialAccessDraft privateAccess() =>
      CompanyFileInitialAccessDraft(
        inheritPermissions: false,
        rules: const [
          CompanyFileAccessRule(
            subjectType: 'USER',
            subjectId: 'reader-id',
            subjectName: '查看人(10010)',
          ),
          CompanyFileAccessRule(
            subjectType: 'DEPARTMENT',
            subjectId: 'department-id',
            subjectName: '研发部',
          ),
        ],
        password: 'Synthetic-access-password-1!',
      );

  test(
    'folder creation carries one atomic entry access command without system grants',
    () async {
      final api = _CommandApi(), access = privateAccess();
      final entry = await CompanyFileRepository(api).createFolder(
        parentId: 'parent-id',
        name: '部门模板',
        description: '受限资料',
        access: access,
      );
      expect(entry.id, 'created-node');
      expect(api.calls, hasLength(1));
      final call = api.calls.single;
      expect(call.path, '/company-files/folders');
      expect(call.body['access'], access.toJson());
      expect(call.body['parentId'], 'parent-id');
      expect(call.body.toString(), isNot(contains('company_file:')));
      expect(call.body.toString(), isNot(contains('authorization:')));
      expect(call.path, isNot(contains(access.password!)));
      expect(call.query.toString(), isNot(contains(access.password!)));
      expect(call.headers.toString(), isNot(contains(access.password!)));
    },
  );

  test(
    'a file reservation uses the same per-entry access contract and immutable request ID',
    () async {
      final api = _CommandApi(), access = privateAccess();
      await CompanyFileRepository(api).reserveFile(
        parentId: 'parent-id',
        name: '内部模板.docx',
        requestId: 'request-id',
        access: access,
      );
      final call = api.calls.single;
      expect(call.path, '/company-files/files');
      expect(call.body['access'], access.toJson());
      expect(call.body['requestId'], 'request-id');
      final rules = List<Map<String, dynamic>>.from(
        (call.body['access'] as Map)['rules'] as List,
      );
      expect(rules.map((rule) => rule['subjectType']), ['USER', 'DEPARTMENT']);
      expect(
        rules.every(
          (rule) => (rule['actions'] as List).cast<String>().toSet().difference(
            {'view', 'download'},
          ).isEmpty,
        ),
        isTrue,
      );
    },
  );

  test(
    'old callers omit initial access and retain the inherited server default',
    () async {
      final api = _CommandApi();
      await CompanyFileRepository(api).createFolder(name: '原有调用');
      await CompanyFileRepository(
        api,
      ).reserveFile(name: '原有模板.txt', requestId: 'fixed-request');
      expect(api.calls, hasLength(2));
      expect(
        api.calls.every((call) => !call.body.containsKey('access')),
        isTrue,
      );
    },
  );

  test(
    'initial access freezes mutable rule inputs and never exposes passwords in debug text',
    () {
      final actions = <String>{'view', 'download'};
      final rules = [
        CompanyFileAccessRule(
          subjectType: 'USER',
          subjectId: 'reader',
          subjectName: 'Reader',
          actions: actions,
        ),
      ];
      final access = CompanyFileInitialAccessDraft(
        inheritPermissions: false,
        rules: rules,
        password: 'Synthetic-access-password-1!',
      );
      actions.clear();
      rules.clear();
      expect(access.rules, hasLength(1));
      expect(access.rules.single.actions, {'view', 'download'});
      expect(access.toString(), isNot(contains(access.password!)));
    },
  );
}
