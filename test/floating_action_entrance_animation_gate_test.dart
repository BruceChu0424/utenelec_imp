import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// 右下角悬浮按钮「入场动画」静态闸门(2026-09-15 用户口径：全站取消)。
//
// 现象：详情/审核页的右下角动作组要等数据回来才建(`_detail == null ? null : _actions()`)，
// Scaffold 于是把它当「FAB 从无到有」，按 floatingActionButtonAnimator 默认值
// (FloatingActionButtonAnimator.scaling)缩放淡入——销售订货单审核后跳详情页，
// 四个按钮会先缩后弹。用户明确要求「都给取消动画 其他页面也是」。
//
// 口径：凡是给 Scaffold 传 `floatingActionButton:` 的页面，必须同时传
// `floatingActionButtonAnimator: FloatingActionButtonAnimator.noAnimation`。
// 本闸门按文件比对两个具名参数的出现次数(只数「行首参数」形态，注释里的示例不计)，
// 新页面漏配即失败。
void main() {
  test('每个传 floatingActionButton 的 Scaffold 都显式关掉入场动画', () {
    final fabParam = RegExp(r'^\s*floatingActionButton:', multiLine: true);
    final animatorParam = RegExp(
      r'^\s*floatingActionButtonAnimator:',
      multiLine: true,
    );
    // 关掉动画的唯一写法：换成别的 animator 就不是「无动画」了。
    const noAnimation =
        'floatingActionButtonAnimator: FloatingActionButtonAnimator.noAnimation,';

    final libDir = Directory('lib');
    expect(libDir.existsSync(), isTrue, reason: '请在仓库根目录运行本测试');

    final offenders = <String>[];
    var scanned = 0;
    for (final entity in libDir.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final source = entity.readAsStringSync();
      final fabs = fabParam.allMatches(source).length;
      if (fabs == 0) continue;
      scanned++;
      final path = entity.path.replaceAll(r'\', '/');
      final animators = animatorParam.allMatches(source).length;
      if (animators != fabs) {
        offenders.add(
          '$path: floatingActionButton=$fabs 但 animator=$animators',
        );
        continue;
      }
      final disabled = noAnimation.allMatches(source).length;
      if (disabled != fabs) {
        offenders.add('$path: animator 不是 noAnimation($disabled/$fabs)');
      }
    }

    // 防闸门空转：正则漂移导致一个文件都没扫到时，上面的 isEmpty 会「假绿」。
    expect(scanned, greaterThan(40), reason: '扫到的带 FAB 页面过少，正则可能已漂移');
    expect(
      offenders,
      isEmpty,
      reason:
          '以下 Scaffold 会让右下角按钮缩放淡入，请补 '
          '`$noAnimation`：\n${offenders.join('\n')}',
    );
  });
}
