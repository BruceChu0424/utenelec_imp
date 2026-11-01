package com.uten.imp.features.profilechange;

import com.uten.imp.application.port.HrNoticePort;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.notice.NoticeService;
import com.uten.imp.features.org.employee.Employee;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.features.profilechange.dto.ProfileChangeDto;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;
import static org.mockito.Mockito.*;
import static org.mockito.ArgumentMatchers.*;

class ProfileChangeResultNoticeTest {
    @ParameterizedTest
    @ValueSource(strings={"approve", "reject"})
    void resultsCarryTheProvenBatchAndPreserveTheirOrdinaryReceiptSemantics(String action) {
        var repo=mock(ProfileChangeRepository.class);
        var employees=mock(EmployeeRepository.class);
        var users=mock(UserAccountRepository.class);
        var notices=mock(NoticeService.class);
        var access=mock(ProfileChangeAccess.class);
        UUID batch=UUID.randomUUID(), employeeId=UUID.randomUUID(), submitterId=UUID.randomUUID();
        var reviewer=new AuthUser(UUID.randomUUID(), null, "reviewer", Set.of("profile:review"), false, true, false);
        when(access.requireHr()).thenReturn(reviewer);
        var employee=new Employee(); employee.setId(employeeId); employee.setVersion(0);
        when(employees.findByIdForUpdate(employeeId)).thenReturn(Optional.of(employee));
        var request=new ProfileChangeRequest(); request.setBatchId(batch); request.setEmployeeId(employeeId);
        request.setSubmittedBy(employeeId); request.setEmployeeVersion(0); request.setFieldCode("phone");
        var rows=List.of(request);
        when(repo.findByBatchId(batch)).thenReturn(rows);
        when(repo.findByBatchIdAndStatus(batch,"pending")).thenReturn(rows);
        var submitter=new UserAccount(); submitter.setId(submitterId);
        when(users.findByEmployeeId(employeeId)).thenReturn(Optional.of(submitter));
        var service=new ProfileChangeReviewService(repo,employees,users,notices,mock(HrNoticePort.class),
                mock(ProfileFieldApplier.class),mock(ProfileChangeMapper.class),mock(ProfileChangeSnapshotCodec.class),
                access,mock(TxSessionVars.class));
        service.review(batch,new ProfileChangeDto.ReviewAction(action,"核对意见"));
        verify(notices).publishForUser(eq(submitterId),anyString(),anyString(),eq("approval"),eq("系统"),
                eq("approve".equals(action)?"/profile/me/changes":"/profile/edit"),
                eq("approve".equals(action)?"PROFILE_CHANGE_APPROVED":"PROFILE_CHANGE_REJECTED"),
                eq("approve".equals(action)?"normal":"important"),eq(batch));
    }
}
