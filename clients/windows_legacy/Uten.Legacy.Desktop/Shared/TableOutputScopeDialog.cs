using System;
using System.Globalization;
using System.Windows;
using Uten.Legacy.Desktop.Controls;

namespace Uten.Legacy.Desktop.Shared
{
    /// <summary>A cancelled scope choice performs no read, job submission or printing.</summary>
    public sealed class TableOutputScopeDialog : UtenDialogWindow
    {
        public bool? SelectedOnly { get; private set; }
        public TableOutputScopeDialog(Window parent, string action, int selectedCount, long total)
            : base(parent, "选择" + action + "范围", 480)
        {
            if (selectedCount < 0 || total < 0) throw new ArgumentOutOfRangeException();
            ActionButton("全部（" + total.ToString(CultureInfo.InvariantCulture) + " 项）",
                () => { SelectedOnly = false; Close(); });
            var selected = ActionButton("仅选中（" + selectedCount.ToString(CultureInfo.InvariantCulture) + " 项）",
                () => { SelectedOnly = true; Close(); }, primary: selectedCount > 0);
            selected.IsEnabled = selectedCount > 0;
            ActionButton("取消", () => Close());
        }
        public static bool? Choose(Window parent, string action, int selectedCount, long total)
        { var dialog = new TableOutputScopeDialog(parent, action, selectedCount, total); dialog.ShowDialog(); return dialog.SelectedOnly; }
    }
}
