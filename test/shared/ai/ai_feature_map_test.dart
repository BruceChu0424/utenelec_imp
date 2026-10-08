// AI 功能与页面目录(SPEC P1-1、P1-4, ADR-153 修订): 由真实路由表、路由守卫、工作台与
// 模块首页卡片、中文界面文案和页面文档生成 `server/src/main/resources/ai-feature-map.json`,
// 并逐字比对。服务端 AiChatFeatureDirectory(功能目录与权限说明两个工具)和
// AiChatUserScope(提示词里可打开的模块、回答里导航用语的核对)只读这份文件, 按读者
// 当前权限回答「在哪里、怎么进、有哪些功能、为什么打不开」; 路由本身不发给模型。
//
// 目录漂移(新页面、改卡片名、改守卫、补页面文档)时本测试失败, 重新生成:
//   UPDATE_AI_FEATURE_MAP=1 flutter test test/shared/ai/ai_feature_map_test.dart
// 再检查差异并提交。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/cards/uten_hub_card.dart';
import 'package:uten_imp/components/layout/uten_collapsible_section.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/router/app_router.dart';
import 'package:uten_imp/core/router/hub_catalog.dart';
import 'package:uten_imp/core/router/permission_by_path.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/dashboard/widgets/workbench_module_area.dart';
import 'package:uten_imp/features/visitor/providers/visitor_session_provider.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../helpers/badge_summary_fixture.dart';
import '../drafts/memory_form_draft_storage.dart';

const _mapFile = 'server/src/main/resources/ai-feature-map.json';
const _rewriteVariable = 'UPDATE_AI_FEATURE_MAP';
const _docsDirectory = 'docs/03-页面';
const _regenerate =
    '$_rewriteVariable=1 flutter test test/shared/ai/ai_feature_map_test.dart';

/// 不是业务功能的路由: 登录与错误页、根路由、访客门户、草稿页与「本页权限」工作台。
const _infrastructure = <String>{
  RouteName.home,
  RouteName.login,
  RouteName.changePassword,
  RouteName.accessDenied,
  RouteName.notFound,
  RouteName.formDrafts,
};

bool _isInfrastructure(String route) =>
    _infrastructure.contains(route) || route.startsWith('/visitor/');

/// 导航栏上的四个主 Tab(名称取中文界面文案)。
Map<String, String> _mainTabs(AppLocalizations l10n) => {
  RouteName.dashboard: l10n.navDashboard,
  RouteName.notice: l10n.navNotice,
  RouteName.profile: l10n.navProfile,
  RouteName.settings: l10n.navSettings,
};

// ---------------------------------------------------------------- router

void _collect(RouteBase base, String parent, Map<String, GoRoute> out) {
  switch (base) {
    case GoRoute(:final path, :final routes):
      final full = path.startsWith('/')
          ? path
          : (path.isEmpty ? parent : '$parent/$path');
      out.putIfAbsent(full, () => base);
      for (final child in routes) {
        _collect(child, full, out);
      }
    case ShellRoute(:final routes):
      for (final child in routes) {
        _collect(child, parent, out);
      }
    case StatefulShellRoute(:final branches):
      for (final branch in branches) {
        for (final child in branch.routes) {
          _collect(child, parent, out);
        }
      }
  }
}

/// Whether [pattern] serves [route]; a parameter in [route] only matches a
/// parameter of [pattern] at the same position.
bool _covers(String pattern, String route) {
  final a = pattern.split('/');
  final b = route.split('/');
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i].startsWith(':')) {
      if (b[i].isEmpty) return false;
    } else if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
}

int _literalSegments(String pattern) =>
    pattern.split('/').where((s) => s.isNotEmpty && !s.startsWith(':')).length;

/// The registered pattern that serves [route] (most literal segments wins).
String? _patternOf(Map<String, GoRoute> routes, String route) {
  String? best;
  for (final pattern in routes.keys) {
    if (!_covers(pattern, route)) continue;
    if (best == null || _literalSegments(pattern) > _literalSegments(best)) {
      best = pattern;
    }
  }
  return best;
}

