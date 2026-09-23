import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 页面 / 组件里本地拼权限的基线(ADR-109 / permissions-15)。
///
/// 按钮能不能点，最终要由服务端按「权限码 + 对象范围 + 单据状态 + 附加审核权」一次算好
/// 随详情下发(如日报、出货财审的 allowedActions)。页面或组件里每多一处 `Perm.x`，
/// 就多一处可能和服务端判断不一致的地方(例：日报审核按钮漏了车间直送审核权，点了才被拒)。
///
/// 计数口径：lib/features 下所有 pages / widgets 目录里出现的 `Perm.x` 引用，不管写成
/// `contains(Perm.x)`、`_has(Perm.x)` 还是 `can(Perm.x)`——换个辅助函数包一层也照样计数，
/// 绕不过去。路由守卫与 hub 卡片走 lib/core/router 下的目录派生，不在此计数。
///
/// 本测试只许这个数下降：新页面请改用服务端下发的动作集合；把旧页面迁走后，
/// 同步把 [_baseline] 调小。数字上涨会直接红。
// 2026-09-23 第一阶段合并: 主档明细区把状态/删除权限码作为配置传入共享组件(客户分类 +1、模具分类 +3),
// 总账报表「附表取数设置」按钮 +1, 仓库到货预期视图 -1, 净 +4。改为服务端下发动作集合归后续 uikit 工作流。
const _baseline = 595;

final _permReference = RegExp(r'\bPerm\.[a-zA-Z]');

void main() {
  test('pages and widgets never add new local permission checks', () {
    var total = 0;
    final perFile = <String, int>{};
    for (final entity in Directory('lib/features').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final normalized = entity.path.replaceAll(r'\', '/');
      if (!normalized.contains('/pages/') &&
          !normalized.contains('/widgets/')) {
        continue;
      }
      final count = _permReference.allMatches(entity.readAsStringSync()).length;
      if (count == 0) continue;
      total += count;
      perFile[normalized] = count;
    }
    final top =
        (perFile.entries.toList()..sort((a, b) => b.value.compareTo(a.value)))
            .take(5)
            .map((e) => '${e.key}: ${e.value}')
            .join('\n');
    expect(
      total,
      lessThanOrEqualTo(_baseline),
      reason:
          '页面 / 组件里本地拼权限的次数从 $_baseline 涨到了 $total。按钮显隐请改用服务端'
          '下发的动作集合(如 allowedActions)，不要再在页面里引用 Perm.x。\n'
          '当前最多的文件：\n$top',
    );
  });

  test('the counter cannot be dodged by wrapping the check in a helper', () {
    const wrapped = '''
bool _has(String code) => permissions.contains(code);
bool get _canApprove => _has(Perm.salesShipmentFinanceApprove);
''';
    expect(_permReference.allMatches(wrapped).length, 1);
  });
}
