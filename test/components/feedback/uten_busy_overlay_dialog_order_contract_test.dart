// 跑批遮罩与结果弹层的先后顺序契约（2026-09-21 实机缺陷的守卫）。
//
// UtenBusyOverlay 把遮罩作为「不属于任何路由」的裸 OverlayEntry 插进 root Overlay，
// 而 Flutter 的 Navigator 每次路由历史变动都会 overlay.rearrange(_allRouteOverlayEntries)，
// 把不在新列表里的旧 entry 整组塞回末尾——也就是每推一次路由都主动把这条遮罩重新抬到最顶。
// 因此「遮罩亮着时推弹窗/推页面」必然被整片盖住且一个按钮都点不动，调整先后顺序绕不开，
// 唯一可靠做法是弹层之前把遮罩整个撤掉（置忙标志为假）并等这一帧画完。
//
// 更糟的是这几处都构成死锁：遮罩要等 await 返回才撤，而 await 要等被盖住的弹窗被点掉才返回。
// 已知实机现象：委外批量到货登记的短交确认框点不动；员工入职后一次性密码框点不动（且
// barrierDismissible=false + PopScope 挡返回，只能重启应用）；生产计划审核后下达结果框点不动。
//
// 本契约只锁「撤遮罩」这一步还在，不锁具体写法。新增同类调用点请一并登记。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 一条规则：`file` 里 `anchor` 之前不远处必须出现 `needle`。
class _Rule {
  const _Rule({
    required this.file,
    required this.anchor,
    required this.needle,
    required this.why,
    this.maxDistance = 700,
  });

  /// 仓库相对路径。
  final String file;

  /// 被保护的动作（推弹窗 / 推页面 / pop 出去让别人推弹窗），必须在文件里唯一出现。
  final String anchor;

  /// 撤遮罩的那一步。
  final String needle;

  /// 违约时用户会遇到什么。
  final String why;

  /// needle 与 anchor 的最大字符距离，保证它确实作用于这次动作。
  final int maxDistance;
}

const _busyFlagOff = '遮罩的忙标志没有在动作之前置假';
const _waitFrame = '没有等遮罩那一帧画完（OverlayEntry 要等宿主 dispose 才真的摘掉）';

const _rules = <_Rule>[
  // ① 委外到货登记：短交确认框。遮罩不撤则两个按钮都点不动。
  _Rule(
    file:
        'lib/features/warehouse/widgets/subcontract_short_delivery_confirm_dialog.dart',
    anchor: 'await showSubcontractShortDeliveryConfirmDialog(',
    needle: 'setBusy(false);',
    why: '委外到货登记短交确认框：$_busyFlagOff，「继续登记并通知委外」「返回修改」都会点不动',
  ),
  _Rule(
    file:
        'lib/features/warehouse/widgets/subcontract_short_delivery_confirm_dialog.dart',
    anchor: 'await showSubcontractShortDeliveryConfirmDialog(',
    needle: 'await WidgetsBinding.instance.endOfFrame;',
    why: '委外到货登记短交确认框：$_waitFrame',
  ),
  // ② 员工入职：一次性凭据框（barrierDismissible=false + PopScope 挡返回，被盖住＝死锁）。
  _Rule(
    file: 'lib/features/employee/pages/employee_onboarding_page.dart',
    anchor: 'await showEmployeeCredentialDialog(',
    needle: 'setState(() => _submitting = false);',
    why: '员工入职一次性凭据框：$_busyFlagOff，临时密码拿不到也关不掉，只能重启应用',
  ),
  _Rule(
    file: 'lib/features/employee/pages/employee_onboarding_page.dart',
    anchor: 'await showEmployeeCredentialDialog(',
    needle: 'await WidgetsBinding.instance.endOfFrame;',
    why: '员工入职一次性凭据框：$_waitFrame',
  ),
  // ③ 补开账号：开户弹窗 pop 前先清标志，外层推凭据框前再等一帧。
  _Rule(
    file: 'lib/features/employee/widgets/employee_account_provision_flow.dart',
    anchor: 'Navigator.of(context).pop(result);',
    needle: 'setState(() => _submitting = false);',
    maxDistance: 400,
    why: '补开账号：$_busyFlagOff，开户弹窗退场期间遮罩还在，会盖住随后的一次性凭据框',
  ),
  _Rule(
    file: 'lib/features/employee/widgets/employee_account_provision_flow.dart',
    anchor: 'await showEmployeeCredentialDialog(',
    needle: 'await WidgetsBinding.instance.endOfFrame;',
    why: '补开账号：$_waitFrame',
  ),
  // ④ 生产计划详情：审核成功后的「下达结果」弹层。被盖住＝整页卡死。
  _Rule(
    file: 'lib/features/production/pages/production_plan_detail_page.dart',
    anchor: 'await afterSuccess(',
    needle: 'setState(() => _busy = false);',
    why: '生产计划「下达结果」弹层：$_busyFlagOff，弹层点不动且遮罩等它返回，整页卡死',
  ),
  _Rule(
    file: 'lib/features/production/pages/production_plan_detail_page.dart',
    anchor: 'await afterSuccess(',
    needle: 'await WidgetsBinding.instance.endOfFrame;',
    why: '生产计划「下达结果」弹层：$_waitFrame',
  ),
];

void main() {
  test('结果弹层之前一定先撤跑批遮罩（root Overlay 裸图层会被重排抬到最顶）', () {
    final problems = <String>[];
    for (final rule in _rules) {
      final file = File(rule.file);
      if (!file.existsSync()) {
        problems.add('${rule.file}: 文件不存在，登记已过期，请更新本契约');
        continue;
      }
      final source = file.readAsStringSync();
      final anchorCount = rule.anchor.allMatches(source).length;
      if (anchorCount != 1) {
        problems.add(
          '${rule.file}: 锚点「${rule.anchor}」出现 $anchorCount 次（应恰好 1 次），'
          '登记已过期，请更新本契约',
        );
        continue;
      }
      final anchorAt = source.indexOf(rule.anchor);
      final needleAt = source.lastIndexOf(rule.needle, anchorAt);
      if (needleAt < 0) {
        problems.add(
          '${rule.file}: 「${rule.anchor}」之前缺少「${rule.needle}」——${rule.why}',
        );
        continue;
      }
      if (anchorAt - needleAt > rule.maxDistance) {
        problems.add(
          '${rule.file}: 「${rule.needle}」离「${rule.anchor}」有 ${anchorAt - needleAt} 个字符，'
          '超出 ${rule.maxDistance}，请确认它确实作用于这次动作——${rule.why}',
        );
      }
    }
    expect(
      problems,
      isEmpty,
      reason:
          '跑批遮罩没在结果弹层之前撤下，用户会遇到「弹窗点不动 / 整页卡死」：\n'
          '${problems.join('\n')}',
    );
  });

  test('遮罩组件本身仍是 root Overlay 裸图层（本契约的前提没被悄悄改掉）', () {
    final source = File(
      'lib/components/feedback/uten_busy_overlay.dart',
    ).readAsStringSync();
    expect(
      source.contains('rootOverlay: true'),
      isTrue,
      reason:
          '遮罩若改成随宿主挂载或改走路由，本文件「弹层前先撤遮罩」的约束前提就变了，'
          '请连同 _rules 登记一起重新评估',
    );
  });
}
