defmodule OrchidWeb.Layouts do
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <title>Orchid - LLM Agent Framework</title>
        <style>
          :root {
            --app-height: 100vh;
          }
          @supports (height: 100dvh) {
            :root {
              --app-height: 100dvh;
            }
          }
          * { box-sizing: border-box; margin: 0; padding: 0; }
          html {
            height: 100%;
          }
          body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
            background: #0d1117;
            color: #c9d1d9;
            min-height: var(--app-height);
          }
          .app-layout {
            display: flex;
            min-height: var(--app-height);
            height: var(--app-height);
          }
          .sidebar {
            width: 260px;
            background: #161b22;
            border-right: 1px solid #30363d;
            display: flex;
            flex-direction: column;
            flex-shrink: 0;
          }
          .sidebar-header {
            padding: 1rem;
            border-bottom: 1px solid #30363d;
          }
          .sidebar-header h2 {
            color: #58a6ff;
            font-size: 0.9rem;
            margin-bottom: 0.5rem;
          }
          .sidebar-search {
            width: 100%;
            background: #0d1117;
            border: 1px solid #30363d;
            color: #c9d1d9;
            padding: 0.5rem;
            border-radius: 6px;
            font-size: 0.85rem;
          }
          .sidebar-search:focus {
            outline: none;
            border-color: #58a6ff;
          }
          .sidebar-content {
            flex: 1;
            overflow-y: auto;
            padding: 0.5rem;
          }
          .project-item {
            padding: 0.5rem 0.75rem;
            border-radius: 6px;
            cursor: pointer;
            display: flex;
            align-items: center;
            gap: 0.5rem;
            color: #c9d1d9;
            text-decoration: none;
            font-size: 0.9rem;
          }
          .project-item:hover {
            background: #21262d;
          }
          .project-item.active {
            background: #238636;
          }
          .project-icon {
            width: 8px;
            height: 8px;
            border-radius: 50%;
            background: #8b949e;
            flex-shrink: 0;
          }
          .project-item.active .project-icon {
            background: #fff;
          }
          .sidebar-footer {
            padding: 0.75rem;
            border-top: 1px solid #30363d;
          }
          .sidebar-footer .btn {
            width: 100%;
            font-size: 0.85rem;
          }
          .main-content {
            flex: 1;
            display: flex;
            flex-direction: column;
            min-width: 0;
            min-height: 0;
          }
          .container {
            max-width: 1200px;
            margin: 0 auto;
            padding: 1rem;
            width: 100%;
            min-height: 0;
          }
          h1 { color: #58a6ff; margin-bottom: 1rem; }
          .btn {
            background: #238636;
            color: white;
            border: none;
            padding: 0.5rem 1rem;
            border-radius: 6px;
            cursor: pointer;
            font-size: 0.9rem;
            text-decoration: none;
            display: inline-block;
          }
          .btn:hover { background: #2ea043; }
          .btn-secondary { background: #21262d; border: 1px solid #30363d; }
          .btn-secondary:hover { background: #30363d; }
          .btn-danger { background: #da3633; }
          .btn-danger:hover { background: #f85149; }
          .btn-sm { padding: 0.25rem 0.5rem; font-size: 0.8rem; }
          .chat-container {
            display: flex;
            flex-direction: column;
            height: calc(var(--app-height) - 120px);
            min-height: 0;
            background: #161b22;
            border-radius: 8px;
            border: 1px solid #30363d;
          }
          .messages {
            flex: 1;
            min-height: 0;
            overflow-y: auto;
            padding: 1rem;
          }
          .message {
            margin-bottom: 1rem;
            padding: 0.75rem 1rem;
            border-radius: 8px;
            max-width: 85%;
          }
          .message.user {
            background: #238636;
            margin-left: auto;
          }
          .message.assistant {
            background: #21262d;
            border: 1px solid #30363d;
          }
          .message.tool-call {
            background: #1c2128;
            border: 1px solid #f0883e;
            border-left: 3px solid #f0883e;
            font-size: 0.85rem;
          }
          .message.tool-call .tool-name {
            color: #f0883e;
            font-weight: 600;
            margin-bottom: 0.25rem;
          }
          .message.tool-call .tool-args {
            margin: 0;
            font-size: 0.8rem;
            max-height: 150px;
            overflow-y: auto;
          }
          .message.tool-result {
            background: #1c2128;
            border: 1px solid #3fb950;
            border-left: 3px solid #3fb950;
            font-size: 0.8rem;
            max-width: 90%;
          }
          .message.tool-result pre {
            margin: 0;
            max-height: 200px;
            overflow-y: auto;
            white-space: pre-wrap;
            word-break: break-word;
          }
          .message.error {
            background: #3d1a1a;
            border: 1px solid #f85149;
            border-left: 3px solid #f85149;
            color: #f85149;
            font-size: 0.85rem;
          }
          .message pre {
            background: #0d1117;
            padding: 0.5rem;
            border-radius: 4px;
            overflow-x: auto;
            margin: 0.5rem 0;
          }
          .message code {
            font-family: "SF Mono", Monaco, monospace;
            font-size: 0.85rem;
          }
          .input-area {
            padding: 1rem;
            border-top: 1px solid #30363d;
            display: flex;
            gap: 0.5rem;
          }
          .input-area textarea {
            flex: 1;
            background: #0d1117;
            border: 1px solid #30363d;
            color: #c9d1d9;
            padding: 0.75rem;
            border-radius: 6px;
            resize: none;
            font-family: inherit;
            font-size: 0.95rem;
          }
          .input-area textarea:focus {
            outline: none;
            border-color: #58a6ff;
          }
          .header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 1rem;
          }
          .agent-list {
            display: grid;
            grid-template-columns: repeat(auto-fill, minmax(280px, 1fr));
            gap: 1rem;
            margin-top: 1rem;
          }
          .agent-card {
            background: #161b22;
            border: 1px solid #30363d;
            border-radius: 8px;
            padding: 1rem;
          }
          .agent-card h3 { color: #58a6ff; margin-bottom: 0.5rem; font-size: 0.9rem; }
          .agent-card .status { color: #8b949e; font-size: 0.8rem; }
          .agent-card .actions { margin-top: 0.75rem; display: flex; gap: 0.5rem; }
          .streaming-cursor {
            display: inline-block;
            width: 8px;
            height: 16px;
            background: #58a6ff;
            animation: blink 1s infinite;
          }
          @keyframes blink { 50% { opacity: 0; } }
          .model-select {
            background: #21262d;
            border: 1px solid #30363d;
            color: #c9d1d9;
            padding: 0.5rem;
            border-radius: 6px;
          }
          .no-projects {
            color: #8b949e;
            font-size: 0.85rem;
            padding: 0.5rem 0.75rem;
          }
          .agent-project {
            margin: 0.5rem 0;
          }
          .project-badge {
            background: #1f6feb;
            color: #fff;
            padding: 0.2rem 0.5rem;
            border-radius: 12px;
            font-size: 0.75rem;
          }
          @media (max-width: 768px) {
            .app-layout {
              flex-direction: column;
            }
            .sidebar {
              width: 100%;
              max-height: 40vh;
              border-right: none;
              border-bottom: 1px solid #30363d;
            }
            .main-content {
              min-height: 60vh;
            }
            .chat-container {
              height: calc(var(--app-height) - 40vh - 60px);
            }
            .agent-list {
              grid-template-columns: 1fr;
            }
            .message {
              max-width: 95%;
            }
            .message.tool-result {
              max-width: 95%;
            }
          }
        </style>
        <script src="https://cdn.jsdelivr.net/npm/phoenix@1.7.14/priv/static/phoenix.min.js"></script>
        <script src="https://cdn.jsdelivr.net/npm/phoenix_live_view@1.1.19/priv/static/phoenix_live_view.min.js"></script>
        <script>
          document.addEventListener("DOMContentLoaded", function() {
            const setAppHeight = () => {
              const viewport = window.visualViewport
              const height = viewport ? viewport.height : window.innerHeight
              document.documentElement.style.setProperty("--app-height", `${height}px`)
            }

            setAppHeight()
            window.addEventListener("resize", setAppHeight)
            window.addEventListener("orientationchange", setAppHeight)
            if (window.visualViewport) {
              window.visualViewport.addEventListener("resize", setAppHeight)
              window.visualViewport.addEventListener("scroll", setAppHeight)
            }

            let Hooks = {
              ScrollBottom: {
                mounted() {
                  this.el.scrollTop = this.el.scrollHeight
                },
                updated() {
                  this.el.scrollTop = this.el.scrollHeight
                }
              },
              CtrlEnterSubmit: {
                mounted() {
                  this.el.addEventListener("keydown", (e) => {
                    if (e.key === "Enter" && e.ctrlKey) {
                      e.preventDefault()
                      if (this.el.form && this.el.form.requestSubmit) {
                        this.el.form.requestSubmit()
                      } else if (this.el.form) {
                        this.el.form.dispatchEvent(new Event("submit", {bubbles: true, cancelable: true}))
                      }
                    }
                  })
                }
              }
            }
            let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
            let liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
              hooks: Hooks,
              params: {_csrf_token: csrfToken}
            })
            liveSocket.connect()
          })
        </script>
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end
end
