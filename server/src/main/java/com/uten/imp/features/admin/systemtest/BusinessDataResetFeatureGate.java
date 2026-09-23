package com.uten.imp.features.admin.systemtest;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.core.env.Environment;
import org.springframework.core.env.Profiles;
import org.springframework.stereotype.Component;

/**
 * 工作台「清空业务数据」的运行配置开关。
 *
 * <p>base/cloud 默认关闭（fail closed）；{@code dev} 与 {@code internal-test}
 * profile 显式开启。2026-09-12 用户拍板：测试阶段公司内网服务器（prod profile）
 * 同样放行（可用 {@code UTEN_BUSINESS_DATA_RESET_ENABLED=false} 临时停用），
 * 正式上线时整个 systemtest 功能随 ADR-067 一并删除。</p>
 *
 * <p>启动门禁 (ADR-110; security-06): prod profile 下开关打开时启动日志明确告警, 提醒这是测试期
 * 决定、上线前必须删除; 云端站点 (对公网开放) 不论开关如何一律视为关闭——{@code UTEN_PROFILE=cloud,prod}
 * 会继承 prod 的默认 true, 这里兜住「云端始终 fail closed」的承诺。</p>
 */
@Slf4j
@Component
public final class BusinessDataResetFeatureGate {

    public static final String PROPERTY = "uten.features.business-data-reset-enabled";

    private final boolean enabled;

    @org.springframework.beans.factory.annotation.Autowired
    public BusinessDataResetFeatureGate(
            @Value("$" + "{" + PROPERTY + ":false}") boolean enabled,
            @Value("$" + "{uten.deployment.site:local}") String site,
            Environment environment) {
        boolean cloudSite = "cloud".equalsIgnoreCase(site);
        if (enabled && cloudSite) {
            log.warn("云端站点忽略 {}=true：清空业务数据在云端始终关闭", PROPERTY);
        } else if (enabled && environment.acceptsProfiles(Profiles.of("prod"))) {
            log.warn("【测试期开关】生产 profile 已开启工作台「清空业务数据」({}=true)。"
                    + "这是 2026-09-12 测试期决定, 执行前需超管再认证 + 逐字口令; "
                    + "正式上线前必须按 ADR-067 删除整个系统测试功能。", PROPERTY);
        }
        this.enabled = enabled && !cloudSite;
    }

    public BusinessDataResetFeatureGate(boolean enabled) {
        this.enabled = enabled;
    }

    public boolean enabled() {
        return enabled;
    }

    public void requireEnabled() {
        if (!enabled) {
            throw new ApiException(
                    ErrorCode.FORBIDDEN,
                    "当前环境未开启业务数据清空（仅本地开发库与内网测试服务器可用）");
        }
    }
}