bool _rendersPage(GoRoute route) =>
    route.builder != null || route.pageBuilder != null;

String _sample(String route) => route
    .split('/')
    .map((segment) => segment.startsWith(':') ? 'sample' : segment)
    .join('/');

bool _hasParameter(String route) => route.contains('/:');

/// A concrete doc route whose parameter segment is a placeholder such as `X`.
bool _placeholder(String pattern, String route) {
  final a = pattern.split('/');
  final b = route.split('/');
  for (var i = 0; i < a.length && i < b.length; i++) {
    if (a[i].startsWith(':') && !b[i].startsWith(':') && b[i].length < 2) {
      return true;
    }
  }
  return false;
}

// ---------------------------------------------------------------- docs

class _Doc {
  _Doc(
    this.file,
    this.title,
    this.purpose,
    this.routes,
    this.labels,
    this.aliases,
  );
  final String file;
  final String title;
  final String purpose;

  /// Declared routes in document order; the first one is the page itself.
  final List<String> routes;

  /// Chinese label written right after a route: 「`/stock/count-requests`(盘点历史)」.
  final Map<String, String> labels;

  /// Other names: the file name and the 「> 别名：」 line (what people call the page).
  final List<String> aliases;
}

final _aliasLine = RegExp(r'^\s*>?\s*(?:\*\*)?别名(?:\*\*)?\s*[：:]\s*(.+)$');

/// 「路由：`/x`」「> **任务路由**：`/x`」「路由根：`/x`」「- 路由 `/x`」都算; 「路由守卫」不算。
final _routeLine = RegExp(
  r'^\s*(?:>\s*)?(?:[-*]\s+)?(?:\*\*)?(?:列表|详情|任务|入口)?路由根?(?:\*\*)?'
  r'\s*(?:[：:]|(?=`))',
);
final _purposeHeading = RegExp(
  r'^#{2,3}\s*(?:[一二三四五六七八九十]+、\s*)?(?:当前|页面)?(?:定位|目标)',
);

String _normalizedRoute(String raw) {
  var value = raw.split('?').first.split('#').first.trim();
  value = value.replaceAllMapped(RegExp(r'\{(\w+)\}'), (m) => ':${m[1]}');
  while (value.length > 1 && value.endsWith('/')) {
    value = value.substring(0, value.length - 1);
  }
  return value;
}

String _cleanTitle(String raw) {
  var value = raw.replaceAll('**', '').trim();
  final bracket = RegExp(r'\s*[\uFF08(][^\uFF08\uFF09()]*[\uFF09)]\s*$');
  while (bracket.hasMatch(value)) {
    value = value.replaceFirst(bracket, '').trim();
  }
  return value;
}

/// The first sentence of a doc paragraph as plain business text, or nothing when
/// it carries code, paths, permission codes, versions or implementation words.
/// Full-width parentheses become ASCII ones (the project's text rule).
String _plain(String raw) {
  var value = raw
      .replaceAll('**', '')
      .replaceAll('\uFF08', '(')
      .replaceAll('\uFF09', ')')
      .replaceAllMapped(RegExp(r'\[([^\]]*)\]\([^)]*\)'), (m) => m[1]!)
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  final end = value.indexOf(RegExp('[。；]'));
  if (end >= 0) value = '${value.substring(0, end)}。';
  final technical = RegExp(
    r'`|[A-Za-z]{2,}[_:/.]|[_/\\]|\bV\d{3}\b|源码|实现|后端|接口|迁移|服务端|前端|路由',
  );
  if (value.length < 6 ||
      value.length > 80 ||
      !value.endsWith('。') ||
      technical.hasMatch(value)) {
    return '';
  }
  return value;
}

/// Card text is what the screen shows; only whitespace is normalized.
String _shown(String raw) => raw.replaceAll(RegExp(r'\s+'), ' ').trim();

