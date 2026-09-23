package com.uten.imp.features.notice;

import com.uten.imp.application.port.WorkbenchBadgeSources;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * 通知未读数与未读摘要的计数来源(工作台徽章汇总, ADR-108)。
 *
 * <p>经控制器代理读取未读索引, 资格判定沿用 {@code notice:read}; 汇总里只带数量、48 位摘要
 * 与最新发布时间(毫秒), 不带逐条列表——前端摘要对不上时才去拉 /notices/unread-index。
 * 原来的 60s 未读数轮询与每分钟从纪元分页的全量对账由这一份替代。
 */
@Component
@RequiredArgsConstructor
class NoticeWorkbenchBadgeSources implements WorkbenchBadgeSources {

    private final NoticeController controller;

    @Override
    public List<Source> sources() {
        return List.of(new Source("notices", () -> {
            NoticeService.UnreadIndex index = controller.unreadIndex();
            Map<String, Long> facts = new LinkedHashMap<>();
            facts.put("unread", index.unreadCount());
            facts.put("digest", index.digest());
            facts.put("latestPublishedAt", index.latestPublishedAt() == null
                    ? 0L : index.latestPublishedAt().toEpochMilli());
            return facts;
        }));
    }
}
