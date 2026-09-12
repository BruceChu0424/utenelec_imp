package com.uten.imp.features.admin.systemtest;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

/**
 * 工作台「清空业务数据」的运行配置开关。
 *
 * <p>base/cloud 默认关闭（fail closed）；{@code dev} 与 {@code internal-test}
 * profile 显式开启。2026-09-12 用户拍板：测试阶段公司内网服务器（prod profile）
 * 同样放行（可用 {@code UTEN_BUSINESS_DATA_RESET_ENABLED=false} 临时停用），
 * 正式上线时整个 systemtest 功能随 ADR-067 一并删除。</p>
 */
@Component
public final class BusinessDataResetFeatureGate {

    public static final String PROPERTY = "uten.features.business-data-reset-enabled";

    private final boolean enabled;

    public BusinessDataResetFeatureGate(
            @Value("$" + "{" + PROPERTY + ":false}") boolean enabled) {
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