/// A card's description as a purpose line: full-width parentheses become ASCII
/// ones (the project's text rule); purposes are read, never matched to the screen.
String _purposeOf(String raw) =>
    _shown(raw).replaceAll('\uFF08', '(').replaceAll('\uFF09', ')');

List<_Doc> _readDocs() {
  final docs = <_Doc>[];
  final files =
      Directory(_docsDirectory)
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.md'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  for (final file in files) {
    final lines = file.readAsLinesSync();
    var title = '';
    var purpose = '';
    final routes = <String>[];
    final labels = <String, String>{};
    final aliases = <String>[];
    var inPurpose = false;
    for (final line in lines) {
      if (title.isEmpty && line.startsWith('# ')) {
        title = _cleanTitle(line.substring(2));
      }
      final alias = _aliasLine.firstMatch(line);
      if (alias != null) {
        for (final name in alias[1]!.split(RegExp('[、，,；;]'))) {
          final value = name.replaceAll('**', '').trim();
          if (value.isNotEmpty && value.length <= 20) aliases.add(value);
        }
      }
      if (_routeLine.hasMatch(line)) {
        final declared = RegExp(
          r'`(/[^`\s]*)`(?:[\uFF08(]([^\uFF08\uFF09()`]{2,16})[\uFF09)])?',
        );
        for (final match in declared.allMatches(line)) {
          final route = _normalizedRoute(match[1]!);
          if (!RegExp(r'^/[A-Za-z0-9_\-/:]*$').hasMatch(route) ||
              routes.contains(route)) {
            continue;
          }
          routes.add(route);
          final label = match[2]?.trim();
          if (label != null && !RegExp('[A-Za-z0-9_:/]').hasMatch(label)) {
            labels[route] = label;
          }
        }
      }
      if (purpose.isEmpty) {
        if (_purposeHeading.hasMatch(line)) {
          inPurpose = true;
        } else if (line.startsWith('#')) {
          inPurpose = false;
        } else if (inPurpose && line.trim().isNotEmpty) {
          final text = line.trim();
          if (!RegExp(r'^[>\-*|`#\d]').hasMatch(text)) {
            purpose = _plain(text);
            inPurpose = false;
          }
        }
      }
    }
    final name = file.uri.pathSegments.last;
    docs.add(
      _Doc(
        '$_docsDirectory/$name',
        title,
        purpose,
        List.unmodifiable(routes),
        Map.unmodifiable(labels),
        List.unmodifiable([
          name.substring(0, name.length - '.md'.length),
          ...aliases,
        ]),
      ),
    );
  }
  return docs;
}

// ---------------------------------------------------------------- cards

class _Card {
  _Card(this.label, this.description, this.location, this.path);
  final String label;
  final String description;
  final String location;
  final List<String> path;
}

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(id: 'feature-map', code: 'E001', name: '目录生成'),
  );
}

class _NoSession extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

class _NoVisitor extends VisitorSessionNotifier {
  @override
  VisitorSessionState build() => const VisitorSessionState();
}

class _Snapshot extends SessionSnapshotNotifier {
  @override
  Future<SessionSnapshot?> build() async => SessionSnapshot();
}

/// Any location lands here, so a card tap records where it goes.
GoRoute _landing(int depth) => GoRoute(
  path: depth == 0 ? '/:p0' : ':p$depth',
  pageBuilder: (_, _) =>
      const NoTransitionPage(child: Scaffold(body: Text('landed'))),
  routes: depth >= 6 ? const [] : [_landing(depth + 1)],
);

