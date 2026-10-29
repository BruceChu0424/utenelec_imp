package com.uten.imp.features.clientupdates;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import java.util.Set;

/** Runtime is a release partition, independent of a Windows processor architecture. */
final class ClientRuntimeFamily {
    static final String FLUTTER = "flutter";
    static final String WPF_LEGACY = "wpf_legacy";
    private ClientRuntimeFamily() { }
    static String normalize(String value) { return value == null ? FLUTTER : value; }
    static String requireKnown(String value) {
        String family = normalize(value);
        if (!Set.of(FLUTTER, WPF_LEGACY).contains(family)) throw invalid();
        return family;
    }
    static void requireTarget(String value, String platform, String architecture) {
        if (WPF_LEGACY.equals(requireKnown(value))
                && !("windows".equals(platform) && architecture != null && Set.of("x86", "x64").contains(architecture))) throw invalid();
    }
    static String setupMode(String family) { return WPF_LEGACY.equals(family) ? "windows_wpf_setup" : "windows_setup"; }
    static String archiveMode(String family) { return WPF_LEGACY.equals(family) ? "windows_wpf_archive" : "windows_archive"; }
    static void requireMode(ClientReleaseDto.Release release) {
        requireTarget(release.runtimeFamily(), release.platform(), release.architecture());
        if (WPF_LEGACY.equals(release.runtimeFamily())) {
            if (!(("installer".equals(release.packageKind()) && setupMode(WPF_LEGACY).equals(release.installMode()))
                    || ("update".equals(release.packageKind()) && archiveMode(WPF_LEGACY).equals(release.installMode())))) throw invalid();
        } else if ("windows_wpf_setup".equals(release.installMode()) || "windows_wpf_archive".equals(release.installMode())) throw invalid();
    }
    private static ApiException invalid() { return new ApiException(ErrorCode.VALIDATION_FAILED, "客户端运行时与平台、架构或包模式不匹配"); }
}
