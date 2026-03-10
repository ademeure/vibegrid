// HTTP bridge for Windows — replaces WKWebView message handlers.
// Loaded before app.js so that sendToNative() finds window.vibeGridBridgePostMessage.
//
// app.js, styles.css, and index.html are shared with macOS (canonical copies
// live at Sources/VibeGrid/Resources/web/). Run `make sync-web` to refresh.
// This file and favicon.svg are Windows-only additions.

(function () {
  "use strict";

  let pollTimer = null;
  let stateVersion = 0;
  let isDuplicate = false;

  // Read per-session token injected by the server into the HTML.
  const vibeGridToken = document.querySelector('meta[name="vibegrid-token"]')?.content || '';

  // --- Duplicate tab detection via BroadcastChannel ---
  // The NEWEST tab is always the active one. When a new tab opens, it tells
  // all older tabs to yield by sending "takeover". Older tabs become duplicates.
  const channel = typeof BroadcastChannel !== "undefined"
    ? new BroadcastChannel("vibegrid-control-center")
    : null;

  if (channel) {
    // Tell any existing tabs to stand down
    channel.postMessage({ type: "takeover" });

    channel.addEventListener("message", (e) => {
      if (e.data && e.data.type === "takeover" && !isDuplicate) {
        // A newer tab just opened — we yield
        becomeDuplicate();
      }
    });
  }

  function becomeDuplicate() {
    isDuplicate = true;
    if (pollTimer) {
      clearInterval(pollTimer);
      pollTimer = null;
    }
    // In app mode (--app flag), window.close() works. In a regular browser
    // tab it may be blocked, so fall back to showing a message.
    window.close();
    const show = () => {
      document.body.innerHTML =
        '<div style="display:flex;align-items:center;justify-content:center;height:100vh;' +
        'font-family:system-ui;color:#888;text-align:center;padding:2rem;">' +
        '<div><h2 style="margin-bottom:0.5rem">VibeGrid moved to a new tab</h2>' +
        '<p>This tab is no longer active. You can close it.</p></div></div>';
    };
    if (document.body) {
      show();
    } else {
      document.addEventListener("DOMContentLoaded", show);
    }
  }

  // --- Browser-native YAML import/export (replaces native file dialogs) ---

  async function handleSaveAsYaml() {
    try {
      const res = await fetch("/api/yaml/export", {
        headers: { "X-VibeGrid-Token": vibeGridToken },
      });
      if (!res.ok) {
        window.vibeGridReceive({ type: "notice", payload: { level: "error", message: "Failed to generate YAML" } });
        return;
      }
      const yamlText = await res.text();
      const blob = new Blob([yamlText], { type: "text/yaml" });
      const url = URL.createObjectURL(blob);
      const a = document.createElement("a");
      a.href = url;
      a.download = "vibegrid-config.yaml";
      document.body.appendChild(a);
      a.click();
      document.body.removeChild(a);
      URL.revokeObjectURL(url);
      window.vibeGridReceive({ type: "notice", payload: { level: "success", message: "YAML downloaded" } });
    } catch (err) {
      window.vibeGridReceive({ type: "notice", payload: { level: "error", message: err.message } });
    }
  }

  function handleLoadFromYaml() {
    const input = document.createElement("input");
    input.type = "file";
    input.accept = ".yaml,.yml";
    input.style.display = "none";
    input.addEventListener("change", async () => {
      const file = input.files[0];
      if (!file) return;
      try {
        const text = await file.text();
        const res = await fetch("/api/yaml/import", {
          method: "POST",
          headers: { "Content-Type": "text/plain", "X-VibeGrid-Token": vibeGridToken },
          body: text,
        });
        if (!res.ok) {
          const errText = await res.text();
          window.vibeGridReceive({ type: "notice", payload: { level: "error", message: errText } });
          return;
        }
        const reply = await res.json();
        if (reply && reply.type) {
          window.vibeGridReceive(reply);
        }
        // Refresh state so UI reflects the imported config
        const stateRes = await fetch("/api/bridge", {
          method: "POST",
          headers: { "Content-Type": "application/json", "X-VibeGrid-Token": vibeGridToken },
          body: JSON.stringify({ type: "requestState", payload: {} }),
        });
        if (stateRes.ok) {
          const stateReply = await stateRes.json();
          if (stateReply && stateReply.type) {
            window.vibeGridReceive(stateReply);
          }
        }
      } catch (err) {
        window.vibeGridReceive({ type: "notice", payload: { level: "error", message: err.message } });
      } finally {
        document.body.removeChild(input);
      }
    });
    document.body.appendChild(input);
    input.click();
  }

  // JS → Go backend: called by postBridgeMessage() fallback path
  window.vibeGridBridgePostMessage = async function (msg) {
    if (isDuplicate) return; // dead tab, don't send anything

    // Intercept YAML import/export — use browser file dialogs instead
    if (msg && msg.type === "saveAsYaml") {
      handleSaveAsYaml();
      return;
    }
    if (msg && msg.type === "loadFromYaml") {
      handleLoadFromYaml();
      return;
    }

    try {
      const res = await fetch("/api/bridge", {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-VibeGrid-Token": vibeGridToken },
        body: JSON.stringify(msg),
      });
      if (!res.ok) {
        console.error("bridge error:", res.status, await res.text());
        return;
      }
      const reply = await res.json();
      // Server confirmed exit — close the window
      if (reply && reply.type === "exitApp") {
        window.close();
        return;
      }
      // If the backend sends a direct response, dispatch it
      if (reply && reply.type) {
        window.vibeGridReceive(reply);
      }
    } catch (err) {
      console.error("bridge fetch error:", err);
    }
  };

  // Go backend → JS: poll for state pushes
  let consecutiveFailures = 0;
  let disconnectedOverlay = null;

  function showDisconnected() {
    if (disconnectedOverlay) return;
    const target = document.body || document.documentElement;
    if (!target) return;
    const overlay = document.createElement("div");
    overlay.style.cssText =
      "position:fixed;inset:0;z-index:99999;display:flex;align-items:center;" +
      "justify-content:center;background:rgba(0,0,0,0.75);font-family:system-ui;" +
      "color:#fff;text-align:center;padding:2rem;";
    overlay.innerHTML =
      '<div><h2 style="margin-bottom:0.5rem">VibeGrid has disconnected</h2>' +
      '<p style="color:#aaa;margin-bottom:1.5rem">The backend process is no longer running.</p>' +
      '<button style="padding:0.5rem 1.5rem;border-radius:6px;' +
      'border:none;background:#28cd41;color:#fff;font-size:1rem;cursor:pointer">Reconnect</button></div>';
    overlay.querySelector("button").addEventListener("click", () => location.reload());
    target.appendChild(overlay);
    disconnectedOverlay = overlay;
  }

  function hideDisconnected() {
    if (!disconnectedOverlay) return;
    disconnectedOverlay.remove();
    disconnectedOverlay = null;
  }

  async function pollState() {
    if (isDuplicate) return;
    try {
      const res = await fetch("/api/state?v=" + stateVersion, {
        headers: { "X-VibeGrid-Token": vibeGridToken },
        signal: AbortSignal.timeout(500),
      });
      if (!res.ok) {
        consecutiveFailures++;
      } else {
        if (consecutiveFailures > 0) {
          consecutiveFailures = 0;
          hideDisconnected();
        }
        const envelope = await res.json();
        if (envelope && envelope.version > stateVersion) {
          stateVersion = envelope.version;
          if (envelope.message) {
            window.vibeGridReceive(envelope.message);
          }
        }
      }
    } catch (_) {
      consecutiveFailures++;
    }
    if (consecutiveFailures >= 1) {
      showDisconnected();
    }
  }

  function startPolling() {
    if (pollTimer || isDuplicate) return;
    pollTimer = setInterval(pollState, 500);
  }

  // Also intercept sendToNative's "ready" call which bypasses the
  // vibeGridBridgePostMessage path in the original code
  const origSendToNative = window.sendToNative;
  Object.defineProperty(window, "_vibeGridBridgeReady", { value: true });

  // Platform capabilities — checked by app.js to hide unsupported features.
  // When true, hides features that require a native (non-web) host:
  // always-on-top, move-to-bottom, sticky VibeGrid, and related settings. macOS native has these; the web
  // bridge (Windows, future Linux) does not.
  window.vibeGridPlatform = {
    noNativeFeatures: true,
  };

  // Start polling immediately — state will arrive when ready
  startPolling();
})();
