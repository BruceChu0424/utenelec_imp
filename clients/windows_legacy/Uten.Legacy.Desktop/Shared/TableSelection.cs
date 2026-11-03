using System;
using System.Windows.Controls;

namespace Uten.Legacy.Desktop.Shared
{
    /// <summary>Clear transient table intent when a caller actually opens another business view.
    /// Do not call for context menus, form pickers, failed navigation or window deactivation.</summary>
    public static class TableSelection
    {
        public static void Clear(DataGrid table, Action clearRemembered = null)
        {
            if (table == null) throw new ArgumentNullException(nameof(table));
            table.UnselectAll();
            table.UnselectAllCells();
            table.CurrentCell = new DataGridCellInfo();
            clearRemembered?.Invoke();
        }
    }
}
