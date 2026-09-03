package com.uten.imp.features.admin.systemtest;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

/**
 * 工作台「清空业务数据」的运行配置开关。
 *
 * <p>默认关闭（生产/云端 fail closed）；仅 {@code dev} 与 {@code internal-test}
 * profile 显式开启，对应「本地开发库」与「内网测试服务器」两类目标库。
 * 公司目标库（prod）不配置此开关，端点直接拒绝执行。</p>
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
