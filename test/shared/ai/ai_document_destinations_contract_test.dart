import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/router/permission_by_path.dart';
import 'package:uten_imp/core/router/route_access_policy.dart';
import 'package:uten_imp/shared/ai/chat/ai_chat_models.dart';

// Contract between the server page catalog for file answers and the client
// route guard (SPEC "AI 文件理解" Phase A, D5): the server offers a page chip
// only when the caller holds every permission it lists, and the chat re-checks
// the client guard before going there. If the two drifted, a permitted chip
// would land on the no-access page, or the server would offer a page the
// client guard hides. Each destination is one source line:
//   new Destination("employee", "员工档案", "/employee", List.of("employee:view"), "员工档案查看"),
// (key, title, fixed route, ALL permissions required, Chinese permission label
// used in plain "blocked" reasons).
const _catalogPath =
    'server/src/main/java/com/uten/imp/features/ai/chat/AiDocumentDestinations.java';

final _destination = RegExp(
  r'new Destination\(\s*"([^"]*)"\s*,\s*"([^"]*)"\s*,\s*"([^"]*)"\s*,\s*'
  r'List\.of\(([^)]*)\)\s*,\s*"([^"]*)"\s*\)',
);

typedef _Destination = ({
  String key,
  String title,
  String route,
  List<String> permissions,
  String label,
});

List<_Destination> _parse(String source) => [
  for (final match in _destination.allMatches(source))
    (
      key: match.group(1)!,
      title: match.group(2)!,
      route: match.group(3)!,
      permissions: [
        for (final code in RegExp(r'"([^"]*)"').allMatches(match.group(4)!))
          code.group(1)!,
      ],
      label: match.group(5)!,
    ),
];

void main() {
  final file = File(_catalogPath);

  test('the server page catalog for file answers exists', () {
    expect(
      file.existsSync(),
      isTrue,
      reason: '找不到 $_catalogPath; 请在仓库根目录运行, 或先完成服务端页面目录',
    );
  });

  test('every destination is one parseable line with a safe fixed route', () {
    if (!file.existsSync()) return;
    final source = file.readAsStringSync();
    final destinations = _parse(source);
    expect(destinations, isNotEmpty);
    // A literal split over lines (or written another way) would escape the
    // checks below, so every constructor call must match the one-line form.
    final lines = source
        .split('\n')
        .where((line) => line.contains('new Destination('))
        .toList();
    expect(
      lines.where((line) => _destination.hasMatch(line)),
      hasLength(lines.length),
      reason: '每个 Destination 必须写在一行内: $lines',
    );
    expect(destinations, hasLength(lines.length));
    final keys = <String>{};
    for (final page in destinations) {
      expect(RegExp(r'^[a-z][a-z0-9_]{0,47}$').hasMatch(page.key), isTrue);
      expect(keys.add(page.key), isTrue, reason: '重复的页面 key: ${page.key}');
      expect(page.title.trim(), isNotEmpty);
      expect(page.title.length, lessThanOrEqualTo(40));
      expect(
        safeAiChatPath(page.route),
        page.route,
        reason: '${page.key}: 路由必须是不带参数的本地路径',
      );
      expect(page.permissions, isNotEmpty, reason: page.key);
    }
  });

  test('the server never offers a page the client route guard would block', () {
    if (!file.existsSync()) return;
    final permissionCatalog = File(
      'lib/shared/auth/permissions.dart',
    ).readAsStringSync();
    for (final page in _parse(file.readAsStringSync())) {
      final server = page.permissions.toSet();
      for (final code in server) {
        expect(
          permissionCatalog.contains("'$code'"),
          isTrue,
          reason: '${page.key}: 未知权限码 $code',
        );
      }
      final all = requiredAllPermsFor(page.route);
      expect(
        server.containsAll(all),
        isTrue,
        reason: '${page.key} (${page.route}): 客户端要求全部持有 $all, 服务端只要求 $server',
      );
      final any = requiredAnyPermFor(page.route);
      if (any != null) {
        expect(
          any,
          isNotEmpty,
          reason: '${page.key} (${page.route}): 客户端对该路由一律拒绝',
        );
        expect(
          any.any(server.contains),
          isTrue,
          reason: '${page.key} (${page.route}): 客户端要求任一 $any, 服务端要求 $server',
        );
      }
      // Holding exactly what the server checks passes the same gate the
      // router and the chat apply (hub pages included).
      expect(
        locationAllowedFor(server, false, page.route),
        isTrue,
        reason: '${page.key} (${page.route})',
      );
    }
  });

  test('blocked reasons name the permission in plain Chinese, not a code', () {
    if (!file.existsSync()) return;
    for (final page in _parse(file.readAsStringSync())) {
      expect(page.label.trim(), isNotEmpty, reason: page.key);
      expect(
        RegExp(r'[:_]').hasMatch(page.label) ||
            page.permissions.any(page.label.contains),
        isFalse,
        reason: '${page.key}: 权限说明不能出现权限码: ${page.label}',
      );
    }
  });
}
