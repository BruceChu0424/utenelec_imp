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
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HexFormat;
import java.nio.file.Path;
import java.nio.channels.FileChannel;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.file.StandardOpenOption;
import javax.xml.XMLConstants;
import javax.xml.parsers.DocumentBuilderFactory;
import org.apache.commons.compress.archivers.zip.ZipArchiveEntry;
import org.apache.commons.compress.archivers.zip.ZipFile;

/** Candidate package contract only; no claim of Win7 UAT, complete ERP migration or code signing. */
final class WindowsWpfPackageInspector {
    static final String EXECUTABLE = WpfPackageContract.EXECUTABLE;
    static final Set<String> REQUIRED = WpfPackageContract.FILES;
    private WindowsWpfPackageInspector() { }
    static boolean allowedFile(String name) { return REQUIRED.contains(name); }
    static void requireDirectory(Path path) throws IOException {
        // ZIP format EOCD + maximum 16-bit comment, before ZipFile allocates entries.
        try (var file = FileChannel.open(path, StandardOpenOption.READ)) {
            long size = file.size();
            int count = (int) Math.min(size, 22 + 65535);
            var tail = ByteBuffer.allocate(count).order(ByteOrder.LITTLE_ENDIAN);
            file.position(size - count);
            while (tail.hasRemaining()) if (file.read(tail) < 0) throw invalid("WPF ZIP 目录截断");
            int position = -1;
            for (int index = count - 4; index >= 0; index--)
                if (tail.getInt(index) == 0x06054b50) { position = index; break; }
            if (position < 0 || position > count - 22) throw invalid("WPF ZIP 缺少有界目录");
            int expected = REQUIRED.size() + 1;
            long length = Integer.toUnsignedLong(tail.getInt(position + 12));
            long offset = Integer.toUnsignedLong(tail.getInt(position + 16));
            if (tail.getShort(position + 4) != 0 || tail.getShort(position + 6) != 0
                    || Short.toUnsignedInt(tail.getShort(position + 8)) != expected
                    || Short.toUnsignedInt(tail.getShort(position + 10)) != expected
                    || length < expected * 46 || length > WpfPackageContract.MAXIMUM_CENTRAL_DIRECTORY_BYTES
                    || offset + length != size - count + position
                    || position + 22 + Short.toUnsignedInt(tail.getShort(position + 20)) != count)
                throw invalid("WPF ZIP 必须为单盘、非 ZIP64、有界七条目目录");
        }
    }
    static void inspect(ZipFile zip, Map<String, ZipArchiveEntry> files, ClientReleaseDto.Release release, ObjectMapper mapper)
            throws IOException {
        for (String name : Set.of(EXECUTABLE, "Uten.Legacy.Core.dll", "BouncyCastle.Cryptography.dll")) {
            byte[] bytes = read(zip, files.get(name), WpfPackageContract.MAXIMUM_MANAGED_FILE_BYTES);
            boolean vendor = "BouncyCastle.Cryptography.dll".equals(name);
            if (vendor && !WpfPackageContract.DEPENDENCY_DLL_SHA256.equals(sha256(bytes))) throw invalid("WPF TLS 依赖与 schema-1 固定锁不匹配，升级依赖需完整安装包");
            WindowsManagedImageInspector.inspect(bytes, release, !EXECUTABLE.equals(name), !vendor, vendor);
        }
        byte[] license = read(zip, files.get("BouncyCastle-LICENSE.md"), WpfPackageContract.MAXIMUM_LICENSE_BYTES);
        if (!WpfPackageContract.DEPENDENCY_LICENSE_SHA256.equals(sha256(license))) throw invalid("WPF TLS 许可与固定依赖锁不匹配");
        inspectConfiguration(read(zip, files.get("uten.client.json"), WpfPackageContract.MAXIMUM_CONFIGURATION_BYTES), mapper);
        inspectRuntime(read(zip, files.get("Uten.Legacy.Desktop.exe.config"), WpfPackageContract.MAXIMUM_CONFIGURATION_BYTES));
    }
    private static String sha256(byte[] bytes) {
        try { return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(bytes)); }
        catch (NoSuchAlgorithmException impossible) { throw new IllegalStateException(impossible); }
    }
    static JsonNode strictJson(byte[] bytes, ObjectMapper mapper) throws IOException {
        return mapper.copy().enable(com.fasterxml.jackson.core.JsonParser.Feature.STRICT_DUPLICATE_DETECTION)
                .enable(com.fasterxml.jackson.databind.DeserializationFeature.FAIL_ON_TRAILING_TOKENS).readTree(bytes);
    }
    private static void fields(JsonNode value, Set<String> required, Set<String> optional) {
        if (value == null || !value.isObject()) throw invalid("WPF JSON 必须是对象");
        for (String key : required) if (!value.has(key)) throw invalid("WPF JSON 缺少约定字段");
        value.fieldNames().forEachRemaining(key -> { if (!required.contains(key) && !optional.contains(key)) throw invalid("WPF JSON 包含未知字段"); });
    }
    static void fileFields(JsonNode value) { fields(value, WpfPackageContract.FILE_RECORD_KEYS, Set.of()); }
    static void manifestFields(JsonNode value) {
        fields(value, WpfPackageContract.MANIFEST_REQUIRED_KEYS, WpfPackageContract.MANIFEST_OPTIONAL_KEYS);
        if (value.has("sourceCommit") && (!value.path("sourceCommit").isTextual() || !value.path("sourceCommit").asText().matches("[0-9a-f]{40}"))
                || value.has("candidate") && (!value.path("candidate").isBoolean() || !value.path("candidate").booleanValue())
                || value.has("releaseReady") && (!value.path("releaseReady").isBoolean() || value.path("releaseReady").booleanValue()))
            throw invalid("WPF 候选来源字段无效");
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
        try { root = strictJson(bytes, mapper); }
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
