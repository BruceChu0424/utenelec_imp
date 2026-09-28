// 全量路由 × 权限覆盖契约（2026-09-05 新增）：
// 逐条枚举 appRouter 真实注册的 GoRoute（含 productionRoutes 等挂载子树），把动态段
// 代入样本值后过 permission_by_path，要求——
//   1. 除「文档豁免清单」（基础设施/访客门户/dashboard/profile/settings/
//      page-permissions，见 权限体系总设计.md §二）外，任何路由都必须有 any/all 守卫；
//   2. 豁免清单本身也不许漂移：清单里的路由若真的挂上了权限码，测试同样报错。
// 新增页面忘记注册权限时，这里第一个红——不必等人工全量审计。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/router/app_router.dart';
import 'package:uten_imp/core/router/permission_by_path.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/features/visitor/providers/visitor_session_provider.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

/// 桩会话：默认未登录态，不触 secure_storage（测试环境无插件实现）。
class _StubSessionNotifier extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

class _StubVisitorSessionNotifier extends VisitorSessionNotifier {
  @override
  VisitorSessionState build() => const VisitorSessionState();
}

/// 文档口径的「登录即可」路由（权限体系总设计.md §二豁免清单）。
/// 末尾通配 `*` 表示前缀豁免（访客门户）。
const _documentedExempt = <String>{
  '/',
  '/login',
  '/change-password',
  '/access-denied',
  '/not-found',
  // 工作台首页：全员可达，卡片逐个按权限过滤（设计决策，总设计 §三）。
  '/dashboard',
  // 本人资料/设置：字段策略由后端 ProfileFieldPolicy 管。
  '/profile',
  '/profile/edit',
  '/profile/me/changes',
  '/profile/me/department',
  '/settings',
  // 业务页「本页权限」工作台：服务端按 surface 能力与负责人子树把关。
  '/page-permissions/*',
  // 访客门户：独立访客会话。
  '/visitor/*',
};

bool _isDocumentedExempt(String path) =>
    _documentedExempt.contains(path) ||
    _documentedExempt.any(
      (e) => e.endsWith('/*') && path.startsWith(e.substring(0, e.length - 1)),
    );

