use std::{
    collections::HashMap,
    env,
    fs::File,
    io::BufReader,
    net::SocketAddr,
    path::PathBuf,
    sync::Arc,
    time::{Duration, Instant},
};

use anyhow::{Context, Result, anyhow};
use futures_util::{SinkExt, StreamExt};
use quinn::{Endpoint, ServerConfig};
use rustls::pki_types::{CertificateDer, PrivateKeyDer};
use serde::{Deserialize, Serialize};
use tokio::{
    net::TcpListener,
    sync::{Mutex, mpsc},
    time,
};
use tokio_rustls::TlsAcceptor;
use tokio_util::codec::{Framed, LinesCodec};
use tracing::{info, warn};

#[derive(Clone)]
struct Config {
    quic_addr: SocketAddr,
    tcp_addr: SocketAddr,
    cert_pem: PathBuf,
    key_pem: PathBuf,
    shared_token: String,
    session_ttl: Duration,
}

#[derive(Clone)]
struct RelayState {
    sessions: Arc<Mutex<HashMap<String, RelaySession>>>,
}

#[derive(Clone)]
struct RelaySession {
    peers: HashMap<String, RelayPeer>,
    expires_at: Instant,
}

#[derive(Clone)]
struct RelayPeer {
    peer_device_id: String,
    _transport: RelayTransport,
    tx: mpsc::Sender<String>,
    last_seen: Instant,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize)]
#[serde(rename_all = "kebab-case")]
enum RelayTransport {
    Quic,
    TcpTls,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(tag = "type", rename_all = "kebab-case")]
enum RelayFrame {
    Join {
        session_id: String,
        device_id: String,
        peer_device_id: String,
        token: String,
    },
    JoinAck {
        session_id: String,
        device_id: String,
        transport: RelayTransport,
    },
    Audio {
        session_id: String,
        sender_device_id: String,
        sequence_number: u64,
        sent_at_ms: i64,
        payload: String,
    },
    Control {
        session_id: String,
        sender_device_id: String,
        kind: String,
        payload: String,
    },
    PeerUnavailable {
        session_id: String,
        device_id: String,
    },
    Error {
        message: String,
    },
}

#[derive(Clone)]
struct JoinedPeer {
    session_id: String,
    device_id: String,
    peer_device_id: String,
}

#[tokio::main]
async fn main() -> Result<()> {
    let _ = rustls::crypto::aws_lc_rs::default_provider().install_default();

    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "turbo_relay=info,relay=info".into()),
        )
        .init();

    let config = Config::from_env()?;
    let state = RelayState {
        sessions: Arc::new(Mutex::new(HashMap::new())),
    };

    let cleanup_state = state.clone();
    tokio::spawn(async move {
        cleanup_loop(cleanup_state).await;
    });

    let quic = serve_quic(config.clone(), state.clone());
    let tcp = serve_tcp_tls(config.clone(), state);

    tokio::select! {
        result = quic => result?,
        result = tcp => result?,
        _ = tokio::signal::ctrl_c() => {
            info!("shutdown requested");
        }
    }

    Ok(())
}

impl Config {
    fn from_env() -> Result<Self> {
        let quic_addr = env::var("TURBO_RELAY_QUIC_ADDR")
            .unwrap_or_else(|_| "0.0.0.0:9443".to_string())
            .parse()
            .context("invalid TURBO_RELAY_QUIC_ADDR")?;
        let tcp_addr = env::var("TURBO_RELAY_TCP_ADDR")
            .unwrap_or_else(|_| "0.0.0.0:9444".to_string())
            .parse()
            .context("invalid TURBO_RELAY_TCP_ADDR")?;
        let cert_pem = env::var("TURBO_RELAY_CERT_PEM")
            .map(PathBuf::from)
            .context("TURBO_RELAY_CERT_PEM is required")?;
        let key_pem = env::var("TURBO_RELAY_KEY_PEM")
            .map(PathBuf::from)
            .context("TURBO_RELAY_KEY_PEM is required")?;
        let shared_token =
            env::var("TURBO_RELAY_SHARED_TOKEN").context("TURBO_RELAY_SHARED_TOKEN is required")?;
        let session_ttl_seconds = env::var("TURBO_RELAY_SESSION_TTL_SECONDS")
            .ok()
            .and_then(|value| value.parse::<u64>().ok())
            .unwrap_or(180);

        Ok(Self {
            quic_addr,
            tcp_addr,
            cert_pem,
            key_pem,
            shared_token,
            session_ttl: Duration::from_secs(session_ttl_seconds),
        })
    }
}

