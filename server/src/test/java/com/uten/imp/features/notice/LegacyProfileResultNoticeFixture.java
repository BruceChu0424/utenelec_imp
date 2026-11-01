package com.uten.imp.features.notice;

import java.util.List;
import java.util.UUID;
import java.util.function.Consumer;

/** Shared Java/SQL examples classify the message purpose without inventing any source batch. */
final class LegacyProfileResultNoticeFixture {
    record Example(Notice notice, boolean legacyResult) { }

    static List<Example> examples(UUID user) {
        return List.of(example(user, n->{}, true),
                example(user,n->n.setContent("请查看公司最新个人信息维护安排。"),false),
                example(user,n->n.setType("announcement"),false),
                example(user,n->n.setType("system"),false),
                example(user,n->{n.setAudienceUserId(null);n.setAudienceScope("all");},false),
                example(user,n->n.setTitle("个人信息修改已批准（副本）"),false),
                example(user,n->n.setContent("您提交的 2 项个人信息修改(手机号、姓名)已批准并生效。\n其他内容"),false));
    }

    private static Example example(UUID user,Consumer<Notice> change,boolean expected) {
        Notice n=new Notice();
        n.setType("approval");n.setTitle("个人信息修改已批准");
        n.setContent("您提交的 2 项个人信息修改(手机号、姓名)已批准并生效。");
        n.setPublisher("人事");n.setAudienceUserId(user);n.setAudienceScope("selected");
        n.setAudienceSummary("指定人员");n.setAudienceCount(1);n.setInteractionMode("none");
        change.accept(n);return new Example(n,expected);
    }

    static Object[] sqlArguments(Notice n,String rules) {
        return new Object[]{n.getActionRoute(),n.getSourceEvent(),rules,n.getType(),n.getTitle(),n.getContent(),
                n.getAudienceUserId(),n.getAudienceScope(),n.getAudienceSummary(),n.getAudienceCount(),
                n.getInteractionMode(),n.getKind(),n.getAggregateKind(),n.getAggregateId(),n.getSourceRevision(),
                n.getDueAt(),n.isTopPriority(),n.getPriority(),n.getAttachments(),n.getTargetDepartmentIds(),n.getTargetEmployeeIds()};
    }
}
