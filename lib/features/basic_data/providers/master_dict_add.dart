// 主档字典内联新增弹窗（名称单项）+ 币种/结算方式新增入口。
//
// 范式与颜色/单位（color_unit_dict.dart）一致：单据表单下拉里点「添加」→ 弹窗输入
// 名称 → 前端查重 → POST → 刷新对应字典 → 返回新 UUID（调用方写入选中值，自动选中）。
// 通用弹窗抽到这里供各字典共用；颜色/单位仍从 color_unit_dict 走同一份实现。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_exception.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/drafts/form_draft_dialog_resume.dart';
import '../widgets/master_edit_dialog.dart';
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
  FormDraftSpec? draftSpec,
}) async {
  String? createdId;
  await showMasterEditDialog(
    context: context,
    title: title,
    draftSpec: draftSpec,
    fields: const [MasterFieldDef(key: 'name', label: '名称', required: true)],
    onSubmit: (body) async {
      final name = body['name'] as String;
      if (exists(name)) {
        throw ApiException('DUPLICATE_NAME', '该名称已存在', httpStatus: 400);
      }
      createdId = await create(name);
      return createdId != null;
    },
  );
  return createdId;
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
    draftSpec: FormDraftCatalog.currency.spec(title: '添加币种'),
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
    draftSpec: FormDraftCatalog.settlement.spec(title: '添加结账方式'),
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