/// Renders [page] as a super administrator (every card visible) and taps each
/// workbench tile or hub card, recording the real destination of the tap.
Future<List<_Card>> _harvest(
  WidgetTester tester,
  SharedPreferences preferences,
  String location,
  Widget Function(BuildContext, GoRouterState) page,
  List<String> trail,
) async {
  final router = GoRouter(
    initialLocation: location,
    routes: [
      GoRoute(
        path: location,
        pageBuilder: (context, state) =>
            NoTransitionPage(child: page(context, state)),
      ),
      _landing(0),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        formDraftStorageProvider.overrideWithValue(MemoryFormDraftStorage()),
        sessionProvider.overrideWith(_Session.new),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'feature-map'),
        ),
        sessionSnapshotProvider.overrideWith(_Snapshot.new),
        apiBaseUrlProvider.overrideWith((ref) => 'https://test-server/api'),
        currentPermissionsProvider.overrideWithValue(const <String>{}),
        isSuperAdminProvider.overrideWithValue(true),
        fixedBadgeSummaryOverride(),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 500));

  Future<String> tap(VoidCallback onTap) async {
    onTap();
    await tester.pump(const Duration(milliseconds: 300));
    final landed = router.routerDelegate.currentConfiguration.uri.path;
    router.go(location);
    await tester.pump(const Duration(milliseconds: 300));
    return landed;
  }

  final cards = <_Card>[];
  final hubCards = find.byType(UtenHubCard);
  if (hubCards.evaluate().isNotEmpty) {
    final count = hubCards.evaluate().length;
    for (var i = 0; i < count; i++) {
      final card = tester.widget<UtenHubCard>(hubCards.at(i));
      final landed = await tap(card.onTap);
      cards.add(
        _Card(card.label, card.description ?? '', landed, [
          ...trail,
          card.label,
        ]),
      );
    }
    return cards;
  }
  // Workbench: one tile per module entry, inside its department section.
  final tiles = find.byWidgetPredicate(
    (widget) => widget.runtimeType.toString() == '_ModuleTile',
  );
  final count = tiles.evaluate().length;
  for (var i = 0; i < count; i++) {
    final tile = tiles.at(i);
    final section = tester.widget<UtenCollapsibleSection>(
      find
          .ancestor(of: tile, matching: find.byType(UtenCollapsibleSection))
          .first,
    );
    final ink = tester.widget<InkWell>(
      find.descendant(of: tile, matching: find.byType(InkWell)).first,
    );
    final onTap = ink.onTap;
    if (onTap == null) continue; // 规划中的占位卡, 没有页面。
    final label = find
        .descendant(of: tile, matching: find.byType(Text))
        .evaluate()
        .map((element) => (element.widget as Text).data ?? '')
        .firstWhere((text) => text.trim().isNotEmpty);
    final landed = await tap(onTap);
    cards.add(_Card(label, '', landed, [...trail, section.title, label]));
  }
  return cards;
}

// ---------------------------------------------------------------- map

class _Entry {
  _Entry(this.route, this.pattern);
  final String route;
  final String pattern;
  String title = '';
  final aliases = <String>{};
  String module = '';
  String purpose = '';
  final paths = <String, List<String>>{};
  String? parent;
  List<String>? anyOf;
  List<String> allOf = const [];
  List<String> hubOf = const [];
  String? doc;

  Map<String, Object?> toJson() => {
    'route': route,
    'title': title,
    'aliases': (aliases.toSet()..remove(title)).toList()..sort(),
    'module': module,
    'purpose': purpose,
    'paths': (paths.keys.toList()..sort()).map((key) => paths[key]).toList(),
    'parent': parent,
    'record': _hasParameter(route),
    'anyOf': anyOf,
    'allOf': allOf,
    'hubOf': hubOf,
    'doc': doc,
  };
}

class _Built {
  _Built(this.json, this.unmatchedDocRoutes);
  final String json;
  final List<String> unmatchedDocRoutes;
}

