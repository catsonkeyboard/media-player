#include "my_application.h"

// _exit(0)：进程级硬退出（见 app_destroy_window 说明）。
#include <unistd.h>

// media_kit_video 插件导出的弱符号：关窗开始即置位，此后 VideoOutput 释放
// 时保留 EGL 资源——引擎关闭期间销毁 GL 对象会触发 Mesa UAF 崩溃。
// Dart 侧通道投递在引擎繁忙时会延迟数秒，来不及在播放器释放前生效，
// 因此由 runner 在 delete-event 里同步调用。
extern "C" void media_kit_video_set_engine_terminating(gboolean value)
    __attribute__((weak));

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"


struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  FlMethodChannel* app_channel;  // app/native：优雅退出握手
  GtkWindow* window;             // 主窗口，握手完成后销毁
  gboolean terminating;
  guint terminate_timeout_id;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// 退出路径：摘除窗口后硬退。不能走正常 main 返回/窗口销毁：Flutter 引擎
// teardown 在本机（Impeller/GLES + Mesa）不稳定——大纹理下
// gtk_widget_destroy 内部即会触发引擎线程 use-after-free 崩溃（4K 易复现），
// 且普遍拖长退出数秒。Dart 侧已完成落盘与 mpv 释放，直接 _exit(0) 跳过
// 引擎清理；窗口由 X server 随进程回收。
static void app_destroy_window(MyApplication* self) {
  if (self->terminate_timeout_id != 0) {
    g_source_remove(self->terminate_timeout_id);
    self->terminate_timeout_id = 0;
  }
  if (self->window != nullptr) {
    GtkWindow* window = self->window;
    self->window = nullptr;
    gtk_widget_hide(GTK_WIDGET(window));
  }
  g_timeout_add(200, [](gpointer) -> gboolean {
    fflush(nullptr);
    _exit(0);
  }, nullptr);
}

// 握手兜底：Dart 侧未在时限内回 terminateNow 时强制退出。
static gboolean app_terminate_timeout(gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  self->terminate_timeout_id = 0;
  app_destroy_window(self);
  return G_SOURCE_REMOVE;
}

// 首次关闭：阻止 GTK 立即销毁窗口，先让 Dart 释放 libmpv（落盘进度、
// 销毁播放器），收到 terminateNow（或超时）后再真正退出。
static gboolean app_delete_event(GtkWidget* widget, GdkEvent* event,
                                 gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  if (self->terminating) {
    return TRUE;
  }
  self->terminating = TRUE;
  if (media_kit_video_set_engine_terminating) {
    media_kit_video_set_engine_terminating(TRUE);
  }
  if (self->app_channel != nullptr) {
    fl_method_channel_invoke_method(self->app_channel, "appWillTerminate",
                                    nullptr, nullptr, nullptr, nullptr);
  }
  self->terminate_timeout_id =
      g_timeout_add(15000, app_terminate_timeout, self);
  return TRUE;
}

static void app_window_destroyed(GtkWidget* widget, gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  self->window = nullptr;
}

// Dart 侧 appWillTerminate 处理完成后回包，此处隐藏窗口并硬退。
static void app_method_call_cb(FlMethodChannel* channel, FlMethodCall* call,
                               gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  const gchar* name = fl_method_call_get_name(call);
  if (g_strcmp0(name, "terminateNow") == 0) {
    g_autoptr(FlMethodResponse) response =
        FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
    GError* error = nullptr;
    if (!fl_method_call_respond(call, response, &error)) {
      g_warning("Failed to respond to terminateNow: %s", error->message);
      g_error_free(error);
    }
    app_destroy_window(self);
  } else {
    g_autoptr(FlMethodResponse) response =
        FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
    GError* error = nullptr;
    if (!fl_method_call_respond(call, response, &error)) {
      g_warning("Failed to respond to %s: %s", name, error->message);
      g_error_free(error);
    }
  }
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup that most users will be using (e.g.
  // Ubuntu desktop).
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
    gtk_header_bar_set_title(header_bar, "media_player");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "media_player");
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

  // 优雅退出握手：与 macOS/Windows Runner 相同的 app/native 通道。
  // 关窗时先通知 Dart 释放 libmpv（落盘进度、销毁播放器），回 terminateNow
  // 后再销毁窗口，避免进程在引擎退出阶段被 mpv 线程拖住数十秒。
  self->window = window;
  g_signal_connect(window, "destroy", G_CALLBACK(app_window_destroyed), self);
  g_signal_connect(window, "delete-event", G_CALLBACK(app_delete_event), self);
  g_autoptr(FlStandardMethodCodec) app_codec = fl_standard_method_codec_new();
  self->app_channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)), "app/native",
      FL_METHOD_CODEC(app_codec));
  fl_method_channel_set_method_call_handler(
      self->app_channel, app_method_call_cb, g_object_ref(self),
      g_object_unref);

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
  if (self->terminate_timeout_id != 0) {
    g_source_remove(self->terminate_timeout_id);
    self->terminate_timeout_id = 0;
  }
  g_clear_object(&self->app_channel);
  self->window = nullptr;
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

static void my_application_init(MyApplication* self) {
  self->app_channel = nullptr;
  self->window = nullptr;
  self->terminating = FALSE;
  self->terminate_timeout_id = 0;
}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map a running application to its
  // corresponding .desktop file. This ensures that the application can be
  // recognized beyond just the binary name and allows the application to be
  // recognized beyond the running process.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_NON_UNIQUE, nullptr));
}
