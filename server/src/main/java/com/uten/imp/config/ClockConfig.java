package com.uten.imp.config;

import org.springframework.boot.autoconfigure.condition.ConditionalOnMissingBean;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

import java.time.Clock;

/**
 * 服务端会话与再认证判定使用的时钟 (ADR-110)。生产固定为 UTC 系统时钟; 真库测试用
 * {@code @Primary} 的可控时钟覆盖, 验证空闲超时与绝对期限而不必真的等待。
 */
@Configuration
public class ClockConfig {

    @Bean
    @ConditionalOnMissingBean(Clock.class)
    public Clock systemClock() {
        return Clock.systemUTC();
    }
}
