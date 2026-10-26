@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/print/isolated_print_pdf.dart';

void main() {
  test(
    'original full Chinese glyph font renders raw organization names in portrait layout',
    () async {
      final generator = IsolatedPrintPdfGenerator();
      addTearDown(generator.dispose);
      final font = Uint8List.fromList(
        File('assets/fonts/NotoSansSCFull.ttf').readAsBytesSync(),
      );
      final bytes = await generator.generate(
        PrintPdfRequest.orgChart(
          title: '原部门龘 · 组织架构图',
          subtitle: '打印日期：2026-10-26(北京)',
          fontBytes: font,
          lines: [
            const OrgChartPrintLine(
              kind: 'department',
              depth: 0,
              text: '原部门龘',
              detail: '负责人：张主管 · 601 人',
            ),
            const OrgChartPrintLine(
              kind: 'manager',
              depth: 0,
              text: '★ 张主管(负责人)',
              bold: true,
            ),
            for (var index = 0; index < 601; index++)
              OrgChartPrintLine(
                kind: 'member',
                depth: 0,
                text: '原始姓名龘$index · 原岗位',
                bold: index == 0,
              ),
            const OrgChartPrintLine(
              kind: 'department',
              depth: 1,
              text: '子部门',
              detail: '负责人：李主管 · 0 人',
            ),
            const OrgChartPrintLine(
              kind: 'manager',
              depth: 1,
              text: '★ 李主管(负责人，非本部门直属(挂职))',
              bold: true,
            ),
          ],
        ),
      );
      expect(bytes.take(5), '%PDF-'.codeUnits);
      final evidence = Platform.environment['UTEN_B1_PDF_EVIDENCE_DIR'];
      if (evidence != null) {
        final directory = Directory(evidence).absolute;
        await directory.create(recursive: true);
        await File(
          '${directory.path}${Platform.pathSeparator}department-org-chart-601.pdf',
        ).writeAsBytes(bytes);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
