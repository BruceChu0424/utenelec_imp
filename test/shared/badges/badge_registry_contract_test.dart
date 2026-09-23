// 徽章入口前后端一致性契约(ADR-108 / permissions-08):
// 口径只在服务端 WorkbenchBadgeCatalog 一处登记; 前端 BadgeEntry / BadgeModule 只是
// 「入口 → 显示位置」映射, 必须与服务端逐字一致(入口键、归属容器), BadgeFact 引用的
// 来源键必须是服务端真实注册的来源。本测试直接读服务端源码核对, 任一侧改了另一侧不跟就红。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';

const _serverMain = 'server/src/main/java/com/uten/imp';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final catalog = _read(
    '$_serverMain/features/workbench/badge/WorkbenchBadgeCatalog.java',
  );

  test('入口键与归属容器和服务端目录逐字一致', () {
    final serverEntries = {
      for (final match in RegExp(
        r'^\s{4}(\w+)\(Module\.(\w+)',
        multiLine: true,
      ).allMatches(catalog))
        match.group(1)!: match.group(2)!,
    };
    expect(serverEntries, isNotEmpty);
    expect({
      for (final entry in BadgeEntry.values) entry.name: entry.module.name,
    }, serverEntries);
  });

  test('容器枚举与服务端一致', () {
    final body = RegExp(
      r'enum Module \{([^}]*)\}',
    ).firstMatch(catalog)!.group(1)!;
    final serverModules = body
        .split(',')
        .map((name) => name.trim())
        .where((name) => name.isNotEmpty)
        .toList();
    expect(BadgeModule.values.map((m) => m.name).toList(), serverModules);
  });

  test('BadgeFact 引用的来源键都在服务端注册过', () {
    final sourceKeys = <String>{};
    final sourceFiles = Directory(_serverMain)
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('WorkbenchBadgeSources.java'));
    for (final file in sourceFiles) {
      for (final match in RegExp(
        r'new (?:WorkbenchBadgeSources\.)?Source\(\s*"(\w+)"',
      ).allMatches(file.readAsStringSync())) {
        sourceKeys.add(match.group(1)!);
      }
    }
    expect(sourceKeys, isNotEmpty);

    final factsSource = _read('lib/shared/badges/badge_registry.dart');
    final factBlock = factsSource.substring(
      factsSource.indexOf('abstract final class BadgeFact'),
      factsSource.indexOf('/// 入口红数'),
    );
    final referenced = {
      for (final match in RegExp(r"'(\w+)\.").allMatches(factBlock))
        match.group(1)!,
    };
    expect(referenced, isNotEmpty);
    expect(
      referenced.difference(sourceKeys),
      isEmpty,
      reason: '前端引用了服务端没有注册的来源',
    );
  });

  test('全部 0 时容器与总数都为 0(徽章整个不渲染)', () {
    const summary = BadgeSummary.empty;
    for (final entry in BadgeEntry.values) {
      expect(summary.entryTodo(entry), 0);
      expect(summary.entryInProgress(entry), 0);
    }
    for (final module in BadgeModule.values) {
      expect(summary.moduleTodo(module), 0);
    }
    expect(summary.total, BadgeCounts.zero);
  });
}
