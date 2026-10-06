package com.uten.imp.features.subcontract.draw;

import com.uten.imp.application.port.SubcontractChainNoticePort;
import com.uten.imp.features.subcontract.kit.SubcontractApplicationKitRecheckService;
import com.uten.imp.features.subcontract.kit.SubcontractKitService;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.RowCallbackHandler;

import java.math.BigDecimal;
import java.sql.ResultSet;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.contains;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.doAnswer;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * 提醒水位只记通知侧卡上实际写的数(ADR-143 §4.4 / ADR-156)。重算先读到的可领 / 可下单量与发卡时的实时量
 * 之间隔着别的事务: 发卡时物料已被用掉, 水位记 0(之后物料再到才能再提醒); 发卡时又多到了, 水位记卡上的数。
 */
class NoticeMarkFollowsShownCardTest {

    private final JdbcTemplate jdbc = mock(JdbcTemplate.class);
    private final SubcontractChainNoticePort notices = mock(SubcontractChainNoticePort.class);
    private final UUID item = UUID.randomUUID();

    @Test
    void drawMarkRecordsWhatTheCardShowsNotTheRecheckRead() throws Exception {
        ResultSet row = mock(ResultSet.class);
        when(row.getObject(1, UUID.class)).thenReturn(item);
        when(row.getBigDecimal(2)).thenReturn(new BigDecimal("10"));
        doAnswer(invocation -> {
            invocation.<RowCallbackHandler>getArgument(1).processRow(row);
            return null;
        }).when(jdbc).query(contains("fn_subcontract_draw_summary"), any(RowCallbackHandler.class), any(Object[].class));
        when(jdbc.queryForObject(contains("FROM subcontract_draw_notice_marks"), eq(BigDecimal.class), eq(item)))
                .thenReturn(BigDecimal.ZERO);
        var recheck = new SubcontractDrawRecheckService(jdbc, notices, mock(SubcontractApplicationKitRecheckService.class));

        when(notices.refreshSubcontractDrawAvailable(item)).thenReturn(BigDecimal.ZERO);
        recheck.recheckForOrderItems(List.of(item));
        verify(jdbc).update(contains("SET notified_drawable = ?, epoch = epoch + ?"), eq(BigDecimal.ZERO), eq(0), eq(item));

        when(notices.refreshSubcontractDrawAvailable(item)).thenReturn(new BigDecimal("12"));
        recheck.recheckForOrderItems(List.of(item));
        verify(jdbc).update(contains("SET notified_drawable = ?, epoch = epoch + ?"), eq(new BigDecimal("12")), eq(0), eq(item));
    }

    @Test
    void orderKitMarkRecordsWhatTheCardShowsNotTheRecheckRead() {
        SubcontractKitService kit = mock(SubcontractKitService.class);
        when(kit.orderableNow(List.of(item))).thenReturn(Map.of(item, new BigDecimal("10")));
        when(jdbc.queryForObject(contains("FROM subcontract_application_kit_notice_marks"), eq(BigDecimal.class), eq(item)))
                .thenReturn(new BigDecimal("4"));
        var recheck = new SubcontractApplicationKitRecheckService(jdbc, kit, notices);

        when(notices.refreshSubcontractOrderKitReady(item)).thenReturn(BigDecimal.ZERO);
        recheck.recheck(List.of(item));
        verify(jdbc).update(contains("SET notified_orderable = ?, epoch = epoch + ?"), eq(BigDecimal.ZERO), eq(1), eq(item));

        when(notices.refreshSubcontractOrderKitReady(item)).thenReturn(new BigDecimal("12"));
        recheck.recheck(List.of(item));
        verify(jdbc).update(contains("SET notified_orderable = ?, epoch = epoch + ?"), eq(new BigDecimal("12")), eq(0), eq(item));
    }
}
