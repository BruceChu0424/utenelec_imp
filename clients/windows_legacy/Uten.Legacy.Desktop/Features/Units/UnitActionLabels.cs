using Uten.Legacy.Core;

namespace Uten.Legacy.Desktop.Features.Units
{
    public static class UnitActionLabels
    {
        public static string Title(MutationAction action)
        {
            switch (action.ToString())
            {
                case "UnitCreate": return "新增单位";
                case "UnitUpdate": return "编辑单位";
                case "UnitStatus": return "更改单位状态";
                case "UnitInlineEdit": return "行内编辑单位";
                case "UnitBatchStatus": return "批量启停单位";
                case "UnitBatchDelete": return "删除单位";
                case "UnitUndo": return "撤回单位操作";
                case "UnitRedo": return "取消撤回单位操作";
                case "UnitRecordRestore": return "恢复单位版本";
                case "UnitExportSubmit": return "创建单位导出任务";
                case "UnitExportCancel": return "取消单位导出任务";
                case "UnitColumnLayoutSave": return "保存单位表头";
                case "UnitPlatformDefinitionCreate": return "新增单位自设列";
                case "UnitPlatformDefinitionDelete": return "删除单位自设列定义";
                case "UnitPlatformDefinitionUse": return "使用单位自设列";
                case "UnitPlatformValuesWrite": return "编辑单位自设字段";
                default: return "单位操作";
            }
        }
    }
}
