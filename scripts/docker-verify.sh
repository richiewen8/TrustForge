#!/usr/bin/env bash
# Docker-based verification script for TrustForge bare-metal deployment
# Usage: ./scripts/docker-verify.sh [command]

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}[docker-verify]${NC} $*"; }
info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die() { error "$*"; exit 1; }

usage() {
	cat <<'EOF'
Usage: docker-verify.sh [COMMAND] [OPTIONS]

Build and run TrustForge deployment verification in Docker.

Commands:
  build           Build the Docker test image
  run             Run verification tests in Docker
  full            Build and run (default)
  shell           Run interactive shell in test container
  clean           Remove Docker images and containers

Options:
  --no-cache      Build Docker image without cache
  --platform      Specify platform (default: linux/amd64)
  --verbose       Verbose output

Examples:
  ./docker-verify.sh full                # Complete verification
  ./docker-verify.sh run --verbose       # Run with verbose output
  ./docker-verify.sh shell               # Interactive debugging
  ./docker-verify.sh build --no-cache    # Rebuild without cache
EOF
}

# Parse arguments
COMMAND=${1:-full}
shift 2>/dev/null || true
BUILD_OPTS=()
RUN_OPTS=()
VERBOSE=0

while [[ $# -gt 0 ]]; do
	case $1 in
		--no-cache)
			BUILD_OPTS+=(--no-cache)
			shift
			;;
		--platform)
			BUILD_OPTS+=(--platform "$2")
			shift 2
			;;
		--verbose|-v)
			VERBOSE=1
			RUN_OPTS+=(-e VERBOSE=1)
			shift
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			die "Unknown option: $1"
			;;
	esac
done

# Check Docker installation
check_docker() {
	if ! command -v docker &>/dev/null; then
		die "Docker is not installed or not in PATH"
	fi

	if ! docker info >/dev/null 2>&1; then
		die "Docker daemon is not running or insufficient permissions"
	fi

	info "Docker is available"
}

# Build Docker image
build_image() {
	log "Building Docker test image..."

	if [[ $VERBOSE -eq 1 ]]; then
		docker build "${BUILD_OPTS[@]}" -f "$PROJECT_ROOT/Dockerfile.test" \
			-t trustforge-verify:latest "$PROJECT_ROOT"
	else
		docker build "${BUILD_OPTS[@]}" -f "$PROJECT_ROOT/Dockerfile.test" \
			-t trustforge-verify:latest "$PROJECT_ROOT" >/dev/null 2>&1
	fi

	info "Docker image built successfully"
}

# Run verification tests
run_tests() {
	log "Running verification tests in Docker..."

	# Remove any previous container
	docker rm -f trustforge-verify-run 2>/dev/null || true

	docker run --rm \
		--name trustforge-verify-run \
		"${RUN_OPTS[@]}" \
		-v "$PROJECT_ROOT:/workspace:ro" \
		trustforge-verify:latest full-test

	info "Tests completed"
}

# Run interactive shell
run_shell() {
	log "Starting interactive shell in Docker container..."

	# Remove any previous container
	docker rm -f trustforge-verify-shell 2>/dev/null || true

	docker run -it --rm \
		--name trustforge-verify-shell \
		-v "$PROJECT_ROOT:/workspace:ro" \
		trustforge-verify:latest \
		/bin/bash
}

# Clean up Docker resources
clean_docker() {
	log "Cleaning up Docker resources..."

	docker rm -f trustforge-verify-run 2>/dev/null || true
	docker rm -f trustforge-verify-shell 2>/dev/null || true
	docker rmi trustforge-verify:latest 2>/dev/null || true

	info "Cleanup completed"
}

# Main execution
main() {
	log "TrustForge Deployment Verification (Docker)"
	log "Command: $COMMAND"
	log "Project: $PROJECT_ROOT"
	echo ""

	check_docker
	echo ""

	case "$COMMAND" in
		build)
			build_image
			;;
		run)
			if ! docker image inspect trustforge-verify:latest >/dev/null 2>&1; then
				log "Image not found, building first..."
				build_image
				echo ""
			fi
			run_tests
			;;
		full)
			build_image
			echo ""
			run_tests
			;;
		shell)
			if ! docker image inspect trustforge-verify:latest >/dev/null 2>&1; then
				log "Image not found, building first..."
				build_image
				echo ""
			fi
			run_shell
			;;
		clean)
			clean_docker
			;;
		help|-h|--help)
			usage
			;;
		*)
			die "Unknown command: $COMMAND"
			;;
	esac

	echo ""
	info "Done"
}

main
