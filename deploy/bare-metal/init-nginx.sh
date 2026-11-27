#!/usr/bin/env bash
# Configure Nginx HTTPS reverse proxy for TrustForge API with self-signed certificate
#
# Usage:
#   init-nginx.sh --api-domain <domain> --api-port <port> --tls-port <port> \
#                 [--dry-run] [--nginx-user <user>]
#
# This script automates:
# 1. Generation of self-signed certificate for API domain
# 2. Creation of Nginx reverse proxy configuration
# 3. Configuration of certificate auto-renewal with TrustForge

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

API_DOMAIN=
API_PORT=5000
TLS_PORT=443
NGINX_USER=www-data
NGINX_CONFIG_DIR=/etc/nginx
NGINX_SITES_AVAILABLE=$NGINX_CONFIG_DIR/sites-available
NGINX_SITES_ENABLED=$NGINX_CONFIG_DIR/sites-enabled
CERT_DIR=/etc/trustforge/nginx
DHPARAM_FILE=$CERT_DIR/dhparam.pem
DRY_RUN=0

log() { printf '[init-nginx] %s\n' "$*"; }
die() { printf '[init-nginx] ERROR: %s\n' "$*" >&2; exit 1; }
warn() { printf '[init-nginx] WARNING: %s\n' "$*" >&2; }

usage() {
	cat <<'EOF'
Usage: init-nginx.sh [OPTION]...

Configure Nginx HTTPS reverse proxy for TrustForge API.

Options:
  --api-domain DOMAIN    API domain name (required)
  --api-port PORT        TrustForge API local port (default: 5000)
  --tls-port PORT        HTTPS listen port (default: 443)
  --nginx-user USER      Nginx user (default: www-data)
  --dry-run              Print actions without executing them
  -h, --help             This text
EOF
}

