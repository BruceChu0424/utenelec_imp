using System;
using System.Collections;
using System.Collections.Generic;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Uten.Legacy.Core;
using Uten.Legacy.Desktop.Controls;

namespace Uten.Legacy.Desktop.Views
{
    public sealed class DashboardView : UserControl, IDisposable
    {
        private readonly SessionCoordinator session;
        private readonly Action openGoods;
        private readonly CancellationTokenSource cancellation = new CancellationTokenSource();
        private readonly StackPanel metrics = new StackPanel();
        private readonly StackPanel todos = new StackPanel();
        private readonly TextBlock status = new TextBlock();
        private readonly Button refresh = new Button { Content = "刷新" };
        private bool disposed;
        private long request;

        public DashboardView(SessionCoordinator session, Action openGoods)
        {
            this.session = session; this.openGoods = openGoods;
            var grid = new Grid(); grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); grid.RowDefinitions.Add(new RowDefinition());
            var header = new DockPanel { Margin = new Thickness(0, 0, 0, 16) };
            refresh.Click += (s, e) => Load(); DockPanel.SetDock(refresh, Dock.Right); header.Children.Add(refresh);
            header.Children.Add(new TextBlock { Text = "工作台", Style = (Style)FindResource("Uten.PageTitle"), VerticalAlignment = VerticalAlignment.Center });
            grid.Children.Add(header);
            var body = new StackPanel();
            status.Margin = new Thickness(0, 0, 0, 12); body.Children.Add(status);
            body.Children.Add(new TextBlock { Text = "今日概览", Style = (Style)FindResource("Uten.SectionTitle"), Margin = new Thickness(0, 0, 0, Space("S12")) });
            body.Children.Add(metrics);
            body.Children.Add(new TextBlock { Text = "待办任务", Style = (Style)FindResource("Uten.SectionTitle"), Margin = new Thickness(0, Space("S24"), 0, Space("S12")) });
            body.Children.Add(todos);
            var scroll = new ScrollViewer { Content = body, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
            Grid.SetRow(scroll, 1); grid.Children.Add(scroll); Content = grid;
            Loaded += (s, e) => Load();
        }

        private async void Load()
        {
            if (disposed || !session.IsAuthenticated) return;
            long mine = ++request, generation = session.Generation, readRevision = session.ReadScopeRevision;
            refresh.IsEnabled = false; status.Text = "正在读取工作台…";
            try
            {
                string json = await session.GetAsync("/dashboard/overview", cancellation.Token);
                if (disposed || mine != request || generation != session.Generation || readRevision != session.ReadScopeRevision) return;
                var data = new JavaScriptSerializer { MaxJsonLength = 8 * 1024 * 1024 }.DeserializeObject(json) as Dictionary<string, object>;
                if (data == null) throw new FormatException();
                metrics.Children.Clear(); todos.Children.Clear();
                foreach (var item in Objects(data, "metrics"))
                {
                    var row = new DockPanel();
                    var value = new TextBlock { Text = Text(item, "value"), FontSize = 23, FontWeight = FontWeights.SemiBold, Margin = new Thickness(20, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
                    DockPanel.SetDock(value, Dock.Right); row.Children.Add(value);
                    var caption = new StackPanel(); caption.Children.Add(new TextBlock { Text = Text(item, "title"), FontWeight = FontWeights.SemiBold });
                    caption.Children.Add(new TextBlock { Text = Text(item, "subtitle"), Foreground = Brush("Uten.Muted"), FontSize = (double)FindResource("Uten.FontSize.Caption"), Margin = new Thickness(0, Space("S4"), 0, 0) });
                    row.Children.Add(caption); metrics.Children.Add(Surface(row));
                }
                foreach (var item in Objects(data, "todos"))
                {
                    var caption = new StackPanel(); caption.Children.Add(new TextBlock { Text = Text(item, "title"), FontWeight = FontWeights.SemiBold });
                    caption.Children.Add(new TextBlock { Text = Text(item, "summary"), Foreground = Brush("Uten.Muted"), Margin = new Thickness(0, 6, 0, 0) });
                    string route = Text(item, "route");
                    if (route == "/basic-data/goods" && session.CurrentUser.HasPermission("goods:view"))
                    {
                        var open = new Button { Content = "查看", HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 10, 0, 0) };
                        open.Click += (s, e) => openGoods(); caption.Children.Add(open);
                    }
                    todos.Children.Add(Surface(caption));
                }
                if (metrics.Children.Count == 0) metrics.Children.Add(new TextBlock { Text = "当前没有可显示的概览指标。", Foreground = Brush("Uten.Muted") });
                if (todos.Children.Count == 0) todos.Children.Add(new TextBlock { Text = "当前没有待办任务。", Foreground = Brush("Uten.Muted") });
                status.Text = Text(data, "departmentName");
            }
            catch (OperationCanceledException) { }
            catch (ApiException error)
            {
                if (!disposed && mine == request)
                {
                    if (error.Code == "READ_SCOPE_CHANGED" || error.StatusCode == 403) { metrics.Children.Clear(); todos.Children.Clear(); }
                    status.Text = error.UserMessage;
                }
            }
            catch (Exception) { if (!disposed && mine == request) status.Text = "工作台数据暂时加载失败，请刷新重试。"; }
            finally { if (!disposed && mine == request) refresh.IsEnabled = true; }
        }

        private Border Surface(UIElement child) { return new RoundedSurface { Child = child, Background = Brush("Uten.Surface"), BorderBrush = Brush("Uten.Border"), BorderThickness = new Thickness(1), CornerRadius = (CornerRadius)FindResource("Uten.Radius.Card"), Padding = (Thickness)FindResource("Uten.Padding.S16"), Margin = new Thickness(0, 0, 0, Space("S12")) }; }
        private double Space(string key) { return (double)FindResource("Uten.Space." + key); }
        private Brush Brush(string key) { return (Brush)FindResource(key); }
        private static string Text(IDictionary<string, object> value, string key) { object item; return value.TryGetValue(key, out item) && item != null ? Convert.ToString(item, System.Globalization.CultureInfo.InvariantCulture) : ""; }
        private static IEnumerable<Dictionary<string, object>> Objects(IDictionary<string, object> value, string key)
        {
            object raw; if (!value.TryGetValue(key, out raw) || !(raw is IEnumerable)) yield break;
            foreach (object item in (IEnumerable)raw) if (item is Dictionary<string, object>) yield return (Dictionary<string, object>)item;
        }
        public void Dispose() { disposed = true; ++request; cancellation.Cancel(); cancellation.Dispose(); }
    }
}
