package com.uten.imp.features.rd_task;

import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.application.port.RdMaterialIssuePort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;

import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class RdTaskResolveGuardTest {
    @Test void missingOrConcurrentlyDeletedTaskReturnsNotFoundWithoutAnUpdateOrCompletionEvent() {
        JdbcTemplate jdbc=mock(JdbcTemplate.class);
        BusinessEventPublisher events=mock(BusinessEventPublisher.class);
        var service=new RdTaskService(jdbc,events,mock(SecurityContextCurrentUser.class),mock(TxSessionVars.class));
        UUID id=UUID.randomUUID();
        when(jdbc.queryForList(anyString(),eq(UUID.class),eq(id))).thenReturn(List.of());
        assertThatThrownBy(()->service.resolve(id,1,null)).isInstanceOfSatisfying(ApiException.class,
                error->assertThat(error.getCode()).isEqualTo(ErrorCode.NOT_FOUND));
        verify(jdbc,never()).update(anyString(),any(Object[].class));
        verifyNoInteractions(events);
    }

    @Test void missingOrConcurrentlyDeletedMasterReturnsNotFoundWithoutAnUpdateOrCompletionEvent() {
        JdbcTemplate jdbc=mock(JdbcTemplate.class);
        BusinessEventPublisher events=mock(BusinessEventPublisher.class);
        SecurityContextCurrentUser current=actor();
        var service=spy(new RdTaskService(jdbc,events,current,mock(TxSessionVars.class)));
        UUID id=UUID.randomUUID(),goods=UUID.randomUUID();
        var task=mock(RdTaskContracts.RdTaskRow.class);
        when(task.sourceDocType()).thenReturn(RdMaterialIssuePort.MASTER_SOURCE);
        when(task.goodsId()).thenReturn(goods);
        doReturn(task).when(service).get(id);
        when(jdbc.queryForList(contains("FROM rd_tasks"),eq(UUID.class),eq(id))).thenReturn(List.of(id));
        when(jdbc.queryForList(contains("FROM goods"),eq(UUID.class),eq(goods))).thenReturn(List.of());
        assertThatThrownBy(()->service.resolve(id,1,null)).isInstanceOfSatisfying(ApiException.class,
                error->assertThat(error.getCode()).isEqualTo(ErrorCode.NOT_FOUND));
        verify(jdbc,never()).update(anyString(),any(Object[].class));
        verifyNoInteractions(events);
    }

    @Test void anExistingOrdinaryTaskStillCompletesExactlyOnce() {
        JdbcTemplate jdbc=mock(JdbcTemplate.class);
        BusinessEventPublisher events=mock(BusinessEventPublisher.class);
        SecurityContextCurrentUser current=actor();
        var service=spy(new RdTaskService(jdbc,events,current,mock(TxSessionVars.class)));
        UUID id=UUID.randomUUID();
        var task=mock(RdTaskContracts.RdTaskRow.class);
        when(task.sourceDocType()).thenReturn("OTHER");
        doReturn(task).when(service).get(id);
        when(jdbc.queryForList(anyString(),eq(UUID.class),eq(id))).thenReturn(List.of(id));
        when(jdbc.update(anyString(),any(Object[].class))).thenReturn(1);
        assertThat(service.resolve(id,1,"已核对")).isSameAs(task);
        verify(events).publish(eq(RdTaskService.EVENT_RESOLVED),eq("RD_TASK"),eq(id),anyMap());
        verifyNoMoreInteractions(events);
    }

    private SecurityContextCurrentUser actor() {
        SecurityContextCurrentUser current=mock(SecurityContextCurrentUser.class);
        UUID user=UUID.randomUUID(),employee=UUID.randomUUID();
        when(current.get()).thenReturn(Optional.of(new AuthUser(user,employee,"engineer",Set.of("rd_task:resolve"),false,true,false)));
        when(current.requireId()).thenReturn(user);
        when(current.requireEmployeeId()).thenReturn(employee);
        return current;
    }
}
