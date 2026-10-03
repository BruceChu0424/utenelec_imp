package com.uten.imp.common.files.document;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;

import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.zip.ZipEntry;
import java.util.zip.ZipInputStream;

/**
 * xlsx(OOXML 压缩包)在交给 POI 之前的安全检查: 条目数、路径、压缩方式、解压后大小与压缩比、主动内容。
 *
 * <p>与货品导入的检查同思路但单独实现(common 不引用 features), 口径按客户文件调整:
 * 允许图片与绘图(客户报价单常带产品图, 读取时忽略), 允许打印设置等非宏的 .bin;
 * 拒绝宏(vbaProject.bin)、外部链接、ActiveX、OLE 嵌入对象、自定义 XML 与数据连接。
 */
public final class ZipSafety {

    /** 压缩包本身上限。 */
    public static final long MAX_COMPRESSED_BYTES = 15L * 1024 * 1024;
    /** 条目数上限。 */
    public static final int MAX_ENTRIES = 1024;
    /** 单个工作表 XML 解压后上限。 */
    public static final long MAX_SHEET_XML_BYTES = 8L * 1024 * 1024;
    /** 非图片部件解压后合计上限。 */
    public static final long MAX_NON_MEDIA_BYTES = 32L * 1024 * 1024;
    /** 图片/绘图部件解压后合计上限(只为防压缩炸弹, 读取时不解析图片)。 */
    public static final long MAX_MEDIA_BYTES = 48L * 1024 * 1024;
    /** 解压后总量相对压缩包大小的最大倍数(另加 1 MiB 余量, 小文件不误判)。 */
    public static final long MAX_EXPANSION_RATIO = 200;

    private static final Set<String> REQUIRED_ENTRIES = Set.of("[Content_Types].xml", "xl/workbook.xml");

    private ZipSafety() {
    }

    /** 检查通过返回全部条目名; 不通过抛 422(用户能看懂的中文)。 */
    public static List<String> inspectSpreadsheet(byte[] zip) {
        return inspectSpreadsheet(zip, false);
    }

    /** Only evidence readers may retain external-link metadata; they must never evaluate formulas or open links. */
    public static List<String> inspectSpreadsheetEvidence(byte[] zip) {
        return inspectSpreadsheet(zip, true);
    }

    private static List<String> inspectSpreadsheet(byte[] zip, boolean evidenceOnly) {
        if (zip.length > MAX_COMPRESSED_BYTES) {
            throw BoundedBodyReader.tooLarge(MAX_COMPRESSED_BYTES);
        }
        Set<String> names = new HashSet<>();
        List<String> ordered = new ArrayList<>();
        long nonMedia = 0;
        long media = 0;
        long totalLimit = (long) zip.length * MAX_EXPANSION_RATIO + 1024L * 1024;
        byte[] buffer = new byte[16 * 1024];
        try (ZipInputStream archive = new ZipInputStream(new ByteArrayInputStream(zip))) {
            ZipEntry entry;
            while ((entry = archive.getNextEntry()) != null) {
                if (ordered.size() >= MAX_ENTRIES) {
                    throw rejected("这个 Excel 文件内部结构太复杂, 请另存为普通的 .xlsx 后再试");
                }
                String name = entry.getName();
                validateName(name, names);
                ordered.add(name);
                if (entry.getMethod() != ZipEntry.STORED && entry.getMethod() != ZipEntry.DEFLATED) {
                    throw rejected("这个 Excel 文件的压缩方式不支持, 请另存为普通的 .xlsx 后再试");
                }
                rejectActiveContent(name, evidenceOnly);
                boolean isMedia = isMedia(name);
                boolean isSheet = isSheetXml(name);
                long entryBytes = 0;
                int read;
                while ((read = archive.read(buffer)) != -1) {
                    entryBytes += read;
                    if (isMedia) {
                        media += read;
                        if (media > MAX_MEDIA_BYTES) {
                            throw rejected("这个 Excel 里的图片太多太大, 请删掉图片或拆分后再试");
                        }
                    } else {
                        nonMedia += read;
                        if (nonMedia > MAX_NON_MEDIA_BYTES) {
                            throw rejected("这个 Excel 解压后内容太多, 请只保留需要识别的工作表后再试");
                        }
                    }
                    if (isSheet && entryBytes > MAX_SHEET_XML_BYTES) {
                        throw rejected("这个 Excel 的某个工作表太大, 请只保留需要识别的部分后再试");
                    }
                    if (media + nonMedia > totalLimit) {
                        throw rejected("这个 Excel 文件的压缩比例异常, 已拒绝读取");
                    }
                }
                archive.closeEntry();
            }
        } catch (ApiException e) {
            throw e;
        } catch (IOException | RuntimeException e) {
            throw rejected("这个 Excel 文件已损坏或不是标准格式, 请另存为普通的 .xlsx 后再试");
        }
        if (!names.containsAll(REQUIRED_ENTRIES)) {
            throw rejected("这个 Excel 文件缺少必要内容(可能加了密码), 请另存为不加密的 .xlsx 后再试");
        }
        return List.copyOf(ordered);
    }

    static boolean isMedia(String name) {
        String lower = name.toLowerCase(Locale.ROOT);
        return lower.startsWith("xl/media/") || lower.startsWith("xl/drawings/") || lower.startsWith("xl/charts/")
                || lower.startsWith("docprops/thumbnail");
    }

    static boolean isSheetXml(String name) {
        String lower = name.toLowerCase(Locale.ROOT);
        return lower.startsWith("xl/worksheets/") && lower.endsWith(".xml") && !lower.contains("/_rels/");
    }

    private static void rejectActiveContent(String name, boolean evidenceOnly) {
        String lower = name.toLowerCase(Locale.ROOT);
        String file = lower.substring(lower.lastIndexOf('/') + 1);
        if (file.startsWith("vbaproject") || file.startsWith("vbadata")
                || lower.startsWith("xl/macrosheets/") || lower.startsWith("xl/dialogsheets/")
                || (!evidenceOnly && lower.startsWith("xl/externallinks/"))
                || lower.startsWith("xl/activex/")
                || lower.startsWith("xl/embeddings/")
                || lower.contains("oleobject")
                || lower.startsWith("customxml/")
                || lower.startsWith("xl/querytables/")
                || lower.equals("xl/connections.xml")) {
            throw rejected("这个 Excel 带有宏、外部链接或嵌入对象, 为了安全不能识别, 请另存为普通的 .xlsx 后再试");
        }
    }

    private static void validateName(String name, Set<String> names) {
        if (name == null || name.isEmpty() || name.length() > 255 || name.startsWith("/") || name.contains("\\")
                || name.contains(":") || name.indexOf('\0') >= 0) {
            throw rejected("这个 Excel 文件内部路径不正常, 已拒绝读取");
        }
        String[] segments = name.split("/", -1);
        for (int i = 0; i < segments.length; i++) {
            String segment = segments[i];
            boolean trailingDirectory = i == segments.length - 1 && segment.isEmpty();
            if (!trailingDirectory && (segment.isEmpty() || ".".equals(segment) || "..".equals(segment))) {
                throw rejected("这个 Excel 文件内部路径不正常, 已拒绝读取");
            }
        }
        if (!names.add(name)) {
            throw rejected("这个 Excel 文件内部有重复内容, 已拒绝读取");
        }
    }

    static ApiException rejected(String message) {
        return new ApiException(ErrorCode.VALIDATION_FAILED, message);
    }
}
