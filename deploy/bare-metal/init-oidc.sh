#!/usr/bin/env bash
# Optional: Deploy Dex (lightweight OIDC provider) locally for TrustForge
#
# Usage:
#   init-oidc.sh --oidc-domain <domain> --oidc-port <port> --static-password <password> [--dry-run]
#
# This script automates:
# 1. Download and install Dex
# 2. Configure Dex for local user authentication
# 3. Register TrustForge as OIDC client
# 4. Create systemd service for Dex
# 5. Update trustforge.env with OIDC authority URL

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

OIDC_DOMAIN=
OIDC_PORT=5556
STATIC_PASSWORD=
OIDC_CLIENT_ID=trustforge
OIDC_CLIENT_SECRET=
DEX_DIR=/opt/dex
DEX_CONFIG=$DEX_DIR/dex-config.yaml
DRY_RUN=0

log() { printf '[init-oidc] %s\n' "$*"; }
die() { printf '[init-oidc] ERROR: %s\n' "$*" >&2; exit 1; }
warn() { printf '[init-oidc] WARNING: %s\n' "$*" >&2; }

usage() {
	cat <<'EOF'
Usage: init-oidc.sh [OPTION]...

Deploy and configure Dex (lightweight OIDC provider) for TrustForge.

Options:
  --oidc-domain DOMAIN   OIDC provider domain name (required)
  --oidc-port PORT       Dex API port (default: 5556)
  --static-password PWD  Static password for local users (required)
  --oidc-client-secret SECRET  Client secret for TrustForge (optional, auto-generated if not provided)
  --dry-run              Print actions without executing them
  -h, --help             This text
EOF
}

