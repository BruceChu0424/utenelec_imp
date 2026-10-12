package com.uten.imp.features.admin.platformsetting;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.config.props.StorageProperties;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import java.awt.image.BufferedImage;
import java.time.OffsetDateTime;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class PlatformSettingsServiceTest {
    final PlatformBrandingRepository repo = mock(PlatformBrandingRepository.class);
    final SecurityContextCurrentUser users = mock(SecurityContextCurrentUser.class);
    final AuditService audit = mock(AuditService.class);
    final TxSessionVars tx = mock(TxSessionVars.class);
    final StorageProperties storage = new StorageProperties();
    final PlatformSettingsService service = new PlatformSettingsService(repo, users, tx, audit, storage);
    final AuthUser admin = actor(true, null);
    final byte[] previousLogo = new byte[]{1, 2, 3};
    final String previousSha = "abc";

    @BeforeEach void setup() {
        when(users.get()).thenReturn(Optional.of(admin));
        when(repo.lock()).thenReturn(new PlatformBrandingRepository.Locked(dto(2, true), previousLogo, previousSha));
        when(repo.save(any(), any(), any(), any())).thenAnswer(call -> {
            PlatformBrandingDto.Update value = call.getArgument(0);
            return new PlatformBrandingDto(3, value.companyName(), value.companyAliases(), value.platformName(), value.tagline(),
                    value.primaryColor(), value.secondaryColor(), value.loginNotice(), value.supportPhone(),
                    value.supportEmail(), value.website(), call.getArgument(1) != null, OffsetDateTime.now());
        });
    }

    @Test @SuppressWarnings("unchecked") void keepLogoAndAllMetadataSaveTogetherWithSummaryOnlyAudit() {
        var saved = service.update(request(2, null, false));
        assertEquals(3, saved.version()); assertTrue(saved.hasLogo());
        verify(repo).save(any(), same(previousLogo), eq(previousSha), eq(admin.getId()));
        verify(tx).bindActor(admin.getId(), "admin");
        ArgumentCaptor<Map<String, Object>> change = ArgumentCaptor.forClass(Map.class);
        verify(audit).logCommittedChange(eq(admin.getId()), eq("admin"), eq("update_system_setting"),
                eq("platform_branding"), eq("1"), eq("success"), change.capture());
        assertFalse(change.getValue().containsKey("logoBase64"));
        assertFalse(change.getValue().containsKey("logo_png"));
    }

    @Test void replacementIsSanitizedBeforeAtomicSave() throws Exception {
        String image = PlatformLogoImageTest.encoded(new BufferedImage(4, 3, BufferedImage.TYPE_INT_ARGB), "PNG");
        service.update(request(2, image, false));
        verify(repo).save(any(), argThat(bytes -> bytes.length > 8 && bytes[0] == (byte) 0x89),
                argThat(sha -> sha.length() == 64), eq(admin.getId()));
    }

    @Test void removingLogoClearsBothBytesAndDigest() {
        var saved = service.update(request(2, null, true));
        assertFalse(saved.hasLogo()); verify(repo).save(any(), isNull(), isNull(), eq(admin.getId()));
    }

    @Test void stalePageAndDuplicateSubmissionNeverOverwrite() {
        ApiException failure = assertThrows(ApiException.class, () -> service.update(request(1, null, false)));
        assertEquals(ErrorCode.CONFLICT, failure.getCode()); verify(repo, never()).save(any(), any(), any(), any());
        verifyNoInteractions(audit, tx);
    }

    @Test void invalidFieldsAndAmbiguousLogoCommandAreRejectedBeforeLock() {
        assertThrows(ApiException.class, () -> service.update(request(2, "test", true)));
        var value = request(2, null, false);
        assertThrows(ApiException.class, () -> service.update(new PlatformBrandingDto.Update(2, "", "", value.platformName(), "",
                "#FFFFFF", "#000000", "", "", "", "", null, false)));
        assertThrows(ApiException.class, () -> service.update(new PlatformBrandingDto.Update(2, "公司", "", "平台", "",
                "#FFFFFF", "#000000", "", "", "", "javascript:alert(1)", null, false)));
        verify(repo, never()).lock();
    }

    @Test void noAdminOrImpersonatedIdentityCannotReachAnyWrite() {
        when(users.get()).thenReturn(Optional.of(actor(false, null)));
        assertThrows(ApiException.class, () -> service.update(request(2, null, false)));
        when(users.get()).thenReturn(Optional.of(actor(true, UUID.randomUUID())));
        assertThrows(ApiException.class, () -> service.update(request(2, null, false)));
        verifyNoInteractions(repo, audit, tx);
    }

    @Test void statusReportsConfigurationWithoutClaimingAttachmentHealth() {
        storage.setProvider("internal"); storage.setUploadsEnabled(false);
        when(repo.databaseConnected()).thenReturn(true);
        var status = service.status();
        assertTrue(status.databaseConnected()); assertEquals("DATABASE", status.logoStorage());
        assertEquals(524288, status.maxLogoBytes()); assertFalse(status.attachmentUploadsEnabled());
        assertEquals("internal", status.attachmentStorageBackend());
    }

    @Test void aliasesNormalizeAndDeduplicateWithoutAddingCompanySpecificDefaults() {
        assertEquals("", PlatformSettingsService.normalizeAliases("\n  \n"));
        assertEquals("ACME Electric\n艾科电器", PlatformSettingsService.normalizeAliases(" ACME Electric \r\nacme electric\n\n 艾科电器 "));
        for (String invalid : new String[]{"A", "x".repeat(121), "ACME\tElectric", "ACME\rElectric", "x".repeat(501),
                java.util.stream.IntStream.range(0, 17).mapToObj(i -> "name" + i).collect(java.util.stream.Collectors.joining("\n"))})
            assertThrows(ApiException.class, () -> PlatformSettingsService.normalizeAliases(invalid));
    }

    @Test void companyReadPortReadsOneImmutableVersionedIdentity() {
        when(repo.current()).thenReturn(new PlatformBrandingDto(7, "测试公司", "ACME Electric\n艾科电器", "平台", "",
                "#0F766E", "#2DD4BF", "", "", "", "", false, OffsetDateTime.now()));
        var value = service.currentIdentity();
        assertEquals(7, value.version()); assertEquals("测试公司", value.companyName());
        assertEquals(java.util.List.of("ACME Electric", "艾科电器"), value.companyAliases());
        assertThrows(UnsupportedOperationException.class, () -> value.companyAliases().add("other"));
        verify(repo).current();
    }

    static PlatformBrandingDto dto(int version, boolean hasLogo) {
        return new PlatformBrandingDto(version, "公司", "", "平台", "", "#0F766E", "#2DD4BF", "", "", "", "", hasLogo, OffsetDateTime.now());
    }
    static PlatformBrandingDto.Update request(int version, String image, boolean remove) {
        return new PlatformBrandingDto.Update(version, "公司", "", "平台", "", "#0f766e", "#2dd4bf", "", "", "", "", image, remove);
    }
    static AuthUser actor(boolean superAdmin, UUID impersonator) {
        return new AuthUser(UUID.randomUUID(), UUID.randomUUID(), "admin", Set.of("authorization:manage"),
                false, true, superAdmin, true, impersonator);
    }
}
