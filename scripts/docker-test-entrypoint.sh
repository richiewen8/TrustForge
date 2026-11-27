#!/usr/bin/env bash
# Docker test entrypoint for TrustForge bare-metal deployment verification
# Runs various test scenarios in an isolated environment

set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TRUSTFORGE_DIR=/opt/trustforge
TEST_RESULTS=/tmp/test-results.json
FAILED_TESTS=()
PASSED_TESTS=()
pass_count=0
fail_count=0

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() { echo -e "${BLUE}[TEST]${NC} $*"; }
info() { echo -e "${GREEN}[PASS]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[FAIL]${NC} $*" >&2; }
die() { error "$*"; exit 1; }

# Safe increment counters
inc_pass() { pass_count=$((pass_count + 1)); }
inc_fail() { fail_count=$((fail_count + 1)); }

# Test result tracking
test_start() {
	local test_name=$1
	log "Starting: $test_name"
}

test_pass() {
	local test_name=$1
	local message=${2:-"Test passed"}
	info "$test_name: $message"
	PASSED_TESTS+=("$test_name")
}

test_fail() {
	local test_name=$1
	local message=${2:-"Test failed"}
	error "$test_name: $message"
	FAILED_TESTS+=("$test_name")
}

# Test: Verify file structure
test_file_structure() {
	test_start "File Structure"

	local required_files=(
		"deploy/bare-metal/install.sh"
		"deploy/bare-metal/trustforge.service"
		"deploy/bare-metal/trustforge.env.example"
		"deploy/bare-metal/init-dns.sh"
		"deploy/bare-metal/init-certctl.sh"
		"deploy/bare-metal/init-nginx.sh"
		"deploy/bare-metal/init-step-ca.sh"
		"deploy/bare-metal/init-oidc.sh"
		"deploy/bare-metal/setup-acme-dns.sh"
		"deploy/bare-metal/setup-nginx-tls.sh"
		"deploy/bare-metal/setup-oidc.sh"
		"deploy/bare-metal/setup-step-ca.sh"
		"deploy/bare-metal/common.sh"
		"remote-helper/trustforge-certctl"
		"remote-helper/README.md"
	)

	local missing=()
	for f in "${required_files[@]}"; do
		if [[ ! -f "$TRUSTFORGE_DIR/$f" ]]; then
			missing+=("$f")
		fi
	done

	if [[ ${#missing[@]} -eq 0 ]]; then
		test_pass "File Structure" "All required files present"
		inc_pass
	else
		test_fail "File Structure" "Missing files: ${missing[*]}"
		inc_fail
	fi
}

# Test: Verify file permissions
test_file_permissions() {
	test_start "File Permissions"

	local tests_passed=0
	local tests_failed=0

	# Check executable scripts (0755)
	for script in deploy/bare-metal/{init-,setup-,install}.sh deploy/bare-metal/build-and-verify-in-container.sh; do
		if [[ -f "$TRUSTFORGE_DIR/$script" ]]; then
			local perms=$(stat -c '%a' "$TRUSTFORGE_DIR/$script" 2>/dev/null || echo "000")
			if [[ "$perms" == "755" ]] || [[ "$perms" == "775" ]]; then
				tests_passed=$((tests_passed + 1))
			else
				tests_failed=$((tests_failed + 1))
				warn "  $script has permissions $perms (expected 755)"
			fi
		fi
	done

	# Check binary (0750)
	if [[ -f "$TRUSTFORGE_DIR/remote-helper/trustforge-certctl" ]]; then
		local perms=$(stat -c '%a' "$TRUSTFORGE_DIR/remote-helper/trustforge-certctl" 2>/dev/null || echo "000")
		if [[ "$perms" == "750" ]]; then
			tests_passed=$((tests_passed + 1))
		else
			tests_failed=$((tests_failed + 1))
			warn "  trustforge-certctl has permissions $perms (expected 750)"
		fi
	fi

	if [[ $tests_failed -eq 0 ]]; then
		test_pass "File Permissions" "All permissions correct ($tests_passed checks)"
		inc_pass
	else
		test_fail "File Permissions" "$tests_failed permission checks failed"
		inc_fail
	fi
}

# Test: Shellcheck validation
test_shellcheck() {
	test_start "Shellcheck Validation"

	if ! command -v shellcheck &>/dev/null; then
		warn "shellcheck not installed, skipping"
		return 0
	fi

	local scripts=(
		"deploy/bare-metal/install.sh"
		"deploy/bare-metal/init-dns.sh"
		"deploy/bare-metal/init-certctl.sh"
		"deploy/bare-metal/init-nginx.sh"
		"deploy/bare-metal/init-step-ca.sh"
		"deploy/bare-metal/init-oidc.sh"
		"deploy/bare-metal/setup-acme-dns.sh"
		"deploy/bare-metal/setup-nginx-tls.sh"
		"deploy/bare-metal/setup-oidc.sh"
		"deploy/bare-metal/setup-step-ca.sh"
		"deploy/bare-metal/common.sh"
		"deploy/bare-metal/build-and-verify-in-container.sh"
	)

	local failed=()
	for script in "${scripts[@]}"; do
		if [[ -f "$TRUSTFORGE_DIR/$script" ]]; then
			if ! shellcheck -S style "$TRUSTFORGE_DIR/$script" 2>/dev/null; then
				failed+=("$script")
			fi
		fi
	done

	if [[ ${#failed[@]} -eq 0 ]]; then
		test_pass "Shellcheck Validation" "All scripts passed"
		inc_pass
	else
		test_fail "Shellcheck Validation" "Scripts with issues: ${failed[*]}"
		inc_fail
	fi
}

# Test: Bash syntax validation
test_bash_syntax() {
	test_start "Bash Syntax Validation"

	local scripts=(
		"deploy/bare-metal/install.sh"
		"deploy/bare-metal/init-dns.sh"
		"deploy/bare-metal/init-certctl.sh"
		"deploy/bare-metal/init-nginx.sh"
		"deploy/bare-metal/init-step-ca.sh"
		"deploy/bare-metal/init-oidc.sh"
		"deploy/bare-metal/setup-acme-dns.sh"
		"deploy/bare-metal/setup-nginx-tls.sh"
		"deploy/bare-metal/setup-oidc.sh"
		"deploy/bare-metal/setup-step-ca.sh"
		"deploy/bare-metal/common.sh"
		"deploy/bare-metal/build-and-verify-in-container.sh"
	)

	local failed=()
	for script in "${scripts[@]}"; do
		if [[ -f "$TRUSTFORGE_DIR/$script" ]]; then
			if ! bash -n "$TRUSTFORGE_DIR/$script" 2>/dev/null; then
				failed+=("$script")
			fi
		fi
	done

	if [[ ${#failed[@]} -eq 0 ]]; then
		test_pass "Bash Syntax Validation" "All scripts have valid syntax"
		inc_pass
	else
		test_fail "Bash Syntax Validation" "Scripts with syntax errors: ${failed[*]}"
		inc_fail
	fi
}

# Test: Script help output
test_script_help() {
	test_start "Script Help Output"

	local init_scripts=(
		"init-dns.sh"
		"init-certctl.sh"
		"init-nginx.sh"
		"init-step-ca.sh"
		"init-oidc.sh"
	)

	local failed=()
	for script in "${init_scripts[@]}"; do
		if [[ -f "$TRUSTFORGE_DIR/deploy/bare-metal/$script" ]]; then
			if ! bash "$TRUSTFORGE_DIR/deploy/bare-metal/$script" --help &>/dev/null; then
				failed+=("$script")
			fi
		fi
	done

	if [[ ${#failed[@]} -eq 0 ]]; then
		test_pass "Script Help Output" "All init scripts have --help support"
		inc_pass
	else
		test_fail "Script Help Output" "Scripts without --help: ${failed[*]}"
		inc_fail
	fi
}

# Test: Script dry-run support
test_script_dryrun() {
	test_start "Script Dry-run Support"

	local init_scripts=(
		"init-dns.sh"
		"init-certctl.sh"
		"init-nginx.sh"
		"init-step-ca.sh"
		"init-oidc.sh"
	)

	local tested=0
	local missing_dryrun=()

	for script in "${init_scripts[@]}"; do
		if grep -q "\-\-dry-run" "$TRUSTFORGE_DIR/deploy/bare-metal/$script"; then
			tested=$((tested + 1))
		else
			missing_dryrun+=("$script")
		fi
	done

	if [[ ${#missing_dryrun[@]} -eq 0 ]]; then
		test_pass "Script Dry-run Support" "All $tested init scripts support --dry-run"
		inc_pass
	else
		test_fail "Script Dry-run Support" "Scripts missing --dry-run: ${missing_dryrun[*]}"
		inc_fail
	fi
}

# Test: Configuration file validation
test_config_files() {
	test_start "Configuration File Validation"

	local tests_passed=0
	local tests_failed=0

	# Check trustforge.env.example
	if grep -q "ACME_DNS_HOST" "$TRUSTFORGE_DIR/deploy/bare-metal/trustforge.env.example"; then
		tests_passed=$((tests_passed + 1))
	else
		tests_failed=$((tests_failed + 1))
		warn "  ACME_DNS_HOST missing from trustforge.env.example"
	fi

	if grep -q "ACME_DNS_PORT" "$TRUSTFORGE_DIR/deploy/bare-metal/trustforge.env.example"; then
		tests_passed=$((tests_passed + 1))
	else
		tests_failed=$((tests_failed + 1))
		warn "  ACME_DNS_PORT missing from trustforge.env.example"
	fi

	if grep -q "ACME_DNS_ZONE" "$TRUSTFORGE_DIR/deploy/bare-metal/trustforge.env.example"; then
		tests_passed=$((tests_passed + 1))
	else
		tests_failed=$((tests_failed + 1))
		warn "  ACME_DNS_ZONE missing from trustforge.env.example"
	fi

	if grep -q "ACME_DNS_TOKEN" "$TRUSTFORGE_DIR/deploy/bare-metal/trustforge.env.example"; then
		tests_passed=$((tests_passed + 1))
	else
		tests_failed=$((tests_failed + 1))
		warn "  ACME_DNS_TOKEN missing from trustforge.env.example"
	fi

	# Check systemd service file
	if [[ -f "$TRUSTFORGE_DIR/deploy/bare-metal/trustforge.service" ]]; then
		# Verify no invalid file:// references
		if grep -q "file:/opt/trustforge/BAREMETAL.md" "$TRUSTFORGE_DIR/deploy/bare-metal/trustforge.service"; then
			tests_failed=$((tests_failed + 1))
			warn "  trustforge.service contains invalid file:// reference"
		else
			tests_passed=$((tests_passed + 1))
		fi

		# Verify https:// documentation links
		if grep -q "https://github.com" "$TRUSTFORGE_DIR/deploy/bare-metal/trustforge.service"; then
			tests_passed=$((tests_passed + 1))
		else
			tests_failed=$((tests_failed + 1))
			warn "  trustforge.service missing https:// documentation links"
		fi
	fi

	if [[ $tests_failed -eq 0 ]]; then
		test_pass "Configuration File Validation" "All config files valid ($tests_passed checks)"
		inc_pass
	else
		test_fail "Configuration File Validation" "$tests_failed config checks failed"
		inc_fail
	fi
}

# Test: Documentation completeness
test_documentation() {
	test_start "Documentation Completeness"

	local required_docs=(
		"deploy/bare-metal/DEPLOYMENT-SCRIPTS.md"
		"../BARE-METAL-QUICKSTART.md"
		"../BARE-METAL-REFACTOR-SUMMARY.md"
		"../BARE-METAL-REFACTOR-CHECKLIST.md"
	)

	local missing=()
	for doc in "${required_docs[@]}"; do
		local path="$TRUSTFORGE_DIR/$doc"
		if [[ ! -f "$path" ]]; then
			missing+=("$doc")
		fi
	done

	if [[ ${#missing[@]} -eq 0 ]]; then
		test_pass "Documentation Completeness" "All documentation files present"
		inc_pass
	else
		test_fail "Documentation Completeness" "Missing documentation: ${missing[*]}"
		inc_fail
	fi
}

# Test: Remote helper availability
test_remote_helper() {
	test_start "Remote Helper Availability"

	local helper_pass=0
	if [[ -f "$TRUSTFORGE_DIR/remote-helper/trustforge-certctl" ]]; then
		if file "$TRUSTFORGE_DIR/remote-helper/trustforge-certctl" | grep -q "ELF"; then
			test_pass "Remote Helper Availability" "trustforge-certctl is a valid ELF binary"
			helper_pass=1
		else
			test_fail "Remote Helper Availability" "trustforge-certctl is not a valid ELF binary"
		fi
	else
		test_fail "Remote Helper Availability" "trustforge-certctl binary not found"
	fi

	if [[ -f "$TRUSTFORGE_DIR/remote-helper/README.md" ]]; then
		test_pass "Remote Helper Documentation" "remote-helper/README.md exists"
		helper_pass=1
	else
		test_fail "Remote Helper Documentation" "remote-helper/README.md not found"
	fi

	if [[ $helper_pass -eq 1 ]]; then
		inc_pass
	else
		inc_fail
	fi
}

# Test: Application assembly
test_application_assembly() {
	test_start "Application Assembly"

	if [[ -f "$TRUSTFORGE_DIR/app/current/TrustForge.dll" ]]; then
		test_pass "Application Assembly" "TrustForge.dll present"
		inc_pass
	else
		test_fail "Application Assembly" "TrustForge.dll not found"
		inc_fail
	fi
}

# Generate test report
generate_report() {
	local total=$((${#PASSED_TESTS[@]} + ${#FAILED_TESTS[@]}))
	local passed=${#PASSED_TESTS[@]}
	local failed=${#FAILED_TESTS[@]}
	local pass_rate=$((100 * passed / total))

	echo ""
	echo "========================================"
	echo "   TrustForge Deployment Verification"
	echo "========================================"
	echo "Total Tests: $total"
	echo -e "${GREEN}Passed: $passed${NC}"
	if [[ $failed -gt 0 ]]; then
		echo -e "${RED}Failed: $failed${NC}"
	fi
	echo "Pass Rate: $pass_rate%"
	echo "========================================"
	echo ""

	if [[ $failed -gt 0 ]]; then
		echo -e "${RED}Failed Tests:${NC}"
		for test in "${FAILED_TESTS[@]}"; do
			echo "  - $test"
		done
		echo ""
		return 1
	else
		echo -e "${GREEN}✓ All verification tests passed!${NC}"
		return 0
	fi
}

# Main test runner
main() {
	local test_type=${1:-full-test}

	log "Starting TrustForge deployment verification"
	log "Test type: $test_type"
	log "Working directory: $TRUSTFORGE_DIR"
	echo ""

	case "$test_type" in
		full-test)
			test_file_structure
			test_file_permissions
			test_bash_syntax
			test_shellcheck
			test_script_help
			test_script_dryrun
			test_config_files
			test_documentation
			test_remote_helper
			test_application_assembly
			;;
		quick-test)
			test_file_structure
			test_bash_syntax
			test_config_files
			;;
		syntax-only)
			test_bash_syntax
			;;
		*)
			die "Unknown test type: $test_type"
			;;
	esac

	generate_report
}

main "$@"
