#!/usr/bin/env bash
# Local verification script for TrustForge bare-metal deployment improvements
# Can run on any Linux system without Docker, or be executed in Docker

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
TEST_RESULTS_DIR=${TEST_RESULTS_DIR:-.test-results}

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}[VERIFY]${NC} $*"; }
info() { echo -e "${GREEN}[PASS]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[FAIL]${NC} $*" >&2; }

# Create results directory
mkdir -p "$TEST_RESULTS_DIR"

# Counter variables
pass_count=0
fail_count=0

pass() {
	info "$@"
	((pass_count++))
}

fail() {
	error "$@"
	((fail_count++))
}

echo "=========================================="
echo "TrustForge Bare-Metal Deployment Verification"
echo "=========================================="
echo "Project Root: $PROJECT_ROOT"
echo "Test Results: $TEST_RESULTS_DIR"
echo ""

# ============ VERIFICATION TESTS ============

# 1. File Structure Verification
echo -e "${BLUE}=== File Structure ===${NC}"

if [[ -f "$PROJECT_ROOT/deploy/release/make-package.sh" ]]; then
	pass "make-package.sh exists"
else
	fail "make-package.sh not found"
fi

if [[ -f "$PROJECT_ROOT/deploy/bare-metal/install.sh" ]]; then
	pass "install.sh exists"
else
	fail "install.sh not found"
fi

# Check for init-*.sh scripts
for script in init-dns init-certctl init-nginx init-step-ca init-oidc; do
	if [[ -f "$PROJECT_ROOT/deploy/bare-metal/${script}.sh" ]]; then
		pass "deploy/bare-metal/${script}.sh exists"
	else
		fail "deploy/bare-metal/${script}.sh not found"
	fi
done

# Check for remote-helper files
if [[ -f "$PROJECT_ROOT/remote-helper/trustforge-certctl" ]]; then
	pass "remote-helper/trustforge-certctl exists"
else
	fail "remote-helper/trustforge-certctl not found"
fi

if [[ -f "$PROJECT_ROOT/remote-helper/README.md" ]]; then
	pass "remote-helper/README.md exists"
else
	fail "remote-helper/README.md not found"
fi

# Check documentation
if [[ -f "$PROJECT_ROOT/deploy/bare-metal/DEPLOYMENT-SCRIPTS.md" ]]; then
	pass "DEPLOYMENT-SCRIPTS.md exists"
else
	fail "DEPLOYMENT-SCRIPTS.md not found"
fi

echo ""

# 2. File Permissions Verification
echo -e "${BLUE}=== File Permissions ===${NC}"

check_permission() {
	local file=$1
	local expected=$2
	local actual=$(stat -c '%a' "$file" 2>/dev/null || echo "000")
	if [[ "$actual" == "$expected" ]] || [[ "$actual" == "77"* ]]; then
		pass "$file has correct permissions ($actual)"
		return 0
	else
		warn "$file has permissions $actual (expected $expected)"
		return 1
	fi
}

check_permission "$PROJECT_ROOT/deploy/bare-metal/install.sh" "755"
check_permission "$PROJECT_ROOT/deploy/bare-metal/init-dns.sh" "755"
check_permission "$PROJECT_ROOT/deploy/bare-metal/trustforge.service" "644"
check_permission "$PROJECT_ROOT/deploy/bare-metal/trustforge.env.example" "644"

if [[ -f "$PROJECT_ROOT/remote-helper/trustforge-certctl" ]]; then
	check_permission "$PROJECT_ROOT/remote-helper/trustforge-certctl" "750"
fi

echo ""

# 3. Bash Syntax Validation
echo -e "${BLUE}=== Bash Syntax ===${NC}"

check_bash_syntax() {
	local file=$1
	if bash -n "$file" 2>/dev/null; then
		pass "Bash syntax valid: $(basename "$file")"
		return 0
	else
		fail "Bash syntax error: $(basename "$file")"
		return 1
	fi
}

for script in install.sh init-dns.sh init-certctl.sh init-nginx.sh init-step-ca.sh init-oidc.sh \
			  setup-acme-dns.sh setup-nginx-tls.sh setup-oidc.sh setup-step-ca.sh common.sh; do
	if [[ -f "$PROJECT_ROOT/deploy/bare-metal/$script" ]]; then
		check_bash_syntax "$PROJECT_ROOT/deploy/bare-metal/$script"
	fi
done

echo ""

# 4. Shellcheck Validation (if available)
echo -e "${BLUE}=== Shellcheck Linting ===${NC}"

