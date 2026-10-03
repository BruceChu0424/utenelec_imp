package com.uten.imp.features.ai.provider;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.ai.AiProperties;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecretCipher;
import lombok.extern.slf4j.Slf4j;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.orm.ObjectOptimisticLockingFailureException;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.Clock;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;
import java.util.regex.Pattern;

/**
 * AI 服务商配置(ADR-133)。短事务、事务内从不发网络请求; 密钥只写不读, 审计只记非密钥信息。
 *
 * <p>写入规则: 名称大小写不敏感唯一; 接口地址过防 SSRF 规则, 有登记域名的预设必须落在登记域名内;
 * 境外服务商需要服务端开关 + 数据出境确认; 改了接口协议或地址必须重新填写或清除密钥(已保存的密钥
 * 只发往保存时的地址); 第一个服务商自动成为默认; 默认服务商只有在它是最后一个时才能删除。
 */
@Service
@Slf4j
public class AiProviderService {

    static final String KEY_UNREADABLE_MESSAGE =
            "AI 服务的密钥无法解密(可能来自其他环境或密钥已轮换), 请在 AI 服务设置中重新填写";

    private static final Pattern PRINTABLE_ASCII = Pattern.compile("^[\\x21-\\x7e]+$");
    private static final int MAX_KEY_LENGTH = 512;
    private static final int LAST4_MIN_KEY_LENGTH = 20;
    private static final com.fasterxml.jackson.databind.ObjectMapper HISTORY_JSON=new com.fasterxml.jackson.databind.ObjectMapper();

    private final AiProviderRepository repository;
    private final SecretCipher cipher;
    private final AiProperties properties;
    private final AuditService audit;
    private final NamedParameterJdbcTemplate jdbc;
    private final Clock clock;
    private final Map<UUID, String> protocolCompatibilityWarnings = new java.util.concurrent.ConcurrentHashMap<>();

    public AiProviderService(AiProviderRepository repository, SecretCipher cipher, AiProperties properties,
                             AuditService audit, NamedParameterJdbcTemplate jdbc, Clock clock) {
        this.repository = repository;
        this.cipher = cipher;
        this.properties = properties;
        this.audit = audit;
        this.jdbc = jdbc;
        this.clock = clock;
    }

    // ------------------------------------------------------------------ 读取

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('authorization:manage') and principal.superAdmin")
    public List<AiProviderDtos.ProviderView> list() {
        List<AiProvider> rows = repository.findAllOrdered();
        Map<UUID, String> names = actorNames(rows);
        return rows.stream().map(row -> view(row, names.get(row.getUpdatedBy()))).toList();
    }

    @Transactional(readOnly=true)
    @PreAuthorize("hasAuthority('authorization:manage') and principal.superAdmin")
    public List<AiProviderDtos.ProviderHistoryView> listHistory(boolean onlyDeleted) {
        return repository.findAllHistory(onlyDeleted).stream().map(row->historyView(row,List.of(),null)).toList();
    }
    @Transactional(readOnly=true)
    @PreAuthorize("hasAuthority('authorization:manage') and principal.superAdmin")
    public AiProviderDtos.ProviderHistoryView history(UUID id,Long beforeId,int size) {
        AiProvider row=repository.findById(id).orElseThrow(()->new ApiException(ErrorCode.NOT_FOUND));
        int limit=Math.max(1,Math.min(50,size));
        List<AiProviderDtos.ProviderRevision> versions=jdbc.query("""
                SELECT id,recorded_at,actor_id,operation,public_payload::text AS configuration
                FROM ai_provider_history WHERE provider_id=:id AND (:beforeId IS NULL OR id<:beforeId)
                ORDER BY id DESC LIMIT :limit
                """,new MapSqlParameterSource("id",id).addValue("beforeId",beforeId,java.sql.Types.BIGINT).addValue("limit",limit),
                (rs,index)->new AiProviderDtos.ProviderRevision(rs.getLong("id"),rs.getObject("recorded_at",OffsetDateTime.class),
                    rs.getObject("actor_id",UUID.class),rs.getString("operation"),safeHistoryConfiguration(rs.getString("configuration")),true));
        return historyView(row,versions,versions.size()==limit?versions.getLast().id():null);
    }
    private static Map<String,Object> safeHistoryConfiguration(String text) {
        try{return HISTORY_JSON.readValue(text,new com.fasterxml.jackson.core.type.TypeReference<Map<String,Object>>(){});}
        catch(java.io.IOException failure){throw new ApiException(ErrorCode.CONFLICT,"历史服务配置无法读取，请核对保留记录");}
    }
    private AiProviderDtos.ProviderHistoryView historyView(AiProvider row,List<AiProviderDtos.ProviderRevision> versions,Long cursor) {
        String deletedByName=null;
        if(row.getDeletedBy()!=null){
            var names=jdbc.query("SELECT e.full_name FROM users u LEFT JOIN employees e ON e.id=u.employee_id WHERE u.id=:id",
                new MapSqlParameterSource("id",row.getDeletedBy()),(rs,index)->rs.getString(1));
            if(!names.isEmpty())deletedByName=names.getFirst();
        }
        return new AiProviderDtos.ProviderHistoryView(view(row,null),row.isDeleted(),row.getDeletedAt(),row.getDeletedBy(),deletedByName,
            row.getDeletedReason(),true,versions,cursor);
    }

