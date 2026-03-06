use axum::routing::{get, post};
use clap::Parser;
use color_eyre::eyre::Result;
use rbx_studio_server::*;
use rmcp::model::{LoggingLevel, LoggingMessageNotificationParam};
use rmcp::ServiceExt;
use std::io;
use std::net::Ipv4Addr;
use std::sync::Arc;
use tokio::sync::Mutex;
use tokio::time::Duration;
use tracing_subscriber::{self, EnvFilter};
mod error;
mod install;
mod rbx_studio_server;

/// Simple MCP proxy for Roblox Studio
/// Run without arguments to install the plugin
#[derive(Parser)]
#[command(version, about, long_about = None)]
struct Args {
    /// Run as MCP server on stdio
    #[arg(short, long)]
    stdio: bool,

    /// Port to listen on for Studio plugin connections.
    /// If omitted, automatically selects from the range 44755-44759.
    #[arg(short, long)]
    port: Option<u16>,
}

async fn try_bind_port(port: u16) -> Option<tokio::net::TcpListener> {
    tokio::net::TcpListener::bind((Ipv4Addr::new(127, 0, 0, 1), port))
        .await
        .ok()
}

#[tokio::main]
async fn main() -> Result<()> {
    color_eyre::install()?;
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::from_default_env())
        .with_writer(io::stderr)
        .with_target(false)
        .with_thread_ids(true)
        .init();

    let args = Args::parse();
    if !args.stdio {
        return install::install().await;
    }

    tracing::debug!("Debug MCP tracing enabled");

    let (close_tx, close_rx) = tokio::sync::oneshot::channel();

    let (bound_port, label, server_handle) = if let Some(explicit_port) = args.port {
        let label = port_label(explicit_port);
        let server_state = Arc::new(Mutex::new(AppState::new(label.clone())));
        let server_state_clone = Arc::clone(&server_state);

        let handle = if let Some(listener) = try_bind_port(explicit_port).await {
            let app = axum::Router::new()
                .route("/request", get(request_handler))
                .route("/response", post(response_handler))
                .route("/proxy", post(proxy_handler))
                .route("/status", get(status_handler))
                .with_state(Arc::clone(&server_state));
            tracing::info!("HTTP server listening on {explicit_port} ({label})");
            tokio::spawn(async {
                axum::serve(listener, app)
                    .with_graceful_shutdown(async move { _ = close_rx.await })
                    .await
                    .unwrap();
            })
        } else {
            tracing::info!("Using proxy since port {explicit_port} is busy");
            tokio::spawn(async move {
                dud_proxy_loop(server_state_clone, close_rx, explicit_port).await;
            })
        };

        (explicit_port, label, (server_state, handle))
    } else {
        let mut bound = None;
        for i in 0..PORT_RANGE_SIZE {
            let port = PORT_RANGE_START + i as u16;
            if let Some(listener) = try_bind_port(port).await {
                bound = Some((port, listener));
                break;
            }
            tracing::debug!("Port {port} is busy, trying next");
        }

        if let Some((port, listener)) = bound {
            let label = port_label(port);
            let server_state = Arc::new(Mutex::new(AppState::new(label.clone())));
            let app = axum::Router::new()
                .route("/request", get(request_handler))
                .route("/response", post(response_handler))
                .route("/proxy", post(proxy_handler))
                .route("/status", get(status_handler))
                .with_state(Arc::clone(&server_state));
            tracing::info!("HTTP server listening on {port} ({label})");
            let handle = tokio::spawn(async {
                axum::serve(listener, app)
                    .with_graceful_shutdown(async move { _ = close_rx.await })
                    .await
                    .unwrap();
            });
            (port, label, (server_state, handle))
        } else {
            let fallback_port = PORT_RANGE_START;
            let label = format!("Port ? (all ports busy, proxying via {fallback_port})");
            tracing::warn!("All ports in range are busy, falling back to proxy on {fallback_port}");
            let server_state = Arc::new(Mutex::new(AppState::new(label.clone())));
            let server_state_clone = Arc::clone(&server_state);
            let handle = tokio::spawn(async move {
                dud_proxy_loop(server_state_clone, close_rx, fallback_port).await;
            });
            (fallback_port, label, (server_state, handle))
        }
    };

    let (server_state, server_handle) = server_handle;
    tracing::info!("MCP server running as {label} (port {bound_port})");

    let service = RBXStudioServer::new(Arc::clone(&server_state), label)
        .serve(rmcp::transport::stdio())
        .await
        .inspect_err(|e| {
            tracing::error!("serving error: {:?}", e);
        })?;

    let peer = service.peer().clone();
    let monitor_state = Arc::clone(&server_state);
    tokio::spawn(async move {
        let mut was_connected = false;
        loop {
            tokio::time::sleep(Duration::from_secs(5)).await;
            let (is_connected, label) = {
                let s = monitor_state.lock().await;
                (s.is_plugin_connected(), s.port_label().to_string())
            };
            if was_connected && !is_connected {
                let _ = peer
                    .notify_logging_message(LoggingMessageNotificationParam {
                        level: LoggingLevel::Warning,
                        data: serde_json::json!({
                            "message": format!("Roblox Studio plugin has disconnected from {label}")
                        }),
                        logger: Some("roblox-studio-mcp".to_string()),
                    })
                    .await;
            }
            if !was_connected && is_connected {
                let _ = peer
                    .notify_logging_message(LoggingMessageNotificationParam {
                        level: LoggingLevel::Info,
                        data: serde_json::json!({
                            "message": format!("Roblox Studio plugin connected on {label}")
                        }),
                        logger: Some("roblox-studio-mcp".to_string()),
                    })
                    .await;
            }
            was_connected = is_connected;
        }
    });

    service.waiting().await?;

    close_tx.send(()).ok();
    tracing::info!("Waiting for web server to gracefully shutdown");
    server_handle.await.ok();
    tracing::info!("Bye!");
    Ok(())
}
