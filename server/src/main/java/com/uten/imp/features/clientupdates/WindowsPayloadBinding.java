package com.uten.imp.features.clientupdates;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import java.io.IOException;
import java.nio.channels.FileChannel;
import java.nio.charset.StandardCharsets;
import java.nio.charset.CodingErrorAction;
import java.nio.ByteBuffer;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.util.Arrays;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Map;
import java.util.Set;

/** The main PE binds every AOT/asset/DLL/configuration byte; Authenticode trust is a separate policy. */
final class WindowsPayloadBinding {
    private WindowsPayloadBinding() { }
    record FileProof(long size, String sha256) { }

    static void inspect(Path signedMain, Map<String, FileProof> actual, ClientReleaseDto.Release release) throws IOException {
        inspect(signedMain, actual, release, true);
    }

    static void inspect(Path signedMain, Map<String, FileProof> actual, ClientReleaseDto.Release release,
                        boolean requireSigned) throws IOException {
        JsonNode inventory = read(signedMain, requireSigned);
        String executable = "wpf_legacy".equals(release.runtimeFamily()) ? "Uten.Legacy.Desktop.exe" : "uten_imp.exe";
        if (!release.runtimeFamily().equals(inventory.path("runtimeFamily").asText())
                || !release.version().equals(inventory.path("version").asText())
                || release.buildNumber() != inventory.path("buildNumber").asLong(-1)
                || !release.architecture().equals(inventory.path("architecture").asText())
                || !executable.equals(inventory.path("executable").asText())) throw invalid("主程序绑定的软件版本、架构或运行时与发布信息不一致");
        Map<String, FileProof> signed = new HashMap<>();
        for (var file : inventory.path("files")) signed.put(file.path("path").asText(),
                new FileProof(file.path("size").asLong(), file.path("sha256").asText()));
        Map<String, FileProof> expected = new HashMap<>(actual);
        expected.keySet().removeIf(name -> name.equals(executable) || name.equals("uten-client-manifest.json") || name.startsWith("client_updater/"));
        if (!signed.equals(expected)) throw invalid("更新包的完整运行文件与主程序绑定内容不一致，请重新生成同源正式包");
    }

    static JsonNode read(Path signedMain) throws IOException {
        return read(signedMain, true);
    }

