package com.uten.imp.features.admin.platformsetting;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import lombok.RequiredArgsConstructor;
import org.springframework.dao.DataAccessException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Repository;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.OffsetDateTime;
import java.util.Optional;
import java.util.UUID;

@Repository
@RequiredArgsConstructor
class PlatformBrandingRepository {
    private static final String METADATA = """
            SELECT version,company_name,company_aliases,platform_name,tagline,primary_color,secondary_color,
                   login_notice,support_phone,support_email,website,
                   (logo_png IS NOT NULL) AS has_logo,updated_at
            FROM platform_branding WHERE id=1
            """;
    private final JdbcTemplate jdbc;

    PlatformBrandingDto current() {
        return jdbc.query(METADATA, (rs, index) -> dto(rs)).stream().findFirst()
                .orElseThrow(() -> new ApiException(ErrorCode.BUSINESS, "平台设置尚未初始化，请联系管理员"));
    }

    Locked lock() {
        return jdbc.query(METADATA.replace("updated_at\n", "updated_at,logo_png,logo_sha256\n") + " FOR UPDATE",
                        (rs, index) -> new Locked(dto(rs), rs.getBytes("logo_png"), rs.getString("logo_sha256")))
                .stream().findFirst()
                .orElseThrow(() -> new ApiException(ErrorCode.BUSINESS, "平台设置尚未初始化，请联系管理员"));
    }

    PlatformBrandingDto save(PlatformBrandingDto.Update update, byte[] logo, String sha256, UUID actorId) {
        int changed = jdbc.update("""
                UPDATE platform_branding SET company_name=?,company_aliases=?,platform_name=?,tagline=?,primary_color=?,
                    secondary_color=?,login_notice=?,support_phone=?,support_email=?,website=?,
                    logo_png=?,logo_sha256=?,updated_by=?,version=version+1,updated_at=CURRENT_TIMESTAMP
                WHERE id=1 AND version=?
                """, update.companyName(), update.companyAliases(), update.platformName(), update.tagline(), update.primaryColor(),
                update.secondaryColor(), update.loginNotice(), update.supportPhone(), update.supportEmail(),
                update.website(), logo, sha256, actorId, update.expectedVersion());
        if (changed != 1) throw new ApiException(ErrorCode.CONFLICT, "平台设置已被修改，请刷新后重新确认");
        return current();
    }

    Optional<byte[]> logo(Integer expectedVersion) {
        return jdbc.query("SELECT logo_png FROM platform_branding WHERE id=1 AND logo_png IS NOT NULL"
                        + (expectedVersion == null ? "" : " AND version=?"),
                (rs, index) -> rs.getBytes(1), expectedVersion == null ? new Object[0] : new Object[]{expectedVersion})
                .stream().findFirst();
    }

    boolean databaseConnected() {
        try { return Integer.valueOf(1).equals(jdbc.queryForObject("SELECT 1", Integer.class)); }
        catch (DataAccessException unavailable) { return false; }
    }

    private static PlatformBrandingDto dto(ResultSet rs) throws SQLException {
        return new PlatformBrandingDto(rs.getInt("version"), rs.getString("company_name"),
                rs.getString("company_aliases"), rs.getString("platform_name"), rs.getString("tagline"), rs.getString("primary_color"),
                rs.getString("secondary_color"), rs.getString("login_notice"), rs.getString("support_phone"),
                rs.getString("support_email"), rs.getString("website"), rs.getBoolean("has_logo"),
                rs.getObject("updated_at", OffsetDateTime.class));
    }

    record Locked(PlatformBrandingDto dto, byte[] logo, String logoSha256) {}
}
