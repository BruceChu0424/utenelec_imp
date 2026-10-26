package com.uten.imp.common.files.document;

import javax.xml.stream.XMLInputFactory;
import javax.xml.stream.XMLStreamConstants;
import javax.xml.stream.XMLStreamException;
import java.io.InputStream;
import java.util.Locale;
import java.util.regex.Pattern;

/** Checks automatically loaded resources; ordinary Office document hyperlinks remain usable. */
public final class OfficePreviewXmlSafety {
    public enum Kind { SVG, RELATIONSHIPS, OPEN_DOCUMENT }
    private static final Pattern CSS_URL = Pattern.compile("(?is)url\\s*\\(\\s*(['\"]?)(.*?)\\1\\s*\\)");
    private static final Pattern CSS_URL_START = Pattern.compile("(?is)url\\s*\\(");
    private OfficePreviewXmlSafety() { }

    public static void inspect(InputStream input, Kind kind) {
        var factory = XMLInputFactory.newFactory();
        factory.setProperty(XMLInputFactory.SUPPORT_DTD, false);
        factory.setProperty(XMLInputFactory.IS_SUPPORTING_EXTERNAL_ENTITIES, false);
        factory.setXMLResolver((publicId, systemId, base, namespace) -> {
            throw new XMLStreamException("External XML resources are forbidden");
        });
        try {
            var xml = factory.createXMLStreamReader(input);
            StringBuilder css = null;
            int depth = 0;
            boolean root = true;
            try {
                while (xml.hasNext()) {
                    int event = xml.next();
                    if (event == XMLStreamConstants.DTD || event == XMLStreamConstants.ENTITY_REFERENCE) reject();
                    if (event == XMLStreamConstants.PROCESSING_INSTRUCTION) reject();
                    if (event == XMLStreamConstants.START_ELEMENT) {
                        String element = xml.getLocalName().toLowerCase(Locale.ROOT);
                        if (++depth > 128) reject();
                        if (root && kind == Kind.SVG && !"svg".equals(element)) reject();
                        root = false;
                        if (kind == Kind.SVG && ("script".equals(element) || "foreignobject".equals(element)
                                || element.startsWith("animate") || "set".equals(element))) reject();
                        if (kind == Kind.SVG && "style".equals(element)) css = new StringBuilder();
                        if (kind == Kind.RELATIONSHIPS && "relationship".equals(element)) {
                            String target = xml.getAttributeValue(null, "Target");
                            String type = xml.getAttributeValue(null, "Type");
                            boolean hyperlink = type != null && type.endsWith("/hyperlink");
                            if (!hyperlink && ("External".equalsIgnoreCase(xml.getAttributeValue(null, "TargetMode"))
                                    || absoluteReference(target))) reject();
                        }
                        if (kind != Kind.RELATIONSHIPS) for (int index = 0; index < xml.getAttributeCount(); index++) {
                            String name = xml.getAttributeLocalName(index).toLowerCase(Locale.ROOT);
                            String value = xml.getAttributeValue(index);
                            if ("base".equals(name) && value != null && !value.isBlank()) reject();
                            if (kind == Kind.SVG && name.startsWith("on")) reject();
                            if ("href".equals(name) || "src".equals(name)) {
                                boolean hyperlink = kind == Kind.OPEN_DOCUMENT && "a".equals(element);
                                if (!hyperlink && (kind == Kind.SVG ? !selfContainedSvgReference(value) : externalReference(value))) reject();
                            }
                            if (kind == Kind.SVG) inspectCss(value);
                        }
                    } else if (event == XMLStreamConstants.END_ELEMENT) {
                        if (css != null && "style".equalsIgnoreCase(xml.getLocalName())) {
                            inspectCss(css.toString()); css = null;
                        }
                        depth--;
                    } else if (css != null && (event == XMLStreamConstants.CHARACTERS || event == XMLStreamConstants.CDATA)) {
                        if (css.length() + xml.getTextLength() > 262144) reject();
                        css.append(xml.getText());
                    }
                }
                if (root) reject();
            } finally { xml.close(); }
        } catch (XMLStreamException invalid) { reject(); }
    }

    private static boolean externalReference(String value) {
        if (value == null || value.isBlank()) return false;
        String normalized = value.trim().replace('\\', '/');
        return absoluteReference(normalized)
                || java.util.Arrays.asList(normalized.split("/", -1)).contains("..");
    }

    private static boolean absoluteReference(String value) {
        if (value == null) return false;
        String normalized = value.trim().replace('\\', '/');
        return normalized.startsWith("/") || normalized.contains(":");
    }

    private static boolean selfContainedSvgReference(String value) {
        if (value == null || value.isBlank()) return true;
        String target = value.trim().toLowerCase(Locale.ROOT);
        return target.startsWith("#") || target.startsWith("data:image/png;base64,")
                || target.startsWith("data:image/jpeg;base64,") || target.startsWith("data:image/gif;base64,")
                || target.startsWith("data:image/webp;base64,");
    }

    private static void inspectCss(String css) {
        if (css == null) return;
        // Escapes can disguise url/@import tokens; do not pass them to another parser.
        css = css.replaceAll("(?s)/\\*.*?\\*/", "");
        String lower = css.toLowerCase(Locale.ROOT);
        if (css.indexOf('\\') >= 0 || lower.contains("@import")) reject();
        var urls = CSS_URL.matcher(css);
        while (urls.find()) if (!selfContainedSvgReference(urls.group(2))) reject();
        if (CSS_URL_START.matcher(CSS_URL.matcher(css).replaceAll("")).find()) reject();
    }

    private static void reject() {
        throw ZipSafety.rejected("文档包含外部资源、主动内容或不安全 XML，请导出为 PDF 后预览");
    }
}