    static JsonNode read(Path signedMain, boolean requireSigned) throws IOException {
        Contract contract = contract();
        try (var channel = FileChannel.open(signedMain, StandardOpenOption.READ)) {
            var layout = WindowsEngineSafety.layout(channel);
            long certificate = layout.certificate(), size = channel.size();
            if (certificate == 0 && requireSigned) throw invalid("主程序缺少位于文件末尾的完整签名证书表");
            if (certificate != 0 && (certificate % 8 != 0 || layout.certificateSize() < 8 || layout.certificateSize() > contract.maximumCertificateBytes()
                    || certificate + layout.certificateSize() != size)) throw invalid("主程序缺少位于文件末尾的完整签名证书表");
            // Unsigned policy still requires the exact bounded inventory at EOF.
            // A present certificate table can never be reinterpreted as unsigned overlay.
            long envelopeEnd = certificate == 0 ? size : certificate;
            long position = certificate == 0 ? size : certificate;
            int certificateRecords = 0;
            while (position < size) {
                if (++certificateRecords > contract.maximumCertificateRecords()) throw invalid("主程序签名证书记录数量超出上限");
                var header = WindowsEngineSafety.read(channel, position, 8);
                long length = Integer.toUnsignedLong(header.getInt(0));
                if (length < 8 || Short.toUnsignedInt(header.getShort(4)) != 0x200 || Short.toUnsignedInt(header.getShort(6)) != 2
                        || length > size - position) throw invalid("主程序签名证书记录无效");
                long following = position + ((length + 7) & ~7L);
                if (following > size) throw invalid("主程序签名填充超出证书表");
                for (byte value : WindowsEngineSafety.read(channel, position + length, (int)(following - position - length)).array())
                    if (value != 0) throw invalid("主程序签名证书填充必须为零");
                position = following;
            }
            int footerBytes = 4 + contract.magic().length;
            if (envelopeEnd % 8 != 0 || envelopeEnd < layout.mappedEnd() + footerBytes)
                throw invalid("主程序完整运行文件绑定的位置或对齐无效");
            var footer = WindowsEngineSafety.read(channel, envelopeEnd - footerBytes, footerBytes);
            if (!Arrays.equals(Arrays.copyOfRange(footer.array(), 4, footerBytes), contract.magic())) throw invalid("主程序缺少完整运行文件绑定");
            long length = Integer.toUnsignedLong(footer.getInt(0)), start = envelopeEnd - footerBytes - length;
            if (length < 1 || length > contract.maximumJsonBytes() || start < layout.mappedEnd() || start > layout.mappedEnd() + 7)
                throw invalid("主程序完整运行文件绑定的大小或位置无效");
            for (byte value : WindowsEngineSafety.read(channel, layout.mappedEnd(), (int)(start - layout.mappedEnd())).array())
                if (value != 0) throw invalid("主程序运行文件绑定前的填充必须为零");
            JsonNode inventory;
            try {
                byte[] raw = WindowsEngineSafety.read(channel, start, (int)length).array();
                var decoded = StandardCharsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                        .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(raw));
                if (!decoded.isEmpty() && decoded.charAt(0) == '\ufeff') throw new IOException("BOM is not part of the UTF-8 inventory contract");
                inventory = ClientPackageJson.read(raw, new ObjectMapper());
            }
            catch (IOException malformed) { throw invalid("主程序运行文件绑定不是严格 JSON"); }
            validate(inventory, contract);
            return inventory;
        }
    }

    private static void validate(JsonNode value, Contract contract) {
        exactFields(value, contract.fields());
        if (!value.path("schemaVersion").isIntegralNumber() || !value.path("schemaVersion").canConvertToInt() || value.path("schemaVersion").asInt(-1) != 1
                || !Set.of("flutter", "wpf_legacy").contains(value.path("runtimeFamily").asText())
                || !Set.of("x86", "x64", "arm64").contains(value.path("architecture").asText())
                || !value.path("version").isTextual() || !value.path("version").asText().matches("[0-9]+\\.[0-9]+\\.[0-9]+")
                || !value.path("buildNumber").isIntegralNumber() || !value.path("buildNumber").canConvertToLong()
                || value.path("buildNumber").asLong() < 1 || value.path("buildNumber").asLong() > 65535
                || !value.path("files").isArray() || value.path("files").isEmpty() || value.path("files").size() > contract.maximumFiles())
            throw invalid("主程序运行文件绑定的元数据或文件数量无效");
        String executable = path(value.path("executable"));
        Set<String> seen = new HashSet<>();
        byte[] previous = null;
        for (var item : value.path("files")) {
            exactFields(item, contract.recordFields());
            String name = path(item.path("path"));
            byte[] ordered = name.getBytes(StandardCharsets.UTF_8);
            if (!seen.add(name.toLowerCase(java.util.Locale.ROOT)) || previous != null && Arrays.compareUnsigned(previous, ordered) >= 0
                    || name.equals(executable) || name.equals("uten-client-manifest.json") || name.startsWith("client_updater/")
                    || !item.path("size").isIntegralNumber() || !item.path("size").canConvertToLong() || item.path("size").asLong() < 0
                    || item.path("size").asLong() > 536870912L || !item.path("sha256").isTextual() || !item.path("sha256").asText().matches("[0-9a-f]{64}"))
                throw invalid("主程序运行文件绑定的文件路径、摘要或顺序无效");
            previous = ordered;
        }
    }

    private static String path(JsonNode node) {
        if (!node.isTextual()) throw invalid("主程序运行文件绑定的路径无效");
        String value = node.asText();
        if (value.isEmpty() || value.codePointCount(0, value.length()) > 230 || value.getBytes(StandardCharsets.UTF_8).length > 920
                || value.chars().anyMatch(character -> character < 32 || "\\:<>\"|?*".indexOf(character) >= 0)) throw invalid("主程序运行文件绑定的路径无效");
        for (String part : value.split("/", -1)) if (part.isEmpty() || part.equals(".") || part.equals("..") || part.endsWith(".") || part.endsWith(" "))
            throw invalid("主程序运行文件绑定的路径无效");
        for (int index = 0; index < value.length(); index++) if (Character.isSurrogate(value.charAt(index))) {
            if (!Character.isHighSurrogate(value.charAt(index)) || ++index >= value.length() || !Character.isLowSurrogate(value.charAt(index)))
                throw invalid("主程序运行文件绑定包含无效 Unicode 路径");
        }
        return value;
    }

    private static void exactFields(JsonNode value, Set<String> expected) {
        if (value == null || !value.isObject() || value.size() != expected.size()) throw invalid("主程序运行文件绑定字段不符合共享合同");
        value.fieldNames().forEachRemaining(name -> { if (!expected.contains(name)) throw invalid("主程序运行文件绑定包含未知字段"); });
    }

    private static Contract contract() throws IOException {
        try (var input = WindowsPayloadBinding.class.getResourceAsStream("/contracts/windows-payload-binding/v1.json")) {
            if (input == null) throw invalid("服务端未打包完整运行文件签名合同");
            JsonNode value = new ObjectMapper().readTree(input);
            if (value.path("schemaVersion").asInt() != 1 || !"uten-windows-payload-binding-v1".equals(value.path("contractId").asText()))
                throw invalid("服务端完整运行文件签名合同版本不匹配");
            Set<String> fields = new HashSet<>(), records = new HashSet<>();
            value.path("inventoryFields").forEach(field -> fields.add(field.asText()));
            value.path("recordFields").forEach(field -> records.add(field.asText()));
            return new Contract(value.path("magicAscii").asText().getBytes(StandardCharsets.US_ASCII), value.path("maximumJsonBytes").asInt(),
                    value.path("maximumFiles").asInt(), value.path("maximumCertificateBytes").asInt(16777216),
                    value.path("maximumCertificateRecords").asInt(16), Set.copyOf(fields), Set.copyOf(records));
        }
    }
    private record Contract(byte[] magic, int maximumJsonBytes, int maximumFiles, int maximumCertificateBytes,
                            int maximumCertificateRecords, Set<String> fields, Set<String> recordFields) { }
    private static ApiException invalid(String message) { return new ApiException(ErrorCode.VALIDATION_FAILED, message); }
}
