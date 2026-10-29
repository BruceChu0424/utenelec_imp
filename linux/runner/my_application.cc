#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#include <sys/utsname.h>
#include <cstring>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Store/package-manager updates use the actual installed build, never a Dart
// fallback version that could keep prompting after a successful update.
static void client_update_method_call_cb(FlMethodChannel* channel,
                                        FlMethodCall* method_call,
                                        gpointer user_data) {
  (void)channel;
  (void)user_data;
  if (g_strcmp0(fl_method_call_get_name(method_call), "getSoftwareDownloadHost") == 0) {
    struct utsname system = {};
    const bool read = uname(&system) == 0;
    const char* machine = read ? system.machine : "unknown";
    const char* architecture = std::strcmp(machine, "x86_64") == 0 ? "x64"
        : std::strcmp(machine, "aarch64") == 0 || std::strcmp(machine, "arm64") == 0 ? "arm64"
        : std::strcmp(machine, "i386") == 0 || std::strcmp(machine, "i686") == 0 ? "x86" : "unknown";
    g_autoptr(FlValue) host = fl_value_new_map();
    fl_value_set_string_take(host, "platform", fl_value_new_string("linux"));
    fl_value_set_string_take(host, "architecture", fl_value_new_string(architecture));
    fl_value_set_string_take(host, "osVersion", fl_value_new_string(read ? system.release : ""));
    fl_value_set_string_take(host, "osLabel", fl_value_new_string("Linux"));
    // uname supplies kernel facts, not a fabricated distribution product version.
    fl_value_set_string_take(host, "osMajor", fl_value_new_int(0));
    fl_value_set_string_take(host, "osMinor", fl_value_new_int(0));
    fl_value_set_string_take(host, "osBuild", fl_value_new_int(0));
    fl_value_set_string_take(host, "servicePackMajor", fl_value_new_int(0));
    fl_value_set_string_take(host, "isServer", fl_value_new_bool(FALSE));
    fl_value_set_string_take(host, "isSimulator", fl_value_new_bool(FALSE));
    g_autoptr(FlMethodResponse) response = FL_METHOD_RESPONSE(fl_method_success_response_new(host));
    fl_method_call_respond(method_call, response, nullptr);
    return;
  }
  if (g_strcmp0(fl_method_call_get_name(method_call), "getInstallContext") != 0) {
    g_autoptr(FlMethodResponse) response =
        FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
    fl_method_call_respond(method_call, response, nullptr);
    return;
  }
#if defined(__aarch64__)
  const gchar* architecture = "arm64";
#elif defined(__x86_64__)
  const gchar* architecture = "x64";
#else
  const gchar* architecture = "universal";
#endif
  g_autofree gchar* staging = g_build_filename(g_get_user_cache_dir(),
      "com.uten.uten_imp", "client-updates", nullptr);
  g_mkdir_with_parents(staging, 0700);
  g_autoptr(FlValue) context = fl_value_new_map();
  fl_value_set_string_take(context, "platform", fl_value_new_string("linux"));
  fl_value_set_string_take(context, "architecture", fl_value_new_string(architecture));
  fl_value_set_string_take(context, "currentVersion", fl_value_new_string(FLUTTER_VERSION));
  fl_value_set_string_take(context, "currentBuild", fl_value_new_int(FLUTTER_VERSION_BUILD));
  fl_value_set_string_take(context, "stagingDirectory", fl_value_new_string(staging));
  fl_value_set_string_take(context, "supportsInPlaceUpdate", fl_value_new_bool(FALSE));
  fl_value_set_string_take(context, "requiresSystemConfirmation", fl_value_new_bool(TRUE));
  g_autoptr(FlMethodResponse) response = FL_METHOD_RESPONSE(fl_method_success_response_new(context));
  fl_method_call_respond(method_call, response, nullptr);
}

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "UTEN");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "UTEN");
  }

  gtk_window_set_default_size(window, 1280, 720);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));
  g_autoptr(FlStandardMethodCodec) client_update_codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) client_update_channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      "com.uten.imp/client_update", FL_METHOD_CODEC(client_update_codec));
  fl_method_channel_set_method_call_handler(client_update_channel,
      client_update_method_call_cb, nullptr, nullptr);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_NON_UNIQUE, nullptr));
}
