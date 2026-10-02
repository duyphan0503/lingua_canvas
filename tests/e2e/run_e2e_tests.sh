#!/usr/bin/env bash
# ==============================================================================
# Lingua Canvas - Master 4-Tier E2E Test Suite Runner
# ==============================================================================
# Executes genuine opaque-box tests across all 4 tiers against live endpoints:
#   Tier 1: Feature Coverage (Endpoints, Flutter, Git, Docker configs)
#   Tier 2: Boundary & Corner Cases (Invalid ratings, 404s, malformed JSON, offline AI)
#   Tier 3: Cross-Feature Combinations (FSRS lifecycle, due queue state transitions)
#   Tier 4: Real-World Scenarios (Full IT workplace session & roleplay practice)
#
# Usage:
#   ./tests/e2e/run_e2e_tests.sh [--all | --tier=N | -h]
# ==============================================================================

set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Color definitions
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

TARGET_TIER="all"
API_BASE_URL="${API_BASE_URL:-http://127.0.0.1:8080/api/v1}"
SPAWNED_SERVER_PID=""
LOG_FILE="${SCRIPT_DIR}/server.log"

print_usage() {
    echo -e "${BOLD}Lingua Canvas E2E Test Runner${NC}"
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --all              Run all 4 tiers (default)"
    echo "  --tier=1, -1       Run Tier 1: Feature Coverage only"
    echo "  --tier=2, -2       Run Tier 2: Boundary & Corner Cases only"
    echo "  --tier=3, -3       Run Tier 3: Cross-Feature Combinations only"
    echo "  --tier=4, -4       Run Tier 4: Real-World Scenarios only"
    echo "  --help, -h         Show this help message"
    echo ""
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --all)
            TARGET_TIER="all"
            shift
            ;;
        --tier=1|-1)
            TARGET_TIER="1"
            shift
            ;;
        --tier=2|-2)
            TARGET_TIER="2"
            shift
            ;;
        --tier=3|-3)
            TARGET_TIER="3"
            shift
            ;;
        --tier=4|-4)
            TARGET_TIER="4"
            shift
            ;;
        --help|-h)
            print_usage
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            print_usage
            exit 1
            ;;
    esac
done

cleanup() {
    if [[ -n "${SPAWNED_SERVER_PID}" ]]; then
        if kill -0 "${SPAWNED_SERVER_PID}" 2>/dev/null; then
            echo -e "\n${CYAN}Shutting down background Axum server (PID: ${SPAWNED_SERVER_PID})...${NC}"
            kill -15 "${SPAWNED_SERVER_PID}" 2>/dev/null || true
            wait "${SPAWNED_SERVER_PID}" 2>/dev/null || true
        fi
    fi
}
trap cleanup EXIT INT TERM

echo -e "${BOLD}${CYAN}============================================================${NC}"
echo -e "${BOLD}${CYAN} Lingua Canvas - 4-Tier Opaque-Box E2E Test Suite${NC}"
echo -e "${BOLD}${CYAN}============================================================${NC}"
echo -e "Project Root : ${PROJECT_ROOT}"
echo -e "Target Tier  : ${TARGET_TIER}"
echo -e "API Base URL : ${API_BASE_URL}"
echo ""

# -----------------------------------------------------------------------------
# 1. Environment & Prerequisite Pre-flight Check
# -----------------------------------------------------------------------------
echo -e "${BOLD}1. Verifying Tooling Prerequisites...${NC}"
MISSING_TOOLS=0
REQUIRED_TOOLS=(python3 curl)
if [[ "${TARGET_TIER}" == "all" || "${TARGET_TIER}" == "1" ]]; then
    REQUIRED_TOOLS+=(flutter git)
fi
for tool in "${REQUIRED_TOOLS[@]}"; do
    if command -v "${tool}" >/dev/null 2>&1; then
        echo -e "  [${GREEN}FOUND${NC}] ${tool}"
    else
        echo -e "  [${RED}MISSING${NC}] ${tool}"
        MISSING_TOOLS=1
    fi
done

if [[ "${MISSING_TOOLS}" -ne 0 ]]; then
    echo -e "${RED}Prerequisite check failed. Please ensure required tools are installed.${NC}"
    exit 1
fi
echo -e "${GREEN}Prerequisites verified successfully.${NC}\n"

# -----------------------------------------------------------------------------
# 2. Server Lifecycle Management
# -----------------------------------------------------------------------------
echo -e "${BOLD}2. Managing Axum Server Lifecycle...${NC}"
check_server_healthy() {
    curl -s --max-time 2 "${API_BASE_URL}/health" | grep -q '"status":"healthy"' 2>/dev/null
}

if check_server_healthy; then
    echo -e "  ${GREEN}Server already active and healthy on ${API_BASE_URL}.${NC}"
