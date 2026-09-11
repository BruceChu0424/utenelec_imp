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
  '/entry',
  '/login',
  '/change-password',
  '/access-denied',
  '/not-found',
  // 工作台首页：全员可达，卡片逐个按权限过滤（设计决策，总设计 §三）。
  '/dashboard',
  '/reviews/inbox', // Retired inbox redirects to dashboard; no business data.
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

/// 文档口径的守卫/豁免计数（权限体系总设计.md「181 条守卫 / 19 条豁免」、
/// 页面权限一览.md 表头同数；2026-09-10 实跑核对三处已对齐）。
/// 断言精确计数：新增路由必须同步改代码守卫 + 本处计数 + 文档数字，
/// 防止「文档说 180、实际已 190」的静默漂移。
const _expectedGuardedCount = 181;
const _expectedExemptCount = 19;

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
        final sample = pattern
            .split('/')
            .map((s) => s.startsWith(':') ? 'sample' : s)
            .join('/');
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

      // 计数契约：与权限体系总设计.md §二的「N 守卫/M 豁免」一一对应。
      // 路由增减时三处同步：permission_by_path.dart（守卫本体）、
      // 本文件（_expected*Count）、总设计文档（§二数字）。
      expect(
        guarded.length,
        _expectedGuardedCount,
        reason:
            '守卫路由数 ${guarded.length} ≠ 文档口径 $_expectedGuardedCount。'
            '新增路由请同步 permission_by_path.dart、本处计数与'
            '权限体系总设计.md §二；删路由同理。',
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
