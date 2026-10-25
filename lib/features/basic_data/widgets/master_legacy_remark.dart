import 'dart:convert';

import 'package:flutter/widgets.dart';

import 'master_inline_edit.dart';

/// Present the exact archive marker written by the legacy master importer.
/// Raw notes remain the edit/filter/export source; unknown text stays intact.
String? masterLegacyRemarkText(BuildContext context, String? raw) {
  if (raw == null) return null;
  const marker = '[原始主档编号] ';
  return raw
      .split('\n')
      .map((line) {
        if (!line.trimLeft().startsWith(marker)) return line;
        try {
          final value = jsonDecode(line.trimLeft().substring(marker.length));
          if (value is! Map ||
              value.length != 2 ||
              value['code'] is! String ||
              value['mnumber'] is! String) {
            return line;
          }
          final code = (value['code'] as String).trim();
          final alternate = (value['mnumber'] as String).trim();
          if (code.isEmpty && alternate.isEmpty) return line;
          return [
            if (code.isNotEmpty)
              '${masterEditText(context, '原编号', 'Original code', '원래 번호')}: $code',
            if (alternate.isNotEmpty)
              '${masterEditText(context, '原备用编号', 'Original alternate code', '원래 보조 번호')}: $alternate',
          ].join(' · ');
        } on FormatException {
          return line;
        }
      })
      .join('\n');
}
