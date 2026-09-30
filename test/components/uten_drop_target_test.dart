// UtenDropTarget：拖放上传公共组件。
// 平台判定（web/桌面开、移动端直通）依赖编译目标，单测只锁转换管道：
// DropItem → PlatformFile 的字节/名称/大小搬运 + 目录剔除 + 空名兜底。
import 'dart:convert';
import 'dart:typed_data';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:uten_imp/components/inputs/uten_drop_target.dart';

void main() {
  group('droppedItemsToPlatformFiles', () {
    test('普通文件转成与 FilePicker 同构的 PlatformFile', () async {
      final bytes = Uint8List.fromList(utf8.encode('hello'));
      final (files, skipped) = await droppedItemsToPlatformFiles([
        // 桌面端形态：cross_file 的 io 实现忽略 name 参数、从 path 取 basename。
        DropItemFile.fromData(
          bytes,
          name: '报价单.xlsx',
          path: r'C:\Users\sales\Downloads\报价单.xlsx',
          length: bytes.length,
        ),
      ]);

      expect(files, hasLength(1));
      expect(files.single.name, '报价单.xlsx');
      expect(files.single.size, bytes.length);
      expect(files.single.bytes, bytes);
      expect(skipped, 0);
    });

    test('拖入的文件夹剔除并计入 skipped', () async {
      final bytes = Uint8List.fromList(utf8.encode('x'));
      final (files, skipped) = await droppedItemsToPlatformFiles([
        DropItemDirectory('C:/somewhere', const []),
        DropItemFile.fromData(
          bytes,
          path: '/tmp/dir/a.txt',
          length: bytes.length,
        ),
      ]);

      expect(files, hasLength(1));
      expect(files.single.name, 'a.txt');
      expect(skipped, 1);
    });

    test('名字与路径都取不到时退回中性名', () async {
      final bytes = Uint8List.fromList(const [1, 2, 3]);
      final (files, _) = await droppedItemsToPlatformFiles([
        DropItemFile.fromData(bytes, length: bytes.length),
      ]);

      expect(files.single.name, 'file');
    });

    test('blob URL 不拿来当文件名', () async {
      final bytes = Uint8List.fromList(const [1]);
      final (files, _) = await droppedItemsToPlatformFiles([
        DropItemFile.fromData(
          bytes,
          path: 'blob:http://localhost:53764/8e2f-uuid',
          length: bytes.length,
        ),
      ]);

      expect(files.single.name, 'file');
    });
  });

  group('UtenDropTarget widget', () {
    testWidgets('正常渲染 child（不破坏宿主布局）', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: UtenDropTarget(onFiles: (_) {}, child: const Text('接收区')),
          ),
        ),
      );

      expect(find.text('接收区'), findsOneWidget);
    });
  });
}
