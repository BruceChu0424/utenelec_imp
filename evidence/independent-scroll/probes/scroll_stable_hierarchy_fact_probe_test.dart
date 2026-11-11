import 'dart:convert';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_collapsing_header_scroll_view.dart';

class _Body extends StatefulWidget {
  const _Body({super.key});
  @override State<_Body> createState()=>_BodyState();
}
class _BodyState extends State<_Body> {
  late ScrollController primary;
  @override void didChangeDependencies() {super.didChangeDependencies();primary=PrimaryScrollController.of(context);}
  @override Widget build(BuildContext context)=>Column(children:[
    const SizedBox(height:64,child:TextField(key:ValueKey('draft-input'))),
    Expanded(child:ListView.builder(
      key:const ValueKey('real-body-list'),
      primary:true,itemExtent:48,itemCount:100,
      itemBuilder:(_,i)=>Text('ROW-$i'),
    )),
  ]);
}

void main() {
  final cases=<({String label,Size from,Size to})>[
    (label:'width-wide-to-compact',from:const Size(1000,900),to:const Size(320,900)),
    (label:'width-compact-to-wide',from:const Size(320,900),to:const Size(1000,900)),
    (label:'height-tall-to-short',from:const Size(1000,900),to:const Size(1000,390)),
    (label:'height-short-to-tall',from:const Size(1000,390),to:const Size(1000,900)),
  ];
  for(final sample in cases) {
    testWidgets('stable hierarchy observe ${sample.label} nonzero inner through header wheel', (tester) async {
      tester.view.devicePixelRatio=1;
      tester.view.physicalSize=sample.from;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final outer=ScrollController();
      addTearDown(outer.dispose);
      final bodyKey=GlobalKey<_BodyState>();
      await tester.pumpWidget(MaterialApp(home:Scaffold(body:UtenCollapsingHeaderScrollView(
        controller:outer,
        stableBodyViewport:true,
        collapsingHeader:const SizedBox(height:96,child:Text('HEADER')),
        body:_Body(key:bodyKey),
      ))));
      await tester.pumpAndSettle();
      final body=bodyKey.currentState!;
      await tester.enterText(find.byKey(const ValueKey('draft-input')),'draft 7.125');
      Future<void> wheel(double delta) async {
        final host=tester.getRect(find.byType(UtenCollapsingHeaderScrollView));
        final list=tester.getRect(find.byKey(const ValueKey('real-body-list'))).intersect(host);
        final point=list.height>1?list.center:Offset(host.left+24,host.top+12);
        final pointer=TestPointer(7,PointerDeviceKind.mouse);
        await tester.sendEventToBinding(pointer.hover(point));
        await tester.sendEventToBinding(pointer.scroll(Offset(0,delta)));
        await tester.pumpAndSettle();
      }
      // A focused field can reveal another few header pixels on its first
      // settled frame. Drive the unchanged wheel/hold contract until the
      // real body offset is nonzero; never infer it from a structure type.
      for(var attempt=0;attempt<8&&body.primary.position.pixels<=100;attempt++) {
        await wheel(1000);
        await tester.pump(const Duration(milliseconds:351));
      }
      final initial=body.primary.position.pixels;
      expect(initial,greaterThan(100),reason:'the body must really be scrolled, not merely mounted');
      final startOuter=outer.position.pixels;
      tester.view.physicalSize=sample.to;
      await tester.pumpAndSettle();
      final transitionInner=body.primary.position.pixels;
      final transitionOuter=outer.position.pixels;
      expect(tester.takeException(),isNull);
      expect(transitionInner,closeTo(initial,0.01),reason:'mode transition preserves existing inner coordinate');
      // The historical stable hierarchy did not always reset the header.

      await wheel(24);
      final smallInner=body.primary.position.pixels;
      final smallOuter=outer.position.pixels;
      // Record rather than assume the hierarchy's historical coordinate law.

      await wheel(1000);
      final after=body.primary.position.pixels;
      final result=<String,Object>{
        'case':sample.label,'initialInner':initial,'initialOuter':startOuter,
        'transitionInner':transitionInner,'transitionOuter':transitionOuter,
        'afterSmallInner':smallInner,'afterSmallOuter':smallOuter,
        'afterBoundaryInner':after,'afterBoundaryOuter':outer.position.pixels,
        'outerMax':outer.position.maxScrollExtent,
      };
      // Fact collection only: acceptance/regression is judged against the
      // unchanged 14e product, not by treating this diagnostic exit as green.
      // ignore: avoid_print
      print('SCROLL-FACT '+jsonEncode(result));
      expect(find.text('draft 7.125'),findsOneWidget);
      expect(tester.takeException(),isNull);
    });
  }
}
