package com.uten.imp.features.finance.cost;

import com.uten.imp.common.validation.DocumentQuantity;
import com.fasterxml.jackson.annotation.JsonFormat;
import jakarta.validation.constraints.*;
import java.math.BigDecimal;
import java.util.UUID;

public final class FinanceCostInputContracts {
    private FinanceCostInputContracts() { }
    public record Sales(@NotNull UUID requestId,@NotBlank @Pattern(regexp="[0-9]{4}-(0[1-9]|1[0-2])") String period,
            @NotNull UUID clientId,@Min(-1) long expectedVersion,
            @Pattern(regexp="OEM|FOREIGN|DOMESTIC") String channel,
            @JsonFormat(shape=JsonFormat.Shape.STRING) @Digits(integer=40,fraction=24) BigDecimal freightLocal,
            @JsonFormat(shape=JsonFormat.Shape.STRING) @DecimalMin(value="0",inclusive=false) @Digits(integer=40,fraction=24) BigDecimal exchangeRate,
            @Size(max=1000) String sourceReference,boolean confirmed,
            @JsonFormat(shape=JsonFormat.Shape.STRING) @Digits(integer=1,fraction=6) BigDecimal taxRate,
            @Size(max=240) String clientName,@Size(max=500) String sellerName,@Size(max=240) String region,@Size(max=500) String director) { }
    public record Plastic(@NotNull UUID requestId,@NotNull UUID periodLineId,@Min(-1) long expectedVersion,
            @JsonFormat(shape=JsonFormat.Shape.STRING) @NotNull @DecimalMin("0") @DocumentQuantity BigDecimal rejectReturnQty,
            @JsonFormat(shape=JsonFormat.Shape.STRING) @NotNull @DecimalMin("0") @DocumentQuantity BigDecimal rejectIssueQty,
            @Size(max=2000) String reason,boolean confirmed,
            @JsonFormat(shape=JsonFormat.Shape.STRING) @DecimalMin(value="0",inclusive=false) @Digits(integer=40,fraction=24) BigDecimal weightKgPerUnit,
            @Size(max=240) String materialName,@Min(1) @Max(2000) Integer templateRow,@Size(max=1000) String sourceReference) { }
    public record Order(@NotNull UUID requestId,@NotNull UUID requisitionId,@Min(-1) long expectedVersion,
            @NotBlank @Size(max=200) String orderNo,@NotBlank @Size(max=1000) String sourceReference,boolean confirmed) { }
    public record Saved(UUID requestId,String kind,long version) { }
    public record Copper(@NotNull UUID requestId,@NotNull UUID sourceLineId,@Min(-1)long expectedVersion,
            @NotBlank @Pattern(regexp="PICKLING_INSERT|COPPER_PICKLING")String sectionKey,
            @NotBlank @Size(max=1000)String sourceReference,boolean confirmed) { }
}
