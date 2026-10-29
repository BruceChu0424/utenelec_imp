using System;
using System.IO;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using Uten.Legacy.Desktop.Controls;

namespace Uten.Legacy.Desktop.Views
{
    public sealed class AboutWindow : UtenDialogWindow
    {
        public AboutWindow(Window parent) : base(parent, "关于优腾综合管理平台", 760)
        {
            var assembly = Assembly.GetExecutingAssembly();
            string version = assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion
                ?? assembly.GetName().Version.ToString();
            Body.Children.Add(new TextBlock { Text = "Windows 兼容版 · " + version, FontWeight = FontWeights.SemiBold });
            AddLicense("Noto Sans SC · SIL Open Font License", "PrintAssets/OFL.txt");
            AddLicense("Bouncy Castle · MIT License", "Licenses/BouncyCastle-LICENSE.md");
            ActionButton("关闭", () => Close());
        }
        private void AddLicense(string title, string resource)
        {
            Body.Children.Add(new TextBlock { Text = title, FontWeight = FontWeights.SemiBold,
                Margin = new Thickness(0, Space("S16"), 0, Space("S8")) });
            string text;
            var data = Application.GetResourceStream(new Uri("pack://application:,,,/Uten.Legacy.Desktop;component/" + resource, UriKind.Absolute));
            if (data == null) throw new InvalidOperationException("An embedded license is missing.");
            using (var input = data.Stream)
            using (var reader = new StreamReader(input)) text = reader.ReadToEnd();
            Body.Children.Add(new TextBox { Text = text, IsReadOnly = true, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap,
                Height = 190, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
        }
    }
}