parse_args() {
	[[ $# -gt 0 ]] || { usage >&2; die "init-oidc.sh requires arguments"; }
	while [[ $# -gt 0 ]]; do
		case $1 in
			--oidc-domain)
				[[ $# -ge 2 ]] || die "--oidc-domain needs a value"
				OIDC_DOMAIN=$2
				shift 2
				;;
			--oidc-port)
				[[ $# -ge 2 ]] || die "--oidc-port needs a value"
				OIDC_PORT=$2
				shift 2
				;;
			--static-password)
				[[ $# -ge 2 ]] || die "--static-password needs a value"
				STATIC_PASSWORD=$2
				shift 2
				;;
			--oidc-client-secret)
				[[ $# -ge 2 ]] || die "--oidc-client-secret needs a value"
				OIDC_CLIENT_SECRET=$2
				shift 2
				;;
			--dry-run)
				DRY_RUN=1
				shift
				;;
			-h|--help)
				usage
				exit 0
				;;
			*)
				die "unknown option: $1"
				;;
		esac
	done

	[[ -n $OIDC_DOMAIN ]] || die "--oidc-domain is required"
	[[ -n $STATIC_PASSWORD ]] || die "--static-password is required"

	# Generate client secret if not provided
	if [[ -z $OIDC_CLIENT_SECRET ]]; then
		OIDC_CLIENT_SECRET=$(openssl rand -hex 32)
	fi
}

# Download and install Dex
install_dex() {
	log "Installing Dex..."

	if [[ $DRY_RUN -eq 1 ]]; then
		log "[DRY-RUN] Would download and install Dex"
		return 0
	fi

	if command -v dex >/dev/null 2>&1; then
		log "Dex is already installed"
		return 0
	fi

	# Detect OS and architecture
	local os=$(uname -s | tr '[:upper:]' '[:lower:]')
	local arch=$(uname -m)
	case $arch in
		x86_64) arch=amd64 ;;
		aarch64) arch=arm64 ;;
	esac

	local version="v2.38.0"
	local url="https://github.com/dexidp/dex/releases/download/${version}/dex-${version}-${os}-${arch}.tar.gz"

	local tmp_dir=$(mktemp -d)
	trap "rm -rf '$tmp_dir'" RETURN

	if ! curl -sSL -o "$tmp_dir/dex.tar.gz" "$url" 2>/dev/null; then
		warn "Failed to fetch Dex from GitHub, trying apt"
		sudo apt install -y dex 2>/dev/null || die "Failed to install Dex through any method"
		return 0
	fi

	# Extract and install
	tar -xzf "$tmp_dir/dex.tar.gz" -C "$tmp_dir" || die "Failed to extract Dex"
	sudo install -o root -g root -m 0755 "$tmp_dir/dex-${version}-${os}-${arch}/dex" /usr/local/bin/dex || \
		die "Failed to install Dex binary"

	log "Dex installed successfully"
}

# Create Dex configuration
create_dex_config() {
	log "Creating Dex configuration..."

	if [[ $DRY_RUN -eq 1 ]]; then
		log "[DRY-RUN] Would create Dex config at $DEX_CONFIG"
		return 0
	fi

	# Create dex directory
	sudo install -d -o dex -g dex -m 0750 "$DEX_DIR" 2>/dev/null || \
		sudo install -d -m 0750 "$DEX_DIR"

	# Create configuration file
	sudo tee "$DEX_CONFIG" > /dev/null <<EOF
issuer: https://$OIDC_DOMAIN:$OIDC_PORT
storage:
  type: sqlite3
  config:
	file: $DEX_DIR/dex.db
web:
  http: 127.0.0.1:$OIDC_PORT
  https: 127.0.0.1:5557
  tlsCert: /etc/dex/tls.crt
  tlsKey: /etc/dex/tls.key
oauth2:
  responseTypes: ["code", "token", "id_token"]
  skipApprovalScreen: false
  passwordConnector: local
connectors:
- type: local
  id: local
  name: "Local Login"
  config:
	username: admin
	userID: 08a8684b-db88-4243-9f9d-d60b5a6470a4
staticClients:
- id: $OIDC_CLIENT_ID
  redirectURIs:
  - 'https://$OIDC_DOMAIN/api/auth/callback'
  name: 'TrustForge'
  secret: $OIDC_CLIENT_SECRET
staticPasswords:
- email: admin@$OIDC_DOMAIN
  hash: $STATIC_PASSWORD
  username: admin
  userID: 08a8684b-db88-4243-9f9d-d60b5a6470a4
EOF

	sudo chmod 0640 "$DEX_CONFIG"
	log "Dex configuration created"
}

# Generate self-signed certificate for Dex
generate_dex_certificate() {
	log "Generating self-signed certificate for Dex..."

	if [[ $DRY_RUN -eq 1 ]]; then
		log "[DRY-RUN] Would generate Dex certificate"
		return 0
	fi

	local cert_dir="/etc/dex"

	if [[ -f "$cert_dir/tls.crt" ]]; then
		log "Certificate already exists"
		return 0
	fi

	sudo install -d -m 0750 "$cert_dir" || die "Failed to create cert directory"

	sudo openssl req -x509 -newkey rsa:4096 -keyout "$cert_dir/tls.key" -out "$cert_dir/tls.crt" \
		-days 365 -nodes -subj "/CN=$OIDC_DOMAIN" || \
		die "Failed to generate certificate"

	sudo chmod 0640 "$cert_dir/tls.key"
	sudo chmod 0644 "$cert_dir/tls.crt"

	log "Certificate generated"
}

# Create systemd service for Dex
create_systemd_service() {
	log "Creating systemd service for Dex..."

	if [[ $DRY_RUN -eq 1 ]]; then
		log "[DRY-RUN] Would create Dex systemd service"
		return 0
	fi

	local service_file="/etc/systemd/system/dex.service"

	if [[ -f $service_file ]]; then
		log "Service file already exists"
		return 0
	fi

	sudo useradd -r -s /bin/false dex 2>/dev/null || true

	sudo tee "$service_file" > /dev/null <<EOF
[Unit]
Description=Dex - OpenID Connect Provider
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=30
StartLimitBurst=3

[Service]
Type=simple
User=dex
Group=dex
ProtectSystem=strict
ProtectHome=yes
NoNewPrivileges=yes
PrivateTmp=yes
PrivateDevices=yes
WorkingDirectory=$DEX_DIR
ExecStart=/usr/local/bin/dex serve $DEX_CONFIG
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

	sudo systemctl daemon-reload
	log "Service created and registered"
}

# Start Dex service
start_service() {
	log "Starting Dex service..."

	if [[ $DRY_RUN -eq 1 ]]; then
		log "[DRY-RUN] Would start and enable Dex service"
		return 0
	fi

	sudo systemctl enable dex || warn "Failed to enable Dex service"
	sudo systemctl start dex || warn "Failed to start Dex service"

	sleep 2

	if sudo systemctl is-active --quiet dex; then
		log "Dex service started successfully"
	else
		warn "Dex service may not have started (check with systemctl status dex)"
	fi
}

main() {
	parse_args "$@"

	log "Deploying Dex (OIDC provider)"
	log "OIDC Domain: $OIDC_DOMAIN"
	log "Dex Port: $OIDC_PORT"
	log "Client ID: $OIDC_CLIENT_ID"

	install_dex
	create_dex_config
	generate_dex_certificate
	create_systemd_service
	start_service

	log "Dex deployment complete"
	log "OIDC Authority: https://$OIDC_DOMAIN:$OIDC_PORT"
	log "Client Secret: $OIDC_CLIENT_SECRET"
	log "Admin User: admin@$OIDC_DOMAIN"
	log "IMPORTANT: Save the client secret to a secure location"
}

main "$@"
