package com.uten.imp.features.clientupdates;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import java.io.IOException;
import java.util.HashSet;
import java.util.Map;
import java.util.Set;
import org.apache.commons.compress.archivers.zip.ZipArchiveEntry;
import org.apache.commons.compress.archivers.zip.ZipFile;

/** Actual Flutter payload identity; it is independent of filenames and endpoint strings. */
final class WindowsRuntimeProfileContract {
    static final String FILE = "data/uten-runtime-profile.json";
    private static final int MAX_BYTES = 16384;
    private static final Set<String> KEYS = Set.of("schemaVersion", "buildProfile", "applicationId", "nativeProductName",
            "displayName", "runtimeFamily", "networkScope", "selfUpdatesAllowed");
    private WindowsRuntimeProfileContract() { }

    static boolean required(ClientReleaseDto.Release release) {
        if (!"windows".equals(release.platform()) || !ClientRuntimeFamily.FLUTTER.equals(release.runtimeFamily())) return false;
        return requiredVersion(release.version());
    }

    static boolean requiredVersion(String value) {
        if (value == null) throw invalid("Windows 客户端版本缺失");
        int[] version = WindowsSetupInspector.numericVersion(value);
        return version[0] > 2 || version[0] == 2 && (version[1] > 5 || version[1] == 5 && version[2] >= 44);
    }

    static boolean inspect(ZipFile zip, Map<String, ZipArchiveEntry> files,
            ClientReleaseDto.Release release, ObjectMapper mapper) throws IOException {
        ZipArchiveEntry entry = files.get(FILE);
        if (entry == null) {
            if (required(release)) throw invalid("此版本 Windows 正式包缺少运行身份清单，请从同一审核源码重新生成双包");
            return false;
        }
        if (entry.getSize() < 1 || entry.getSize() > MAX_BYTES) throw invalid("Windows 运行身份清单大小无效");
        JsonNode profile;
        try (var input = zip.getInputStream(entry)) {
            byte[] bytes = input.readNBytes(MAX_BYTES + 1);
            if (bytes.length != entry.getSize() || bytes.length > MAX_BYTES) throw invalid("Windows 运行身份清单长度不一致");
            profile = ClientPackageJson.read(bytes, mapper);
        } catch (JsonProcessingException malformed) {
            throw invalid("Windows 运行身份清单不是唯一、完整的 JSON 对象");
        }
        if (profile == null || !profile.isObject()) throw invalid("Windows 运行身份清单必须是对象");
        Set<String> keys = new HashSet<>();
        profile.fieldNames().forEachRemaining(keys::add);
        if (!KEYS.equals(keys) || !profile.path("schemaVersion").isIntegralNumber()
                || !profile.path("schemaVersion").canConvertToInt() || profile.path("schemaVersion").intValue() != 1)
            throw invalid("Windows 运行身份清单字段或版本无效");
        if (!"formal".equals(profile.path("buildProfile").asText())
                || !"com.uten.uten_imp".equals(profile.path("applicationId").asText())
                || !"优腾综合管理平台".equals(profile.path("nativeProductName").asText())
                || !"UTEN".equals(profile.path("displayName").asText())
                || !ClientRuntimeFamily.FLUTTER.equals(profile.path("runtimeFamily").asText())
                || !"trusted-configured".equals(profile.path("networkScope").asText())
                || !profile.path("selfUpdatesAllowed").isBoolean() || !profile.path("selfUpdatesAllowed").booleanValue())
            throw invalid("本地测试或身份不一致的客户端不能发布到正式软件目录");
        return true;
    }

    static String installerBinding(JsonNode manifest, ClientReleaseDto.Release release, boolean profilePresent) {
        if (!profilePresent && !required(release)) return null;
        if (!"update".equals(release.packageKind())) {
            if (manifest.has("installerSha256")) throw invalid("安装器自身清单不能包含循环的安装器摘要");
            return null;
        }
        JsonNode binding = manifest.path("installerSha256");
        if (!binding.isTextual() || !binding.asText().matches("[0-9a-f]{64}"))
            throw invalid("新 Windows 更新 ZIP 必须绑定同源安装包的真实 SHA-256");
        return binding.asText();
    }

    static void peIdentity(Map<String, String> values, boolean required) {
        rejectLocalTestPe(values);
        String profile = values.get("utenbuildprofile");
        if (profile != null && !required)
            throw invalid("实际 PE 声明了新运行身份，不能移除对应身份清单后按历史包发布");
        if (required && !"formal".equals(profile))
            throw invalid("新 Windows 程序的实际 PE 缺少 formal 运行身份");
    }

    static void rejectLocalTestPe(Map<String, String> values) {
        String profile = values.get("utenbuildprofile");
        if (profile != null && !"formal".equals(profile)
                || "UTEN Local Test".equals(values.get("productname")))
            throw invalid("本地测试程序不能发布到正式软件目录");
    }

    private static ApiException invalid(String message) { return new ApiException(ErrorCode.VALIDATION_FAILED, message); }
}