Future<_Built> _build(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1400, 9000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  final l10n = lookupAppLocalizations(const Locale('zh'));

  final container = ProviderContainer(
    overrides: [
      sessionProvider.overrideWith(_NoSession.new),
      visitorSessionProvider.overrideWith(_NoVisitor.new),
    ],
  );
  addTearDown(container.dispose);
  final routes = <String, GoRoute>{};
  for (final base in container.read(appRouterProvider).configuration.routes) {
    _collect(base, '', routes);
  }

  final entries = <String, _Entry>{};
  _Entry? entryFor(String route) {
    if (_isInfrastructure(route)) return null;
    final existing = entries[route];
    if (existing != null) return existing;
    final pattern = _patternOf(routes, route);
    if (pattern == null || !_rendersPage(routes[pattern]!)) return null;
    final sample = _sample(route);
    final any = requiredAnyPermFor(sample);
    // An empty any-of list is the guard's fail-closed answer: not a page.
    if (any != null && any.isEmpty) return null;
    final entry = _Entry(route, pattern)
      ..anyOf = any == null ? null : (List.of(any)..sort())
      ..allOf = (List.of(requiredAllPermsFor(sample))..sort())
      ..hubOf = isHubLocation(route)
          ? <String>{
              for (final child in hubCardLocations[route]!)
                if (!_isInfrastructure(hubCardPath(child))) hubCardPath(child),
            }.toList()
          : const [];
    return entries[route] = entry;
  }

  // 1. 导航栏主 Tab。
  for (final MapEntry(key: route, value: label) in _mainTabs(l10n).entries) {
    final entry = entryFor(route)!;
    entry.title = label;
    entry.module = label;
    entry.paths['导航栏>$label'] = ['导航栏', label];
  }

  // 2. 工作台各部门分区里的模块卡, 3. 模块首页上的卡片。
  final tiles = await _harvest(
    tester,
    preferences,
    RouteName.dashboard,
    (_, _) => const Scaffold(
      body: SingleChildScrollView(child: WorkbenchModuleArea()),
    ),
    [l10n.navDashboard],
  );
  final hubCards = <String, List<_Card>>{};
  for (final tile in tiles) {
    if (!isHubLocation(tile.location) || hubCards.containsKey(tile.location)) {
      continue;
    }
    final route = routes[tile.location]!;
    hubCards[tile.location] = await _harvest(
      tester,
      preferences,
      tile.location,
      (context, state) => route.builder!(context, state),
      tile.path,
    );
  }
  await tester.pumpWidget(const SizedBox.shrink());

  void addCard(_Card card, String module) {
    final entry = entryFor(card.location);
    expect(
      entry,
      isNotNull,
      reason: '卡片「${card.label}」落点 ${card.location} 不是可打开的页面',
    );
    if (entry!.title.isEmpty) {
      entry.title = card.label;
      entry.module = module;
    } else {
      entry.aliases.add(card.label);
    }
    if (entry.purpose.isEmpty) entry.purpose = _purposeOf(card.description);
    entry.paths[card.path.join('>')] = card.path;
  }

  for (final tile in tiles) {
    final group = tile.path[1];
    addCard(tile, isHubLocation(tile.location) ? tile.label : group);
  }
  for (final MapEntry(key: hub, value: cards) in hubCards.entries) {
    final module = entries[hub]!.title;
    for (final card in cards) {
      addCard(card, module);
    }
    final labels = <String>{for (final card in cards) card.label}.take(8);
    entries[hub]!.purpose = '包含：${labels.join('、')}。';
  }

  // 4. 「新建X」卡片对应的单据列表页(同一路由去掉 /new)。
  for (final cards in [tiles, ...hubCards.values]) {
    for (final card in cards) {
      if (!card.location.endsWith('/new') || !card.label.startsWith('新建')) {
        continue;
      }
      final entry = entryFor(
        card.location.substring(0, card.location.length - '/new'.length),
      );
      if (entry != null && entry.title.isEmpty) {
        entry.title = '${card.label.substring('新建'.length)}列表';
      }
    }
  }

  // 5. 页面文档声明的路由: 文档的第一条路由就是它写的页面(标题取文档一级标题);
  // 后面的路由只有写了中文标注才单独收录, 标题取标注。具体路由必须真能打开:
  // 代入参数的那一段不能是「X」这类占位符。
  final docs = _readDocs();
  final unmatched = <String>[];
  for (final doc in docs) {
    for (final (index, route) in doc.routes.indexed) {
      if (_isInfrastructure(route)) continue;
      final pattern = _patternOf(routes, route);
      if (pattern == null ||
          !_rendersPage(routes[pattern]!) ||
          _placeholder(pattern, route)) {
        unmatched.add('${doc.file}: $route');
        continue;
      }
      final label = doc.labels[route];
      // A short name is a title; a description (with commas or long) is not.
      final named = label != null && !RegExp('[、，,；;]').hasMatch(label);
      final String? title;
      if (named && label.length >= 4 && label.length <= 10) {
        title = label;
      } else if (named && label.length < 4) {
        title = '${doc.title}($label)';
      } else {
        title = index == 0 || label != null ? doc.title : null;
      }
      if (title == null || title.isEmpty) continue;
      final entry = entryFor(route);
      if (entry != null && entry.title.isEmpty) {
        entry.title = title;
        entry.purpose = doc.purpose;
      }
    }
  }

  // 每个条目挂上它的页面文档: 文档写的就是这条路由, 或文档写的参数路由正是
  // 打开这一页的那条路由(「/warehouse/:code/new」对应各类新建单据页)。
  for (final entry in entries.values) {
    _Doc? exact;
    _Doc? covering;
    for (final doc in docs) {
      if (exact == null && doc.routes.contains(entry.route)) exact = doc;
      if (covering == null &&
          doc.routes.any(
            (route) =>
                _hasParameter(route) &&
                _patternOf(routes, route) == entry.pattern &&
                _covers(route, entry.route),
          )) {
        covering = doc;
      }
    }
    final doc = exact ?? covering;
    if (doc == null) continue;
    entry.doc = doc.file;
    // The doc's names belong to the page it is written for (its first route);
    // other pages it mentions would otherwise all answer to the doc's title.
    final primary = doc.routes.first;
    if (primary == entry.route ||
        (_hasParameter(primary) &&
            _patternOf(routes, primary) == entry.pattern &&
            _covers(primary, entry.route))) {
      if (doc.title.isNotEmpty) entry.aliases.add(doc.title);
      entry.aliases.addAll(doc.aliases);
      if (entry.purpose.isEmpty) entry.purpose = doc.purpose;
    }
  }

  // 没有卡片的页面: 上级页面 = 路径上最近的已收录页面, 模块随上级或同一首段的卡片。
  final firstSegmentModule = <String, String>{};
  for (final entry in entries.values) {
    if (entry.paths.isEmpty || entry.module.isEmpty) continue;
    firstSegmentModule.putIfAbsent(
      entry.route.split('/')[1],
      () => entry.module,
    );
  }
  for (final entry in entries.values) {
    if (entry.paths.isNotEmpty) continue;
    final segments = entry.route.split('/');
    for (var length = segments.length - 1; length > 1; length--) {
      final candidate = segments.take(length).join('/');
      if (entries.containsKey(candidate)) {
        entry.parent = candidate;
        break;
      }
    }
  }
  String moduleOf(_Entry entry) {
    if (entry.module.isNotEmpty) return entry.module;
    final parent = entry.parent == null ? null : entries[entry.parent];
    if (parent != null) return moduleOf(parent);
    return firstSegmentModule[entry.route.split('/')[1]] ?? '其它';
  }

  for (final entry in entries.values) {
    entry.module = moduleOf(entry);
  }

  // 同名页面(两个部门都有「任务中心」)标题后注明模块, 读者能分清。
  final byTitle = <String, List<_Entry>>{};
  for (final entry in entries.values) {
    (byTitle[entry.title] ??= []).add(entry);
  }
  for (final same in byTitle.values) {
    if (same.length < 2 || same.map((e) => e.module).toSet().length < 2) {
      continue;
    }
    for (final entry in same) {
      entry.aliases.add(entry.title);
      entry.title = '${entry.title}(${entry.module})';
    }
  }

  final sorted = entries.values.toList()
    ..sort((a, b) => a.route.compareTo(b.route));
  final json = const JsonEncoder.withIndent('  ').convert({
    'note':
        '由 test/shared/ai/ai_feature_map_test.dart 生成, 请勿手改; 重新生成: $_regenerate',
    'features': [for (final entry in sorted) entry.toJson()],
  });
  return _Built('$json\n', unmatched);
}

