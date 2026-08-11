package com.uten.imp.features.notice.dto;

import java.util.List;

/**
 * 庆典通知发布预览：根据所选员工 + 类型，派生节日标签、建议标题、建议祝福模板。
 * 前端发布页选好员工后调用，让 HR 一键填表，无需手动组织文案。
 */
public record NoticeCelebrationPreviewDto(
        String subjectName,
        String eventLabel,
        String suggestedTitle,
        List<String> suggestedTemplates) {
}
