#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#ifdef HAVE_AYATANA_APPINDICATOR
#include <libayatana-appindicator/app-indicator.h>
#else
#include <libappindicator/app-indicator.h>
#endif

#include "flutter/generated_plugin_registrant.h"

#include <cstring>
#include <map>
#include <string>

static constexpr char kTrayChannelName[] = "cpaclient/tray";

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  FlMethodChannel* tray_channel;
  AppIndicator* indicator;
  GtkWidget* tray_menu;
  std::map<GtkWidget*, std::string>* tray_item_keys;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

static void set_window_icon(GtkWindow* window) {
  g_autofree gchar* exe_path = g_file_read_link("/proc/self/exe", nullptr);
  if (exe_path == nullptr) {
    return;
  }

  g_autofree gchar* exe_dir = g_path_get_dirname(exe_path);
  g_autofree gchar* icon_path =
      g_build_filename(exe_dir, "data", "app_icon.png", nullptr);

  if (!g_file_test(icon_path, G_FILE_TEST_EXISTS)) {
    return;
  }

  g_autoptr(GError) error = nullptr;
  gtk_window_set_icon_from_file(window, icon_path, &error);
}

static void tray_send_event(MyApplication* self, const char* method,
                            FlValue* args) {
  if (self->tray_channel == nullptr) {
    return;
  }
  fl_method_channel_invoke_method(self->tray_channel, method, args, nullptr,
                                  nullptr, nullptr);
}

static void on_tray_menu_item_activate(GtkMenuItem* item, gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  if (self->tray_item_keys == nullptr) {
    return;
  }
  auto it = self->tray_item_keys->find(GTK_WIDGET(item));
  if (it == self->tray_item_keys->end()) {
    return;
  }

  g_autoptr(FlValue) args = fl_value_new_map();
  fl_value_set_string_take(args, "key", fl_value_new_string(it->second.c_str()));
  tray_send_event(self, "onTrayMenuItemClick", args);
}

static GtkWidget* build_tray_menu(MyApplication* self, FlValue* menu_items) {
  GtkWidget* menu = gtk_menu_new();
  if (menu_items == nullptr ||
      fl_value_get_type(menu_items) != FL_VALUE_TYPE_LIST) {
    return menu;
  }

  if (self->tray_item_keys == nullptr) {
    self->tray_item_keys = new std::map<GtkWidget*, std::string>();
  } else {
    self->tray_item_keys->clear();
  }

  const size_t count = fl_value_get_length(menu_items);
  for (size_t i = 0; i < count; i++) {
    FlValue* item = fl_value_get_list_value(menu_items, i);
    if (item == nullptr || fl_value_get_type(item) != FL_VALUE_TYPE_MAP) {
      continue;
    }

    FlValue* separator_value = fl_value_lookup_string(item, "separator");
    if (separator_value != nullptr &&
        fl_value_get_type(separator_value) == FL_VALUE_TYPE_BOOL &&
        fl_value_get_bool(separator_value)) {
      gtk_menu_shell_append(GTK_MENU_SHELL(menu),
                            gtk_separator_menu_item_new());
      continue;
    }

    FlValue* key_value = fl_value_lookup_string(item, "key");
    FlValue* label_value = fl_value_lookup_string(item, "label");
    if (key_value == nullptr || label_value == nullptr ||
        fl_value_get_type(key_value) != FL_VALUE_TYPE_STRING ||
        fl_value_get_type(label_value) != FL_VALUE_TYPE_STRING) {
      continue;
    }

    const char* key = fl_value_get_string(key_value);
    const char* label = fl_value_get_string(label_value);
    GtkWidget* menu_item = gtk_menu_item_new_with_label(label);
    self->tray_item_keys->insert({menu_item, key});
    g_signal_connect(G_OBJECT(menu_item), "activate",
                     G_CALLBACK(on_tray_menu_item_activate), self);
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), menu_item);
  }

  gtk_widget_show_all(menu);
  return menu;
}

