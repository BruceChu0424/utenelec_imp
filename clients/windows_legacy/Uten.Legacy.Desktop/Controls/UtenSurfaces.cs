using System.Windows;
using System.Windows.Controls;

namespace Uten.Legacy.Desktop.Controls
{
    public enum UtenSurfaceRole { Card, Table, Dialog, Menu }

    /// <summary>Single programmatic entry for themed surfaces and real child clipping.
    /// Different semantic radii remain different; callers do not copy numeric corner values.</summary>
    public static class UtenSurfaces
    {
        public static RoundedSurface Wrap(UIElement child, UtenSurfaceRole role = UtenSurfaceRole.Card, bool outlined = true)
        {
            var surface = new RoundedSurface { Child = child, BorderThickness = new Thickness(outlined ? 1 : 0) };
            surface.SetResourceReference(Border.CornerRadiusProperty, "Uten.Radius." + role);
            surface.SetResourceReference(Border.BackgroundProperty, "Uten.Surface");
            surface.SetResourceReference(Border.BorderBrushProperty, "Uten.Border");
            return surface;
        }
    }
}
