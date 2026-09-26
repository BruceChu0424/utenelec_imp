// 表头右键菜单的列序纯函数（固定/移动/规范化）单元测试。
//
// 这些函数是 MasterDataTableView / UtenEditableGrid 两表共享的「固定块 = 可见前缀」
// 不变量维护者：固定=搬到块末尾、取消=原位留下、移动不越块界、任何外来源的乱序
// 由 normalize 收回。这里锁定每条语义。
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_table_column_kit.dart';

void main() {
  const order = ['a', 'b', 'c', 'd', 'e'];
  const hidden = <String>{};

  group('utenColumnHeaderMenuCapabilities', () {
    test('普通列：可固定、块内不可移到固定语义外、末列不可再右移', () {
      final cap = utenColumnHeaderMenuCapabilities(
        order: order,
        hiddenKeys: hidden,
        pinnedKeys: const {},
        key: 'c',
        canHide: true,
      );
      expect(cap.pinned, isFalse);
      expect(cap.canPin, isTrue);
      expect(cap.canMoveLeft, isTrue);
      expect(cap.canMoveRight, isTrue);
      expect(cap.canMoveToFront, isTrue);
      expect(cap.canMoveToBack, isTrue);
    });

    test('首列不可左移/移到最前；末列不可右移/移到最后', () {
      final first = utenColumnHeaderMenuCapabilities(
        order: order,
        hiddenKeys: hidden,
        pinnedKeys: const {},
        key: 'a',
        canHide: true,
      );
      expect(first.canMoveLeft, isFalse);
      expect(first.canMoveToFront, isFalse);
      final last = utenColumnHeaderMenuCapabilities(
        order: order,
        hiddenKeys: hidden,
        pinnedKeys: const {},
        key: 'e',
        canHide: true,
      );
      expect(last.canMoveRight, isFalse);
      expect(last.canMoveToBack, isFalse);
    });

    test('固定块内的列不与普通列互换位置', () {
      // 固定 a、b 后：b（块末）右侧是普通列 c → 不可右移。
      final capB = utenColumnHeaderMenuCapabilities(
        order: order,
        hiddenKeys: hidden,
        pinnedKeys: const {'a', 'b'},
        key: 'b',
        canHide: true,
      );
      expect(capB.pinned, isTrue);
      expect(capB.canMoveRight, isFalse);
      expect(capB.canMoveToBack, isFalse); // 已在块末
      // c（普通列首位）左侧是固定列 b → 不可左移、已在普通区最前。
      final capC = utenColumnHeaderMenuCapabilities(
        order: order,
        hiddenKeys: hidden,
        pinnedKeys: const {'a', 'b'},
        key: 'c',
        canHide: true,
      );
      expect(capC.canMoveLeft, isFalse);
      expect(capC.canMoveToFront, isFalse);
    });

    test('普通列只剩一个时不可再固定（滚动区至少留一列）', () {
      final cap = utenColumnHeaderMenuCapabilities(
        order: ['a', 'b'],
        hiddenKeys: const {'b'},
        pinnedKeys: const {},
        key: 'a',
        canHide: false,
      );
      expect(cap.canPin, isFalse);
    });

    test('未知 key 全禁', () {
      final cap = utenColumnHeaderMenuCapabilities(
        order: order,
        hiddenKeys: hidden,
        pinnedKeys: const {},
        key: 'x',
        canHide: true,
      );
      expect(cap.canPin, isFalse);
      expect(cap.canMoveLeft, isFalse);
      expect(cap.canMoveToBack, isFalse);
    });
  });

  group('utenToggleColumnPin', () {
    test('固定 = 搬到固定块末尾（既有固定列之后）', () {
      final r1 = utenToggleColumnPin(
        order: order,
        hiddenKeys: hidden,
        pinnedKeys: const {'b'},
        key: 'd',
      );
      expect(r1.order, ['b', 'd', 'a', 'c', 'e']);
      expect(r1.pinned, {'b', 'd'});
    });

    test('取消固定 = 放回固定前下标（用户口径：回到对应的地方）', () {
      // 固定时 c 从下标 2 搬进固定块；取消时 originIndex=2 放回。
      final r = utenToggleColumnPin(
        order: ['c', 'a', 'b', 'd', 'e'], // c 已被固定到块首
        hiddenKeys: hidden,
        pinnedKeys: const {'c'},
        key: 'c',
        originIndex: 2,
      );
      expect(r.order, ['a', 'b', 'c', 'd', 'e']);
      expect(r.pinned, isEmpty);
    });

    test('取消固定无记录 = 按默认列序相对位次插回（跨会话回退）', () {
      // 默认序 a,b,c,d,e；当前 c 固定在块首，其余 a,b,d,e——取消后 c 应回到
      // 默认序中排在它之后的第一个现存列（d）之前。
      final r = utenToggleColumnPin(
        order: ['c', 'a', 'b', 'd', 'e'],
        hiddenKeys: hidden,
        pinnedKeys: const {'c'},
        key: 'c',
        defaultOrder: order,
      );
      expect(r.order, ['a', 'b', 'c', 'd', 'e']);
      expect(r.pinned, isEmpty);
    });

    test('取消固定的落点撞进固定块 = normalize 收回到块边界之后', () {
      // a、b 固定（a 在块首）；取消 b（origin=1）时落点在固定块内，
      // 规范化把 b 推到固定块（a）之后。
      final r = utenToggleColumnPin(
        order: ['a', 'b', 'c', 'd', 'e'],
        hiddenKeys: hidden,
        pinnedKeys: const {'a', 'b'},
        key: 'b',
        originIndex: 1,
      );
      expect(r.pinned, {'a'});
      expect(r.order.first, 'a');
      expect(r.order.indexOf('b'), 1); // 紧跟固定块之后
    });
  });

  group('utenMoveVisibleColumn', () {
    test('左右一格在同区内交换；隐藏列锚位不动', () {
      expect(
        utenMoveVisibleColumn(
          order: order,
          hiddenKeys: const {'b'},
          pinnedKeys: const {},
          key: 'c',
          move: UtenColumnHeaderMove.left,
        ),
        ['c', 'b', 'a', 'd', 'e'], // b 的锚位保留
      );
    });

    test('普通列 front = 固定块之后；back = 全局末位', () {
      expect(
        utenMoveVisibleColumn(
          order: order,
          hiddenKeys: hidden,
          pinnedKeys: const {'a'},
          key: 'd',
          move: UtenColumnHeaderMove.front,
        ),
        ['a', 'd', 'b', 'c', 'e'],
      );
      expect(
        utenMoveVisibleColumn(
          order: order,
          hiddenKeys: hidden,
          pinnedKeys: const {'a'},
          key: 'b',
          move: UtenColumnHeaderMove.back,
        ),
        ['a', 'c', 'd', 'e', 'b'],
      );
    });

    test('固定列 front = 全局首位；back = 固定块末位', () {
      // 输入须满足「固定块 = 可见前缀」不变量（a、b 已固定在最前）。
      expect(
        utenMoveVisibleColumn(
          order: order,
          hiddenKeys: hidden,
          pinnedKeys: const {'a', 'b'},
          key: 'b',
          move: UtenColumnHeaderMove.front,
        ),
        ['b', 'a', 'c', 'd', 'e'],
      );
      expect(
        utenMoveVisibleColumn(
          order: order,
          hiddenKeys: hidden,
          pinnedKeys: const {'a', 'b'},
          key: 'a',
          move: UtenColumnHeaderMove.back,
        ),
        ['b', 'a', 'c', 'd', 'e'],
      );
    });
  });

  group('utenNormalizePinnedPrefix', () {
    test('乱序输入：固定列稳定搬到可见前缀，隐藏列锚位不动', () {
      expect(
        utenNormalizePinnedPrefix(
          order: ['a', 'b', 'c', 'd'],
          hiddenKeys: const {'a'},
          pinnedKeys: const {'c', 'd'},
        ),
        // 可见序 b,c,d → c,d,b（固定前缀化）；隐藏列 a 的锚位（首位）保留。
        ['a', 'c', 'd', 'b'],
      );
    });

    test('已是前缀 = 原样返回', () {
      expect(
        utenNormalizePinnedPrefix(
          order: order,
          hiddenKeys: hidden,
          pinnedKeys: const {'a'},
        ),
        order,
      );
    });

    test('无固定列 = 原样返回', () {
      expect(
        utenNormalizePinnedPrefix(
          order: order,
          hiddenKeys: hidden,
          pinnedKeys: const {},
        ),
        order,
      );
    });
  });
}
