// 桌面端可执行入口。
// Prevents an additional console window on Windows in release builds.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    alger_music_lib::run()
}
