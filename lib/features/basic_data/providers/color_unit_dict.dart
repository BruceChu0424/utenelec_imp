// 颜色/单位字典 provider + 货品编辑内联新建 helper。
//
// 货品编辑表单的颜色/单位下拉选项来自这两个 provider；内联新建颜色/单位后 invalidate，
// 全局刷新（货品编辑下拉 + 单据名解析复用同一份）。新建后返回新 legacy_id 串，自动选中。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../models/color_node.dart';
import '../models/unit_node.dart';
import '../repositories/color_repository.dart';
import '../repositories/unit_repository.dart';

/// 颜色字典（货品编辑颜色下拉 + 单据颜色名解析共用）。新建颜色后 invalidate 全局刷新。
final colorDictProvider =
    FutureProvider<List<ColorListItem>>((ref) async {
  return ref.watch(colorRepositoryProvider).dict();
});

/// 单位字典。
final unitDictProvider = FutureProvider<List<UnitListItem>>((ref) async {
  return ref.watch(unitRepositoryProvider).dict();
});

/// 货品编辑内联新建颜色：弹窗输入名称 → 预查重 → POST → 刷新字典 → 返回新 legacy_id（自动选中）。
/// 取消/失败返回 null。
Future<String?> showColorAddSheet(BuildContext context, WidgetRef ref) {
  return _showAddSheet(
    context: context,
    title: '添加颜色',
    dict: ref.read(colorDictProvider).valueOrNull ?? const <ColorListItem>[],
    exists: (name) => ref
        .read(colorDictProvider)
        .valueOrNull
        ?.any((c) => (c.name ?? '').toLowerCase() == name.toLowerCase()) ??
        false,
    create: (name) async {
      final d = await ref
          .read(colorRepositoryProvider)
          .create({'name': name, 'status': '使用'});
      ref.invalidate(colorDictProvider);
      return d.legacyId?.toString();
    },
  );
}

/// 货品编辑内联新建单位（同上）。
Future<String?> showUnitAddSheet(BuildContext context, WidgetRef ref) {
  return _showAddSheet(
    context: context,
    title: '添加单位',
    dict: ref.read(unitDictProvider).valueOrNull ?? const <UnitListItem>[],
    exists: (name) => ref
        .read(unitDictProvider)
        .valueOrNull
        ?.any((u) => (u.name ?? '').toLowerCase() == name.toLowerCase()) ??
        false,
    create: (name) async {
      final d = await ref
          .read(unitRepositoryProvider)
          .create({'name': name, 'status': '使用'});
      ref.invalidate(unitDictProvider);
      return d.legacyId?.toString();
    },
  );
}

Future<String?> _showAddSheet({
  required BuildContext context,
  required String title,
  required List<dynamic> dict, // 仅用于长度提示，查重走 exists 闭包（实时读 provider）
  required bool Function(String name) exists,
  required Future<String?> Function(String name) create,
}) {
  final ctl = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, set) {
          String? error;
          Future<void> doSave() async {
            final name = ctl.text.trim();
            if (name.isEmpty) {
              set(() => error = '请输入名称');
              return;
            }
            if (exists(name)) {
              set(() => error = '该名称已存在');
              return;
            }
            try {
              final v = await create(name);
              if (!ctx.mounted) return;
              Navigator.of(ctx).pop(v);
            } on ApiException catch (e) {
              set(() => error = e.message);
            } catch (_) {
              set(() => error = '保存失败，请稍后重试');
            }
          }

          return Dialog(
            shape:
                const RoundedRectangleBorder(borderRadius: UtenRadius.xxlAll),
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
                              style: Theme.of(ctx)
                                  .textTheme
                                  .titleMedium
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
                              errorText: error,
                            ),
                            onSubmitted: (_) => doSave(),
                          ),
                          const SizedBox(height: UtenSpacing.s4),
                          Text(
                            '编号保存后自动生成，状态默认「使用」',
                            style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                                  color: Theme.of(ctx)
                                      .colorScheme
                                      .onSurfaceVariant,
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
