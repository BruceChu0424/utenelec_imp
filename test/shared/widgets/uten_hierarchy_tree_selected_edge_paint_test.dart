import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/basic_data/models/payment_style_node.dart';
import 'package:uten_imp/features/basic_data/widgets/uten_category_tree_view.dart';

void main() {
  for (final dark in [false, true]) {
    for (final mode in UtenCategoryTreeMode.values) {
      testWidgets(
        'selected outer corners contain no retired row-color fringe dark=$dark mode=$mode',
        (tester) async {
          if (Platform.environment['UTEN_TREE_EDGE_PREVIEW_DIR'] != null) {
            final font = FontLoader('NotoSansSC')
              ..addFont(rootBundle.load('assets/fonts/NotoSansSC.ttf'));
            await font.load();
          }
          final capture = GlobalKey();
          await tester.pumpWidget(
            MaterialApp(
              theme: (dark ? buildDarkTheme() : buildLightTheme()).copyWith(
                platform: TargetPlatform.windows,
              ),
              home: Scaffold(
                backgroundColor: dark ? Colors.black : Colors.white,
                body: RepaintBoundary(
                  key: capture,
                  child: ColoredBox(
                    color: dark ? Colors.black : Colors.white,
                    child: SizedBox(
                      width: 240,
                      height: 180,
                      child: UtenCategoryTreeView<PaymentStyleNode>(
                        nodes: [
                          PaymentStyleNode(
                            id: 'first',
                            code: 'A',
                            name: '首项',
                            children: const [],
                          ),
                          PaymentStyleNode(
                            id: 'middle',
                            code: 'B',
                            name: '中项',
                            children: const [],
                          ),
                          PaymentStyleNode(
                            id: 'last',
                            code: 'C',
                            name: '末项',
                            children: const [],
                          ),
                        ],
                        showSearch: false,
                        flatLevelColors: true,
                        mode: mode,
                        trailingBuilder: (_) => const SizedBox(
                          width: 24,
                          height: 56,
                          child: Icon(Icons.lock_outline, size: 18),
                        ),
                        selectedIds: const {'first', 'last'},
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final boundary =
              capture.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final origin = tester.getTopLeft(find.byKey(capture));
          final first = tester
              .getRect(find.byKey(const ValueKey('hierarchy-row:first')))
              .shift(-origin);
          final last = tester
              .getRect(find.byKey(const ValueKey('hierarchy-row:last')))
              .shift(-origin);
          late List<int> rgba;
          late int width;
          await tester.runAsync(() async {
            final picture = await boundary.toImage(pixelRatio: 2);
            width = picture.width;
            rgba = (await picture.toByteData())!.buffer.asUint8List().toList();
            final output = Platform.environment['UTEN_TREE_EDGE_PREVIEW_DIR'];
            if (output != null) {
              final png = await picture.toByteData(
                format: ui.ImageByteFormat.png,
              );
              await File(
                '$output/tree-edges-${dark ? 'dark' : 'light'}-${mode.name}.png',
              ).writeAsBytes(png!.buffer.asUint8List());
            }
            picture.dispose();
          });
          var maximumChroma = 0;
          for (final row in [first, last]) {
            for (var dx = 0; dx < 12; dx++) {
              for (var dy = 0; dy < 12; dy++) {
                final x = (row.left * 2).round() + dx;
                final y = row == first
                    ? (row.top * 2).round() + dy
                    : (row.bottom * 2).round() - 1 - dy;
                final offset = (y * width + x) * 4;
                final rgb = rgba.sublist(offset, offset + 3)..sort();
                final chroma = rgb.last - rgb.first;
                if (chroma > maximumChroma) maximumChroma = chroma;
              }
            }
          }
          // White selection against a neutral backing has only neutral coverage
          // pixels at the outer curve. A teal fringe proves the retired base row
          // was painted underneath a second antialiased clip.
          expect(maximumChroma, lessThanOrEqualTo(1));
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
