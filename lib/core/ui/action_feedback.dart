// 统一操作反馈执行器：一行调用自带「成功 / 业务失败 / 网络失败」顶部通知。
// 文档：docs/02-组件库/UtenNotify.md §统一操作反馈
//
// 解决两类历史问题：
// 1. 每个页面重复写 try / on ApiException / catch 三段样板（仅提示语不同）；
// 2. 部分操作静默失败（异常被吞、用户点了按钮毫无反馈）。
//
// 用法：
//   final detail = await context.guardAction(
//     () => repo.approve(id),
//     success: '已审核',
//   );
//   if (detail == null) return; // 失败已自动弹顶部错误通知
//
//   final rows = await context.guardLoad(() => repo.list()); // 读操作：成功不打扰
//
// 错误映射（全部走 AppNotificationService 顶部弹条，微信式）：
// - ApiException → 后端 message + fieldErrors（网络失败 NetworkException 自带
//   「网络连接失败，请检查后重试」；5xx → 「服务器繁忙」；401/403/429 各有语义文案）；
// - 其它异常 → errorFallback。
import 'package:flutter/widgets.dart';

import '../network/api_exception.dart';
import 'app_notification.dart';

export 'app_notification.dart'
    show AppNotificationKind, AppNotificationContextX;

extension GuardedActionContextX on BuildContext {
  /// 执行一个写操作（保存 / 审核 / 红冲 / 删除 / 提交 …），自动弹顶部通知。
  ///
  /// - 成功：显示 [success]（为 null 则不弹成功条），返回 action 的结果；
  /// - 失败：自动弹顶部错误通知并返回 null，调用方 `if (r == null) return;` 即可。
  Future<T?> guardAction<T>(
    Future<T> Function() action, {
    String? success,
    String errorFallback = '操作失败，请稍后重试',
  }) async {
    try {
      final r = await action();
      // context 可能已随页面销毁（async gap）：只在存活时弹通知。
      if (success != null && mounted) appSuccess(success);
      return r;
    } on ApiException catch (e) {
      if (mounted) {
        appError(
          e.message.isNotEmpty ? e.message : errorFallback,
          fieldErrors: e.fieldErrors,
        );
      }
      return null;
    } catch (_) {
      if (mounted) appError(errorFallback);
      return null;
    }
  }

  /// 执行一个读操作（加载列表 / 详情 / 报表）：成功不打扰，失败自动弹顶部错误通知。
  Future<T?> guardLoad<T>(
    Future<T> Function() action, {
    String errorFallback = '加载失败，请稍后重试',
  }) => guardAction(action, errorFallback: errorFallback);

  /// 执行一个写操作并只关心成败（如 bool 回调场景：删除、基础资料保存）。
  /// 返回 true = 成功（并已弹 [success]），false = 失败（已弹错误条）。
  Future<bool> guardRun(
    Future<void> Function() action, {
    String? success,
    String errorFallback = '操作失败，请稍后重试',
  }) async {
    final ok = await guardAction(
      () async {
        await action();
        return true;
      },
      success: success,
      errorFallback: errorFallback,
    );
    return ok != null;
  }
}
