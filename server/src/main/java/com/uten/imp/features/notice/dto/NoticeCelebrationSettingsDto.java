package com.uten.imp.features.notice.dto;

import java.util.List;

/**
 * 庆典自动发布设置（读：所有 notice:read 可见；写：仅超管 authorization:manage）。
 *
 * <ul>
 *   <li>{@code autoEnabled}：每日 08:00 自动扫描生日/入职纪念日的总开关。</li>
 *   <li>{@code autoTypes}：自动扫描的类型子集（birthday/anniversary/wedding/newborn，
 *       当前调度器仅实现 birthday/anniversary 的自动匹配，wedding/newborn 列出但暂不发）。</li>
 *   <li>{@code publisherName}：自动通知署名（如「公司」/「人力资源部」）。</li>
 * </ul>
 */
public record NoticeCelebrationSettingsDto(
        boolean autoEnabled,
        List<String> autoTypes,
        String publisherName) {
}
