// Web 实现：Blob + 隐藏 anchor 触发浏览器下载（无第三方依赖）。
import 'dart:html' as html;
import 'dart:typed_data';

Future<String> saveBytes(Uint8List bytes, String filename) async {
  final blob = html.Blob([bytes]);
  final url = html.Url.createObjectUrl(blob);
  final anchor = html.AnchorElement(href: url)
    ..download = filename
    ..style.display = 'none';
  html.document.body?.append(anchor);
  anchor.click();
  anchor.remove();
  html.Url.revokeObjectUrl(url);
  return filename;
}
