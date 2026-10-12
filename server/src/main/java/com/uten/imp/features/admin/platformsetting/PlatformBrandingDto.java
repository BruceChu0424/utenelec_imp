package com.uten.imp.features.admin.platformsetting;

import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;
import java.time.OffsetDateTime;

/** Explicit public projection; storage bytes, actor IDs and deployment credentials never leave it. */
public record PlatformBrandingDto(
        int version, String companyName, String companyAliases, String platformName, String tagline,
        String primaryColor, String secondaryColor, String loginNotice,
        String supportPhone, String supportEmail, String website,
        boolean hasLogo, OffsetDateTime updatedAt) {

    public record Update(
            @Min(0) int expectedVersion,
            @NotBlank @Size(max = 120) String companyName,
            @NotNull @Size(max = 500) String companyAliases,
            @NotBlank @Size(max = 80) String platformName,
            @NotNull @Size(max = 160) String tagline,
            @NotBlank @Size(max = 7) String primaryColor,
            @NotBlank @Size(max = 7) String secondaryColor,
            @NotNull @Size(max = 500) String loginNotice,
            @NotNull @Size(max = 50) String supportPhone,
            @NotNull @Size(max = 120) String supportEmail,
            @NotNull @Size(max = 200) String website,
            @Size(max = PlatformLogoImage.MAX_BASE64_CHARS) String logoBase64,
            boolean removeLogo) {}
}
