mod key_store;
mod wallet_bridge;

// Learn more about Tauri commands at https://tauri.app/develop/calling-rust/
#[tauri::command]
fn greet(name: &str) -> String {
    format!("Hello, {}! You've been greeted from Rust!", name)
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .invoke_handler(tauri::generate_handler![
            greet,
            wallet_bridge::wallet_bridge_perform,
            key_store::key_store_set,
            key_store::key_store_get,
            key_store::key_store_delete,
            key_store::key_store_has,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
