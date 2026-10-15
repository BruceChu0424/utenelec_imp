package com.uten.imp.features.visitor.sms.settings;

import com.fasterxml.jackson.annotation.JsonProperty;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

public final class SmsSettingsDto {
    private SmsSettingsDto() {}
    public record Capabilities(boolean canManage,boolean canUseLog,boolean canExposeCode) {}
    public record View(String revision,long version,String source,String provider,String effectiveProvider,
                       String endpoint,String signName,String templateCode,boolean accessKeyConfigured,
                       String accessKeyIdHint,boolean secretUnreadable,Capabilities capabilities,
                       String status,String detail,String applyMode,java.util.List<String> allowedEndpoints) {}
    public record Save(@NotBlank @Size(max=64) String expectedRevision,@Size(max=16) String provider,
                       @Size(max=253) String endpoint,@Size(max=64) String signName,@Size(max=64) String templateCode,
                       @JsonProperty(access=JsonProperty.Access.WRITE_ONLY) @Size(max=256) String accessKeyId,
                       @JsonProperty(access=JsonProperty.Access.WRITE_ONLY) @Size(max=256) String accessKeySecret,
                       boolean clearCredentials,boolean useEnvironment) {
        @Override public String toString() { return "SmsSettingsSave[credentials=REDACTED]"; }
    }
}
