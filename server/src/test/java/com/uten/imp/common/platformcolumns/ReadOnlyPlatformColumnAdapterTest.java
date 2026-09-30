package com.uten.imp.common.platformcolumns;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.Test;
import java.util.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

class ReadOnlyPlatformColumnAdapterTest {
    @Test void readPermissionDoesNotBecomeRecordWriteAndEveryUuidUsesTheDomainReader() {
        UUID own=UUID.randomUUID(),other=UUID.randomUUID();var current=mock(SecurityContextCurrentUser.class);
        when(current.get()).thenReturn(Optional.of(new AuthUser(UUID.randomUUID(),UUID.randomUUID(),"self",Set.of("payroll:view:self"),false,true,false)));
        var adapter=new ReadOnlyPlatformColumnAdapter("payroll_slip","工资条",current,new ObjectMapper(),Set.of("payroll:view:self"),Set.of("payroll:view:self"),
                id->{if(!id.equals(own))throw new ApiException(ErrorCode.NOT_FOUND);return Map.of("id",id,"netIncome","10.125");},
                List.of(new PlatformColumnResourceAdapter.FactDefinition("netIncome","实发",true)));
        assertThat(adapter.personalDefinitions()).isTrue();assertThat(adapter.supportsValues()).isTrue();assertThat(adapter.canWrite()).isFalse();
        assertThat(adapter.authorize(Set.of(own),false).get(own).facts().get("netIncome")).isEqualByComparingTo("10.125");
        assertThatThrownBy(()->adapter.authorize(Set.of(other),false)).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->adapter.authorize(Set.of(own),true)).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->adapter.requireDocumentSaveAccess(true)).isInstanceOf(ApiException.class);
    }
    @Test void maskedFinancialFactsAreNeverForwardedToTheCalculator() {
        UUID id=UUID.randomUUID();var current=mock(SecurityContextCurrentUser.class);
        when(current.get()).thenReturn(Optional.of(new AuthUser(UUID.randomUUID(),UUID.randomUUID(),"reader",Set.of("employee:view"),false,true,false)));
        var adapter=new ReadOnlyPlatformColumnAdapter("employee_history","员工历史",current,new ObjectMapper(),Set.of("employee:view"),Set.of("employee:compensation:view"),
                ignored->Map.of("id",id,"salary","9000","months",3),List.of(
                    new PlatformColumnResourceAdapter.FactDefinition("salary","工资",true),new PlatformColumnResourceAdapter.FactDefinition("months","月数",false)));
        assertThat(adapter.authorize(Set.of(id),false).get(id).facts()).containsKey("months").doesNotContainKey("salary");
    }
}
