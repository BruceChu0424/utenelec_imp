using System.Windows;
using Microsoft.Win32;

namespace Uten.Legacy.Desktop.Shared
{
    public interface IWorkbookSavePicker
    {
        string Choose(Window owner);
    }
    public sealed class NativeWorkbookSavePicker : IWorkbookSavePicker
    {
        public string Choose(Window owner)
        {
            var picker = new SaveFileDialog { FileName = "单位资料.xlsx", DefaultExt = ".xlsx",
                Filter = "Excel工作簿|*.xlsx", AddExtension = true, OverwritePrompt = true };
            return picker.ShowDialog(owner) == true ? picker.FileName : null;
        }
    }
}
