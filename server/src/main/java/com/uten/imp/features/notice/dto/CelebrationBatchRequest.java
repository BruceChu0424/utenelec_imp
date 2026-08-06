package com.uten.imp.features.notice.dto;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotEmpty;

import java.util.List;
import java.util.UUID;

/**
 * 一键批量发布庆典祝福请求（HR 任务中心子页「为今日XX送祝福」）。
 *
 * @param type        庆典类型：birthday / anniversary / wedding / newborn
 * @param employeeIds 祝福对象员工 ID 列表（服务端按 (subject,type,当年) 去重，已发的跳过）
 */
public record CelebrationBatchRequest(
        @NotBlank String type,
        @NotEmpty List<UUID> employeeIds) {}
