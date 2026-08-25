package com.uten.imp.features.master.client;

import org.junit.jupiter.api.Test;
import org.springframework.web.bind.annotation.RequestParam;

import java.lang.reflect.Method;
import java.lang.reflect.Parameter;
import java.util.Arrays;

import static org.assertj.core.api.Assertions.assertThat;

class ClientControllerStubDefaultContractTest {

    @Test
    void allUserFacingCustomerCollectionsExcludeFinanceStubsByDefault() {
        for (String methodName : new String[]{"list", "facets", "dict", "export"}) {
            Method method = Arrays.stream(ClientController.class.getDeclaredMethods())
                    .filter(candidate -> candidate.getName().equals(methodName))
                    .findFirst().orElseThrow();
            Parameter parameter = Arrays.stream(method.getParameters())
                    .filter(candidate -> candidate.getName().equals("excludeLegacyFinanceStub"))
                    .findFirst().orElseThrow();
            RequestParam requestParam = parameter.getAnnotation(RequestParam.class);
            assertThat(requestParam).as(methodName).isNotNull();
            assertThat(requestParam.defaultValue()).isEqualTo("true");
        }
    }
}
