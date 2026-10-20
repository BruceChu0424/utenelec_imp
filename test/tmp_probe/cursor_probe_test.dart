// ignore_for_file: avoid_print
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

class _Row {
  const _Row(this.id, this.name);
  final String id;
  final String name;
}

void main() {
  testWidgets('cursor probe with chain dump', (tester) async {
    String? cursor;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.mouseCursor, (call) async {
      cursor = 'm=${call.method}:a=${call.arguments}';
      return null;
    });
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 900,
          height: 400,
          child: MasterDataTableView<_Row>(
            columns: [
              MasterColumnDef<_Row>(
                key: 'name',
                label: '货品名称',
                width: 200,
                value: (g) => g.name,
                cellBuilder: (context, g) => Text(g.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              MasterColumnDef<_Row>(key: 'code', label: '编号', width: 120, value: (g) => g.id),
            ],
            items: const [_Row('HP-001', '外壳件')],
            facets: const {}, nullCounts: const {}, filters: const {}, onFilterChanged: (_, _) {},
            selectable: true,
            idOf: (g) => g.id,
            selectedIds: const {},
            onSelectedIdsChanged: (_) {},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse, pointer: 99);
    await gesture.addPointer(location: Offset.zero);
    await tester.pump();

    cursor = null;
    await gesture.moveTo(tester.getCenter(find.text('外壳件')));
    await tester.pump();
    print('CURSOR name=$cursor');

    cursor = null;
    await gesture.moveTo(tester.getCenter(find.text('HP-001')));
    await tester.pump();
    print('CURSOR code=$cursor');

    var node = tester.renderObject(find.text('HP-001')).parent;
    final chain = <String>[];
    while (node != null && chain.length < 22) {
      chain.add(node.runtimeType.toString());
      node = node.parent;
    }
    print('CHAIN code=${chain.join(' > ')}');
    final pos = tester.getCenter(find.text('HP-001'));
    final result = HitTestResult();
    tester.binding.hitTestInView(result, pos, tester.view.viewId);
    print('HITPATH=${result.path.map((e) => e.target.runtimeType).join(' > ')}');
    for (final entry in result.path) {
      final t = entry.target;
      if (t is RenderMouseRegion) {
        String inner = '(none)';
        void walk(AbstractNode? n) {
          while (n != null) {
            if (n is RenderParagraph) { inner = n.text.toPlainText(); return; }
            if (n is ContainerRenderObjectMixin) { walk((n as ContainerRenderObjectMixin).firstChild); if (inner != '(none)') return; }
            n = n is RenderObject ? n.parent : null;
          }
        }
        walk(t);
        print('MOUSEREGION cursor=${t.cursor} size=${t.size} chain=${t.debugCreator}');
      }
    }
    final para = tester.renderObject(find.text('HP-001')) as RenderParagraph;
    final localPara = para.globalToLocal(pos);
    print('PARA hit=${para.hitTest(BoxHitTestResult(), position: localPara)} size=${para.size} local=$localPara');
  });
}
