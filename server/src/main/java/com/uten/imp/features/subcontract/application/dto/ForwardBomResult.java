package com.uten.imp.features.subcontract.application.dto;

/**
 * 委外任务中心「通知研发完善」的结果(ADR-143 §二.3)：该委外件未完成的「完善 BOM」研发任务编号;
 * {@code created} = 这次新建了研发任务(此时已通知工程研发部), 为假时只是把操作人加进等待名单。
 */
public record ForwardBomResult(String taskNo, boolean created) {
}
