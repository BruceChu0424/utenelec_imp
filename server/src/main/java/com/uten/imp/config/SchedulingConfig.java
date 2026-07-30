package com.uten.imp.config;

import org.springframework.context.annotation.Configuration;
import org.springframework.scheduling.annotation.EnableScheduling;

/**
 * 开启 Spring 定时任务。当前唯一调度项：{@code DeliveryDueWarningScheduler}
 * 延期预警每日扫描（业务链 SOP §一，交货 ≤3 天未结案通知业务员+调度）。
 */
@Configuration
@EnableScheduling
public class SchedulingConfig {
}