    @PreAuthorize("hasAuthority('authorization:manage') and principal.superAdmin")
    public AiProviderDtos.PresetsView presets() {
        List<AiProviderDtos.PresetView> presets = new ArrayList<>();
        for (AiProviderPreset preset : AiProviderPreset.values()) {
            String reason = null;
            if (preset.region() == AiRegion.OVERSEAS && !properties.isAllowOverseasProviders()) {
                reason = "服务器没有开启境外 AI 服务(客户资料会出境, 需要先完成数据出境评估, 再由运维开启)";
            } else if (preset.region() != AiRegion.LOCAL && preset.region() != null
                    && !properties.isOutboundEnabled()) {
                reason = "这台服务器关闭了对外 AI 调用, 只能使用本机部署的服务";
            }
            presets.add(new AiProviderDtos.PresetView(
                    preset.name(),
                    preset.label(),
                    preset.region() == null ? null : preset.region().name(),
                    preset.protocol().name(),
                    preset.defaultBaseUrl(),
                    preset.suggestedModels(),
                    preset.jsonMode().name(),
                    preset.thinkingControl().name(),
                    preset.sendTemperature(),
                    preset.supportsVision(),
                    preset.requiresApiKey(preset.region() == null ? AiRegion.MAINLAND : preset.region()),
                    preset.registeredDomains(),
                    reason == null,
                    reason));
        }
        return new AiProviderDtos.PresetsView(
                presets,
                properties.isAllowOverseasProviders(),
                properties.isAllowLanHttp(),
                properties.isOutboundEnabled(),
                "客户资料(公司名、货品描述)会发送到境外服务商, 我已确认完成数据出境评估");
    }

    /**
     * 网关用: 当前默认服务商的运行配置(已解密密钥), 或不可用原因。只读短事务, 不发网络请求。
     */
    @Transactional(readOnly = true)
    public Resolution resolveDefault() {
        Optional<AiProvider> found = repository.findDefault();
        if (found.isEmpty()) {
            return Resolution.unavailable(null, null, false, "还没有配置默认的 AI 服务");
        }
        AiProvider row = found.get();
        if (!row.isEnabled()) {
            return Resolution.unavailable(row.getName(), row.getModel(), row.isSupportsVision(),
                    "默认的 AI 服务已停用");
        }
        String regionBlock = regionBlockReason(row.getRegion());
        if (regionBlock != null) {
            return Resolution.unavailable(row.getName(), row.getModel(), row.isSupportsVision(), regionBlock);
        }
        AiEndpointPolicy.Endpoint endpoint;
        try {
            endpoint = AiEndpointPolicy.validateConfigured(row.getBaseUrl(), row.getRegion(),
                    properties.isAllowLanHttp());
        } catch (AiEndpointPolicy.PolicyViolation e) {
            return Resolution.unavailable(row.getName(), row.getModel(), row.isSupportsVision(),
                    "默认 AI 服务的接口地址不符合安全规则: " + e.getMessage());
        }
        String apiKey = null;
        if (row.getSecret() != null) {
            try {
                apiKey = cipher.decrypt(row.getSecret(), AiProvider.secretAad(row.getId()));
            } catch (SecretCipher.SecretUnreadableException e) {
                return Resolution.unavailable(row.getName(), row.getModel(), row.isSupportsVision(),
                        KEY_UNREADABLE_MESSAGE);
            } catch (IllegalStateException e) {
                return Resolution.unavailable(row.getName(), row.getModel(), row.isSupportsVision(),
                        "服务器没有配置密钥加密, 请联系运维");
            }
        } else if (row.getPreset().requiresApiKey(row.getRegion())) {
            return Resolution.unavailable(row.getName(), row.getModel(), row.isSupportsVision(),
                    "默认的 AI 服务还没有填写密钥");
        }
        return Resolution.available(runtime(row, endpoint, apiKey));
    }

