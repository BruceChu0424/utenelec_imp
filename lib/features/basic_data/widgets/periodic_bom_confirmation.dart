// 整批领料的料 (期间边, ADR-131) 保存时服务端要人确认的两件事:
// 单个重量小于 0.1 克或大于 5000 克 (confirmUnusualWeight)、同一产品再加一种整批领料的料
// (confirmSecondPeriodicMaterial)。
//
// 服务端回 422 VALIDATION_FAILED, fieldErrors 全是这两个字段名 (message 是写给员工看的中文)。
// 页面据此弹确认框; 确认后把对应字段置 true, 原样重发。BOM 行编辑、添加组件、粘贴组件、
// 车间内料仓上线准备都走这一套。页面自己事先能判断的 (如单重超范围) 可以先问, 服务端仍会再核一遍,
// 漏问的由这里兜住。
import 'package:flutter/material.dart';

import '../../../core/network/api_error.dart';
import '../../../core/network/api_exception.dart';

/// 确认异常单个重量的请求字段名。
const periodicConfirmUnusualWeight = 'confirmUnusualWeight';

/// 确认同一产品第二种整批领料的料的请求字段名。
const periodicConfirmSecondMaterial = 'confirmSecondPeriodicMaterial';

/// 这个错误只是「要人确认」时返回要确认的各项 (字段名 + 说明); 其它错误返回 null。
List<ApiFieldError>? periodicConfirmationsOf(Object error) {
  if (error is! ApiException || error.code != 'VALIDATION_FAILED') return null;
  final fields = error.fieldErrors;
  if (fields == null || fields.isEmpty) return null;
  final onlyConfirmations = fields.every(
    (f) =>
        f.field == periodicConfirmUnusualWeight ||
        f.field == periodicConfirmSecondMaterial,
  );
  return onlyConfirmations ? fields : null;
}

/// 弹框列出服务端要确认的事。确认返回要置 true 的字段名, 取消返回 null。
///
/// 调用前先撤掉忙碌遮罩 (遮罩会盖住后弹的确认框)。
Future<Set<String>?> askPeriodicConfirmations(
  BuildContext context,
  List<ApiFieldError> confirmations,
) async {
  final secondMaterial = confirmations.any(
    (f) => f.field == periodicConfirmSecondMaterial,
  );
  final unusual = confirmations.any(
    (f) => f.field == periodicConfirmUnusualWeight,
  );
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('保存前请确认'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final f in confirmations)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text('· ${f.message}'),
                ),
              if (unusual)
                const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Text('单个重量小于 0.1 克或大于 5000 克, 常见是把公斤当成克填了。'),
                ),
              if (secondMaterial)
                const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Text('同一个产品同时用两种料 (双色 / 双料) 才这样填; 只是换料的话, 请改原来那一行。'),
                ),
            ],
          ),
        ),
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('返回修改'),
        ),
        FilledButton(
          key: const Key('periodic-bom-confirm'),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('确定没错, 继续保存'),
        ),
      ],
    ),
  );
  if (ok != true) return null;
  return {for (final f in confirmations) f.field};
}

/// 把确认过的字段写进请求体 (只写 true, 没问到的字段不动)。
void applyPeriodicConfirmations(
  Iterable<Map<String, dynamic>> bodies,
  Set<String> confirmed,
) {
  for (final body in bodies) {
    for (final field in confirmed) {
      body[field] = true;
    }
  }
}