static void tray_destroy(MyApplication* self) {
  if (self->indicator != nullptr) {
    app_indicator_set_status(self->indicator, APP_INDICATOR_STATUS_PASSIVE);
    g_object_unref(self->indicator);
    self->indicator = nullptr;
  }
  if (self->tray_menu != nullptr) {
    gtk_widget_destroy(self->tray_menu);
    self->tray_menu = nullptr;
  }
  if (self->tray_item_keys != nullptr) {
    self->tray_item_keys->clear();
  }
}

static void tray_initialize(MyApplication* self, FlValue* args) {
  FlValue* icon_path_value = fl_value_lookup_string(args, "iconPath");
  FlValue* tooltip_value = fl_value_lookup_string(args, "toolTip");
  FlValue* menu_items_value = fl_value_lookup_string(args, "menuItems");

  const char* icon_path = nullptr;
  if (icon_path_value != nullptr &&
      fl_value_get_type(icon_path_value) == FL_VALUE_TYPE_STRING) {
    icon_path = fl_value_get_string(icon_path_value);
  }

  const char* tooltip = "CPAClient";
  if (tooltip_value != nullptr &&
      fl_value_get_type(tooltip_value) == FL_VALUE_TYPE_STRING) {
    tooltip = fl_value_get_string(tooltip_value);
  }

  tray_destroy(self);

  self->indicator = app_indicator_new(
      "cpaclient", icon_path == nullptr ? "" : icon_path,
      APP_INDICATOR_CATEGORY_APPLICATION_STATUS);
  if (self->indicator == nullptr) {
    g_warning("Tray initialize failed: app indicator unavailable");
    return;
  }

  self->tray_menu = build_tray_menu(self, menu_items_value);
  app_indicator_set_menu(self->indicator, GTK_MENU(self->tray_menu));
  app_indicator_set_status(self->indicator, APP_INDICATOR_STATUS_ACTIVE);
  app_indicator_set_title(self->indicator, tooltip);

  if (icon_path != nullptr && std::strlen(icon_path) > 0) {
    app_indicator_set_icon_full(self->indicator, icon_path, tooltip);
  }
}

static void tray_pop_up_context_menu(MyApplication* self) {
  if (self->tray_menu == nullptr) {
    return;
  }
  gtk_menu_popup_at_pointer(GTK_MENU(self->tray_menu), nullptr);
}

static void tray_handle_method_call(MyApplication* self,
                                    FlMethodCall* method_call) {
  g_autoptr(FlMethodResponse) response = nullptr;
  const gchar* method = fl_method_call_get_name(method_call);
  FlValue* args = fl_method_call_get_args(method_call);

  if (strcmp(method, "initialize") == 0) {
    if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
      response = FL_METHOD_RESPONSE(fl_method_error_response_new(
          "invalid_args", "initialize requires map arguments", nullptr));
    } else {
      tray_initialize(self, args);
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
    }
  } else if (strcmp(method, "popUpContextMenu") == 0) {
    tray_pop_up_context_menu(self);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (strcmp(method, "destroy") == 0) {
    tray_destroy(self);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  fl_method_call_respond(method_call, response, nullptr);
}

static void tray_method_call_cb(FlMethodChannel* channel,
                                FlMethodCall* method_call,
                                gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  tray_handle_method_call(self, method_call);
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

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
    gtk_header_bar_set_title(header_bar, "cpaclient");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "cpaclient");
  }

  gtk_window_set_default_size(window, 1280, 720);
  set_window_icon(window);
  gtk_widget_show(GTK_WIDGET(window));

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(project,
                                                self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->tray_channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      kTrayChannelName, FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(self->tray_channel,
                                            tray_method_call_cb,
                                            g_object_ref(self),
                                            g_object_unref);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
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
  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  tray_destroy(self);
  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  if (self->tray_channel != nullptr) {
    g_clear_object(&self->tray_channel);
  }
  if (self->tray_item_keys != nullptr) {
    delete self->tray_item_keys;
    self->tray_item_keys = nullptr;
  }
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
  self->tray_channel = nullptr;
  self->indicator = nullptr;
  self->tray_menu = nullptr;
  self->tray_item_keys = nullptr;
}

MyApplication* my_application_new() {
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID,
                                     "flags", G_APPLICATION_NON_UNIQUE,
                                     nullptr));
}
