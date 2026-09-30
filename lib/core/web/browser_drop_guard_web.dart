// Web 实现：document 级 dragover/drop preventDefault。
// dragover 不 preventDefault 的话浏览器根本不会派发 drop；
// drop preventDefault 掉「在新标签打开拖入的文件」的默认导航。
import 'dart:js_interop';

import 'package:web/web.dart' as web;

void install() {
  final swallow = ((web.Event e) => e.preventDefault()).toJS;
  web.document.addEventListener('dragover', swallow);
  web.document.addEventListener('drop', swallow);
}
