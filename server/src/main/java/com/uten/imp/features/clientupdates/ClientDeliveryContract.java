package com.uten.imp.features.clientupdates;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;

/** Missing means the historical contract. Readers never migrate or rewrite old catalog bytes. */
final class ClientDeliveryContract {
    static final String PAIRED_WINDOWS = "paired_v1";
    static final String AUDITED_ANDROID = "audited_v1";
    private ClientDeliveryContract() { }
    static String forNewRelease(String platform, String installMode) {
        return "windows".equals(platform) ? PAIRED_WINDOWS
                : "android".equals(platform) && "android_package".equals(installMode) ? AUDITED_ANDROID : null;
    }
    static boolean paired(ClientReleaseDto.Release release) { return PAIRED_WINDOWS.equals(release.deliveryContract()); }
    static boolean auditedAndroid(ClientReleaseDto.Release release) { return AUDITED_ANDROID.equals(release.deliveryContract()); }
    static void require(ClientReleaseDto.Release release) {
        if (release.deliveryContract() == null) return;
        boolean valid = paired(release) && "windows".equals(release.platform())
                && ("installer".equals(release.packageKind()) && ClientRuntimeFamily.setupMode(release.runtimeFamily()).equals(release.installMode())
                    || "update".equals(release.packageKind()) && ClientRuntimeFamily.archiveMode(release.runtimeFamily()).equals(release.installMode()))
                || auditedAndroid(release) && "android".equals(release.platform())
                    && "flutter".equals(release.runtimeFamily()) && "android_package".equals(release.installMode())
                    && "update".equals(release.packageKind());
        if (!valid) throw new ApiException(ErrorCode.VALIDATION_FAILED, "客户端交付合同与平台、运行时或包用途不匹配");
    }
}
