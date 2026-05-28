//! Sub-agent key storage backed by the OS credential vault.
//!
//! On Windows this is DPAPI (Credential Manager), on macOS the Keychain, on
//! Linux Secret Service (gnome-keyring / kwallet). All access is mediated by
//! the OS, so secrets are protected at rest by the user's login session.
//!
//! Each sub-agent has a stable `agent_id` (a UUID, generated when the agent
//! is provisioned). The keyring entry is namespaced as
//! `frost:subagent:<agent_id>` so multiple agents coexist cleanly and the
//! Frost service name keeps Frost entries discoverable in OS tooling.

use keyring::Entry;
use serde::{Deserialize, Serialize};
use zeroize::Zeroize;

const SERVICE: &str = "frost";

#[derive(Debug, thiserror::Error, Serialize)]
#[serde(tag = "kind", content = "message")]
pub enum KeyStoreError {
    #[error("keyring backend error: {0}")]
    Backend(String),
    #[error("no key for agent {0}")]
    NotFound(String),
}

fn entry(agent_id: &str) -> Result<Entry, KeyStoreError> {
    Entry::new(SERVICE, &format!("subagent:{agent_id}"))
        .map_err(|e| KeyStoreError::Backend(e.to_string()))
}

#[derive(Debug, Deserialize)]
pub struct StoreArgs {
    pub agent_id: String,
    pub private_key_hex: String,
}

#[tauri::command]
pub fn key_store_set(args: StoreArgs) -> Result<(), KeyStoreError> {
    let mut secret = args.private_key_hex;
    let res = entry(&args.agent_id)?
        .set_password(&secret)
        .map_err(|e| KeyStoreError::Backend(e.to_string()));
    secret.zeroize();
    res
}

#[tauri::command]
pub fn key_store_get(agent_id: String) -> Result<String, KeyStoreError> {
    let e = entry(&agent_id)?;
    match e.get_password() {
        Ok(pw) => Ok(pw),
        Err(keyring::Error::NoEntry) => Err(KeyStoreError::NotFound(agent_id)),
        Err(err) => Err(KeyStoreError::Backend(err.to_string())),
    }
}

#[tauri::command]
pub fn key_store_delete(agent_id: String) -> Result<(), KeyStoreError> {
    let e = entry(&agent_id)?;
    match e.delete_credential() {
        Ok(()) => Ok(()),
        Err(keyring::Error::NoEntry) => Err(KeyStoreError::NotFound(agent_id)),
        Err(err) => Err(KeyStoreError::Backend(err.to_string())),
    }
}

#[tauri::command]
pub fn key_store_has(agent_id: String) -> Result<bool, KeyStoreError> {
    let e = entry(&agent_id)?;
    match e.get_password() {
        Ok(_) => Ok(true),
        Err(keyring::Error::NoEntry) => Ok(false),
        Err(err) => Err(KeyStoreError::Backend(err.to_string())),
    }
}
