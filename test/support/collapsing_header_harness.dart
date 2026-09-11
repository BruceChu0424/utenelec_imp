// 折叠头（UtenCollapsingHeaderScrollView）接入页的共用测试夹具。
//
// 两类断言：
//  1) 折叠：在 body（表格）上滚鼠标滚轮，头部锚点的顶边 dy 必须变小——
//     「先滚页面（收头部）再滚表格」生效；
//  2) 三视口不溢出：1280x900(桌面) / 390x844(手机竖屏，走紧凑回退) /
//     844x390(手机横屏，短视口——2026-09-10 表格固定件被压溢出的复现档位)，
//     统一叠 textScale 1.5 放大字号后仍不得抛异常。
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_collapsing_header_scroll_view.dart';

/// 折叠头页面的回归视口档位（名称用于失败信息定位）。
const utenCollapsingViewports = <({String label, Size size})>[
  (label: 'desktop 1280x900', size: Size(1280, 900)),
  (label: 'phone portrait 390x844', size: Size(390, 844)),
  (label: 'phone landscape 844x390', size: Size(844, 390)),
];

/// 设定物理视口（devicePixelRatio=1，逻辑像素=物理像素），测试结束自动还原。
void useUtenViewport(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// MaterialApp.builder：整树套 textScaler（模拟系统字号放大档）。
TransitionBuilder utenTextScaleBuilder(double scale) {
  return (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child ?? const SizedBox.shrink(),
  );
}

/// 上滚滚轮，断言 [headerAnchor]（折叠头里的任意可见控件）随之上移——即
/// 「先滚页面收头部」生效。
///
/// 悬停点按当前布局分支选：
///  - 联动模式（NestedScrollView 在树里）：停在 [bodyAnchor]（明细表）上，验证
///    「滚表格时先收头部」的外内交接；
///  - 整页回退模式（头部太高/视口太小，见组件 §紧凑回退）：body 在定高盒内自滚、
///    不与外层交接，停在滚动视图顶部（折叠头区域）滚页面。
///
/// [delta] 取小值（默认 100）以保证头部锚点滚动后仍在树里可量。
Future<void> expectUtenHeaderCollapses(
  WidgetTester tester, {
  required Finder headerAnchor,
  required Finder bodyAnchor,
  double delta = 100,
}) async {
  expect(headerAnchor, findsOneWidget, reason: '折叠头锚点必须存在才能量位移');
  final coordinated = find.byType(NestedScrollView).evaluate().isNotEmpty;
  if (coordinated) {
    expect(bodyAnchor, findsOneWidget, reason: 'body 锚点（表格）必须存在才能投递滚轮事件');
  }
  final before = tester.getTopLeft(headerAnchor).dy;
  final scrollRect = tester.getRect(
    find.byType(UtenCollapsingHeaderScrollView),
  );
  final point = coordinated
      ? tester.getCenter(bodyAnchor)
      : Offset(scrollRect.center.dx, scrollRect.top + 24);
  final pointer = TestPointer(1, PointerDeviceKind.mouse);
  await tester.sendEventToBinding(pointer.hover(point));
  await tester.sendEventToBinding(pointer.scroll(Offset(0, delta)));
  await tester.pumpAndSettle();
  expect(
    tester.getTopLeft(headerAnchor).dy,
    lessThan(before),
    reason: '上滚时头部应先收起（顶边 dy 变小）；没动说明未接折叠容器或表格漏了 primary:true',
  );
}

/// 用滚轮把页面往上滚 [delta] 像素（分多次投递，模拟真实滚轮）。
///
/// 用滚轮而非 drag：详情页头部常包 SelectionArea，拖拽会被解释成文字框选而不滚动。
/// 悬停点取滚动视图顶部附近（折叠头区域），滚完头部后 NestedScrollView 会自动把
/// 后续滚动交接给 body 内部。
Future<void> utenScrollPage(
  WidgetTester tester, {
  required Finder scrollView,
  double delta = 720,
}) async {
  final rect = tester.getRect(scrollView);
  final pointer = TestPointer(7, PointerDeviceKind.mouse);
  await tester.sendEventToBinding(
    pointer.hover(Offset(rect.center.dx, rect.top + 24)),
  );
  for (var scrolled = 0.0; scrolled < delta; scrolled += 120) {
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 120)));
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

/// 三视口回归的统一口径：构建即不抛异常；把头部滚走后 body 的表格必须可达
/// 且仍不抛异常（短视口下 body 初始位于折线以下，属预期，滚到即可用）。
Future<void> expectUtenBodyReachable(
  WidgetTester tester, {
  required Finder bodyAnchor,
}) async {
  expect(tester.takeException(), isNull, reason: '首帧构建不得溢出/抛异常');
  await utenScrollPage(
    tester,
    scrollView: find.byType(UtenCollapsingHeaderScrollView),
  );
  expect(bodyAnchor, findsOneWidget, reason: '头部滚走后表格必须进入视口');
  expect(tester.takeException(), isNull, reason: '头部收起后表格固定件不得溢出');
}
