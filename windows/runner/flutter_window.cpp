#include "flutter_window.h"

#include <optional>

#include <shellapi.h>

#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"

namespace {
constexpr wchar_t kTrayTooltip[] = L"CPAClient";
constexpr wchar_t kAutoStartArg[] = L"--cpaclient-autostart";

bool IsAutoStartLaunch() {
  int argc = 0;
  wchar_t** argv = CommandLineToArgvW(GetCommandLineW(), &argc);
  if (argv == nullptr) {
    return false;
  }

  bool matched = false;
  for (int i = 0; i < argc; ++i) {
    if (wcscmp(argv[i], kAutoStartArg) == 0) {
      matched = true;
      break;
    }
  }

  LocalFree(argv);
  return matched;
}
}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  SetupTrayChannel();

  const bool auto_start_launch = IsAutoStartLaunch();
  flutter_controller_->engine()->SetNextFrameCallback([&, auto_start_launch]() {
    if (!auto_start_launch) {
      this->Show();
    }
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  DestroyTray();
  tray_channel_.reset();

  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::SetupTrayChannel() {
  tray_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "cpaclient/tray",
      &flutter::StandardMethodCodec::GetInstance());

  tray_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        HandleTrayMethodCall(call, std::move(result));
      });
}

void FlutterWindow::HandleTrayMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const auto* args = call.arguments() == nullptr
                         ? nullptr
                         : std::get_if<flutter::EncodableMap>(call.arguments());

  if (call.method_name() == "initialize") {
    if (!args) {
      result->Error("invalid_args", "initialize requires map arguments");
      return;
    }
    InitializeTray(*args);
    result->Success();
    return;
  }

  if (call.method_name() == "popUpContextMenu") {
    PopUpContextMenu();
    result->Success();
    return;
  }

  if (call.method_name() == "destroy") {
    DestroyTray();
    result->Success();
    return;
  }

  result->NotImplemented();
}

void FlutterWindow::InitializeTray(const flutter::EncodableMap& arguments) {
  DestroyTray();

  tray_icon_data_ = {};
  tray_icon_data_.cbSize = sizeof(NOTIFYICONDATAW);
  tray_icon_data_.hWnd = GetHandle();
  tray_icon_data_.uID = 1;
  tray_icon_data_.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  tray_icon_data_.uCallbackMessage = tray_callback_message_;

  auto icon_it = arguments.find(flutter::EncodableValue("iconPath"));
  if (icon_it != arguments.end()) {
    const auto* icon_path = std::get_if<std::string>(&icon_it->second);
    if (icon_path && !icon_path->empty()) {
      tray_icon_handle_ = static_cast<HICON>(LoadImageA(
          nullptr, icon_path->c_str(), IMAGE_ICON, 0, 0,
          LR_LOADFROMFILE | LR_DEFAULTSIZE));
    }
  }
  if (tray_icon_handle_ == nullptr) {
    tray_icon_handle_ = LoadIcon(GetModuleHandle(nullptr),
                                 MAKEINTRESOURCE(IDI_APP_ICON));
  }
  tray_icon_data_.hIcon = tray_icon_handle_;

  auto tooltip_it = arguments.find(flutter::EncodableValue("toolTip"));
  std::wstring tooltip = kTrayTooltip;
  if (tooltip_it != arguments.end()) {
    if (const auto* value = std::get_if<std::string>(&tooltip_it->second)) {
      tooltip.assign(value->begin(), value->end());
    }
  }
  wcsncpy_s(tray_icon_data_.szTip, _countof(tray_icon_data_.szTip),
            tooltip.c_str(), _TRUNCATE);

  Shell_NotifyIconW(NIM_ADD, &tray_icon_data_);
  tray_initialized_ = true;

  auto menu_it = arguments.find(flutter::EncodableValue("menuItems"));
  if (menu_it != arguments.end()) {
    if (const auto* menu_items = std::get_if<flutter::EncodableList>(&menu_it->second)) {
      RebuildTrayMenu(*menu_items);
    }
  }
}

