cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "dj_camera_channel.cpp"
  "dj_cursor_channel.cpp"
  "dj_hotkey.cpp"
  "dj_input_channel.cpp"
  "dj_screen_channel.cpp"
  "dj_system_channel.cpp"
  "dj_tray.cpp"
  "dj_voice_channel.cpp"
  "flutter_window.cpp"
  "main.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
# DJ native channels: shell32 (ShellExecuteW, SHFileOperationW,
# SHGetKnownFolderPath), ole32 (IFileDialog COM), uuid (COM GUIDs:
# CLSID_FileOpenDialog, IID_IFileDialog/IShellItem, FOLDERID_*),
# sapi (ISpVoice TTS), winhttp (whisper-server inference POST),
# gdiplus (screenshot PNG encode), mfplat/mf/mfreadwrite/mfuuid/shlwapi
# (Privacy Screen in-memory webcam capture via Media Foundation).
# NOTE: the KS property-set GUID (KSPROPERTYSETID_ExtendedCameraControl)
# is deliberately NOT linked here: ksguid.lib is not shipped in the
# Windows SDK, so dj_camera_channel.cpp instantiates it in its own
# translation unit via <initguid.h> instead.
target_link_libraries(${BINARY_NAME} PRIVATE "shell32.lib" "ole32.lib"
                                             "uuid.lib" "sapi.lib"
                                             "winhttp.lib" "gdiplus.lib"
                                             "mfplat.lib" "mf.lib"
                                             "mfreadwrite.lib" "mfuuid.lib"
                                             "shlwapi.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)