async fn serve_quic(config: Config, state: RelayState) -> Result<()> {
    let server_config = quic_server_config(&config)?;
    let endpoint = Endpoint::server(server_config, config.quic_addr)
        .context("failed to bind QUIC endpoint")?;
    info!(addr = %config.quic_addr, "QUIC relay listening");

    while let Some(connecting) = endpoint.accept().await {
        let state = state.clone();
        let config = config.clone();
        tokio::spawn(async move {
            match connecting.await {
                Ok(connection) => {
                    info!(remote = %connection.remote_address(), "QUIC client connected");
                    while let Ok((send, recv)) = connection.accept_bi().await {
                        let state = state.clone();
                        let config = config.clone();
                        tokio::spawn(async move {
                            if let Err(error) = handle_quic_stream(send, recv, config, state).await
                            {
                                warn!(error = %error, "QUIC stream closed");
                            }
                        });
                    }
                }
                Err(error) => warn!(error = %error, "QUIC connection failed"),
            }
        });
    }

    Ok(())
}

async fn handle_quic_stream(
    send: quinn::SendStream,
    recv: quinn::RecvStream,
    config: Config,
    state: RelayState,
) -> Result<()> {
    let (tx, mut rx) = mpsc::channel::<String>(128);
    let mut reader = Framed::new(recv, LinesCodec::new());
    let mut writer = Framed::new(send, LinesCodec::new());

    let first = reader
        .next()
        .await
        .ok_or_else(|| anyhow!("stream closed before join"))?
        .context("invalid join line")?;
    let joined = handle_join(&first, &config, &state, RelayTransport::Quic, tx).await?;
    writer
        .send(serde_json::to_string(&RelayFrame::JoinAck {
            session_id: joined.session_id.clone(),
            device_id: joined.device_id.clone(),
            transport: RelayTransport::Quic,
        })?)
        .await
        .context("failed to write QUIC join ack")?;

    loop {
        tokio::select! {
            outbound = rx.recv() => {
                let Some(outbound) = outbound else { break; };
                writer.send(outbound).await.context("failed to write QUIC frame")?;
            }
            inbound = reader.next() => {
                let Some(inbound) = inbound else { break; };
                let inbound = inbound.context("invalid QUIC line")?;
                handle_inbound_frame(&inbound, &state, &joined).await?;
            }
        }
    }

    remove_peer(&state, &joined).await;
    Ok(())
}

async fn serve_tcp_tls(config: Config, state: RelayState) -> Result<()> {
    let tls_config = tls_server_config(&config)?;
    let acceptor = TlsAcceptor::from(Arc::new(tls_config));
    let listener = TcpListener::bind(config.tcp_addr)
        .await
        .context("failed to bind TCP/TLS endpoint")?;
    info!(addr = %config.tcp_addr, "TCP/TLS relay listening");

    loop {
        let (stream, remote) = listener.accept().await?;
        let acceptor = acceptor.clone();
        let config = config.clone();
        let state = state.clone();
        tokio::spawn(async move {
            match acceptor.accept(stream).await {
                Ok(stream) => {
                    info!(remote = %remote, "TCP/TLS client connected");
                    if let Err(error) = handle_tcp_tls_stream(stream, config, state).await {
                        warn!(remote = %remote, error = %error, "TCP/TLS client closed");
                    }
                }
                Err(error) => warn!(remote = %remote, error = %error, "TCP/TLS handshake failed"),
            }
        });
    }
}

