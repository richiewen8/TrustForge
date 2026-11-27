#!/usr/bin/env bash
# Initialize Technitium DNS with ACME challenge zone and generate minimum-privilege token for TrustForge
#
# Usage:
#   init-dns.sh --dns-host <hostname> --dns-port <port> --admin-token <token> \
#               --acme-zone <zone> --env-file <path> [--dry-run]
#
# This script automates the creation of:
# 1. ACME challenge zone in Technitium DNS
# 2. Minimum-privilege API token with limited permissions
# 3. Updates trustforge.env with DNS configuration

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

DNS_HOST=
DNS_PORT=53
ADMIN_TOKEN=
ACME_ZONE=_acme-challenge
ENV_FILE=
DRY_RUN=0
API_TIMEOUT=10

log() { printf '[init-dns] %s\n' "$*"; }
die() { printf '[init-dns] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
	cat <<'EOF'
Usage: init-dns.sh [OPTION]...

Initialize Technitium DNS with ACME challenge zone and generate minimum-privilege token.

Options:
  --dns-host HOST        Technitium DNS API host (required)
  --dns-port PORT        Technitium DNS API port (default: 53, change to 8053 for HTTPS)
  --admin-token TOKEN    Administrator token for Technitium API (required)
  --acme-zone ZONE       ACME challenge zone name (default: _acme-challenge)
  --env-file FILE        Path to trustforge.env to update (required)
  --dry-run              Print actions without executing them
  -h, --help             This text
EOF
}