else
    echo -e "  Server not running on ${API_BASE_URL}. Compiling and launching binary..."
    API_URL_PORT="$(python3 -c 'from urllib.parse import urlsplit; from sys import argv; p=urlsplit(argv[1]); print(p.port or (443 if p.scheme == "https" else 80))' "${API_BASE_URL}")"
    if [[ -n "${PORT:-}" && "${PORT}" != "${API_URL_PORT}" ]]; then
        echo -e "${RED}PORT (${PORT}) must match the port in API_BASE_URL (${API_URL_PORT}).${NC}"
        exit 1
    fi
    export PORT="${API_URL_PORT}"
    if ! command -v cargo >/dev/null 2>&1; then
        echo -e "${RED}cargo is required because no healthy server is available.${NC}"
        exit 1
    fi
    SERVER_BIN="${PROJECT_ROOT}/server/target/debug/server"
    echo -e "  Building ${SERVER_BIN} via cargo..."
    cargo build --manifest-path "${PROJECT_ROOT}/server/Cargo.toml" --bin server

    echo -e "  Starting background server process..."
    "${SERVER_BIN}" > "${LOG_FILE}" 2>&1 &
    SPAWNED_SERVER_PID=$!
    echo -e "  Spawned server with PID: ${SPAWNED_SERVER_PID}"

    # Poll /health with timeout
    TIMEOUT=20
    WAIT_SEC=0
    SERVER_READY=0
    while [[ "${WAIT_SEC}" -lt "${TIMEOUT}" ]]; do
        if check_server_healthy; then
            SERVER_READY=1
            break
        fi
        if ! kill -0 "${SPAWNED_SERVER_PID}" 2>/dev/null; then
            echo -e "${RED}Server crashed on startup. Recent log output:${NC}"
            tail -n 20 "${LOG_FILE}"
            exit 1
        fi
        sleep 0.5
        WAIT_SEC=$((WAIT_SEC + 1))
    done

    if [[ "${SERVER_READY}" -ne 1 ]]; then
        echo -e "${RED}Server failed to report healthy within ${TIMEOUT}s. Log:${NC}"
        tail -n 25 "${LOG_FILE}"
        exit 1
    fi
    echo -e "  ${GREEN}Axum server ready and healthy.${NC}"
fi
echo ""

# -----------------------------------------------------------------------------
# 3. Test Suite Execution
# -----------------------------------------------------------------------------
OVERALL_STATUS=0
TIER1_STATUS="PENDING"
TIER2_STATUS="PENDING"
TIER3_STATUS="PENDING"
TIER4_STATUS="PENDING"
START_TIMESTAMP=$(date +%s)

export API_BASE_URL

# Tier 1
if [[ "${TARGET_TIER}" == "all" || "${TARGET_TIER}" == "1" ]]; then
    echo -e "${BOLD}${BLUE}>>> Running Tier 1: Feature Coverage...${NC}"
    if python3 -B "${SCRIPT_DIR}/tier1_feature_coverage.py"; then
        TIER1_STATUS="PASSED"
    else
        TIER1_STATUS="FAILED"
        OVERALL_STATUS=1
    fi
    echo ""
fi

# Tier 2
if [[ "${TARGET_TIER}" == "all" || "${TARGET_TIER}" == "2" ]]; then
    echo -e "${BOLD}${BLUE}>>> Running Tier 2: Boundary & Corner Cases...${NC}"
    if python3 -B "${SCRIPT_DIR}/tier2_boundary_cases.py"; then
        TIER2_STATUS="PASSED"
    else
        TIER2_STATUS="FAILED"
        OVERALL_STATUS=1
    fi
    echo ""
fi

# Tier 3
if [[ "${TARGET_TIER}" == "all" || "${TARGET_TIER}" == "3" ]]; then
    echo -e "${BOLD}${BLUE}>>> Running Tier 3: Cross-Feature Combinations...${NC}"
    if python3 -B "${SCRIPT_DIR}/tier3_cross_feature.py"; then
        TIER3_STATUS="PASSED"
    else
        TIER3_STATUS="FAILED"
        OVERALL_STATUS=1
    fi
    echo ""
fi

# Tier 4
if [[ "${TARGET_TIER}" == "all" || "${TARGET_TIER}" == "4" ]]; then
    echo -e "${BOLD}${BLUE}>>> Running Tier 4: Real-World Application Scenarios...${NC}"
    if python3 -B "${SCRIPT_DIR}/tier4_real_world.py"; then
        TIER4_STATUS="PASSED"
    else
        TIER4_STATUS="FAILED"
        OVERALL_STATUS=1
    fi
    echo ""
fi

END_TIMESTAMP=$(date +%s)
ELAPSED=$((END_TIMESTAMP - START_TIMESTAMP))

# -----------------------------------------------------------------------------
# 4. Final Executive Summary
# -----------------------------------------------------------------------------
echo -e "${BOLD}${CYAN}============================================================${NC}"
echo -e "${BOLD}${CYAN} Final Executive E2E Test Summary${NC}"
echo -e "${BOLD}${CYAN}============================================================${NC}"
print_tier_status() {
    local name="$1"
    local status="$2"
    if [[ "${status}" == "PASSED" ]]; then
        echo -e "  ${name}: ${GREEN}${BOLD}PASSED${NC}"
    elif [[ "${status}" == "FAILED" ]]; then
        echo -e "  ${name}: ${RED}${BOLD}FAILED${NC}"
    else
        echo -e "  ${name}: ${YELLOW}${status}${NC}"
    fi
}

print_tier_status "Tier 1 (Feature Coverage)          " "${TIER1_STATUS}"
print_tier_status "Tier 2 (Boundary & Corner Cases)   " "${TIER2_STATUS}"
print_tier_status "Tier 3 (Cross-Feature Combinations)" "${TIER3_STATUS}"
print_tier_status "Tier 4 (Real-World Scenarios)      " "${TIER4_STATUS}"
echo -e "Total Execution Time: ${ELAPSED}s"
echo -e "${BOLD}${CYAN}============================================================${NC}"

if [[ "${OVERALL_STATUS}" -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}✔ ALL E2E TIERS PASSED - SYSTEM COMPLIANT & READY${NC}\n"
    exit 0
else
    echo -e "${RED}${BOLD}✖ ONE OR MORE E2E TIERS FAILED${NC}\n"
    exit 1
fi