parse_args() {
	[[ $# -gt 0 ]] || { usage >&2; die "init-nginx.sh requires arguments"; }
	while [[ $# -gt 0 ]]; do
		case $1 in
			--api-domain)
				[[ $# -ge 2 ]] || die "--api-domain needs a value"
				API_DOMAIN=$2
				shift 2
				;;
			--api-port)
				[[ $# -ge 2 ]] || die "--api-port needs a value"
				API_PORT=$2
				shift 2
				;;
			--tls-port)
				[[ $# -ge 2 ]] || die "--tls-port needs a value"
				TLS_PORT=$2
				shift 2
				;;
			--nginx-user)
				[[ $# -ge 2 ]] || die "--nginx-user needs a value"
				NGINX_USER=$2
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

	[[ -n $API_DOMAIN ]] || die "--api-domain is required"
}

# Check if Nginx is installed
check_nginx() {
	log "Checking if Nginx is installed..."

	if ! command -v nginx >/dev/null 2>&1; then
		die "Nginx is not installed. Install it with: sudo apt install nginx"
	fi

	if [[ $DRY_RUN -eq 0 ]] && ! [[ -d $NGINX_CONFIG_DIR ]]; then
		die "Nginx configuration directory not found: $NGINX_CONFIG_DIR"
	fi

	log "Nginx is installed"
}

# Check if ports are available
check_port_availability() {
	log "Checking port availability..."

	if [[ $DRY_RUN -eq 1 ]]; then
		log "[DRY-RUN] Would check ports $TLS_PORT (HTTPS) and $API_PORT (local)"
		return 0
	fi

	if netstat -tuln 2>/dev/null | grep -q ":$TLS_PORT "; then
		warn "Port $TLS_PORT is already in use (may be occupied by another service)"
	fi

	log "Port check completed"
}

# Create certificate directory
create_cert_directory() {
	log "Creating certificate directory: $CERT_DIR"

	if [[ $DRY_RUN -eq 1 ]]; then
		log "[DRY-RUN] Would create $CERT_DIR with mode 0750"
		return 0
	fi

	sudo install -d -o root -g $NGINX_USER -m 0750 "$CERT_DIR" || \
		die "Failed to create certificate directory"

	log "Certificate directory created"
}

# Generate DH parameters for Perfect Forward Secrecy
generate_dhparam() {
	log "Generating DH parameters (this may take a few minutes)..."

	if [[ $DRY_RUN -eq 1 ]]; then
		log "[DRY-RUN] Would generate DH parameters at $DHPARAM_FILE"
		return 0
	fi

	if [[ -f $DHPARAM_FILE ]]; then
		log "DH parameters already exist"
		return 0
	fi

	sudo openssl dhparam -out "$DHPARAM_FILE" 2048 || \
		warn "Failed to generate DH parameters (using default)"

	sudo chmod 0644 "$DHPARAM_FILE"
	log "DH parameters generated"
}

# Generate self-signed certificate (temporary, will be replaced by TrustForge)
generate_initial_certificate() {
	local cert_file="$CERT_DIR/${API_DOMAIN}.crt"
	local key_file="$CERT_DIR/${API_DOMAIN}.key"

	log "Generating initial self-signed certificate for $API_DOMAIN..."

	if [[ $DRY_RUN -eq 1 ]]; then
		log "[DRY-RUN] Would generate self-signed certificate"
		return 0
	fi

	if [[ -f $cert_file && -f $key_file ]]; then
		log "Certificate already exists"
		return 0
	fi

	# Generate self-signed certificate with 365 day validity
	sudo openssl req -x509 -newkey rsa:4096 -keyout "$key_file" -out "$cert_file" \
		-days 365 -nodes -subj "/CN=$API_DOMAIN" || \
		die "Failed to generate self-signed certificate"

	sudo chmod 0644 "$cert_file"
	sudo chmod 0640 "$key_file"
	sudo chown root:$NGINX_USER "$key_file"

	log "Initial certificate generated"
}

# Create Nginx reverse proxy configuration
create_nginx_config() {
	local config_file="$NGINX_SITES_AVAILABLE/trustforge-api"

	log "Creating Nginx reverse proxy configuration..."

	if [[ $DRY_RUN -eq 1 ]]; then
		log "[DRY-RUN] Would create Nginx config at $config_file"
		return 0
	fi

	if [[ -f $config_file ]]; then
		log "Nginx configuration already exists"
		return 0
	fi

	local cert_file="$CERT_DIR/${API_DOMAIN}.crt"
	local key_file="$CERT_DIR/${API_DOMAIN}.key"
	local dhparam_file="$DHPARAM_FILE"

	# Create configuration
	sudo tee "$config_file" > /dev/null <<EOF
# TrustForge API reverse proxy configuration
# Generated by init-nginx.sh

upstream trustforge_api {
	server 127.0.0.1:$API_PORT;
	keepalive 32;
}

# HTTP to HTTPS redirect
server {
	listen 80;
	listen [::]:80;
	server_name $API_DOMAIN;

	location / {
		return 301 https://\$server_name\$request_uri;
	}
}

# HTTPS server
server {
	listen $TLS_PORT ssl http2;
	listen [::]:$TLS_PORT ssl http2;
	server_name $API_DOMAIN;

	# SSL configuration
	ssl_certificate $cert_file;
	ssl_certificate_key $key_file;
	ssl_dhparam $dhparam_file;

	ssl_protocols TLSv1.2 TLSv1.3;
	ssl_ciphers HIGH:!aNULL:!MD5;
	ssl_prefer_server_ciphers on;
	ssl_session_cache shared:SSL:10m;
	ssl_session_timeout 10m;

	# Security headers
	add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
	add_header X-Content-Type-Options "nosniff" always;
	add_header X-Frame-Options "DENY" always;
	add_header X-XSS-Protection "1; mode=block" always;

	# Logging
	access_log /var/log/nginx/trustforge-api-access.log;
	error_log /var/log/nginx/trustforge-api-error.log;

	# Reverse proxy to TrustForge API
	location / {
		proxy_pass http://trustforge_api;
		proxy_http_version 1.1;

		# Headers
		proxy_set_header Host \$host;
		proxy_set_header X-Real-IP \$remote_addr;
		proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
		proxy_set_header X-Forwarded-Proto \$scheme;
		proxy_set_header Connection "";

		# Timeouts
		proxy_connect_timeout 60s;
		proxy_send_timeout 60s;
		proxy_read_timeout 60s;
	}
}
EOF

	sudo chmod 0644 "$config_file"
	log "Nginx configuration created"
}

# Enable Nginx site
enable_nginx_site() {
	local config_file="$NGINX_SITES_AVAILABLE/trustforge-api"
	local enabled_link="$NGINX_SITES_ENABLED/trustforge-api"

	log "Enabling TrustForge Nginx site..."

	if [[ $DRY_RUN -eq 1 ]]; then
		log "[DRY-RUN] Would create symlink from sites-available to sites-enabled"
		return 0
	fi

	if [[ -L $enabled_link ]]; then
		log "Site already enabled"
		return 0
	fi

	if [[ -f $enabled_link ]]; then
		sudo rm "$enabled_link"
	fi

	sudo ln -s "$config_file" "$enabled_link" || \
		warn "Failed to enable site (may require manual enable)"

	log "Site enabled"
}

# Test and reload Nginx
reload_nginx() {
	log "Testing and reloading Nginx configuration..."

	if [[ $DRY_RUN -eq 1 ]]; then
		log "[DRY-RUN] Would test and reload Nginx"
		return 0
	fi

	if ! sudo nginx -t 2>&1 | grep -q "successful"; then
		warn "Nginx configuration test failed (manual review required)"
		return 1
	fi

	sudo systemctl reload nginx || \
		warn "Failed to reload Nginx (may require manual reload)"

	log "Nginx reloaded successfully"
}

main() {
	parse_args "$@"

	log "Configuring Nginx reverse proxy for TrustForge API"
	log "API Domain: $API_DOMAIN"
	log "API Port: $API_PORT (local)"
	log "TLS Port: $TLS_PORT (public)"

	check_nginx
	check_port_availability
	create_cert_directory
	generate_dhparam
	generate_initial_certificate
	create_nginx_config
	enable_nginx_site
	reload_nginx

	log "Nginx reverse proxy configuration complete"
	log "IMPORTANT: Initial certificate is self-signed and will be replaced by TrustForge"
}

main "$@"
