package com.uten.imp.features.admin.platformsetting;

import com.uten.imp.application.port.CompanyBrandingReadPort;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.config.props.StorageProperties;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import java.net.URI;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Objects;
import java.util.Optional;

@Service
@RequiredArgsConstructor
public class PlatformSettingsService implements CompanyBrandingReadPort {
    private final PlatformBrandingRepository repository;
    private final SecurityContextCurrentUser currentUser;
    private final TxSessionVars tx;
    private final AuditService audit;
    private final StorageProperties storage;

    @Transactional(readOnly = true)
    public PlatformBrandingDto current() { return repository.current(); }

    @Override
    @Transactional(readOnly = true)
    public CompanyBrandingReadPort.Identity currentIdentity() {
        PlatformBrandingDto value = repository.current();
        List<String> aliases = value.companyAliases().isEmpty() ? List.of() : List.of(value.companyAliases().split("\n"));
        return new CompanyBrandingReadPort.Identity(value.version(), value.companyName(), aliases);
    }

    @Transactional(readOnly = true)
    public Optional<byte[]> logo(Integer version) { return repository.logo(version); }

    @Transactional
    @PreAuthorize("hasAuthority('authorization:manage') and principal.superAdmin and !principal.visitor")
    public PlatformBrandingDto update(PlatformBrandingDto.Update request) {
        AuthUser actor = currentUser.get().filter(user -> user.isSuperAdmin() && !user.isVisitor()
                        && user.getImpersonatedBy() == null && !user.isMustChangePassword()
                        && user.getPermissions().contains("authorization:manage"))
                .orElseThrow(() -> new ApiException(ErrorCode.FORBIDDEN));
        PlatformBrandingDto.Update normalized = normalize(request);
        byte[] replacement = normalized.logoBase64() == null ? null : PlatformLogoImage.decode(normalized.logoBase64());
        PlatformBrandingRepository.Locked locked = repository.lock();
        PlatformBrandingDto before = locked.dto();
        if (before.version() != normalized.expectedVersion())
            throw new ApiException(ErrorCode.CONFLICT, "平台设置已被修改，请刷新后重新确认");
        if (before.version() == Integer.MAX_VALUE)
            throw new ApiException(ErrorCode.CONFLICT, "平台设置版本已达到上限，请联系管理员");
        byte[] logo = normalized.removeLogo() ? null : replacement == null ? locked.logo() : replacement;
        String digest = logo == null ? null : replacement == null ? locked.logoSha256() : PlatformLogoImage.sha256(logo);
        tx.bindActor(actor.getId(), actor.getLoginAccount());
        PlatformBrandingDto saved = repository.save(normalized, logo, digest, actor.getId());
        List<String> fields = changedFields(before, saved);
        boolean logoChanged = !Objects.equals(locked.logoSha256(), digest);
        if (logoChanged) fields.add("logo");
        audit.logCommittedChange(actor.getId(), actor.getLoginAccount(), "update_system_setting",
                "platform_branding", "1", "success", Map.of("changedFields", List.copyOf(fields),
                        "previousVersion", before.version(), "version", saved.version(), "logoChanged", logoChanged));
        return saved;
    }

    /** Deployment capabilities are configuration facts, not a storage/scanner health claim. */
    @PreAuthorize("hasAuthority('authorization:manage') and principal.superAdmin and !principal.visitor")
    public Status status() {
        return new Status(repository.databaseConnected(), "DATABASE", PlatformLogoImage.MAX_BYTES,
                PlatformLogoImage.MAX_DIMENSION, storage.getProvider(), storage.isUploadsEnabled());
    }

    public record Status(boolean databaseConnected, String logoStorage, int maxLogoBytes,
                         int maxLogoDimension, String attachmentStorageBackend,
                         boolean attachmentUploadsEnabled) {}

