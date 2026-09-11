# AttachmentPreviewDialog（附件内嵌预览）

> 状态：已实现 · 组件：`lib/shared/attachments/attachment_preview_dialog.dart` · 能力矩阵：`lib/shared/attachments/attachment_file_rules.dart` · 服务端转换：`server/src/main/java/com/uten/imp/features/attachment/AttachmentPreviewService.java` · 最近更新：2026-09-11（从 6 种扩到办公常见类型）

单据附件、员工档案、报销发票点开就能看，不必先下载到本机再找应用打开。一个弹窗，六条渲染通道，通道由同一张能力表决定。

## 一、能力矩阵（唯一真源）

能力表写在 `attachment_file_rules.dart` 的 `_rules` 里，`guessAttachmentContentType()`（能不能传）、`attachmentPreviewKind()`（怎么看）、`AttachmentFileKind.of()`（行内图标）、`attachmentTypeLabel()`（类型角标）全部读它，**不再各处各写一套判断**，所以列表行的图标不会承诺一个会失败的预览。

三张表是包含关系：**服务端转换 ⊂ 可预览 ⊂ 可上传**。

| 扩展名 | 上传 Content-Type | 预览方式 | 依赖 |
|---|---|---|---|
| jpg / jpeg / png / webp / gif / bmp | `image/*` | 内嵌图片，可缩放拖动 | Flutter `dart:ui` 内置解码器 |
| tif / tiff | `image/tiff` | **不预览**，只下载 | — （Flutter 解码不了，LibreOffice 还原不稳，不做假预览） |
| heic / heif | `image/heic`、`image/heif` | **不预览**，只下载 | — （同上；手机照片先转 jpg 再传即可预览） |
| pdf | `application/pdf` | PDFium 连续页 + 上下页 | `pdfrx` |
| doc / docx | `application/msword`、`…wordprocessingml.document` | 服务端转 PDF 后内嵌 | LibreOffice Writer |
| rtf | `application/rtf` | 服务端转 PDF 后内嵌 | LibreOffice Writer |
| odt | `…opendocument.text` | 服务端转 PDF 后内嵌 | LibreOffice Writer |
| xls / xlsx | `application/vnd.ms-excel`、`…spreadsheetml.sheet` | 服务端转 PDF 后内嵌 | LibreOffice Calc |
| ods | `…opendocument.spreadsheet` | 服务端转 PDF 后内嵌 | LibreOffice Calc |
| ppt / pptx | `application/vnd.ms-powerpoint`、`…presentationml.presentation` | 服务端转 PDF 后内嵌 | LibreOffice Impress |
| odp | `…opendocument.presentation` | 服务端转 PDF 后内嵌 | LibreOffice Impress |
| svg | `image/svg+xml` | 服务端转 PDF 后内嵌 | LibreOffice Draw |
| csv | `text/csv` | 对齐表格（表头固定、横向滚动） | 客户端解析，不占服务端转换槽位 |
| txt / log | `text/plain` | 纯文本只读 | 编码自动识别 |
| md | `text/markdown` | 纯文本原样显示（不渲染 Markdown，不引依赖） | 编码自动识别 |
| json / xml | `application/json`、`text/xml` | 纯文本只读 | 编码自动识别 |
| zip | `application/zip` | 条目清单（名称/大小/层级），**不解压** | 纯 Dart 读中央目录 |
| 7z / rar | `application/x-7z-compressed`、`application/vnd.rar` | **不预览**，只下载 | — （目录区本身是压缩的，读不了） |

不在表里的扩展名一律拒绝上传（`guessAttachmentContentType` 返回 null），拒绝文案统一用 `kAttachmentUploadTypesHint`。

改这张表必须同步改服务端三处，否则上传会被拦或预览对不上：
`StorageProperties.allowedContentTypes`（白名单）、`AttachmentContentInspector.EXTENSIONS` + 魔数分支（扩展名与真实内容必须对上）、`AttachmentPreviewService.CONVERTIBLE_*`（转换集合）。

## 二、交互与状态

