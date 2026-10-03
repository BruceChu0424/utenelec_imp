package com.uten.imp.common.files.document;

import com.uten.imp.common.web.ApiException;
import javax.xml.stream.XMLInputFactory;
import javax.xml.stream.XMLStreamConstants;
import javax.xml.stream.XMLStreamException;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.zip.ZipInputStream;

/** Reads only Word body text. Never resolves relationships, opens embedded files or evaluates fields. */
public final class DocxTextReader {
    private static final String WORD = "http://schemas.openxmlformats.org/wordprocessingml/2006/main";
    private static final long MAX_EXPANDED = 32L * 1024 * 1024;
    private DocxTextReader() {}
    public static List<String> read(byte[] bytes) {
        if (bytes.length > ZipSafety.MAX_COMPRESSED_BYTES) throw BoundedBodyReader.tooLarge(ZipSafety.MAX_COMPRESSED_BYTES);
        return DocumentParseGate.run(deadline -> {
            byte[] document = null;
            long total = 0;
            var names = new HashSet<String>();
            try (var zip = new ZipInputStream(new ByteArrayInputStream(bytes))) {
                java.util.zip.ZipEntry entry;
                byte[] buffer = new byte[8192];
                while ((entry = zip.getNextEntry()) != null) {
                    deadline.check();
                    String name = entry.getName();
                    String lower = name.toLowerCase(Locale.ROOT);
                    if (name.length() > 255 || name.startsWith("/") || name.contains("\\") || name.contains("..")
                            || !names.add(name) || names.size() > ZipSafety.MAX_ENTRIES
                            || lower.contains("vbaproject") || lower.contains("activex") || lower.contains("embeddings/")
                            || lower.startsWith("customxml/")) throw ZipSafety.rejected("这个 Word 文件包含不支持的结构或主动内容，请导出为 PDF 后再试");
                    boolean body = name.equals("word/document.xml");
                    ByteArrayOutputStream out = body ? new ByteArrayOutputStream() : null;
                    int read;
                    long bodyBytes = 0;
                    while ((read = zip.read(buffer)) != -1) {
                        deadline.check(); total += read; bodyBytes += read;
                        if (total > MAX_EXPANDED || total > (long) bytes.length * 200 + 1024 * 1024
                                || (body && bodyBytes > 8L * 1024 * 1024))
                            throw ZipSafety.rejected("这个 Word 文件解压后过大，请拆分后再试");
                        if (out != null) out.write(buffer, 0, read);
                    }
                    if (out != null) document = out.toByteArray();
                }
            } catch (ApiException e) { throw e; }
            catch (IOException e) { throw ZipSafety.rejected("这个 Word 文件已损坏或加密，请导出为 PDF 后再试"); }
            if (document == null || !names.contains("[Content_Types].xml")) throw ZipSafety.rejected("这个文件不是完整的 Word 文档");
            var factory = XMLInputFactory.newFactory();
            factory.setProperty(XMLInputFactory.SUPPORT_DTD, false);
            factory.setProperty("javax.xml.stream.isSupportingExternalEntities", false);
            factory.setXMLResolver((publicId, systemId, base, namespace) -> { throw new XMLStreamException("External entities are disabled"); });
            try {
                var xml = factory.createXMLStreamReader(new ByteArrayInputStream(document));
                var lines = new ArrayList<String>();
                var line = new StringBuilder();
                boolean text = false;
                int characters = 0;
                while (xml.hasNext()) {
                    deadline.check();
                    int event = xml.next();
                    if (event == XMLStreamConstants.DTD || event == XMLStreamConstants.ENTITY_REFERENCE)
                        throw ZipSafety.rejected("这个 Word 文件包含不支持的 XML 实体");
                    if (event == XMLStreamConstants.START_ELEMENT && WORD.equals(xml.getNamespaceURI())) {
                        text = "t".equals(xml.getLocalName());
                        if ("tab".equals(xml.getLocalName()) || "br".equals(xml.getLocalName())) line.append(' ');
                    } else if (event == XMLStreamConstants.CHARACTERS && text) {
                        characters += xml.getTextLength();
                        if (characters > 128_000) throw ZipSafety.rejected("这个 Word 文本过长，请拆分后再识别");
                        line.append(xml.getText());
                    } else if (event == XMLStreamConstants.END_ELEMENT && WORD.equals(xml.getNamespaceURI())) {
                        text = false;
                        if ("p".equals(xml.getLocalName()) && !line.isEmpty()) {
                            lines.add(line.toString()); line.setLength(0);
                        }
                    }
                }
                xml.close();
                if (!line.isEmpty()) lines.add(line.toString());
                return List.copyOf(lines);
            } catch (XMLStreamException e) { throw ZipSafety.rejected("这个 Word 文件文字结构损坏，请导出为 PDF 后再试"); }
        });
    }
}
