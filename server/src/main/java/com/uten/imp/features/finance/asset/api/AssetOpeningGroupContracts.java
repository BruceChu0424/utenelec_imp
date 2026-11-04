package com.uten.imp.features.finance.asset.api;

import jakarta.validation.Valid;
import jakarta.validation.constraints.*;
import java.time.LocalDate;
import java.util.*;

public final class AssetOpeningGroupContracts {
    private AssetOpeningGroupContracts() { }
    public record Member(@NotBlank @Pattern(regexp="FIXED_ASSET|DEFERRED_EXPENSE")String objectType,
            @NotNull UUID objectId,@Min(1)int sourceRow,@Min(0)@Max(1200)int remainingMonths,@Min(0)long expectedVersion) { }
    public record Create(@NotNull UUID requestId,@NotNull UUID sourceImportId,UUID sourceVoucherId,
            @NotNull LocalDate asOf,@NotNull @Size(max=2000)List<UUID> entryIds,
            @NotEmpty @Size(max=2000)List<@Valid Member> members,@NotBlank @Size(max=2000)String reason,
            @Size(max=2000)List<UUID> sourceVoucherIds) {
        public Create(UUID requestId,UUID sourceImportId,UUID sourceVoucherId,LocalDate asOf,List<UUID>entryIds,List<Member>members,String reason){
            this(requestId,sourceImportId,sourceVoucherId,asOf,entryIds,members,reason,null);
        }
    }
    public record Action(@Min(0)long expectedVersion,@NotBlank @Size(max=2000)String reason) { }
}
