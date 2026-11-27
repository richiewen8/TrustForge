#!/usr/bin/env bash
# Deploy trustforge-certctl to remote target machine via SSH
#
# Usage:
#   init-certctl.sh --target-host <host> --target-user <user> --certctl-binary <path> \
#                   --service-id <uuid> [--target-ssh-key <key>] [--dry-run]
#
# This script automates:
# 1. SSH connectivity verification to target
# 2. Installation of trustforge-certctl binary on target
# 3. Creation of service configuration JSON
# 4. Setup of sudo rule for trustforge-deployer

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

TARGET_HOST=
TARGET_USER=
TARGET_SSH_PORT=22
TARGET_SSH_KEY=
CERTCTL_BINARY=
SERVICE_ID=
DRY_RUN=0
SUDO_USER=trustforge-deployer

log() { printf '[init-certctl] %s\n' "$*"; }
die() { printf '[init-certctl] ERROR: %s\n' "$*" >&2; exit 1; }
warn() { printf '[init-certctl] WARNING: %s\n' "$*" >&2; }

usage() {
	cat <<'EOF'
Usage: init-certctl.sh [OPTION]...

Deploy trustforge-certctl to a remote Linux target machine.

Options:
  --target-host HOST     Target machine hostname or IP (required)
  --target-user USER     SSH user for target machine (default: root)
  --target-ssh-port PORT SSH port on target machine (default: 22)
  --target-ssh-key KEY   Path to SSH private key (optional)
  --certctl-binary PATH  Path to trustforge-certctl binary (required)
  --service-id UUID      Service UUID for certificate management (required)
  --dry-run              Print actions without executing them
  -h, --help             This text
EOF
}

