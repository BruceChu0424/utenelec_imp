package com.uten.imp.features.profilechange;

import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;
import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;
import static org.mockito.ArgumentMatchers.*;

class ProfileChangeObserverTest {
    @Test void readGrantCannotReviewAndSensitiveSnapshotsAreNotEvenDecrypted() {
        var current=mock(SecurityContextCurrentUser.class);
        var actor=new AuthUser(UUID.randomUUID(),UUID.randomUUID(),"observer",Set.of("profile_change:view"),false,true,false);
        when(current.get()).thenReturn(Optional.of(actor));
        var access=new ProfileChangeAccess(current);
        assertThat(access.requireReader()).isSameAs(actor);
        assertThatThrownBy(access::requireHr).isInstanceOf(ApiException.class);
        var employees=mock(EmployeeRepository.class);
        when(employees.findAllById(any())).thenReturn(List.of());
        var codec=mock(ProfileChangeSnapshotCodec.class);
        var mapper=new ProfileChangeMapper(employees,codec);
        var request=new ProfileChangeRequest();
        request.setId(UUID.randomUUID()); request.setBatchId(UUID.randomUUID());
        request.setEmployeeId(UUID.randomUUID()); request.setSubmittedBy(UUID.randomUUID());
        request.setFieldCode("phone"); request.setStatus("pending");
        request.setValueEncoding("PGCRYPTO_V1"); request.setOldValueEnc("cipher-old"); request.setNewValueEnc("cipher-new");
        var detail=mapper.toBatchDetail(List.of(request),false);
        assertThat(detail.items().getFirst().oldValue()).isEqualTo("***");
        assertThat(detail.items().getFirst().newValue()).isEqualTo("***");
        verifyNoInteractions(codec);
        when(codec.decode("phone","PGCRYPTO_V1","cipher-old")).thenReturn("old-authorized-value");
        when(codec.decode("phone","PGCRYPTO_V1","cipher-new")).thenReturn("new-authorized-value");
        assertThat(mapper.toBatchDetail(List.of(request),true).items().getFirst().newValue()).isEqualTo("new-authorized-value");
    }
}
