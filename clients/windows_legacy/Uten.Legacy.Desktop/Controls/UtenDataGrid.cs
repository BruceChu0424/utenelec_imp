using System.Collections;
using System.Windows.Controls;

namespace Uten.Legacy.Desktop.Controls
{
    public sealed class UtenDataGrid : DataGrid
    {
        protected override void OnItemsSourceChanged(IEnumerable oldValue, IEnumerable newValue)
        {
            base.OnItemsSourceChanged(oldValue, newValue);
            if (oldValue == null) return;

            // WPF caches measured Auto widths for virtual rows. Change the unit
            // briefly to invalidate that cache when the result set is replaced.
            foreach (DataGridColumn column in Columns)
            {
                if (!column.Width.IsAuto) continue;
                column.Width = DataGridLength.SizeToHeader;
                column.Width = DataGridLength.Auto;
            }
        }
    }
}
