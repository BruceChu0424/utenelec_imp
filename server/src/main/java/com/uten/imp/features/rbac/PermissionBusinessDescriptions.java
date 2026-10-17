package com.uten.imp.features.rbac;

/** Business explanations shared by central and page-level permission settings. */
public final class PermissionBusinessDescriptions {
    private PermissionBusinessDescriptions() {
    }

    public static String descriptionFor(Permission permission) {
        return descriptionFor(permission.getCode(), permission.getDescription());
    }

    /** Describes existing authority combinations without granting or filtering permissions. */
    public static String descriptionFor(String code, String catalogDescription) {
        if ("goods:price:edit".equals(code)) {
            return "本项为货品售价/折扣的字段授权。新建时，还须开启「新增货品资料」；"
                    + "修改已有货品时，还须开启「编辑货品资料」，并符合该货品的可写范围。"
                    + "本项同时允许查看货品售价；查看折扣须另行开启「查看货品折扣」。";
        }
        if ("employee:create".equals(code)) {
            return "办理员工入职还须开启「编辑员工证件、联系方式与银行字段」；"
                    + "在入职页面选择部门还须开启「查看部门」。"
                    + "填写薪资、社保、公积金与补贴时，还须另行开启「编辑员工薪资、社保、公积金与补贴字段」。";
        }
        if ("employee:compensation:edit".equals(code)) {
            return "本项为薪资、社保、公积金与补贴的字段写入授权。"
                    + "办理入职时，还须开启「办理员工入职」和「编辑员工证件、联系方式与银行字段」；"
                    + "修改已有员工时，还须开启「编辑员工」。"
                    + "查看已有薪酬须另行开启「查看员工薪资字段」。";
        }
        return catalogDescription;
    }
}