    /**
     * 连接测试/获取模型(已保存的密钥): 只用保存的协议、地址与模型; 页面带来的值与保存的不一致即 422。
     */
    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('authorization:manage') and principal.superAdmin")
    public AiProviderRuntime storedRuntime(UUID id, AiProviderDtos.StoredProbeRequest check) {
        AiProvider row = repository.findById(id).filter(provider->!provider.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "这个 AI 服务已被删除, 请刷新页面"));
        if (check != null) {
            if (check.protocol() != null && !check.protocol().isBlank()
                    && !row.getProtocol().name().equalsIgnoreCase(check.protocol().trim())) {
                throw keyMustBeRetyped();
            }
            if (check.baseUrl() != null && !check.baseUrl().isBlank()
                    && !Objects.equals(AiEndpointPolicy.normalizeOrNull(check.baseUrl()),
                    AiEndpointPolicy.normalizeOrNull(row.getBaseUrl()))) {
                throw keyMustBeRetyped();
            }
            if (check.model() != null && !check.model().isBlank() && !row.getModel().equals(check.model().trim())) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "模型名称已修改, 请先保存再用已保存的密钥测试");
            }
        }
        requireRegionAllowed(row.getRegion());
        AiEndpointPolicy.Endpoint endpoint = endpointOrThrow(row.getBaseUrl(), row.getRegion());
        String apiKey = null;
        if (row.getSecret() != null) {
            try {
                apiKey = cipher.decrypt(row.getSecret(), AiProvider.secretAad(row.getId()));
            } catch (SecretCipher.SecretUnreadableException e) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, KEY_UNREADABLE_MESSAGE);
            }
        } else if (row.getPreset().requiresApiKey(row.getRegion())) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "还没有保存密钥, 请先填写密钥");
        }
        return runtime(row, endpoint, apiKey);
    }

    /** 连接测试/获取模型(本次填写的密钥): 不读任何已保存配置。 */
    public AiProviderRuntime probeRuntime(AiProviderDtos.ProbeRequest request) {
        if (request == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "请填写 AI 服务信息");
        }
        AiProviderPreset preset = requirePreset(request.preset());
        AiRegion region = effectiveRegion(preset, request.region());
        requireRegionAllowed(region);
        if (region == AiRegion.OVERSEAS && !Boolean.TRUE.equals(request.overseasAcknowledged())) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "请先勾选数据出境确认");
        }
        AiProtocol protocol = parseEnum(AiProtocol.class, request.protocol(), preset.protocol(), "接口协议");
        AiEndpointPolicy.Endpoint endpoint = endpointOrThrow(request.baseUrl(), region);
        requireRegisteredDomain(preset, endpoint);
        requireCompatibleProtocol(preset, protocol, endpoint);
        String model = request.model() == null || request.model().isBlank()
                ? "" : requireModel(request.model());
        String apiKey = normalizeKey(request.apiKey());
        if (apiKey == null && preset.requiresApiKey(region)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "请填写密钥后再测试");
        }
        AiJsonMode jsonMode = parseEnum(AiJsonMode.class, request.jsonMode(), preset.jsonMode(), "JSON 输出方式");
        AiThinkingControl thinking = parseEnum(AiThinkingControl.class, request.thinkingControl(),
                preset.thinkingControl(), "关闭深度思考方式");
        boolean temperature = request.sendTemperature() == null ? preset.sendTemperature() : request.sendTemperature();
        int timeout = boundedInt(request.timeoutSeconds(), 120, 10, 600, "超时秒数");
        return new AiProviderRuntime(null, "连接测试", preset, region, protocol, endpoint, model, apiKey,
                jsonMode, thinking, temperature, false, 256, timeout);
    }

    // ------------------------------------------------------------------ 写入

    @Transactional
    @PreAuthorize("hasAuthority('authorization:manage') and principal.superAdmin")
    public AiProviderDtos.ProviderView create(AiProviderDtos.ProviderRequest request, AuthUser actor) {
        Validated input = validate(request, null);
        lockProviderWrites();
        List<AiProvider> all = repository.lockAll();
        requireUniqueName(input.name(), null);
        AiProvider row = new AiProvider();
        row.setId(UUID.randomUUID());
        apply(row, input);
        if (input.apiKey() == null && input.preset().requiresApiKey(input.region())) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "请填写密钥");
        }
        if (input.apiKey() != null) {
            storeKey(row, input.apiKey());
        }
        OffsetDateTime now = OffsetDateTime.now(clock);
        if (input.region() == AiRegion.OVERSEAS) {
            row.setOverseasAckAt(now);
            row.setOverseasAckBy(actor.getId());
        }
        row.setDefault(all.stream().noneMatch(AiProvider::isDefault));
        row.setCreatedAt(now);
        row.setCreatedBy(actor.getId());
        row.setUpdatedAt(now);
        row.setUpdatedBy(actor.getId());
        AiProvider saved = saveUnique(row);
        String detail = "新增 AI 服务「" + saved.getName() + "」(" + saved.getPreset().label() + ", 模型 "
                + saved.getModel() + ")" + (saved.isDefault() ? ", 设为默认" : "")
                + (saved.getSecret() == null ? ", 未填写密钥" : keyChangedText(saved))
                + (saved.getRegion() == AiRegion.OVERSEAS ? ", 已确认数据出境评估" : "");
        auditChange(actor, "ai_provider.create", saved, detail);
        return view(saved, null);
    }

    @Transactional
    @PreAuthorize("hasAuthority('authorization:manage') and principal.superAdmin")
    public AiProviderDtos.ProviderView update(UUID id, AiProviderDtos.ProviderRequest request, AuthUser actor) {
        if (request == null || request.version() == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "请刷新页面后再保存");
        }
        lockProviderWrites();
        AiProvider row = repository.findById(id).filter(provider->!provider.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "这个 AI 服务已被删除, 请刷新页面"));
        requireVersion(row, request.version());
        Validated input = validate(request, row);
        requireUniqueName(input.name(), row.getId());

        boolean clearKey = Boolean.TRUE.equals(request.clearApiKey());
        if (clearKey && input.apiKey() != null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "不能同时填写新密钥和清除密钥");
        }
        boolean endpointChanged = row.getProtocol() != input.protocol()
                || !Objects.equals(AiEndpointPolicy.normalizeOrNull(row.getBaseUrl()), input.endpoint().normalized());
        if (endpointChanged && row.getSecret() != null && input.apiKey() == null && !clearKey) {
            throw keyMustBeRetyped();
        }
        List<String> changes = describeChanges(row, input);
        AiRegion previousRegion = row.getRegion();
        apply(row, input);
        String keyText = "";
        if (input.apiKey() != null) {
            storeKey(row, input.apiKey());
            keyText = keyChangedText(row);
        } else if (clearKey && row.getSecret() != null) {
            row.setSecret(null);
            row.setApiKeyLast4(null);
            keyText = ", 密钥已清除";
        }
        if (row.getSecret() == null && row.getPreset().requiresApiKey(row.getRegion())) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "请填写密钥");
        }
        OffsetDateTime now = OffsetDateTime.now(clock);
        if (row.getRegion() == AiRegion.OVERSEAS) {
            if (previousRegion != AiRegion.OVERSEAS || endpointChanged || row.getOverseasAckAt() == null) {
                row.setOverseasAckAt(now);
                row.setOverseasAckBy(actor.getId());
                changes.add("重新确认数据出境评估");
            }
        } else {
            row.setOverseasAckAt(null);
            row.setOverseasAckBy(null);
        }
        if (endpointChanged) {
            row.setLastTestAt(null);
            row.setLastTestOk(null);
            row.setLastTestMessage(null);
        }
        row.setUpdatedAt(now);
        row.setUpdatedBy(actor.getId());
        AiProvider saved = saveUnique(row);
        String detail = "修改 AI 服务「" + saved.getName() + "」"
                + (changes.isEmpty() ? "" : ": " + String.join("; ", changes)) + keyText;
        auditChange(actor, "ai_provider.update", saved, detail);
        return view(saved, null);
    }

    @Transactional
    @PreAuthorize("hasAuthority('authorization:manage') and principal.superAdmin")
    public void delete(UUID id, Long version, AuthUser actor) {
        lockProviderWrites();
        List<AiProvider> all = repository.lockAll();
        AiProvider row = all.stream().filter(p -> p.getId().equals(id)).findFirst()
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "这个 AI 服务已被删除, 请刷新页面"));
        if (version != null) {
            requireVersion(row, version);
        }
        if (row.isDefault() && all.size() > 1) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "这是默认的 AI 服务, 请先把别的服务设为默认再删除");
        }
        row.setDeleted(true);row.setDeletedAt(OffsetDateTime.now(clock));row.setDeletedBy(actor.getId());
        row.setUpdatedAt(OffsetDateTime.now(clock));row.setUpdatedBy(actor.getId());
        row.setDeletedReason("USER_LOGICAL_DELETE");row.setEnabled(false);row.setDefault(false);repository.save(row);
        repository.flush();
        auditChange(actor, "ai_provider.delete", row,
                "删除 AI 服务「" + row.getName() + "」(" + row.getPreset().label() + ")");
    }

    @Transactional
    @PreAuthorize("hasAuthority('authorization:manage') and principal.superAdmin")
    public AiProviderDtos.ProviderView setDefault(UUID id, Long version, AuthUser actor) {
        lockProviderWrites();
        List<AiProvider> all = repository.lockAll();
        AiProvider target = all.stream().filter(p -> p.getId().equals(id)).findFirst()
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "这个 AI 服务已被删除, 请刷新页面"));
        if (version != null) {
            requireVersion(target, version);
        }
        if (!target.isEnabled()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "请先启用这个 AI 服务再设为默认");
        }
        if (target.isDefault()) {
            return view(target, null);
        }
        OffsetDateTime now = OffsetDateTime.now(clock);
        String previous = null;
        for (AiProvider other : all) {
            if (other.isDefault()) {
                previous = other.getName();
                other.setDefault(false);
                other.setUpdatedAt(now);
                other.setUpdatedBy(actor.getId());
            }
        }
        // 部分唯一索引(至多一个默认)逐行检查: 先把旧默认写掉再设新默认。
        repository.flush();
        target.setDefault(true);
        target.setUpdatedAt(now);
        target.setUpdatedBy(actor.getId());
        repository.flush();
        auditChange(actor, "ai_provider.set_default", target,
                "把「" + target.getName() + "」设为默认 AI 服务"
                        + (previous == null ? "" : "(原默认「" + previous + "」)"));
        return view(target, null);
    }

    @Transactional
    @PreAuthorize("hasAuthority('authorization:manage') and principal.superAdmin")
    public AiProviderDtos.ProviderView setEnabled(UUID id, boolean enabled, Long version, AuthUser actor) {
        lockProviderWrites();
        AiProvider row = repository.findById(id).filter(provider->!provider.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "这个 AI 服务已被删除, 请刷新页面"));
        if (version != null) {
            requireVersion(row, version);
        }
        if (row.isEnabled() == enabled) {
            return view(row, null);
        }
        row.setEnabled(enabled);
        row.setUpdatedAt(OffsetDateTime.now(clock));
        row.setUpdatedBy(actor.getId());
        repository.flush();
        auditChange(actor, "ai_provider.set_enabled", row,
                (enabled ? "启用" : "停用") + " AI 服务「" + row.getName() + "」"
                        + (row.isDefault() && !enabled ? "(默认服务已停用, AI 识别暂不可用)" : ""));
        return view(row, null);
    }

    /**
     * 记录「用已保存的密钥」做的连接测试结果。只在测试期间配置没有被改过(版本未变)时写入;
     * 不改版本号, 不影响正在打开的编辑表单。
     */
    @Transactional
    @PreAuthorize("hasAuthority('authorization:manage') and principal.superAdmin")
    public void recordStoredTest(UUID id, long testedVersion, boolean ok, String message, OffsetDateTime at) {
        jdbc.update("""
                UPDATE ai_providers
                SET last_test_at = :at, last_test_ok = :ok, last_test_message = :message
                WHERE id = :id AND version = :version AND NOT is_deleted
                """, new MapSqlParameterSource()
                .addValue("at", at)
                .addValue("ok", ok)
                .addValue("message", truncate(message, 500))
                .addValue("id", id)
                .addValue("version", testedVersion));
    }

    /** 当前版本号(连接测试开始前记下, 结束后按它条件写入)。 */
    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('authorization:manage') and principal.superAdmin")
    public long currentVersion(UUID id) {
        return repository.findById(id).map(AiProvider::getVersion)
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "这个 AI 服务已被删除, 请刷新页面"));
    }

    // ------------------------------------------------------------------ 内部

    /** 网关解析结果。 */
    public record Resolution(AiProviderRuntime runtime, String providerName, String model, boolean supportsVision,
                             String unavailableReason) {
        static Resolution available(AiProviderRuntime runtime) {
            return new Resolution(runtime, runtime.name(), runtime.model(), runtime.supportsVision(), null);
        }

        static Resolution unavailable(String providerName, String model, boolean supportsVision, String reason) {
            return new Resolution(null, providerName, model, supportsVision, reason);
        }

        public boolean available() {
            return runtime != null;
        }
    }

    private record Validated(String name, AiProviderPreset preset, AiRegion region, AiProtocol protocol,
                             AiEndpointPolicy.Endpoint endpoint, String baseUrl, String model, String apiKey,
                             AiJsonMode jsonMode, AiThinkingControl thinkingControl, boolean sendTemperature,
                             boolean supportsVision, int maxOutputTokens, int timeoutSeconds, boolean enabled) {
    }

    private Validated validate(AiProviderDtos.ProviderRequest request, AiProvider existing) {
        if (request == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "请填写 AI 服务信息");
        }
        String name = request.name() == null ? "" : request.name().trim();
        if (name.isEmpty() || name.length() > 64 || name.chars().anyMatch(Character::isISOControl)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "显示名称必须填写, 不超过 64 个字");
        }
        AiProviderPreset preset = requirePreset(request.preset());
        AiRegion region = effectiveRegion(preset, request.region());
        requireRegionAllowed(region);
        if (region == AiRegion.OVERSEAS && !Boolean.TRUE.equals(request.overseasAcknowledged())) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "请勾选数据出境确认后再保存");
        }
        AiProtocol protocol = parseEnum(AiProtocol.class, request.protocol(), preset.protocol(), "接口协议");
        AiEndpointPolicy.Endpoint endpoint = endpointOrThrow(request.baseUrl(), region);
        requireRegisteredDomain(preset, endpoint);
        requireCompatibleProtocol(preset, protocol, endpoint);
        String model = requireModel(request.model());
        String apiKey = normalizeKey(request.apiKey());
        AiJsonMode jsonMode = parseEnum(AiJsonMode.class, request.jsonMode(),
                existing == null ? preset.jsonMode() : existing.getJsonMode(), "JSON 输出方式");
        AiThinkingControl thinking = parseEnum(AiThinkingControl.class, request.thinkingControl(),
                existing == null ? preset.thinkingControl() : existing.getThinkingControl(), "关闭深度思考方式");
        boolean temperature = request.sendTemperature() != null ? request.sendTemperature()
                : existing == null ? preset.sendTemperature() : existing.isSendTemperature();
        boolean vision = request.supportsVision() != null ? request.supportsVision()
                : existing == null ? preset.supportsVision() : existing.isSupportsVision();
        int maxTokens = boundedInt(request.maxOutputTokens(),
                existing == null ? 8192 : existing.getMaxOutputTokens(), 256, 65536, "最大输出长度");
        int timeout = boundedInt(request.timeoutSeconds(),
                existing == null ? 120 : existing.getTimeoutSeconds(), 10, 600, "超时秒数");
        boolean enabled = request.enabled() != null ? request.enabled() : existing == null || existing.isEnabled();
        return new Validated(name, preset, region, protocol, endpoint, request.baseUrl().trim(), model, apiKey,
                jsonMode, thinking, temperature, vision, maxTokens, timeout, enabled);
    }

    private void apply(AiProvider row, Validated input) {
        row.setName(input.name());
        row.setPreset(input.preset());
        row.setRegion(input.region());
        row.setProtocol(input.protocol());
        row.setBaseUrl(input.endpoint().normalized());
        row.setModel(input.model());
        row.setJsonMode(input.jsonMode());
        row.setThinkingControl(input.thinkingControl());
        row.setSendTemperature(input.sendTemperature());
        row.setSupportsVision(input.supportsVision());
        row.setMaxOutputTokens(input.maxOutputTokens());
        row.setTimeoutSeconds(input.timeoutSeconds());
        row.setEnabled(input.enabled());
    }

    private List<String> describeChanges(AiProvider row, Validated input) {
        List<String> changes = new ArrayList<>();
        if (!row.getName().equals(input.name())) {
            changes.add("名称 " + row.getName() + " → " + input.name());
        }
        if (row.getPreset() != input.preset()) {
            changes.add("服务商 " + row.getPreset().label() + " → " + input.preset().label());
        }
        if (row.getRegion() != input.region()) {
            changes.add("区域 " + regionLabel(row.getRegion()) + " → " + regionLabel(input.region()));
        }
        if (row.getProtocol() != input.protocol()) {
            changes.add("接口协议 " + row.getProtocol() + " → " + input.protocol());
        }
        if (!Objects.equals(AiEndpointPolicy.normalizeOrNull(row.getBaseUrl()), input.endpoint().normalized())) {
            changes.add("接口地址 " + row.getBaseUrl() + " → " + input.endpoint().normalized());
        }
        if (!row.getModel().equals(input.model())) {
            changes.add("模型 " + row.getModel() + " → " + input.model());
        }
        if (row.getJsonMode() != input.jsonMode()) {
            changes.add("JSON 输出方式 " + row.getJsonMode() + " → " + input.jsonMode());
        }
        if (row.getThinkingControl() != input.thinkingControl()) {
            changes.add("关闭深度思考 " + row.getThinkingControl() + " → " + input.thinkingControl());
        }
        if (row.isSendTemperature() != input.sendTemperature()) {
            changes.add("发送温度参数 " + yesNo(row.isSendTemperature()) + " → " + yesNo(input.sendTemperature()));
        }
        if (row.isSupportsVision() != input.supportsVision()) {
            changes.add("图片识别 " + yesNo(row.isSupportsVision()) + " → " + yesNo(input.supportsVision()));
        }
        if (row.getMaxOutputTokens() != input.maxOutputTokens()) {
            changes.add("最大输出长度 " + row.getMaxOutputTokens() + " → " + input.maxOutputTokens());
        }
        if (row.getTimeoutSeconds() != input.timeoutSeconds()) {
            changes.add("超时秒数 " + row.getTimeoutSeconds() + " → " + input.timeoutSeconds());
        }
        if (row.isEnabled() != input.enabled()) {
            changes.add(input.enabled() ? "启用" : "停用");
        }
        return changes;
    }

    private void storeKey(AiProvider row, String apiKey) {
        if (!cipher.available()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "服务器没有配置密钥加密, 请联系运维后再填写密钥");
        }
        row.setSecret(cipher.encrypt(apiKey, AiProvider.secretAad(row.getId())));
        row.setApiKeyLast4(apiKey.length() >= LAST4_MIN_KEY_LENGTH ? apiKey.substring(apiKey.length() - 4) : null);
    }

    private static String keyChangedText(AiProvider row) {
        return row.getApiKeyLast4() == null ? ", 密钥已更换" : ", 密钥已更换(尾号 " + row.getApiKeyLast4() + ")";
    }

    private AiProvider saveUnique(AiProvider row) {
        try {
            return repository.saveAndFlush(row);
        } catch (ObjectOptimisticLockingFailureException e) {
            throw new ApiException(ErrorCode.CONFLICT, "AI 服务配置已被别人修改, 请刷新后重试");
        } catch (DataIntegrityViolationException e) {
            String detail = String.valueOf(e.getMostSpecificCause().getMessage());
            if (detail.contains("uq_ai_providers_name")) {
                throw new ApiException(ErrorCode.CONFLICT, "已有同名的 AI 服务, 请换一个显示名称");
            }
            throw new ApiException(ErrorCode.CONFLICT, "AI 服务配置已被别人修改, 请刷新后重试");
        }
    }

    /**
     * 显式审计事件: 结果记 success(按成功操作分级), 名称与说明放进变更快照(审计详情可见), 从不含密钥或密文。
     */
    private void auditChange(AuthUser actor, String action, AiProvider row, String detail) {
        Map<String, Object> change = new LinkedHashMap<>();
        change.put("name", row.getName());
        change.put("detail", detail);
        audit.logCommittedChange(actor.getId(), actor.getLoginAccount(), action, "ai_providers",
                row.getId().toString(), "success", change);
    }

    /**
     * 服务商表的写入串行化(表只有几行): 「第一个服务商自动成为默认」「至多一个默认」「默认只在最后一个时可删」
     * 这些跨行规则在并发保存时也成立。事务级咨询锁, 随事务结束释放。
     */
    private void lockProviderWrites() {
        jdbc.query("SELECT pg_advisory_xact_lock(hashtext('ai_providers:write'))", new MapSqlParameterSource(),
                rs -> null);
    }

    private void requireUniqueName(String name, UUID excludeId) {
        UUID exclude = excludeId == null ? new UUID(0L, 0L) : excludeId;
        if (repository.existsByNameIgnoreCaseExcluding(name, exclude)) {
            throw new ApiException(ErrorCode.CONFLICT, "已有同名的 AI 服务, 请换一个显示名称");
        }
    }

    private static void requireVersion(AiProvider row, Long version) {
        if (!Objects.equals(row.getVersion(), version)) {
            throw new ApiException(ErrorCode.CONFLICT, "AI 服务配置已被别人修改, 请刷新后重试");
        }
    }

    private static ApiException keyMustBeRetyped() {
        return new ApiException(ErrorCode.VALIDATION_FAILED, "接口地址已修改, 请重新填写密钥");
    }

    private static AiProviderPreset requirePreset(String value) {
        return AiProviderPreset.parse(value)
                .orElseThrow(() -> new ApiException(ErrorCode.VALIDATION_FAILED, "请选择服务商"));
    }

    private static AiRegion effectiveRegion(AiProviderPreset preset, String requested) {
        if (preset.region() != null) {
            return preset.region();
        }
        return parseEnum(AiRegion.class, requested, null, "区域");
    }

    private void requireRegionAllowed(AiRegion region) {
        String reason = regionBlockReason(region);
        if (reason != null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, reason);
        }
    }

    private String regionBlockReason(AiRegion region) {
        if (region == AiRegion.OVERSEAS && !properties.isAllowOverseasProviders()) {
            return "服务器没有开启境外 AI 服务(客户资料会出境, 需要先完成数据出境评估, 再由运维开启)";
        }
        if (region != AiRegion.LOCAL && !properties.isOutboundEnabled()) {
            return "这台服务器关闭了对外 AI 调用, 只能使用本机部署的服务";
        }
        return null;
    }

    private AiEndpointPolicy.Endpoint endpointOrThrow(String baseUrl, AiRegion region) {
        try {
            return AiEndpointPolicy.validateConfigured(baseUrl, region, properties.isAllowLanHttp());
        } catch (AiEndpointPolicy.PolicyViolation e) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, e.getMessage());
        }
    }

    private static void requireRegisteredDomain(AiProviderPreset preset, AiEndpointPolicy.Endpoint endpoint) {
        if (!preset.acceptsHost(endpoint.host())) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "接口地址不属于「" + preset.label() + "」的登记域名(应为 "
                            + String.join(" / ", preset.registeredDomains())
                            + " 下的地址); 其他地址请选「" + AiProviderPreset.CUSTOM.label() + "」");
        }
    }

    private static void requireCompatibleProtocol(AiProviderPreset preset, AiProtocol protocol,
                                                   AiEndpointPolicy.Endpoint endpoint) {
        String reason = AiEndpointProtocolCompatibility.mismatch(preset, protocol, endpoint);
        if (reason != null) throw new ApiException(ErrorCode.VALIDATION_FAILED, reason);
    }

    private static String requireModel(String value) {
        String model = value == null ? "" : value.trim();
        if (model.isEmpty() || model.length() > 128 || !PRINTABLE_ASCII.matcher(model).matches()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "请填写模型名称(英文字母、数字和符号, 不超过 128 个字符)");
        }
        return model;
    }

    /** 空串视为没填; 其余必须是不含空格的可见 ASCII 字符。 */
    private static String normalizeKey(String value) {
        if (value == null) {
            return null;
        }
        String key = value.trim();
        if (key.isEmpty()) {
            return null;
        }
        if (key.length() > MAX_KEY_LENGTH || !PRINTABLE_ASCII.matcher(key).matches()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "密钥里有空格或特殊字符, 请从服务商后台重新复制");
        }
        return key;
    }

    private static <E extends Enum<E>> E parseEnum(Class<E> type, String value, E fallback, String label) {
        if (value == null || value.isBlank()) {
            if (fallback == null) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "请选择" + label);
            }
            return fallback;
        }
        try {
            return Enum.valueOf(type, value.trim().toUpperCase(java.util.Locale.ROOT));
        } catch (IllegalArgumentException e) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, label + "不对, 请重新选择");
        }
    }

    private static int boundedInt(Integer value, int fallback, int min, int max, String label) {
        int result = value == null ? fallback : value;
        if (result < min || result > max) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, label + "需在 " + min + " 到 " + max + " 之间");
        }
        return result;
    }

    private AiProviderRuntime runtime(AiProvider row, AiEndpointPolicy.Endpoint endpoint, String apiKey) {
        AiProtocol effective = AiEndpointProtocolCompatibility.effectiveProtocol(row.getPreset(), row.getProtocol(), endpoint);
        if (effective != row.getProtocol()) {
            String state = row.getProtocol().name() + ":" + effective.name();
            if (!state.equals(protocolCompatibilityWarnings.put(row.getId(), state))) {
                log.warn("AI canonical endpoint compatibility: providerId={}, configuredProtocol={}, effectiveProtocol={}; persisted configuration unchanged",
                        row.getId(), row.getProtocol(), effective);
            }
        } else protocolCompatibilityWarnings.remove(row.getId());
        return new AiProviderRuntime(row.getId(), row.getName(), row.getPreset(), row.getRegion(),
                effective, endpoint, row.getModel(), apiKey, row.getJsonMode(), row.getThinkingControl(),
                row.isSendTemperature(), row.isSupportsVision(), row.getMaxOutputTokens(), row.getTimeoutSeconds());
    }

    private AiProviderDtos.ProviderView view(AiProvider row, String updatedByName) {
        boolean configured = row.getSecret() != null;
        boolean unreadable = false;
        if (configured) {
            try {
                cipher.decrypt(row.getSecret(), AiProvider.secretAad(row.getId()));
            } catch (SecretCipher.SecretUnreadableException | IllegalStateException e) {
                unreadable = true;
            }
        }
        String masked = !configured ? null
                : row.getApiKeyLast4() == null ? "已配置" : "••••" + row.getApiKeyLast4();
        String name = updatedByName;
        if (name == null && row.getUpdatedBy() != null) {
            name = actorNames(List.of(row)).get(row.getUpdatedBy());
        }
        return new AiProviderDtos.ProviderView(
                row.getId(),
                row.getName(),
                row.getPreset().name(),
                row.getPreset().label(),
                row.getRegion().name(),
                row.getProtocol().name(),
                row.getBaseUrl(),
                row.getModel(),
                configured,
                masked,
                unreadable,
                row.getJsonMode().name(),
                row.getThinkingControl().name(),
                row.isSendTemperature(),
                row.isSupportsVision(),
                row.getMaxOutputTokens(),
                row.getTimeoutSeconds(),
                row.isEnabled(),
                row.isDefault(),
                row.getOverseasAckAt() != null,
                row.getLastTestAt(),
                row.getLastTestOk(),
                row.getLastTestMessage(),
                row.getVersion() == null ? 0L : row.getVersion(),
                row.getUpdatedAt(),
                name);
    }

    private Map<UUID, String> actorNames(List<AiProvider> rows) {
        Set<UUID> ids = new HashSet<>();
        for (AiProvider row : rows) {
            if (row.getUpdatedBy() != null) {
                ids.add(row.getUpdatedBy());
            }
        }
        if (ids.isEmpty()) {
            return Map.of();
        }
        Map<UUID, String> names = new HashMap<>();
        jdbc.query("""
                SELECT u.id, e.full_name
                FROM users u
                LEFT JOIN employees e ON e.id = u.employee_id
                WHERE u.id IN (:ids)
                """, new MapSqlParameterSource("ids", ids), rs -> {
            String fullName = rs.getString("full_name");
            if (fullName != null) {
                names.put(rs.getObject("id", UUID.class), fullName);
            }
        });
        return names;
    }

    private static String regionLabel(AiRegion region) {
        return switch (region) {
            case MAINLAND -> "境内";
            case OVERSEAS -> "境外";
            case LOCAL -> "本机部署";
        };
    }

    private static String yesNo(boolean value) {
        return value ? "是" : "否";
    }

    private static String truncate(String value, int max) {
        if (value == null || value.length() <= max) {
            return value;
        }
        return value.substring(0, max);
    }
}
