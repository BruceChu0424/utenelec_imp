package com.uten.imp.features.ai;

/** 公共 AI 平台用到的权限码(ADR-133)。 */
public final class AiPermissions {

    /** 使用 AI 识别: 没有它时任务只走固定规则, 不调用 AI 服务。 */
    public static final String AI_USE = "ai:use";

    private AiPermissions() {
    }
}