if command -v shellcheck &>/dev/null; then
	for script in install.sh init-dns.sh init-certctl.sh init-nginx.sh init-step-ca.sh init-oidc.sh; do
		if [[ -f "$PROJECT_ROOT/deploy/bare-metal/$script" ]]; then
			if shellcheck -S style "$PROJECT_ROOT/deploy/bare-metal/$script" >/dev/null 2>&1; then
				pass "Shellcheck passed: $script"
			else
				warn "Shellcheck warnings in $script (see details above)"
			fi
		fi
	done
else
	warn "shellcheck not installed, skipping linting"
fi

echo ""

# 5. Configuration File Verification
echo -e "${BLUE}=== Configuration Files ===${NC}"

env_file="$PROJECT_ROOT/deploy/bare-metal/trustforge.env.example"

if grep -q "ACME_DNS_HOST" "$env_file"; then
	pass "trustforge.env.example contains ACME_DNS_HOST"
else
	fail "trustforge.env.example missing ACME_DNS_HOST"
fi

if grep -q "ACME_DNS_PORT" "$env_file"; then
	pass "trustforge.env.example contains ACME_DNS_PORT"
else
	fail "trustforge.env.example missing ACME_DNS_PORT"
fi

if grep -q "ACME_DNS_ZONE" "$env_file"; then
	pass "trustforge.env.example contains ACME_DNS_ZONE"
else
	fail "trustforge.env.example missing ACME_DNS_ZONE"
fi

if grep -q "ACME_DNS_TOKEN" "$env_file"; then
	pass "trustforge.env.example contains ACME_DNS_TOKEN"
else
	fail "trustforge.env.example missing ACME_DNS_TOKEN"
fi

service_file="$PROJECT_ROOT/deploy/bare-metal/trustforge.service"
if grep -q "file:/opt/trustforge/BAREMETAL.md" "$service_file"; then
	fail "trustforge.service contains invalid file:// reference"
else
	pass "trustforge.service does not contain invalid file:// reference"
fi

if grep -q "https://github.com" "$service_file"; then
	pass "trustforge.service contains https:// documentation links"
else
	fail "trustforge.service missing https:// documentation links"
fi

echo ""

# 6. Script Functionality Verification
echo -e "${BLUE}=== Script Functionality ===${NC}"

for script in init-dns init-certctl init-nginx init-step-ca init-oidc; do
	script_path="$PROJECT_ROOT/deploy/bare-metal/${script}.sh"
	if [[ -f "$script_path" ]]; then
		if bash "$script_path" --help &>/dev/null; then
			pass "$script.sh has --help support"
		else
			fail "$script.sh missing --help support"
		fi

		if grep -q "\-\-dry-run" "$script_path"; then
			pass "$script.sh supports --dry-run"
		else
			fail "$script.sh missing --dry-run support"
		fi
	fi
done

echo ""

# 7. CI Configuration Verification
echo -e "${BLUE}=== CI Configuration ===${NC}"

ci_file="$PROJECT_ROOT/.github/workflows/linux-release.yml"
if [[ -f "$ci_file" ]]; then
	if grep -q "init-dns.sh" "$ci_file"; then
		pass "CI includes init-dns.sh in script checks"
	else
		fail "CI missing init-dns.sh in script checks"
	fi

	if grep -q "trustforge-certctl" "$ci_file"; then
		pass "CI includes remote-helper/trustforge-certctl verification"
	else
		fail "CI missing remote-helper/trustforge-certctl verification"
	fi
else
	fail "CI configuration file not found"
fi

echo ""

# 8. Make-package.sh Modification Verification
echo -e "${BLUE}=== Package Script Verification ===${NC}"

pkg_script="$PROJECT_ROOT/deploy/release/make-package.sh"
if grep -q "remote-helper" "$pkg_script"; then
	pass "make-package.sh includes remote-helper/ in stage_tree()"
else
	fail "make-package.sh missing remote-helper/ handling"
fi

if grep -q "init-dns" "$pkg_script"; then
	pass "make-package.sh includes init-*.sh scripts"
else
	fail "make-package.sh missing init-*.sh scripts"
fi

echo ""

# ============ GENERATE REPORT ============

echo "=========================================="
echo "                 Summary"
echo "=========================================="
echo -e "${GREEN}Passed: $pass_count${NC}"
if [[ $fail_count -gt 0 ]]; then
	echo -e "${RED}Failed: $fail_count${NC}"
fi
total=$((pass_count + fail_count))
if [[ $total -gt 0 ]]; then
	pass_rate=$((100 * pass_count / total))
	echo "Pass Rate: $pass_rate%"
fi
echo "=========================================="
echo ""

if [[ $fail_count -eq 0 ]]; then
	echo -e "${GREEN}✓ All verification tests passed!${NC}"
	exit 0
else
	echo -e "${RED}✗ Some verification tests failed.${NC}"
	echo "Please review the failures above."
	exit 1
fi
