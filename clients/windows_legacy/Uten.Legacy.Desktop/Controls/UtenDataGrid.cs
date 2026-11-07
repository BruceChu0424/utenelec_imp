using System.Collections;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;

namespace Uten.Legacy.Desktop.Controls
{
    public sealed class UtenDataGrid : DataGrid
    {
        public static readonly DependencyProperty ColumnResizeHandleStyleProperty = DependencyProperty.RegisterAttached(
            "ColumnResizeHandleStyle", typeof(Style), typeof(UtenDataGrid),
            new PropertyMetadata(null, OnColumnResizeHandleStyleChanged));

        public static Style GetColumnResizeHandleStyle(DataGridColumnHeader header) =>
            (Style)header.GetValue(ColumnResizeHandleStyleProperty);

        public static void SetColumnResizeHandleStyle(DataGridColumnHeader header, Style value) =>
            header.SetValue(ColumnResizeHandleStyleProperty, value);

        private static void OnColumnResizeHandleStyleChanged(DependencyObject source, DependencyPropertyChangedEventArgs change)
        {
            var header = (DataGridColumnHeader)source;
            header.Loaded -= OnColumnHeaderLoaded;
            if (change.NewValue != null) header.Loaded += OnColumnHeaderLoaded;
            if (header.IsLoaded) ApplyColumnResizeHandleStyle(header);
        }

        private static void OnColumnHeaderLoaded(object sender, RoutedEventArgs e) =>
            ApplyColumnResizeHandleStyle((DataGridColumnHeader)sender);

        private static void ApplyColumnResizeHandleStyle(DataGridColumnHeader header)
        {
            // Keep the platform header and its native resize, sort and reorder handling.
            var style = GetColumnResizeHandleStyle(header);
            ApplyResizeHandleStyle(header.Template?.FindName("PART_LeftHeaderGripper", header) as Thumb, style);
            ApplyResizeHandleStyle(header.Template?.FindName("PART_RightHeaderGripper", header) as Thumb, style);
        }

        private static void ApplyResizeHandleStyle(Thumb handle, Style style)
        {
            if (handle == null) return;
            if (style == null) handle.ClearValue(StyleProperty);
            else handle.Style = style;
        }

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