- **顶栏**：类型图标 + 文件名 + 副标题（如实交代看到的是什么：文本编码 / CSV 行列数 / 包内条目数 / PDF 页码 / 文件大小）+ 类型角标 + 「下载原件」+「关闭」。
- **加载**：解码与解析放在下一个微任务，首帧先出「正在解析…」，大文件不卡住弹窗打开动画。
- **失败**：一个图标 + 一句结论 + 一句下一步（如「ZIP 索引读取失败，文件可能已损坏 / 可用「下载」保存原件后用本机应用打开」）。绝不静默留白，也绝不假装看得了。
- **键盘**：`Esc` 关闭；PDF 下 `←/↑` 上一页、`→/↓` 下一页；底部页码条同样可点。
- **无障碍**：弹窗整体 `Semantics(label: '附件预览 <文件名>')`；按钮均带 tooltip；压缩包每条目播报「目录/文件 + 名称 + 大小」。
- **响应式**：375 宽 + 1.5 倍字号下文件名省略、CSV 横向滚动，不溢出（有用例守着）。

## 三、文本编码识别

中文市场的 ERP，老系统与 Excel 导出的 txt/csv 大量是 GBK。`decodeAttachmentText()` 按「先确定性、后启发式」判定：

1. BOM：UTF-8 / UTF-16LE / UTF-16BE 直接认定；
2. 严格 UTF-8 解码成功 → UTF-8（纯 ASCII 走这条）；
3. 字节结构完全符合 GB18030 且确实出现多字节序列 → GB18030；
4. 都不符合 → UTF-8 容错解码，副标题如实标「编码未知（可能有乱码，建议下载原件核对）」。

zip 条目名同样走这套（中央目录标志位 11 = UTF-8，否则多半是 GBK）。

### GB18030 解码表

`lib/shared/attachments/gb18030_table.dart` 是**机器生成的数据文件，请勿手工编辑**：双字节区 126×190 个槽位按 UTF-16 大端存放后 Base64 编码（首次解码才展开），四字节 BMP 区存成连续段三元组，增补平面用线性公式。生成源是 JDK 21 的 `GB18030`/`GBK` 字符集（不一致时以 JDK 为准），校验向量见 `test/attachments/attachment_text_decoder_test.dart`。

## 四、调用方

```dart
// 已保存单据：AttachmentSection._view 先判是否需要服务端转换
if (AttachmentPreviewDialog.isOffice(a.originalName, a.contentType)) {
  pdf = await service.previewBytes(a);      // GET /attachments/{id}/preview
  if (pdf != null) return _showPreview(pdf, a.originalName, 'application/pdf');
  context.appWarning('该文件暂不支持在线预览，已改为下载原件');
}
final bytes = await service.downloadBytes(a);
if (AttachmentPreviewDialog.canPreview(a.originalName, a.contentType)) {
  showDialog(builder: (_) => AttachmentPreviewDialog(
    bytes: bytes, name: a.originalName, contentType: a.contentType));
} else {
  await saveBytes(bytes, a.originalName);   // 只下载
}
```

服务端转换的字节带着**原名**（如 `报价.docx`）和 `application/pdf` 传进来；弹窗按扩展名判出 `serverPdf` 后统一走 PDF 通道，因此显示的仍是原文件名。

`onDownload` 可选；不传时弹窗直接把手上的字节 `saveBytes` 存盘并在顶栏下方显示保存路径。

## 五、边界

- 预览是派生视图，不是业务附件：服务端转换结果缓存在 `preview/<附件id>-<原件sha256>.pdf`，可随时整目录删除重建，不参与备份与对账（ADR-074）。
- 服务器没装 LibreOffice（或缺对应组件）时后端返回业务错误，客户端提示并回落为下载原件——不会白屏，也不会静默失败。
- 压缩包只列条目，不提供解压：避免解压炸弹，也避免把「预览」做成半个文件管理器。
- tiff/heic/7z/rar 明确写成「不预览」而不是「先试试」：宁可行内图标就显示下载，也不让用户点开一个必然失败的预览。

## 六、测试

| 用例 | 位置 |
|---|---|
| 能力矩阵、三表包含关系、各分支渲染、Esc、375+1.5x | `test/attachments/attachment_preview_dialog_test.dart` |
| 编码识别与 GB18030 解码（含四字节区） | `test/attachments/attachment_text_decoder_test.dart` |
| CSV 引号/换行/分隔符嗅探/截断 | `test/attachments/attachment_delimited_text_test.dart` |
| ZIP 中央目录、GBK 条目名、ZIP 注释、损坏包 | `test/attachments/attachment_archive_listing_test.dart` |
| 转换集合与魔数把关 | `server/src/test/java/com/uten/imp/features/attachment/AttachmentPreviewServiceTest.java`、`AttachmentContentInspectorTest.java` |