/// 目录里还没有页面文档的页面(SPEC P1-1 覆盖清单)。补了带「路由：」行的页面文档后
/// 从这里删掉; 新增页面要么补文档, 要么在这里登记。
const _pagesWithoutDocs = <String>{
  '/finance', // 钱流管理
  '/finance/audits', // 业务审核中心
  '/finance/checks', // 支票管理
  '/finance/report/customer-prepayment', // 客户预收流水
  '/hr/profile-changes', // 信息变更审核
  '/operations/workbench/purchase', // 采购任务中心
  '/operations/workbench/subcontract', // 委外任务中心
  '/procurement/arrival-exceptions', // 待退回供应商
  '/production', // 生产管理
  '/production/chain-health', // 链路健康初筛
  '/production/daily-reports', // 生产日报列表
  '/production/material-increment-requests', // 追加用料审批
  '/production/overproduction-rate-requests', // 超产比例审批
  '/production/reports/plan-detail', // 计划明细
  '/production/reports/plan-summary', // 计划汇总
  '/purchase', // 采购管理
  '/purchase/orders', // 采购订货单列表
  '/purchase/receipts', // 采购收货单列表
  '/purchase/receipts/new', // 新建采购收货单
  '/purchase/report/detail', // 采购明细报表
  '/purchase/report/expediting', // 采购催料
  '/purchase/report/summary', // 采购汇总报表
  '/purchase/returns', // 采购退货单列表
  '/purchase/returns/new', // 新建采购退货单
  '/sales', // 销售管理
  '/sales/customer-shipments', // 客户零星发货列表
  '/sales/customer-shipments/new', // 新建客户零星发货
  '/sales/orders', // 销售订货单列表
  '/sales/quotes', // 销售报价单列表
  '/sales/report/detail', // 销售明细报表
  '/sales/report/summary', // 销售汇总报表
  '/sales/returns', // 销售退货单列表
  '/sales/returns/new', // 新建销售退货单
  '/sales/shipments', // 销售出货单列表
  '/sales/shipments/new', // 新建销售出货单
  '/subcontract/material-issues', // 委外材料出仓单
  '/subcontract/material-returns', // 余料退回列表
  '/subcontract/material-returns/new', // 新建余料退回
  '/subcontract/orders', // 委外订货列表
  '/subcontract/orders/new', // 新建委外订货
  '/subcontract/report/detail', // 委外明细报表
  '/subcontract/report/in-out-status', // 委外出入状况表
  '/subcontract/report/summary', // 委外汇总报表
  '/subcontract/returns', // 成品退回列表
  '/subcontract/returns/new', // 新建成品退回
  '/subcontract/wastes', // 损耗与责任列表
  '/subcontract/wastes/new', // 新建损耗与责任
  '/warehouse/CHECK', // 盘点单列表
  '/warehouse/FINISHED_IN', // 产成品进仓列表
  '/warehouse/FINISHED_OUT', // 产成品出库列表
  '/warehouse/OTHER_IN', // 其它入库列表
  '/warehouse/OTHER_OUT', // 其它出库列表
  '/warehouse/TRANSFER', // 调拨单列表
  '/warehouse/report/detail', // 仓库明细报表
  '/warehouse/report/summary', // 仓库汇总报表
};

