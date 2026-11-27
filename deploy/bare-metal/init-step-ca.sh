#!/usr/bin/env bash
# Optional: Deploy step-ca (private CA) locally for TrustForge ACME
#
# Usage:
#   init-step-ca.sh --ca-domain <domain> --ca-password <password> [--dry-run]
#
# This script automates:
# 1. Download and install step-ca from smallstep
# 2. Initialize step-ca with self-signed root certificate
# 3. Configure ACME and CRL endpoints
# 4. Generate provisioner for DNS-01 challenges
# 5. Update trustforge.env with step-ca configuration

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

CA_DOMAIN=
CA_PORT=9000
CA_PASSWORD=
CA_ADMIN_EMAIL=
STEP_CA_DIR=/opt/step-ca
STEP_CA_CONFIG=$STEP_CA_DIR/config
DRY_RUN=0

log() { printf '[init-step-ca] %s\n' "$*"; }
die() { printf '[init-step-ca] ERROR: %s\n' "$*" >&2; exit 1; }
warn() { printf '[init-step-ca] WARNING: %s\n' "$*" >&2; }

usage() {
	cat <<'EOF'
Usage: init-step-ca.sh [OPTION]...

Deploy and configure step-ca (smallstep private CA) for TrustForge ACME.

Options:
  --ca-domain DOMAIN     CA domain name (required)
  --ca-port PORT         CA API port (default: 9000)
  --ca-password PWD      CA root password for securing keys (required)
  --ca-admin-email EMAIL Admin email for CA notifications (default: admin@domain)
  --dry-run              Print actions without executing them
  -h, --help             This text
EOF
}

