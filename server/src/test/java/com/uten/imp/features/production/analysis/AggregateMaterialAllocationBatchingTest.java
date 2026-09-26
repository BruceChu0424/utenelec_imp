package com.uten.imp.features.production.analysis;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.test.util.ReflectionTestUtils;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** Database round trips must remain bounded as a shared order gains source paths. */
class AggregateMaterialAllocationBatchingTest {
    @Test void tenThousandSourceSharesUseOneInsertAndOneAppendUpdate() throws Exception {
        var em=mock(EntityManager.class);var query=mock(Query.class);var user=mock(SecurityContextCurrentUser.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);when(query.setParameter(anyString(),any())).thenReturn(query);
        when(user.requireId()).thenReturn(UUID.randomUUID());
        var mapper=new ObjectMapper();var service=mock(AggregateMaterialOrderWriteService.class,CALLS_REAL_METHODS);
        ReflectionTestUtils.setField(service,"em",em);ReflectionTestUtils.setField(service,"mapper",mapper);ReflectionTestUtils.setField(service,"user",user);
        var constructor=Class.forName(AggregateMaterialOrderWriteService.class.getName()+"$Batch").getDeclaredConstructors()[0];constructor.setAccessible(true);
        Object batch=constructor.newInstance(UUID.randomUUID(),UUID.randomUUID(),UUID.randomUUID(),UUID.randomUUID(),null,"MAKE",1L);
        List<AggregateMaterialOrderContracts.SourcePreview> sources=new ArrayList<>();
        for(int index=0;index<10000;index++)sources.add(new AggregateMaterialOrderContracts.SourcePreview(UUID.randomUUID(),UUID.randomUUID(),"来源"+index,1,LocalDate.of(2026,9,25),BigDecimal.ONE,BigDecimal.ONE,BigDecimal.ONE,BigDecimal.ZERO));
        sources.add(new AggregateMaterialOrderContracts.SourcePreview(UUID.randomUUID(),UUID.randomUUID(),"纯公共上下文",1,null,BigDecimal.ZERO,BigDecimal.ZERO,BigDecimal.ZERO,BigDecimal.ZERO));
        ReflectionTestUtils.invokeMethod(service,"allocations",batch,sources,false);
        verify(em,times(1)).createNativeQuery(anyString());verify(query,times(1)).executeUpdate();
        var initial=ArgumentCaptor.forClass(Object.class);verify(query).setParameter(eq("rows"),initial.capture());
        assertEquals(10000,mapper.readTree(initial.getValue().toString()).size());
        clearInvocations(em,query);
        ReflectionTestUtils.invokeMethod(service,"allocations",batch,sources,true);
        var sql=ArgumentCaptor.forClass(String.class);verify(em,times(2)).createNativeQuery(sql.capture());verify(query,times(2)).executeUpdate();
        assertTrue(sql.getAllValues().getFirst().stripLeading().startsWith("UPDATE preplan_supply_action_allocations"));
        assertTrue(sql.getAllValues().getLast().stripLeading().startsWith("INSERT INTO preplan_supply_action_allocations"));
        var appended=ArgumentCaptor.forClass(Object.class);verify(query,times(2)).setParameter(eq("rows"),appended.capture());
        for(Object payload:appended.getAllValues())assertEquals(initial.getValue(),payload);
    }
}
