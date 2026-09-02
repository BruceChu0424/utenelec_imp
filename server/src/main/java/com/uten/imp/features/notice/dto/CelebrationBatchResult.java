package com.uten.imp.features.notice.dto;

/**
 * 一键批量发布庆典祝福结果。
 *
 * @param published 实际覆盖的祝福对象人数（本类型本年已发过的按人跳过——幂等去重）
 * @param skipped   跳过人数（员工不存在，或本类型本年已出现在任何庆典卡）
 * @param notices   实际新建通知张数：V454 起一键祝福合并为每天每类一张聚合卡，
 *                  正常为 0（全员跳过）或 1
 */
public record CelebrationBatchResult(int published, int skipped, int notices) {}