/// 递归收集所有叶子 GoRoute 的完整路径（ShellRoute 不贡献路径段）。
void _collect(RouteBase base, String parent, List<String> out) {
  switch (base) {
    case GoRoute(:final path, :final routes):
      final full = path.startsWith('/')
          ? path
          : (path.isEmpty ? parent : '$parent/$path');
      if (routes.isEmpty) {
        out.add(full);
      } else {
        for (final child in routes) {
          _collect(child, full, out);
        }
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

/// 当前工作区逐条核对：206 条守卫 / 17 条豁免(2026-09-25 入口选择页下线，
/// /entry 路由移除后豁免 18→17；访客门户路由保留但被 redirect 拦截)。
/// 包含报销编辑路径，仍继承 expense:apply；生产路线重构不新增页面。
/// 断言精确计数：新增路由必须同步改代码守卫 + 本处计数 + 文档数字，
/// 防止「文档说 180、实际已 190」的静默漂移。
const _legacyGuardedCount = 206;
const _expectedExemptCount = 17;

/// 2026-09-26 实际新增路径逐条核对，不能用总数 +5 代替路由身份/组合权限验证。
const _reviewedNewGuardedRoutes = <String, List<String>>{
  '/warehouse/material-discovery/:requestId': [
    Perm.stockDocIssue,
    Perm.stockDocApprove,
  ],
  '/finance/assets/new': [Perm.financeAssetView, Perm.financeAssetEdit],
  '/production/material-return/new': [Perm.productionMaterialSettle],
  '/production/overproduction-rate-requests/new': [
    Perm.productionExecutionRequestOverproductionRate,
  ],
  '/production/material-discovery-request': [
    Perm.productionExecutionView,
    Perm.productionExecutionStart,
  ],
  // 2026-09-28 车间内料仓 (ADR-131) 五页: 内料仓页与用量报表只要查看码 (任一),
  // 组合门槛为空; 发料、盘点、设置三页要求本码本身。
  '/workshop-material/bin': [],
  '/reports/workshop-material': [],
  '/workshop-material/issue': [Perm.workshopMaterialIssue],
  '/workshop-material/count': [Perm.workshopMaterialCount],
  '/warehouse/workshop-material/setup': [Perm.workshopMaterialSetup],

  // 2026-09-27 AI 服务设置(ADR-133): 沿用 /admin/* 的 authorization:manage 单一守卫,
  // 无组合权限; 服务端另校验 superAdmin。守卫断言见 test/features/admin/admin_ai_settings_page_test.dart
  // 的 'route inherits the system-administration guard'。
  '/admin/ai-settings': [],
  // 2026-09-27 报价财务核价(ADR-134)：列表与详情只挂 any 守卫
  // sales_quote_finance:view(无组合门槛)，改价/退回/确认按服务端 allowedActions。
  '/finance/quote-review': <String>[],
  '/finance/quote-review/:id': <String>[],
};

String _samplePath(String pattern) => pattern
    .split('/')
    .map((segment) => segment.startsWith(':') ? 'sample' : segment)
    .join('/');

void main() {
  test(
    'every registered route is guarded or on the documented exempt list',
    () {
      final container = ProviderContainer(
        overrides: [
          sessionProvider.overrideWith(() => _StubSessionNotifier()),
          visitorSessionProvider.overrideWith(
            () => _StubVisitorSessionNotifier(),
          ),
        ],
      );
      addTearDown(container.dispose);
      final router = container.read(appRouterProvider);

      final paths = <String>[];
      for (final base in router.configuration.routes) {
        _collect(base, '', paths);
      }
      expect(paths, isNotEmpty, reason: '路由树为空——枚举逻辑或路由装配出了问题');

      final unguarded = <String>[];
      final exemptButGuarded = <String>[];
      final guarded = <String>[];
      for (final pattern in paths) {
        // 动态段代入样本值（:id / :seg / :type …）。
        final sample = _samplePath(pattern);
        final any = requiredAnyPermFor(sample);
        final all = requiredAllPermsFor(sample);
        // all 契约默认返回空列表（非 null）：空 = 无组合门槛，不算守卫；
        // any 返回 [] = 已知前缀未知段 fail-closed 404，算守卫。
        final hasGuard = any != null || all.isNotEmpty;
        if (hasGuard) {
          guarded.add(sample);
          if (_isDocumentedExempt(sample)) exemptButGuarded.add(sample);
        } else if (!_isDocumentedExempt(sample)) {
          unguarded.add(sample);
        }
      }

      final reviewedSamples = _reviewedNewGuardedRoutes.keys
          .map(_samplePath)
          .toSet();
      for (final route in _reviewedNewGuardedRoutes.entries) {
        expect(
          paths.where((path) => path == route.key),
          hasLength(1),
          reason: '${route.key} 必须只注册一次',
        );
        expect(
          requiredAllPermsFor(_samplePath(route.key)),
          orderedEquals(route.value),
          reason: '${route.key} 不得放松已核对的组合权限',
        );
        expect(guarded, contains(_samplePath(route.key)));
      }
      // 组合门槛为空的已核对路径, 单独锁住它的「任一」守卫。
      for (final path in const [
        '/workshop-material/bin',
        '/reports/workshop-material',
      ]) {
        expect(
          requiredAnyPermFor(path),
          orderedEquals(const [Perm.workshopMaterialView]),
          reason: '$path 不得放松查看守卫',
        );
      }
      // 新路径按精确身份和组合权限比较；原清单仍按原数量锁定，禁止只抬总数。
      expect(
        guarded.where((path) => !reviewedSamples.contains(path)).length,
        _legacyGuardedCount,
        reason:
            '原守卫路由清单数量已变化；新增页面须登记精确路径及权限，'
            '同时同步 permission_by_path.dart 与权限体系总设计.md §二。',
      );
      final exemptCount = paths.length - guarded.length;
      expect(
        exemptCount,
        _expectedExemptCount,
        reason:
            '豁免路由数 $exemptCount ≠ 文档口径 $_expectedExemptCount。'
            '豁免清单变动须同步 _documentedExempt、本处计数与总设计 §二。',
      );

      expect(
        unguarded,
        isEmpty,
        reason:
            '以下路由既无权限守卫也不在豁免清单（权限体系总设计.md §二）。'
            '要么在 permission_by_path.dart 注册守卫，要么把它加入两处清单并说明设计依据。',
      );
      expect(
        exemptButGuarded,
        isEmpty,
        reason: '以下路由在豁免清单里却挂了权限码——文档与代码漂移，二者取其一改齐。',
      );
    },
  );
}
