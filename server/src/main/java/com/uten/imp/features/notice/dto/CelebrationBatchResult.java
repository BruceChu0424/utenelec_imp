package com.uten.imp.features.notice.dto;

/**
 * 一键批量发布庆典祝福结果。
 *
 * @param published 实际新发布条数
 * @param skipped   跳过条数（员工不存在，或本类型本年已发过——幂等去重）
 */
public record CelebrationBatchResult(int published, int skipped) {}