parse_args() {
	[[ $# -gt 0 ]] || { usage >&2; die "init-dns.sh requires arguments"; }
	while [[ $# -gt 0 ]]; do
		case $1 in
			--dns-host)
				[[ $# -ge 2 ]] || die "--dns-host needs a value"
				DNS_HOST=$2
				shift 2
				;;
			--dns-port)
				[[ $# -ge 2 ]] || die "--dns-port needs a value"
				DNS_PORT=$2
				shift 2
				;;
			--admin-token)
				[[ $# -ge 2 ]] || die "--admin-token needs a value"
				ADMIN_TOKEN=$2
				shift 2
				;;
			--acme-zone)
				[[ $# -ge 2 ]] || die "--acme-zone needs a value"
				ACME_ZONE=$2
				shift 2
				;;
			--env-file)
				[[ $# -ge 2 ]] || die "--env-file needs a value"
				ENV_FILE=$2
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

	[[ -n $DNS_HOST ]] || die "--dns-host is required"
	[[ -n $ADMIN_TOKEN ]] || die "--admin-token is required"
	[[ -n $ENV_FILE ]] || die "--env-file is required"
}

# Check if Technitium DNS is reachable
check_dns_connectivity() {
	local protocol="http"
	if [[ $DNS_PORT == 8053 ]]; then
		protocol="https"
	fi

	log "Checking connectivity to Technitium DNS at $protocol://$DNS_HOST:$DNS_PORT..."

	local response
	if ! response=$(curl -s -m "$API_TIMEOUT" -w "\n%{http_code}" \
		-H "X-Admin-Token: $ADMIN_TOKEN" \
		"$protocol://$DNS_HOST:$DNS_PORT/api/list?domain=."); then
		die "Failed to reach Technitium DNS API"
	fi

	local http_code=$(echo "$response" | tail -1)
	if [[ $http_code != "200" ]]; then
		die "Technitium DNS API returned HTTP $http_code (expected 200)"
	fi

	log "Successfully connected to Technitium DNS"
}

# Create ACME challenge zone
create_acme_zone() {
	local protocol="http"
	if [[ $DNS_PORT == 8053 ]]; then
		protocol="https"
	fi

	log "Creating ACME challenge zone: $ACME_ZONE"

	if [[ $DRY_RUN -eq 1 ]]; then
		log "[DRY-RUN] Would create zone: $ACME_ZONE"
		return 0
	fi

	# Check if zone already exists
	local response
	if response=$(curl -s -m "$API_TIMEOUT" -w "\n%{http_code}" \
		-H "X-Admin-Token: $ADMIN_TOKEN" \
		"$protocol://$DNS_HOST:$DNS_PORT/api/list?zone=$ACME_ZONE"); then

		local http_code=$(echo "$response" | tail -1)
		if [[ $http_code == "200" ]]; then
			log "Zone $ACME_ZONE already exists"
			return 0
		fi
	fi

	# Create zone
	response=$(curl -s -m "$API_TIMEOUT" -w "\n%{http_code}" \
		-X POST \
		-H "X-Admin-Token: $ADMIN_TOKEN" \
		-H "Content-Type: application/x-www-form-urlencoded" \
		-d "zone=$ACME_ZONE&type=Primary" \
		"$protocol://$DNS_HOST:$DNS_PORT/api/createZone")

	local http_code=$(echo "$response" | tail -1)
	if [[ $http_code != "200" ]]; then
		die "Failed to create ACME zone (HTTP $http_code)"
	fi

	log "Successfully created ACME challenge zone: $ACME_ZONE"
}

# Generate minimum-privilege API token
generate_api_token() {
	local protocol="http"
	if [[ $DNS_PORT == 8053 ]]; then
		protocol="https"
	fi

	log "Generating minimum-privilege API token for TrustForge..."

	if [[ $DRY_RUN -eq 1 ]]; then
		log "[DRY-RUN] Would generate token for zone: $ACME_ZONE"
		return 0
	fi

	# Create token with limited permissions (Zone query and record management only)
	local token_name="trustforge-acme-$(date +%s)"
	local response

	response=$(curl -s -m "$API_TIMEOUT" -w "\n%{http_code}" \
		-X POST \
		-H "X-Admin-Token: $ADMIN_TOKEN" \
		-H "Content-Type: application/x-www-form-urlencoded" \
		-d "tokenName=$token_name&permissions=ZoneTransferOnDemand;ZoneExport;ZoneImport;ZoneRead;ZoneWrite&zones=$ACME_ZONE" \
		"$protocol://$DNS_HOST:$DNS_PORT/api/createToken")

	local http_code=$(echo "$response" | tail -1)
	if [[ $http_code != "200" ]]; then
		die "Failed to create API token (HTTP $http_code)"
	fi

	local body=$(echo "$response" | sed '$d')
	local token=$(echo "$body" | grep -oP '(?<="token":")[^"]*' || true)

	if [[ -z $token ]]; then
		die "Failed to extract token from API response"
	fi

	log "Successfully generated API token"
	echo "$token"
}

# Update trustforge.env with DNS configuration
update_env_file() {
	local token=$1

	if [[ ! -f $ENV_FILE ]]; then
		die "Environment file not found: $ENV_FILE"
	fi

	if [[ $DRY_RUN -eq 1 ]]; then
		log "[DRY-RUN] Would update $ENV_FILE with:"
		log "[DRY-RUN]   ACME_DNS_HOST=$DNS_HOST"
		log "[DRY-RUN]   ACME_DNS_PORT=$DNS_PORT"
		log "[DRY-RUN]   ACME_DNS_ZONE=$ACME_ZONE"
		log "[DRY-RUN]   ACME_DNS_TOKEN=<redacted>"
		return 0
	fi

	log "Updating $ENV_FILE..."

	# Create backup
	cp "$ENV_FILE" "$ENV_FILE.bak"

	# Update or add DNS configuration parameters
	if grep -q "^ACME_DNS_HOST=" "$ENV_FILE"; then
		sed -i "s|^ACME_DNS_HOST=.*|ACME_DNS_HOST=$DNS_HOST|" "$ENV_FILE"
	else
		echo "ACME_DNS_HOST=$DNS_HOST" >> "$ENV_FILE"
	fi

	if grep -q "^ACME_DNS_PORT=" "$ENV_FILE"; then
		sed -i "s|^ACME_DNS_PORT=.*|ACME_DNS_PORT=$DNS_PORT|" "$ENV_FILE"
	else
		echo "ACME_DNS_PORT=$DNS_PORT" >> "$ENV_FILE"
	fi

	if grep -q "^ACME_DNS_ZONE=" "$ENV_FILE"; then
		sed -i "s|^ACME_DNS_ZONE=.*|ACME_DNS_ZONE=$ACME_ZONE|" "$ENV_FILE"
	else
		echo "ACME_DNS_ZONE=$ACME_ZONE" >> "$ENV_FILE"
	fi

	if grep -q "^ACME_DNS_TOKEN=" "$ENV_FILE"; then
		sed -i "s|^ACME_DNS_TOKEN=.*|ACME_DNS_TOKEN=$token|" "$ENV_FILE"
	else
		echo "ACME_DNS_TOKEN=$token" >> "$ENV_FILE"
	fi

	# Secure the file permissions
	chmod 0640 "$ENV_FILE"

	log "Successfully updated $ENV_FILE (backup saved to $ENV_FILE.bak)"
}

main() {
	parse_args "$@"

	log "Initializing Technitium DNS for TrustForge ACME DNS-01 challenges"
	log "DNS Host: $DNS_HOST:$DNS_PORT"
	log "ACME Zone: $ACME_ZONE"
	log "Environment File: $ENV_FILE"

	check_dns_connectivity
	create_acme_zone
	local token
	token=$(generate_api_token)
	update_env_file "$token"

	log "Technitium DNS initialization complete"
}

main "$@"
