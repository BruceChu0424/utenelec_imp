// 主档字典内联新增弹窗（名称单项）+ 币种/结算方式新增入口。
//
// 范式与颜色/单位（color_unit_dict.dart）一致：单据表单下拉里点「添加」→ 弹窗输入
// 名称 → 前端查重 → POST → 刷新对应字典 → 返回新 UUID（调用方写入选中值，自动选中）。
// 通用弹窗抽到这里供各字典共用；颜色/单位仍从 color_unit_dict 走同一份实现。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/inputs/uten_field_message.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/action_feedback.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../models/reference_method_option.dart';
import '../repositories/currency_repository.dart';
import '../repositories/reference_method_repository.dart';

/// 通用「输入名称新建字典项」弹窗：名称非空校验 + 前端查重（[exists] 实时读字典）、
/// [create] 返回新 id 后 pop；取消/失败返回 null。
Future<String?> showNameAddSheet({
  required BuildContext context,
  required String title,
  required bool Function(String name) exists,
  required Future<String?> Function(String name) create,
}) {
  final ctl = TextEditingController();
  String? error;
  return showDialog<String>(
    context: context,
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, set) {
          Future<void> doSave() async {
            final name = ctl.text.trim();
            if (name.isEmpty) {
              set(() => error = '请输入名称');
              return;
            }
            if (exists(name)) {
              const msg = '该名称已存在';
              set(() => error = msg);
              ctx.appError(msg);
              return;
            }
            try {
              final v = await create(name);
              if (!ctx.mounted) return;
              Navigator.of(ctx).pop(v);
            } on ApiException catch (e) {
              set(() => error = e.message);
              if (ctx.mounted) ctx.appError(e.message);
            } catch (_) {
              const msg = '保存失败，请稍后重试';
              set(() => error = msg);
              if (ctx.mounted) ctx.appError(msg);
            }
          }

          return Dialog(
            shape: const RoundedRectangleBorder(
              borderRadius: UtenRadius.xxlAll,
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: SafeArea(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        UtenSpacing.s16,
                        UtenSpacing.s12,
                        UtenSpacing.s8,
                        UtenSpacing.s12,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              title,
                              style: Theme.of(ctx).textTheme.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.close_rounded),
                            onPressed: () => Navigator.of(ctx).pop(),
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    Padding(
                      padding: const EdgeInsets.all(UtenSpacing.s16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          TextField(
                            controller: ctl,
                            autofocus: true,
                            decoration: InputDecoration(
                              labelText: '名称',
                              border: const OutlineInputBorder(),
                              isDense: true,
                              error: utenFieldError(error),
                            ),
                            onSubmitted: (_) => doSave(),
                          ),
                          const SizedBox(height: UtenSpacing.s4),
                          Text(
                            '编号保存后自动生成，状态默认「使用」',
                            style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                              color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    Padding(
                      padding: const EdgeInsets.all(UtenSpacing.s16),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          TextButton(
                            onPressed: () => Navigator.of(ctx).pop(),
                            child: const Text('取消'),
                          ),
                          const SizedBox(width: UtenSpacing.s12),
                          FilledButton(
                            onPressed: doSave,
                            child: const Text('保存'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      );
    },
  ).whenComplete(ctl.dispose);
}

/// 单据表单内联新增币种（currency:edit）：创建后重载 [names]（调用方页面的
/// 名称服务实例）的币种字典并返回新 UUID。
Future<String?> showCurrencyAddSheet(
  BuildContext context,
  WidgetRef ref,
  MasterDictionaryService names,
) {
  if (!ref.read(currentPermissionsProvider).contains(Perm.currencyCreate)) {
    return Future<String?>.value();
  }
  return showNameAddSheet(
    context: context,
    title: '添加币种',
    exists: (name) => names.currencyEntries.values.any(
      (n) => n.toLowerCase() == name.toLowerCase(),
    ),
    create: (name) async {
      final d = await ref.read(currencyRepositoryProvider).create({
        'name': name,
        'status': '使用',
      });
      await names.reloadCurrencies();
      return d.id;
    },
  );
}

/// 单据表单内联新增结账方式（payment_style:edit）：创建后 invalidate 字典
/// provider 并返回新 UUID。
Future<String?> showSettlementAddSheet(BuildContext context, WidgetRef ref) {
  if (!ref
      .read(currentPermissionsProvider)
      .contains(Perm.settlementMethodCreate)) {
    return Future<String?>.value();
  }
  return showNameAddSheet(
    context: context,
    title: '添加结账方式',
    exists: (name) =>
        (ref.read(settlementMethodOptionsProvider).valueOrNull ??
                const <ReferenceMethodOption>[])
            .any((m) => m.name.toLowerCase() == name.toLowerCase()),
    create: (name) async {
      final created = await ref
          .read(referenceMethodRepositoryProvider)
          .createSettlement(name);
      ref.invalidate(settlementMethodOptionsProvider);
      return created.id;
    },
  );
}