void FlutterWindow::RebuildTrayMenu(const flutter::EncodableList& menu_items) {
  if (tray_menu_) {
    DestroyMenu(tray_menu_);
    tray_menu_ = nullptr;
  }
  tray_command_keys_.clear();
  next_tray_command_id_ = 50000;

  tray_menu_ = CreatePopupMenu();
  if (!tray_menu_) {
    return;
  }

  for (const auto& item_value : menu_items) {
    const auto* item = std::get_if<flutter::EncodableMap>(&item_value);
    if (!item) {
      continue;
    }

    auto separator_it = item->find(flutter::EncodableValue("separator"));
    if (separator_it != item->end()) {
      if (const auto* is_separator = std::get_if<bool>(&separator_it->second);
          is_separator && *is_separator) {
        AppendMenuW(tray_menu_, MF_SEPARATOR, 0, nullptr);
        continue;
      }
    }

    auto key_it = item->find(flutter::EncodableValue("key"));
    auto label_it = item->find(flutter::EncodableValue("label"));
    if (key_it == item->end() || label_it == item->end()) {
      continue;
    }

    const auto* key = std::get_if<std::string>(&key_it->second);
    const auto* label = std::get_if<std::string>(&label_it->second);
    if (!key || !label) {
      continue;
    }

    UINT command_id = next_tray_command_id_++;
    std::wstring wlabel(label->begin(), label->end());
    AppendMenuW(tray_menu_, MF_STRING, command_id, wlabel.c_str());
    tray_command_keys_.insert({command_id, *key});
  }
}

void FlutterWindow::PopUpContextMenu() {
  if (!tray_menu_) {
    return;
  }
  POINT cursor;
  GetCursorPos(&cursor);
  SetForegroundWindow(GetHandle());
  TrackPopupMenu(tray_menu_, TPM_BOTTOMALIGN | TPM_LEFTALIGN, cursor.x,
                 cursor.y, 0, GetHandle(), nullptr);
  PostMessage(GetHandle(), WM_NULL, 0, 0);
}

void FlutterWindow::DestroyTray() {
  if (tray_initialized_) {
    Shell_NotifyIconW(NIM_DELETE, &tray_icon_data_);
    tray_initialized_ = false;
  }
  if (tray_menu_) {
    DestroyMenu(tray_menu_);
    tray_menu_ = nullptr;
  }
  tray_command_keys_.clear();
  if (tray_icon_handle_) {
    DestroyIcon(tray_icon_handle_);
    tray_icon_handle_ = nullptr;
  }
  tray_icon_data_ = {};
}

void FlutterWindow::SendTrayEvent(const std::string& method,
                                  const flutter::EncodableMap* arguments) {
  if (!tray_channel_) {
    return;
  }
  if (arguments) {
    tray_channel_->InvokeMethod(method, std::make_unique<flutter::EncodableValue>(*arguments));
    return;
  }
  tray_channel_->InvokeMethod(method, nullptr);
}

LRESULT FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                                      WPARAM const wparam,
                                      LPARAM const lparam) noexcept {
  if (message == tray_callback_message_) {
    switch (lparam) {
      case WM_LBUTTONDOWN:
        SendTrayEvent("onTrayIconMouseDown");
        break;
      case WM_RBUTTONDOWN:
        SendTrayEvent("onTrayIconRightMouseDown");
        break;
      default:
        break;
    }
    return 0;
  }

  if (message == WM_COMMAND) {
    UINT command_id = LOWORD(wparam);
    auto it = tray_command_keys_.find(command_id);
    if (it != tray_command_keys_.end()) {
      flutter::EncodableMap args = {
          {flutter::EncodableValue("key"), flutter::EncodableValue(it->second)}};
      SendTrayEvent("onTrayMenuItemClick", &args);
      return 0;
    }
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