    static PlatformBrandingDto.Update normalize(PlatformBrandingDto.Update request) {
        if (request == null || request.expectedVersion() < 0) throw invalid("请刷新平台设置后重试");
        if (request.removeLogo() && request.logoBase64() != null)
            throw invalid("不能同时替换和移除 Logo，请重新选择操作");
        String company = text(request.companyName(), 1, 120, "公司名称", false);
        String aliases = normalizeAliases(request.companyAliases());
        String platform = text(request.platformName(), 1, 80, "平台名称", false);
        String tagline = text(request.tagline(), 0, 160, "品牌标语", false);
        String notice = text(request.loginNotice(), 0, 500, "登录提示", true);
        String phone = text(request.supportPhone(), 0, 50, "联系电话", false);
        String email = text(request.supportEmail(), 0, 120, "联系邮箱", false);
        if (!email.isEmpty() && !email.matches("[^\\s@]+@[^\\s@]+\\.[^\\s@]+")) throw invalid("联系邮箱格式无效");
        String website = text(request.website(), 0, 200, "公司网站", false);
        if (!website.isEmpty()) {
            try {
                URI uri = URI.create(website);
                if (!"https".equalsIgnoreCase(uri.getScheme()) || uri.getHost() == null || uri.getUserInfo() != null)
                    throw invalid("公司网站须为完整的 HTTPS 地址");
            } catch (IllegalArgumentException invalidUri) { throw invalid("公司网站须为完整的 HTTPS 地址"); }
        }
        return new PlatformBrandingDto.Update(request.expectedVersion(), company, aliases, platform, tagline,
                color(request.primaryColor(), "主题色"), color(request.secondaryColor(), "副主题色"),
                notice, phone, email, website, request.logoBase64(), request.removeLogo());
    }

    private static String text(String value, int min, int max, String label, boolean multiline) {
        if (value == null) throw invalid(label + "不能为空");
        String result = value.trim();
        if (result.length() < min || result.length() > max) throw invalid(label + "长度须在 " + min + " 至 " + max + " 个字符之间");
        if (result.chars().anyMatch(ch -> Character.isISOControl(ch) && !(multiline && (ch == '\n' || ch == '\r' || ch == '\t'))))
            throw invalid(label + "包含无效字符");
        return result;
    }

    private static String color(String value, String label) {
        if (value == null || !value.trim().matches("#[0-9a-fA-F]{6}")) throw invalid(label + "须为 #RRGGBB 颜色");
        return value.trim().toUpperCase(Locale.ROOT);
    }

    static String normalizeAliases(String value) {
        if (value == null || value.length() > 500) throw invalid("公司别名最多 500 个字符");
        String normalized = value.replace("\r\n", "\n");
        if (normalized.chars().anyMatch(ch -> Character.isISOControl(ch) && ch != '\n'))
            throw invalid("公司别名请按换行填写，不得包含其他控制字符");
        var names = new LinkedHashMap<String, String>();
        for (String line : normalized.split("\n", -1)) {
            String name = line.strip();
            if (name.isEmpty()) continue;
            if (name.length() < 2 || name.length() > 120) throw invalid("每个公司别名须为 2 至 120 个字符");
            names.putIfAbsent(name.toLowerCase(Locale.ROOT), name);
        }
        if (names.size() > 16) throw invalid("公司别名最多填写 16 个不同名称");
        return String.join("\n", names.values());
    }

    private static List<String> changedFields(PlatformBrandingDto a, PlatformBrandingDto b) {
        var result = new ArrayList<String>();
        if (!Objects.equals(a.companyName(), b.companyName())) result.add("companyName");
        if (!Objects.equals(a.companyAliases(), b.companyAliases())) result.add("companyAliases");
        if (!Objects.equals(a.platformName(), b.platformName())) result.add("platformName");
        if (!Objects.equals(a.tagline(), b.tagline())) result.add("tagline");
        if (!Objects.equals(a.primaryColor(), b.primaryColor())) result.add("primaryColor");
        if (!Objects.equals(a.secondaryColor(), b.secondaryColor())) result.add("secondaryColor");
        if (!Objects.equals(a.loginNotice(), b.loginNotice())) result.add("loginNotice");
        if (!Objects.equals(a.supportPhone(), b.supportPhone())) result.add("supportPhone");
        if (!Objects.equals(a.supportEmail(), b.supportEmail())) result.add("supportEmail");
        if (!Objects.equals(a.website(), b.website())) result.add("website");
        return result;
    }

    private static ApiException invalid(String message) { return new ApiException(ErrorCode.VALIDATION_FAILED, message); }
}
