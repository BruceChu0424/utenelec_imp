package com.uten.imp.features.master.account;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.master.account.dto.AccountQueryFilter;
import com.uten.imp.common.web.ContactSensitiveFilter;
import java.util.Map;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.test.util.ReflectionTestUtils;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class AccountHeaderTransportTest {
    @Test void bankAccountHeaderUsesBodyAndCombinesThePublicNumericCriteria() {
        AccountService service=mock(AccountService.class);
        var controller=new AccountController(service,null,null,null,null,null,null);
        var request=new MockHttpServletRequest();
        request.addParameter("search.balanceCurrent",">90071992547409.1234");
        ReflectionTestUtils.setField(controller,"request",request);
        controller.search(null,null,null,null,null,null,1,20,null,null,
                new ContactSensitiveFilter("6222",null,null,null,null,Map.of("bankAccountNo","6222%_")));
        var capture=ArgumentCaptor.forClass(AccountQueryFilter.class);
        verify(service).list(capture.capture(),eq(1),eq(20),isNull(),isNull());
        assertThat(capture.getValue().keyword()).isEqualTo("6222");
        assertThat(capture.getValue().columnSearch()).containsExactlyInAnyOrderEntriesOf(
                Map.of("bankAccountNo","6222%_","balanceCurrent",">90071992547409.1234"));
    }
    @Test void bankAccountHeaderCannotBeSubmittedThroughTheUrl() {
        AccountService service=mock(AccountService.class);
        var controller=new AccountController(service,null,null,null,null,null,null);
        var request=new MockHttpServletRequest();request.addParameter("search.bankAccountNo","6222");
        ReflectionTestUtils.setField(controller,"request",request);
        assertThatThrownBy(()->controller.list(null,null,null,null,null,null,null,1,20,null,null))
                .isInstanceOf(ApiException.class).hasMessageContaining("请求体");
        verifyNoInteractions(service);
    }
}