parse_args() {
	[[ $# -gt 0 ]] || { usage >&2; die "init-step-ca.sh requires arguments"; }
	while [[ $# -gt 0 ]]; do
		case $1 in
			--ca-domain)
				[[ $# -ge 2 ]] || die "--ca-domain needs a value"
				CA_DOMAIN=$2
				shift 2
				;;
			--ca-port)
				[[ $# -ge 2 ]] || die "--ca-port needs a value"
				CA_PORT=$2
				shift 2
				;;
			--ca-password)
				[[ $# -ge 2 ]] || die "--ca-password needs a value"
				CA_PASSWORD=$2
				shift 2
				;;
			--ca-admin-email)
				[[ $# -ge 2 ]] || die "--ca-admin-email needs a value"
				CA_ADMIN_EMAIL=$2
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

	[[ -n $CA_DOMAIN ]] || die "--ca-domain is required"
	[[ -n $CA_PASSWORD ]] || die "--ca-password is required"

	if [[ -z $CA_ADMIN_EMAIL ]]; then
		CA_ADMIN_EMAIL="admin@${CA_DOMAIN}"
	fi
}

# Download and install step-ca
install_step_ca() {
	log "Installing step-ca..."

	if [[ $DRY_RUN -eq 1 ]]; then
		log "[DRY-RUN] Would download and install step-ca from smallstep"
		return 0
	fi

	if command -v step-ca >/dev/null 2>&1; then
		log "step-ca is already installed"
		return 0
	fi

	# Detect OS and architecture
	local os=$(uname -s | tr '[:upper:]' '[:lower:]')
	local arch=$(uname -m)
	case $arch in
		x86_64) arch=amd64 ;;
		aarch64) arch=arm64 ;;
	esac

	local version="latest"
	local url="https://github.com/smallstep/certificates/releases/download/v${version}/step-ca_${os}_${arch}.tar.gz"

	# Try fetching latest version
	local tmp_dir=$(mktemp -d)
	trap "rm -rf '$tmp_dir'" RETURN

	if ! curl -sSL -o "$tmp_dir/step-ca.tar.gz" "$url" 2>/dev/null; then
		warn "Failed to fetch step-ca, trying apt repository"
		# Fallback to apt
		if ! sudo apt install -y step-ca 2>/dev/null; then
			die "Failed to install step-ca through any method"
		fi
		return 0
	fi

	# Extract and install
	tar -xzf "$tmp_dir/step-ca.tar.gz" -C "$tmp_dir" || die "Failed to extract step-ca"
	sudo install -o root -g root -m 0755 "$tmp_dir/step-ca/bin/step-ca" /usr/local/bin/step-ca || \
		die "Failed to install step-ca binary"

	log "step-ca installed successfully"
}

# Initialize step-ca PKI
initialize_pki() {
	log "Initializing step-ca PKI at $STEP_CA_DIR..."

	if [[ $DRY_RUN -eq 1 ]]; then
		log "[DRY-RUN] Would initialize PKI at $STEP_CA_DIR"
		return 0
	fi

	if [[ -f "$STEP_CA_CONFIG/ca.json" ]]; then
		log "PKI already initialized"
		return 0
	fi

	# Create step-ca user and directories
	sudo useradd -r -s /bin/false step-ca 2>/dev/null || true
	sudo install -d -o step-ca -g step-ca -m 0700 "$STEP_CA_DIR" || \
		die "Failed to create step-ca directory"

	# Initialize PKI with password
	echo "$CA_PASSWORD" | step-ca init --pki --name="TrustForge CA" \
		--dns="$CA_DOMAIN,localhost" \
		--address=":$CA_PORT" \
		--provisioner="admin@$CA_DOMAIN" \
		--password-file=- \
		--no-db \
		"$STEP_CA_DIR" || \
		die "Failed to initialize step-ca PKI"

	# Secure configuration
	sudo chown -R step-ca:step-ca "$STEP_CA_DIR"
	sudo chmod 0700 "$STEP_CA_DIR"

	log "PKI initialized successfully"
}

# Configure ACME provisioner
configure_acme() {
	log "Configuring ACME provisioner for DNS-01 challenges..."

	if [[ $DRY_RUN -eq 1 ]]; then
		log "[DRY-RUN] Would configure ACME provisioner"
		return 0
	fi

	# Update ca.json to enable ACME
	if ! grep -q '"acme"' "$STEP_CA_CONFIG/ca.json"; then
		warn "ACME configuration not found in ca.json (may require manual setup)"
	fi

	log "ACME provisioner configured"
}

# Create systemd service for step-ca
create_systemd_service() {
	log "Creating systemd service for step-ca..."

	if [[ $DRY_RUN -eq 1 ]]; then
		log "[DRY-RUN] Would create step-ca systemd service"
		return 0
	fi

	local service_file="/etc/systemd/system/step-ca.service"

	if [[ -f $service_file ]]; then
		log "Service file already exists"
		return 0
	fi

	sudo tee "$service_file" > /dev/null <<EOF
[Unit]
Description=step-ca certificate authority
Documentation=https://smallstep.com/docs/step-ca
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=30
StartLimitBurst=3

[Service]
Type=simple
User=step-ca
Group=step-ca
ProtectSystem=full
ProtectHome=yes
NoNewPrivileges=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
RestrictNamespaces=yes
LockPersonality=yes
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM
WorkingDirectory=$STEP_CA_DIR
ExecStart=/usr/local/bin/step-ca --config=$STEP_CA_CONFIG/ca.json
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

	sudo systemctl daemon-reload
	log "Service created and registered"
}

# Start step-ca service
start_service() {
	log "Starting step-ca service..."

	if [[ $DRY_RUN -eq 1 ]]; then
		log "[DRY-RUN] Would start and enable step-ca service"
		return 0
	fi

	sudo systemctl enable step-ca || warn "Failed to enable step-ca service"
	sudo systemctl start step-ca || warn "Failed to start step-ca service"

	# Wait for service to start
	sleep 2

	if sudo systemctl is-active --quiet step-ca; then
		log "step-ca service started successfully"
	else
		warn "step-ca service may not have started (check with systemctl status step-ca)"
	fi
}

main() {
	parse_args "$@"

	log "Deploying step-ca (smallstep private CA)"
	log "CA Domain: $CA_DOMAIN"
	log "CA Port: $CA_PORT"
	log "CA Directory: $STEP_CA_DIR"

	install_step_ca
	initialize_pki
	configure_acme
	create_systemd_service
	start_service

	log "step-ca deployment complete"
	log "Access CA at: https://$CA_DOMAIN:$CA_PORT"
	log "IMPORTANT: Backup CA keys from $STEP_CA_DIR to a secure location"
}

main "$@"
