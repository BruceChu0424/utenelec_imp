package com.uten.imp.features.clientupdates;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.net.InetAddress;
import java.net.URI;
import java.util.HashSet;
import java.util.Map;
import java.util.Set;
import javax.xml.XMLConstants;
import javax.xml.parsers.DocumentBuilderFactory;
import org.apache.commons.compress.archivers.zip.ZipArchiveEntry;
import org.apache.commons.compress.archivers.zip.ZipFile;

/** Candidate package contract only; no claim of Win7 UAT, complete ERP migration or code signing. */
final class WindowsWpfPackageInspector {
    static final String EXECUTABLE = "Uten.Legacy.Desktop.exe";
    static final Set<String> REQUIRED = Set.of(EXECUTABLE, "Uten.Legacy.Core.dll", "BouncyCastle.Cryptography.dll",
            "Uten.Legacy.Desktop.exe.config", "BouncyCastle-LICENSE.md", "uten.client.json");
    private WindowsWpfPackageInspector() { }
    static boolean allowedFile(String name) { return REQUIRED.contains(name) || "uten-wpf.ico".equals(name); }
    static void inspect(ZipFile zip, Map<String, ZipArchiveEntry> files, ClientReleaseDto.Release release, ObjectMapper mapper)
            throws IOException {
        for (String name : Set.of(EXECUTABLE, "Uten.Legacy.Core.dll", "BouncyCastle.Cryptography.dll"))
            WindowsManagedImageInspector.inspect(read(zip, files.get(name), 32 * 1024 * 1024), release,
                    !EXECUTABLE.equals(name), !"BouncyCastle.Cryptography.dll".equals(name));
        if (read(zip, files.get("BouncyCastle-LICENSE.md"), 65536).length == 0) throw invalid("WPF 客户端必须携带安全通信库许可");
        inspectConfiguration(read(zip, files.get("uten.client.json"), 65536), mapper);
        inspectRuntime(read(zip, files.get("Uten.Legacy.Desktop.exe.config"), 65536));
    }
    private static byte[] read(ZipFile zip, ZipArchiveEntry entry, int maximum) throws IOException {
        if (entry == null || entry.getSize() < 1 || entry.getSize() > maximum) throw invalid("WPF 客户端文件缺失或超出大小限制");
        try (var input = zip.getInputStream(entry)) {
            byte[] bytes = input.readNBytes(maximum + 1);
            if (bytes.length != entry.getSize() || bytes.length > maximum) throw invalid("WPF 客户端文件读取不完整");
            return bytes;
        }
    }
    private static void inspectConfiguration(byte[] bytes, ObjectMapper mapper) throws IOException {
        JsonNode root;
        try { root = mapper.readTree(bytes); }
        catch (com.fasterxml.jackson.core.JsonProcessingException malformed) { throw invalid("WPF 公司连接配置不是有效 JSON"); }
        if (root == null || !root.isObject() || !root.path("endpoints").isArray()
                || root.path("endpoints").isEmpty() || root.path("endpoints").size() > 8) throw invalid("WPF 包必须携带已审核的正式公司连接配置");
        var known = Set.of("endpoints", "selectedEndpointId", "requestTimeoutSeconds", "maxResponseBytes");
        root.fieldNames().forEachRemaining(key -> { if (!known.contains(key)) throw invalid("WPF 连接配置包含未审核字段"); });
        if (root.has("requestTimeoutSeconds") && (!root.path("requestTimeoutSeconds").isIntegralNumber()
                || !root.path("requestTimeoutSeconds").canConvertToInt() || root.path("requestTimeoutSeconds").asInt() < 1
                || root.path("requestTimeoutSeconds").asInt() > 120)) throw invalid("WPF 请求超时配置无效");
        if (root.has("maxResponseBytes") && (!root.path("maxResponseBytes").isIntegralNumber()
                || !root.path("maxResponseBytes").canConvertToInt() || root.path("maxResponseBytes").asInt() < 1024
                || root.path("maxResponseBytes").asInt() > 8388608)) throw invalid("WPF 响应上限配置无效");
        var ids = new HashSet<String>();
        for (JsonNode endpoint : root.path("endpoints")) {
            if (!endpoint.isObject() || !endpoint.path("id").isTextual() || !endpoint.path("name").isTextual()
                    || !endpoint.path("apiBaseUrl").isTextual()) throw invalid("WPF 连接字段格式无效");
            endpoint.fieldNames().forEachRemaining(key -> {
                if (!Set.of("id", "name", "apiBaseUrl").contains(key)) throw invalid("WPF 连接配置不能包含密码或未审核字段");
            });
            String id = endpoint.path("id").asText(), name = endpoint.path("name").asText();
            if (id.isBlank() || id.length() > 64 || id.chars().anyMatch(Character::isISOControl) || !ids.add(id)
                    || name.isBlank() || name.length() > 100 || name.chars().anyMatch(Character::isISOControl))
                throw invalid("WPF 公司连接配置的标识或名称无效");
            String address = endpoint.path("apiBaseUrl").asText();
            try {
                URI uri = URI.create(address);
                String host = uri.getHost();
                String normalizedHost = host == null ? "" : host.toLowerCase(java.util.Locale.ROOT).replaceAll("\\.+$", "");
                if (address.length() > 2048 || address.chars().anyMatch(value -> value <= 32 || value == 127)
                        || !"https".equalsIgnoreCase(uri.getScheme()) || host == null || uri.getRawUserInfo() != null
                        || uri.getRawQuery() != null || uri.getRawFragment() != null
                        || !"/api".equals(uri.getRawPath().replaceAll("/+$", ""))
                        || normalizedHost.equals("localhost") || normalizedHost.endsWith(".localhost")
                        || normalizedHost.matches("127\\..*") || Set.of("0.0.0.0", "0", "::", "[::]", "::1", "[::1]").contains(normalizedHost)
                        || normalizedHost.matches("[0-9.]+") && !normalizedHost.matches("(?:[0-9]{1,3}\\.){3}[0-9]{1,3}")
                        || normalizedHost.matches("(?:0x[0-9a-f]+|[0-9]+)(?:\\.(?:0x[0-9a-f]+|[0-9]+)){0,3}")
                            && !normalizedHost.matches("(?:[0-9]{1,3}\\.){3}[0-9]{1,3}"))
                    throw invalid("WPF 正式连接必须是非回环 HTTPS /api 地址");
                // Parse numeric literals only. Never perform DNS/network lookups during package inspection.
                if (normalizedHost.matches("[0-9.]+")) {
                    String[] parts = normalizedHost.split("\\.", -1);
                    if (parts.length != 4) throw invalid("WPF IPv4 连接格式无效");
                    int first = -1, sum = 0;
                    for (int index = 0; index < parts.length; index++) {
                        if (parts[index].length() > 1 && parts[index].startsWith("0")) throw invalid("WPF IPv4 连接不能使用歧义数字格式");
                        int number = Integer.parseInt(parts[index]);
                        if (number > 255) throw invalid("WPF IPv4 连接格式无效");
                        if (index == 0) first = number;
                        sum += number;
                    }
                    if (first == 127 || sum == 0) throw invalid("WPF 正式连接不能指向本机");
                } else if (normalizedHost.indexOf(':') >= 0) {
                    String addressLiteral = normalizedHost.replace("[", "").replace("]", "");
                    if (!addressLiteral.matches("[0-9a-f:.]+")) throw invalid("WPF IPv6 连接格式无效");
                    try {
                        InetAddress literal = InetAddress.getByName(addressLiteral);
                        if (literal.isLoopbackAddress() || literal.isAnyLocalAddress()) throw invalid("WPF 正式连接不能指向本机");
                    } catch (java.net.UnknownHostException malformed) { throw invalid("WPF IPv6 连接格式无效"); }
                }
            } catch (IllegalArgumentException malformed) { throw invalid("WPF 公司 HTTPS 连接配置格式无效"); }
        }
        if (!root.path("selectedEndpointId").isTextual() || !ids.contains(root.path("selectedEndpointId").asText()))
            throw invalid("WPF 默认连接不在审核列表中");
    }
    private static void inspectRuntime(byte[] bytes) {
        try {
            var factory = DocumentBuilderFactory.newInstance();
            factory.setFeature("http://apache.org/xml/features/disallow-doctype-decl", true);
            factory.setFeature("http://xml.org/sax/features/external-general-entities", false);
            factory.setFeature("http://xml.org/sax/features/external-parameter-entities", false);
            factory.setAttribute(XMLConstants.ACCESS_EXTERNAL_DTD, "");
            factory.setAttribute(XMLConstants.ACCESS_EXTERNAL_SCHEMA, "");
            factory.setXIncludeAware(false);
            factory.setExpandEntityReferences(false);
            var builder = factory.newDocumentBuilder();
            builder.setErrorHandler(new org.xml.sax.helpers.DefaultHandler() {
                @Override public void error(org.xml.sax.SAXParseException failure) throws org.xml.sax.SAXException { throw failure; }
                @Override public void fatalError(org.xml.sax.SAXParseException failure) throws org.xml.sax.SAXException { throw failure; }
            });
            var document = builder.parse(new ByteArrayInputStream(bytes));
            var runtimes = document.getElementsByTagName("supportedRuntime");
            if (!"configuration".equals(document.getDocumentElement().getTagName()) || document.getDocumentElement().hasAttribute("xmlns")
                    || runtimes.getLength() != 1 || !"startup".equals(runtimes.item(0).getParentNode().getNodeName())
                    || runtimes.item(0).getParentNode().getParentNode() != document.getDocumentElement()
                    || !"v4.0".equals(runtimes.item(0).getAttributes().getNamedItem("version").getNodeValue())
                    || !".NETFramework,Version=v4.8".equals(runtimes.item(0).getAttributes().getNamedItem("sku").getNodeValue()))
                throw invalid("WPF 包必须使用 .NET Framework 4.8 原生运行配置");
            var remote = document.getElementsByTagName("loadFromRemoteSources");
            for (int index = 0; index < remote.getLength(); index++) {
                var enabled = remote.item(index).getAttributes().getNamedItem("enabled");
                if (enabled != null && "true".equalsIgnoreCase(enabled.getNodeValue())) throw invalid("WPF 包不能启用远程程序集加载");
            }
        } catch (ApiException invalid) { throw invalid; }
        catch (Exception malformed) { throw invalid("WPF 运行配置格式无效或含外部实体"); }
    }
    private static ApiException invalid(String message) { return new ApiException(ErrorCode.VALIDATION_FAILED, message); }
}