parse_args() {
	[[ $# -gt 0 ]] || { usage >&2; die "init-certctl.sh requires arguments"; }
	while [[ $# -gt 0 ]]; do
		case $1 in
			--target-host)
				[[ $# -ge 2 ]] || die "--target-host needs a value"
				TARGET_HOST=$2
				shift 2
				;;
			--target-user)
				[[ $# -ge 2 ]] || die "--target-user needs a value"
				TARGET_USER=$2
				shift 2
				;;
			--target-ssh-port)
				[[ $# -ge 2 ]] || die "--target-ssh-port needs a value"
				TARGET_SSH_PORT=$2
				shift 2
				;;
			--target-ssh-key)
				[[ $# -ge 2 ]] || die "--target-ssh-key needs a value"
				TARGET_SSH_KEY=$2
				shift 2
				;;
			--certctl-binary)
				[[ $# -ge 2 ]] || die "--certctl-binary needs a value"
				CERTCTL_BINARY=$2
				shift 2
				;;
			--service-id)
				[[ $# -ge 2 ]] || die "--service-id needs a value"
				SERVICE_ID=$2
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

	[[ -n $TARGET_HOST ]] || die "--target-host is required"
	[[ -n $CERTCTL_BINARY ]] || die "--certctl-binary is required"
	[[ -n $SERVICE_ID ]] || die "--service-id is required"
	[[ -f $CERTCTL_BINARY ]] || die "trustforge-certctl binary not found: $CERTCTL_BINARY"
}

# Build SSH command with optional key
ssh_cmd() {
	local cmd=("ssh" "-p" "$TARGET_SSH_PORT")
	if [[ -n $TARGET_SSH_KEY ]]; then
		cmd+=("-i" "$TARGET_SSH_KEY")
	fi
	cmd+=("${TARGET_USER}@${TARGET_HOST}")
	echo "${cmd[@]}"
}

# Build SCP command with optional key
scp_cmd() {
	local cmd=("scp" "-P" "$TARGET_SSH_PORT")
	if [[ -n $TARGET_SSH_KEY ]]; then
		cmd+=("-i" "$TARGET_SSH_KEY")
	fi
	echo "${cmd[@]}"
}

# Verify SSH connectivity
check_ssh_connectivity() {
	log "Verifying SSH connectivity to ${TARGET_USER}@${TARGET_HOST}:${TARGET_SSH_PORT}..."

	if [[ $DRY_RUN -eq 1 ]]; then
		log "[DRY-RUN] Would check SSH connectivity"
		return 0
	fi

	local ssh_command
	ssh_command=$(ssh_cmd)

	if ! $ssh_command "true" 2>/dev/null; then
		die "SSH connection failed to $TARGET_HOST"
	fi

	log "SSH connectivity verified"
}

# Deploy binary to target
deploy_binary() {
	log "Deploying trustforge-certctl to ${TARGET_HOST}..."

	if [[ $DRY_RUN -eq 1 ]]; then
		log "[DRY-RUN] Would deploy binary to /usr/local/sbin/trustforge-certctl"
		return 0
	fi

	local scp_command
	scp_command=$(scp_cmd)

	# Copy binary
	$scp_command "$CERTCTL_BINARY" "${TARGET_USER}@${TARGET_HOST}:/tmp/trustforge-certctl" || \
		die "Failed to copy trustforge-certctl to target"

	# Install with proper permissions via SSH
	local ssh_command
	ssh_command=$(ssh_cmd)

	$ssh_command "sudo install -o root -g root -m 0750 /tmp/trustforge-certctl /usr/local/sbin/trustforge-certctl && rm /tmp/trustforge-certctl" || \
		die "Failed to install trustforge-certctl on target"

	log "trustforge-certctl deployed successfully"
}

# Create required directories on target
setup_directories() {
	log "Setting up required directories on target..."

	if [[ $DRY_RUN -eq 1 ]]; then
		log "[DRY-RUN] Would create /etc/trustforge/services and /var/lib/trustforge directories"
		return 0
	fi

	local ssh_command
	ssh_command=$(ssh_cmd)

	$ssh_command "sudo install -d -o root -g root -m 0700 /etc/trustforge/services && \
				  sudo install -d -o root -g root -m 0700 /var/lib/trustforge" || \
		die "Failed to create directories on target"

	log "Directories created"
}

# Configure sudo rule for trustforge-deployer
configure_sudo() {
	log "Configuring sudo rule for $SUDO_USER..."

	if [[ $DRY_RUN -eq 1 ]]; then
		log "[DRY-RUN] Would add sudo rule: $SUDO_USER ALL=(root) NOPASSWD: /usr/local/sbin/trustforge-certctl"
		return 0
	fi

	local ssh_command
	ssh_command=$(ssh_cmd)

	# Create sudoers file for trustforge-deployer
	$ssh_command "echo '$SUDO_USER ALL=(root) NOPASSWD: /usr/local/sbin/trustforge-certctl' | sudo tee /etc/sudoers.d/trustforge-deployer >/dev/null && \
				  sudo chmod 0440 /etc/sudoers.d/trustforge-deployer" || \
		warn "Failed to configure sudo rule (may require manual setup)"

	log "Sudo rule configured"
}

# Create service configuration template
create_service_config() {
	log "Creating service configuration template for service: $SERVICE_ID..."

	if [[ $DRY_RUN -eq 1 ]]; then
		log "[DRY-RUN] Would create service config at /etc/trustforge/services/${SERVICE_ID}.json"
		return 0
	fi

	local service_file_name="${SERVICE_ID//-}"  # Remove hyphens from UUID

	local ssh_command
	ssh_command=$(ssh_cmd)

	# Create template service config
	local service_config='{
  "certificatePath": "/etc/trustforge/services/'${SERVICE_ID}'/certificates/current/certificate.pem",
  "chainPath": "/etc/trustforge/services/'${SERVICE_ID}'/certificates/current/chain.pem",
  "privateKeyPath": "/etc/trustforge/services/'${SERVICE_ID}'/certificates/current/private-key.pem",
  "fileOwner": "root",
  "fileGroup": "www-data",
  "fileMode": "0640",
  "remoteHelperId": "trustforge-certctl-v1",
  "reloadActionId": "nginx-reload",
  "healthCheckId": "nginx-health"
}'

	# Write config via SSH
	$ssh_command "echo '$service_config' | sudo tee /etc/trustforge/services/${service_file_name}.json >/dev/null && \
				  sudo chmod 0600 /etc/trustforge/services/${service_file_name}.json && \
				  sudo chown root:root /etc/trustforge/services/${service_file_name}.json" || \
		warn "Failed to create service config template"

	log "Service configuration template created"
}

main() {
	parse_args "$@"

	log "Deploying trustforge-certctl to target machine"
	log "Target: ${TARGET_USER}@${TARGET_HOST}:${TARGET_SSH_PORT}"
	log "Service ID: $SERVICE_ID"

	check_ssh_connectivity
	deploy_binary
	setup_directories
	configure_sudo
	create_service_config

	log "trustforge-certctl deployment complete"
}

main "$@"