async fn handle_tcp_tls_stream<S>(stream: S, config: Config, state: RelayState) -> Result<()>
where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
{
    let (tx, mut rx) = mpsc::channel::<String>(128);
    let mut framed = Framed::new(stream, LinesCodec::new());

    let first = framed
        .next()
        .await
        .ok_or_else(|| anyhow!("stream closed before join"))?
        .context("invalid join line")?;
    let joined = handle_join(&first, &config, &state, RelayTransport::TcpTls, tx).await?;
    framed
        .send(serde_json::to_string(&RelayFrame::JoinAck {
            session_id: joined.session_id.clone(),
            device_id: joined.device_id.clone(),
            transport: RelayTransport::TcpTls,
        })?)
        .await
        .context("failed to write TCP/TLS join ack")?;

    loop {
        tokio::select! {
            outbound = rx.recv() => {
                let Some(outbound) = outbound else { break; };
                framed.send(outbound).await.context("failed to write TCP/TLS frame")?;
            }
            inbound = framed.next() => {
                let Some(inbound) = inbound else { break; };
                let inbound = inbound.context("invalid TCP/TLS line")?;
                handle_inbound_frame(&inbound, &state, &joined).await?;
            }
        }
    }

    remove_peer(&state, &joined).await;
    Ok(())
}

async fn handle_join(
    line: &str,
    config: &Config,
    state: &RelayState,
    transport: RelayTransport,
    tx: mpsc::Sender<String>,
) -> Result<JoinedPeer> {
    let frame: RelayFrame = serde_json::from_str(line).context("join frame was not JSON")?;
    let RelayFrame::Join {
        session_id,
        device_id,
        peer_device_id,
        token,
    } = frame
    else {
        return Err(anyhow!("first frame must be join"));
    };
    if token != config.shared_token {
        return Err(anyhow!("invalid relay token"));
    }
    validate_id("session_id", &session_id)?;
    validate_id("device_id", &device_id)?;
    validate_id("peer_device_id", &peer_device_id)?;

    let joined = JoinedPeer {
        session_id,
        device_id,
        peer_device_id,
    };

    let mut sessions = state.sessions.lock().await;
    let session = sessions
        .entry(joined.session_id.clone())
        .or_insert_with(|| RelaySession {
            peers: HashMap::new(),
            expires_at: Instant::now() + config.session_ttl,
        });
    session.expires_at = Instant::now() + config.session_ttl;
    session.peers.insert(
        joined.device_id.clone(),
        RelayPeer {
            peer_device_id: joined.peer_device_id.clone(),
            _transport: transport,
            tx,
            last_seen: Instant::now(),
        },
    );
    info!(
        session_id = %joined.session_id,
        device_id = %joined.device_id,
        peer_device_id = %joined.peer_device_id,
        transport = ?transport,
        "peer joined relay session"
    );

    Ok(joined)
}

