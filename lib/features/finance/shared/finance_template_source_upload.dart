import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../shared/providers/export_context_epoch_provider.dart';

/// The same immutable workbook is reused after an explicit sheet choice.
/// Selection errors occur before source storage; other failures keep their
/// original transport/write semantics and never cause an automatic new upload.
Future<Map<String, dynamic>?> uploadFinanceTemplateSource({
  required BuildContext context,
  required ApiClient api,
  required Uint8List bytes,
  required Map<String, dynamic> query,
  required bool asset,
  required bool Function() isCurrent,
  Duration sendTimeout = const Duration(minutes: 2),
  Duration receiveTimeout = const Duration(minutes: 3),
}) async {
  if (!isCurrent()) return null;
  final original = Map<String, dynamic>.unmodifiable(query);
  var retired = false;
  Future<Map<String, dynamic>> send(Map<String, dynamic> parameters) =>
      api.postBytes(
        '/finance/template-imports/${asset ? 'assets' : 'costs'}/preview',
        bytes,
        query: parameters,
        sendTimeout: sendTimeout,
        receiveTimeout: receiveTimeout,
      );
  try {
    return await send(original);
  } on ApiException catch (error) {
    final fields = error.fieldErrors;
    if (!isCurrent() ||
        !context.mounted ||
        !error.hasResponseCode ||
        error.code != 'VALIDATION_FAILED' ||
        !const {400, 422}.contains(error.httpStatus) ||
        fields == null ||
        fields.length < 2 ||
        fields.length > 64 ||
        fields.any(
          (field) =>
              field.field != 'sourceSheet' ||
              field.message.trim().isEmpty ||
              field.message.length > 500,
        ) ||
        fields.map((field) => field.message).toSet().length != fields.length) {
      rethrow;
    }
    String? selected;
    final chosen = await UtenDialog.showAndWaitForExit<String>(
      context,
      barrierDismissible: false,
      builder: (dialogContext) => Consumer(
        builder: (context, ref, _) {
          ref.watch(exportContextEpochProvider);
          ref.watch(apiClientProvider);
          final current =
              !retired &&
              isCurrent() &&
              identical(api, ref.read(apiClientProvider));
          if (!current) retired = true;
          return StatefulBuilder(
            builder: (context, update) => UtenAlertDialog(
              title: const Text('选择原表工作表'),
              content: current
                  ? UtenDropdownField(
                      label: '原表工作表',
                      value: selected,
                      info: '同一文件有多张表头相同的原表，请按附件中的原名选择。',
                      items: [
                        for (final field in fields)
                          UtenDropdownItem(
                            value: field.message,
                            label: field.message,
                          ),
                      ],
                      onChanged: (value) => update(() => selected = value),
                    )
                  : const Text('身份或权限已变化，请关闭后从原入口重新打开。'),
              actions: [
                UtenButton(
                  type: UtenButtonType.secondary,
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('取消'),
                ),
                if (current)
                  UtenButton(
                    onPressed: selected == null
                        ? null
                        : () => Navigator.pop(dialogContext, selected),
                    child: const Text('导入所选工作表'),
                  ),
              ],
            ),
          );
        },
      ),
    );
    if (chosen == null || retired || !isCurrent()) return null;
    return send({...original, 'sourceSheet': chosen});
  }
}
