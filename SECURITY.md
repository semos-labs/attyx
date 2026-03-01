# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in Attyx, **please do not open a public issue.** Instead, report it privately:

- Email: **security@semos.sh**
- Include a description of the vulnerability, steps to reproduce, and any relevant logs or screenshots.

We will acknowledge receipt within 48 hours and aim to provide a fix or mitigation plan within 7 days for critical issues.

## Supported Versions

Security updates are applied to the latest release only. We recommend always running the most recent version.

| Version | Supported |
| ------- | --------- |
| Latest  | Yes       |
| Older   | No        |

## Network Access

Attyx communicates over the network in the following ways:

### Authentication (app.semos.sh)

Attyx uses OAuth 2.0 Device Authorization Grant for authentication. The following endpoints are contacted:

- `POST /v1/auth/device/start` — initiate device login flow
- `POST /v1/auth/device/poll` — poll for authorization completion
- `POST /v1/auth/refresh` — refresh expired access tokens
- `GET /v1/me` — fetch account info
- `GET /v1/sessions` — list active sessions

### AI Features (app.semos.sh)

- `POST /v1/ai/execute/stream` — stream AI responses (command explanations, error analysis)

Context sent with AI requests includes: the current command line, selected text, recent terminal output, OS, and shell name. No keystrokes, passwords, or full scrollback history are transmitted.

### Update Checks (api.github.com)

- `GET /repos/semos-labs/attyx/releases/latest` — check for new releases

No telemetry, analytics, or crash reporting data is collected or transmitted.

## Credential Storage

Authentication tokens are stored at `~/.config/attyx/auth.json` (or `$XDG_CONFIG_HOME/attyx/auth.json`) with file permissions `0600` (owner read/write only).

Stored credentials:
- **Access token** — short-lived, used for API requests
- **Refresh token** — long-lived, used to obtain new access tokens

No credentials are embedded in the binary. Run `attyx uninstall` to remove stored credentials.

## Transport Security

- All API communication uses HTTPS/TLS in production.
- Local development defaults to `http://localhost:8085` when the environment is set to development.

## Scope

This policy covers the Attyx terminal emulator and its interactions with Semos services. For vulnerabilities in the Semos platform itself, contact **security@semos.sh**.
