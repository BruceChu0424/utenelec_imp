package com.uten.imp.features.master.client;

import com.uten.imp.common.validation.RequestLimits;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.client.dto.ClientAccessBatchUpdateRequest;
import com.uten.imp.security.OwnerVisibility;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import org.junit.jupiter.api.Test;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.Set;
import java.util.UUID;
import java.util.stream.IntStream;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/**
 * 多选客户批量设置负责人/可见人的守卫与锁序。
 *
 * <p>批量端点复用单客户那套（员工 → 客户 → 账号 → 授权 的锁序、审计事件、
 * 前负责人保留），这里只钉住批量特有的四条：入参守卫、上限、按 id 排序取锁、
 * 「未指定的那一维不动」。
 */
class ClientAccessBatchUpdateTest {

    private static ClientAccessService serviceWith(ClientAccessPolicy policy, EntityManager em) {
        return new ClientAccessService(
                em, mock(TxSessionVars.class), mock(SecurityContextCurrentUser.class), policy);
    }

    private static ClientAccessService service() {
        ClientAccessPolicy policy = mock(ClientAccessPolicy.class);
        when(policy.evaluate()).thenReturn(new ClientAccessPolicy.ClientScope(
                new OwnerVisibility.OwnerScope(true, Set.of(), Set.of()), Set.of(), true));
        return serviceWith(policy, mock(EntityManager.class));
    }

    @Test
    void emptySelectionIsRejectedBeforeTouchingAnyCustomer() {
        ApiException error = assertThrows(ApiException.class, () -> service()
                .updateBatch(new ClientAccessBatchUpdateRequest(
                        List.of(), UUID.randomUUID(), null, "交接")));

        assertThat(error.getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED);
        assertThat(error.getMessage()).contains("请先选择");
    }

    @Test
    void neitherOwnerNorViewersIsRejected() {
        ApiException error = assertThrows(ApiException.class, () -> service()
                .updateBatch(new ClientAccessBatchUpdateRequest(
                        List.of(UUID.randomUUID()), null, null, "交接")));

        assertThat(error.getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED);
        assertThat(error.getMessage()).contains("负责人或可见人");
    }

    @Test
    void selectionAboveBatchLimitIsRejected() {
        List<UUID> tooMany = IntStream.rangeClosed(0, RequestLimits.BATCH_IDS)
                .mapToObj(index -> UUID.randomUUID())
                .toList();

        ApiException error = assertThrows(ApiException.class, () -> service()
                .updateBatch(new ClientAccessBatchUpdateRequest(
                        tooMany, UUID.randomUUID(), null, "交接")));

        assertThat(error.getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED);
        assertThat(error.getMessage()).contains(String.valueOf(RequestLimits.BATCH_IDS));
    }

    /**
     * 越权的客户在批量里必须与单客户同样 fail-closed（伪装成 404，不泄露存在性），
     * 且整批回滚——半批生效比不生效更难收拾。
     */
    @Test
    void customerOutsideTheOperatorScopeFailsTheWholeBatch() {
        UUID clientId = UUID.randomUUID();
        Client client = new Client();
        client.setId(clientId);
        client.setOwnerEmployeeId(UUID.randomUUID());
        EntityManager em = mock(EntityManager.class);
        when(em.find(Client.class, clientId)).thenReturn(client);
        ClientAccessPolicy policy = mock(ClientAccessPolicy.class);
        when(policy.evaluate()).thenReturn(new ClientAccessPolicy.ClientScope(
                new OwnerVisibility.OwnerScope(false, Set.of(), Set.of()), Set.of(), false));

        ApiException error = assertThrows(ApiException.class, () -> serviceWith(policy, em)
                .updateBatch(new ClientAccessBatchUpdateRequest(
                        List.of(clientId), UUID.randomUUID(), null, "交接")));

        assertThat(error.getCode()).isEqualTo(ErrorCode.NOT_FOUND);
    }

    /** 没有负责人的客户在「只批量设可见人」时必须被点名拒绝，不能悄悄跳过。 */
    @Test
    void customerWithoutOwnerRequiresAnOwnerInTheSameBatch() {
        UUID clientId = UUID.randomUUID();
        Client client = new Client();
        client.setId(clientId);
        client.setName("宁波甲乙");
        EntityManager em = mock(EntityManager.class);
        when(em.find(Client.class, clientId)).thenReturn(client);
        ClientAccessPolicy policy = mock(ClientAccessPolicy.class);
        when(policy.evaluate()).thenReturn(new ClientAccessPolicy.ClientScope(
                new OwnerVisibility.OwnerScope(true, Set.of(), Set.of()), Set.of(), true));
        when(policy.canManageAccess(client, policy.evaluate())).thenReturn(true);

        ApiException error = assertThrows(ApiException.class, () -> serviceWith(policy, em)
                .updateBatch(new ClientAccessBatchUpdateRequest(
                        List.of(clientId), null, List.of(UUID.randomUUID()), "交接")));

        assertThat(error.getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED);
        assertThat(error.getMessage()).contains("宁波甲乙");
    }

    /**
     * 源码契约：批量必须按 client id 排序取锁（两个并发批量交叉选中同一批客户时
     * 才不会互相死锁），且未指定的那一维要回落到该客户当前值而不是清空。
     */
    @Test
    void batchSortsClientIdsAndKeepsUntouchedDimension() throws Exception {
        String source = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/master/client/ClientAccessService.java"));
        String batch = source.substring(
                source.indexOf("public List<ClientAccessDetail> updateBatch("),
                source.indexOf("private static String clientLabel("));

        assertThat(batch).contains(".sorted()");
        assertThat(batch).contains("snapshot.getOwnerEmployeeId()");
        assertThat(batch).contains("activeViewerIds(clientId)");
        assertThat(batch).contains("snapshot.getAccessVersion()");
    }
}
