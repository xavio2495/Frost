# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Frost is a Tauri 2 desktop application with a SvelteKit + TypeScript frontend. Currently scaffolded from the official Tauri+SvelteKit+TS template (a single `greet` Rust command wired to a Svelte page) — there is no project-specific business logic yet.

## Commands

All commands are run from the repo root (`D:\Frost\frost`).

- `npm run tauri dev` — run the full desktop app (starts Vite dev server on port 1420, then launches the Tauri shell). This is the primary dev loop.
- `npm run dev` — run the SvelteKit frontend only in the browser.
- `npm run tauri build` — produce a release desktop bundle.
- `npm run build` — build the frontend only (output goes to `build/`, consumed by Tauri via `frontendDist: "../build"`).
- `npm run check` — type-check Svelte + TypeScript (`svelte-kit sync && svelte-check`). Use `check:watch` for the watching variant.
- Rust side: `cargo check` / `cargo build` / `cargo test` from inside `src-tauri/`. There is no JS test runner configured.

## Architecture

Two halves communicate over Tauri's IPC bridge:

- **Frontend** (`src/`): SvelteKit in SPA mode. `svelte.config.js` uses `@sveltejs/adapter-static` with `fallback: "index.html"` because Tauri has no Node SSR runtime. Routes live in `src/routes/`. Svelte 5 runes (`$state`, etc.) are in use.
- **Backend** (`src-tauri/`): Rust crate named `frost_lib` (the `_lib` suffix is intentional — see comment in `Cargo.toml`; it avoids a Windows-only bin/lib name collision). `src/lib.rs` defines `#[tauri::command]` handlers and registers them via `invoke_handler(tauri::generate_handler![...])` in `run()`. `src/main.rs` just calls `frost_lib::run()`.

To add a new IPC command: define a `#[tauri::command] fn ...` in `src-tauri/src/lib.rs`, add it to the `generate_handler!` macro list, then call it from Svelte with `invoke("name", { args })` from `@tauri-apps/api/core`.

## Capabilities & permissions

`src-tauri/capabilities/default.json` is the allowlist for what the main window can do. Currently only `core:default` and `opener:default` (from `tauri-plugin-opener`) are granted. New Tauri APIs / plugins must be added here or IPC calls from the frontend will be rejected at runtime.

## Tauri config notes

- `tauri.conf.json` pins `devUrl` to `http://localhost:1420` — `vite.config.js` must keep serving on that port for `tauri dev` to attach.
- `frontendDist` is `../build`, matching `adapter-static`'s default output.
- Bundle identifier is `app.vercel.port42`.
