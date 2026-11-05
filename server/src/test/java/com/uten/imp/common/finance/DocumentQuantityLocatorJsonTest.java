package com.uten.imp.common.finance;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import java.util.UUID;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import static org.assertj.core.api.Assertions.*;

/** A newly optional locator must not add null fields to an older typed body. */
class DocumentQuantityLocatorJsonTest {
    @ParameterizedTest
    @ValueSource(strings={"purchase.receipt.dto.ReceiptItemLine","purchase.ret.dto.ReturnItemLine",
        "subcontract.receipt.dto.ReceiptItemLine","subcontract.material_return.dto.MaterialReturnItemLine","sales.ret.dto.ReturnItemLine"})
    void absentLocatorKeepsTheOldShapeWhileActualIdentityRoundTrips(String name)throws Exception {
        var json=new ObjectMapper();Class<?> type=Class.forName("com.uten.imp.features."+name);Object row=type.getDeclaredConstructor().newInstance();
        ObjectNode before=json.valueToTree(row);assertThat(before.has("id")).isFalse();
        UUID id=UUID.randomUUID();type.getMethod("setId",UUID.class).invoke(row,id);
        ObjectNode located=json.valueToTree(row);assertThat(located.path("id").asText()).isEqualTo(id.toString());
        Object decoded=json.treeToValue(located,type);assertThat(type.getMethod("getId").invoke(decoded)).isEqualTo(id);
        located.remove("id");assertThat(located).isEqualTo(before);
    }
}
