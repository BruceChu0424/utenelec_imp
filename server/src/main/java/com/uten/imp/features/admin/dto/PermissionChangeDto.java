package com.uten.imp.features.admin.dto;

import java.util.List;

/** 一次授权保存真正改动的码(差量)；两个列表都为空表示本次没有任何写入。 */
public record PermissionChangeDto(List<String> added, List<String> removed) {

    public static PermissionChangeDto unchanged() {
        return new PermissionChangeDto(List.of(), List.of());
    }

    public boolean isEmpty() {
        return added.isEmpty() && removed.isEmpty();
    }
}