Map<String, Object?> _committed() =>
    jsonDecode(File(_mapFile).readAsStringSync()) as Map<String, Object?>;

List<Map<String, Object?>> _features() => [
  for (final item in _committed()['features']! as List<Object?>)
    item! as Map<String, Object?>,
];

void main() {
  testWidgets('the feature directory matches the router, cards and page docs', (
    tester,
  ) async {
    final built = await _build(tester);
    final file = File(_mapFile);
    if (Platform.environment[_rewriteVariable] == '1') {
      file.writeAsStringSync(built.json);
    }
    expect(
      file.existsSync(),
      isTrue,
      reason: '缺少 $_mapFile; 运行 $_regenerate 生成',
    );
    final current = file.readAsStringSync().replaceAll('\r\n', '\n');
    expect(
      current == built.json,
      isTrue,
      reason:
          '$_mapFile 与当前路由、卡片或页面文档不一致(新增或改名的页面、改过的守卫、'
          '补了文档)。运行 $_regenerate 重新生成, 检查差异后提交。'
          '页面文档里写的路由打不开的有: ${built.unmatchedDocRoutes}',
    );
  });

  test('the directory names only real permission codes and plain words', () {
    final catalog = File('lib/shared/auth/permissions.dart').readAsStringSync();
    final features = _features();
    final routes = {for (final f in features) f['route']! as String};
    expect(features.length, greaterThan(100));
    final technical = RegExp(r'`|/[a-z]|[a-z_]+:[a-z_]+|https?:|\.dart\b');
    for (final feature in features) {
      final route = feature['route']! as String;
      for (final code in [
        ...?(feature['anyOf'] as List<Object?>?),
        ...feature['allOf']! as List<Object?>,
      ]) {
        expect(
          catalog.contains("'$code'"),
          isTrue,
          reason: '$route: 未知权限码 $code',
        );
      }
      final words = <String>[
        feature['title']! as String,
        feature['module']! as String,
        feature['purpose']! as String,
        for (final alias in feature['aliases']! as List<Object?>)
          alias! as String,
        for (final path in feature['paths']! as List<Object?>)
          for (final step in path! as List<Object?>) step! as String,
      ];
      expect((feature['title']! as String).trim(), isNotEmpty, reason: route);
      expect((feature['module']! as String).trim(), isNotEmpty, reason: route);
      for (final text in words) {
        expect(technical.hasMatch(text), isFalse, reason: '$route: 「$text」');
      }
      final parent = feature['parent'] as String?;
      expect(parent == null || routes.contains(parent), isTrue, reason: route);
      for (final child in feature['hubOf']! as List<Object?>) {
        expect(routes, contains(child), reason: '$route 的卡片 $child 不在目录里');
      }
      final any = feature['anyOf'] as List<Object?>?;
      expect(any == null || any.isNotEmpty, isTrue, reason: route);
    }
  });

  test('every directory page has a page doc or is on the waiver list', () {
    final missing = <String>[];
    final documented = <String>[];
    for (final feature in _features()) {
      final route = feature['route']! as String;
      final doc = feature['doc'] as String?;
      if (doc != null) {
        expect(File(doc).existsSync(), isTrue, reason: '$route: $doc');
      }
      if (doc == null && !_pagesWithoutDocs.contains(route)) {
        missing.add('$route ${feature['title']}');
      }
      if (doc != null && _pagesWithoutDocs.contains(route)) {
        documented.add(route);
      }
    }
    final stale = _pagesWithoutDocs.difference({
      for (final feature in _features()) feature['route']! as String,
    });
    expect(
      missing,
      isEmpty,
      reason:
          '这些页面没有页面文档: 在 $_docsDirectory 补文档(含「路由：」行)后运行 '
          '$_regenerate, 或登记到 _pagesWithoutDocs',
    );
    expect(documented, isEmpty, reason: '这些页面已有文档, 请从 _pagesWithoutDocs 删掉');
    expect(stale, isEmpty, reason: '这些路由已不在目录里, 请从 _pagesWithoutDocs 删掉');
  });
}