async fn handle_inbound_frame(line: &str, state: &RelayState, joined: &JoinedPeer) -> Result<()> {
    let frame: RelayFrame = serde_json::from_str(line).context("frame was not JSON")?;
    let (session_id, sender_device_id, frame_kind) = match &frame {
        RelayFrame::Audio {
            session_id,
            sender_device_id,
            sequence_number: _,
            sent_at_ms: _,
            payload: _,
        } => (session_id, sender_device_id, "audio"),
        RelayFrame::Control {
            session_id,
            sender_device_id,
            kind: _,
            payload: _,
        } => (session_id, sender_device_id, "control"),
        _ => return Ok(()),
    };

    if session_id != &joined.session_id || sender_device_id != &joined.device_id {
        return Err(anyhow!(
            "{frame_kind} frame identity did not match joined peer"
        ));
    }

    let encoded = serde_json::to_string(&frame)?;
    let (peer_sender, local_sender) = {
        let mut sessions = state.sessions.lock().await;
        let Some(session) = sessions.get_mut(&joined.session_id) else {
            return Ok(());
        };
        let Some(local_peer) = session.peers.get_mut(&joined.device_id) else {
            return Ok(());
        };
        local_peer.last_seen = Instant::now();
        let peer_device_id = local_peer.peer_device_id.clone();
        let local_sender = local_peer.tx.clone();
        let peer_sender = session
            .peers
            .get(&peer_device_id)
            .map(|peer| peer.tx.clone());
        (peer_sender, local_sender)
    };

    match peer_sender {
        Some(tx) => {
            if tx.try_send(encoded).is_err() {
                warn!(
                    session_id = %joined.session_id,
                    device_id = %joined.device_id,
                    frame_kind,
                    "dropped relay frame because peer queue was full or closed"
                );
            }
        }
        None => {
            let notice = RelayFrame::PeerUnavailable {
                session_id: joined.session_id.clone(),
                device_id: joined.peer_device_id.clone(),
            };
            let _ = local_sender.try_send(serde_json::to_string(&notice)?);
            warn!(
                session_id = %joined.session_id,
                device_id = %joined.device_id,
                peer_device_id = %joined.peer_device_id,
                frame_kind,
                "dropped relay frame because peer is unavailable"
            );
        }
    }

    Ok(())
}

async fn remove_peer(state: &RelayState, joined: &JoinedPeer) {
    let mut sessions = state.sessions.lock().await;
    if let Some(session) = sessions.get_mut(&joined.session_id) {
        session.peers.remove(&joined.device_id);
        info!(
            session_id = %joined.session_id,
            device_id = %joined.device_id,
            "peer left relay session"
        );
    }
}

async fn cleanup_loop(state: RelayState) {
    let mut interval = time::interval(Duration::from_secs(15));
    loop {
        interval.tick().await;
        let now = Instant::now();
        let mut sessions = state.sessions.lock().await;
        sessions.retain(|session_id, session| {
            let is_alive = session.expires_at > now && !session.peers.is_empty();
            if !is_alive {
                info!(session_id = %session_id, "expired relay session");
            }
            is_alive
        });
    }
}

fn validate_id(label: &str, value: &str) -> Result<()> {
    if value.is_empty() || value.len() > 160 {
        return Err(anyhow!("{label} has invalid length"));
    }
    if !value
        .chars()
        .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '-' | '_' | ':' | '.'))
    {
        return Err(anyhow!("{label} contains unsupported characters"));
    }
    Ok(())
}

fn quic_server_config(config: &Config) -> Result<ServerConfig> {
    let certs = load_certs(&config.cert_pem)?;
    let key = load_key(&config.key_pem)?;
    let mut crypto = rustls::ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(certs, key)
        .context("invalid relay certificate or key")?;
    crypto.alpn_protocols = vec![b"turbo-relay-v1".to_vec()];
    Ok(ServerConfig::with_crypto(Arc::new(
        quinn::crypto::rustls::QuicServerConfig::try_from(crypto)?,
    )))
}

fn tls_server_config(config: &Config) -> Result<rustls::ServerConfig> {
    let certs = load_certs(&config.cert_pem)?;
    let key = load_key(&config.key_pem)?;
    rustls::ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(certs, key)
        .context("invalid relay certificate or key")
}

fn load_certs(path: &PathBuf) -> Result<Vec<CertificateDer<'static>>> {
    let file = File::open(path)
        .with_context(|| format!("failed to open cert PEM at {}", path.display()))?;
    let mut reader = BufReader::new(file);
    rustls_pemfile::certs(&mut reader)
        .collect::<std::result::Result<Vec<_>, _>>()
        .context("failed to parse cert PEM")
}

fn load_key(path: &PathBuf) -> Result<PrivateKeyDer<'static>> {
    let file = File::open(path)
        .with_context(|| format!("failed to open key PEM at {}", path.display()))?;
    let mut reader = BufReader::new(file);
    rustls_pemfile::private_key(&mut reader)
        .context("failed to parse key PEM")?
        .ok_or_else(|| anyhow!("key PEM contained no private key"))
}
