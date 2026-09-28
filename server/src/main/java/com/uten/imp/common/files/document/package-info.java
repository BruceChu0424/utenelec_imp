/**
 * 客户文件读取地基(ADR-134, SPEC §4): 只读值、不执行任何内容、所有读取都有上限。任何需要读上传文件的功能都可以用,
 * 不依赖任何业务 feature。
 *
 * <ul>
 *   <li>{@link com.uten.imp.common.files.document.DocumentSniffer}: 按文件头判断真实类型
 *       (XLSX/XLS/CSV/PDF/PNG/JPEG/WEBP), 不信任客户端声明;</li>
 *   <li>{@link com.uten.imp.common.files.document.BoundedBodyReader}: 有硬上限的请求体读取;</li>
 *   <li>{@link com.uten.imp.common.files.document.ZipSafety}: xlsx 压缩包检查(条目数、路径、解压大小与压缩比、
 *       宏/外部链接/ActiveX/OLE/自定义 XML/数据连接一律拒绝; 图片与绘图允许但不读);</li>
 *   <li>{@link com.uten.imp.common.files.document.SpreadsheetGridReader}: xlsx(SAX 流式)/xls(HSSF)/csv 读成
 *       {@link com.uten.imp.common.files.document.DocumentGrid}; 公式只取缓存结果, 隐藏的表/行/列跳过,
 *       合并区域记录下来;</li>
 *   <li>{@link com.uten.imp.common.files.document.PdfTextReader}: PDF 文字层(PDFBox 3), 扫描件判定与渲染成图片;</li>
 *   <li>{@link com.uten.imp.common.files.document.PromptTable}: 把表格片段压成带行号列字母的紧凑文本, 发给大模型;</li>
 *   <li>{@link com.uten.imp.common.files.document.DocumentParseGate}: 全进程同一时间只解析一个文件, 单次墙钟 60 秒。</li>
 * </ul>
 *
 * <p>上限一览: 文件 ≤ 15 MiB; xlsx 条目 ≤ 1024、单个工作表 XML ≤ 8 MiB、非图片部件合计 ≤ 32 MiB、图片合计 ≤ 48 MiB;
 * 最多 8 个可见工作表、每表 5000 行、每格 8192 字; CSV 5000 行; PDF 30 页(缓存 32 MiB 内存 + 256 MiB 临时文件);
 * 图片 ≤ 8 MiB 且尺寸在 {@link com.uten.imp.common.files.ImageDimensionGuard} 允许范围内。
 * 拒绝时抛 {@link com.uten.imp.common.web.ApiException}, 消息是给用户看的中文(下一步该怎么做)。
 */
package com.uten.imp.common.files.document;
