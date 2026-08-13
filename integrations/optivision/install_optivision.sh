#!/usr/bin/env bash
# install_optivision.sh - Milestone-based installer for Optivision JDBC Veza connector.

set -o pipefail
set -u

TOTAL_MILESTONES=9
CURRENT_MILESTONE=0

SCRIPT_NAME="optivision"
SLUG="optivision"
INTEGRATION_SUBDIR="integrations/${SLUG}"
DEFAULT_INSTALL_DIR="/opt/VEZA/${SLUG}-veza"
DEFAULT_BRANCH="main"
DEFAULT_REPO_URL="https://github.com/andrewmusto-git/Optivision.git"
STATIC_DRIVER_CLASS="com.microsoft.sqlserver.jdbc.SQLServerDriver"
DEFAULT_ACCOUNT_SQL="SELECT ua.vers_id, ua.user_id, ua.domain_name, ua.type_code, ua.user_name, ua.employee_id, ua.email_address, ua.phone_num, ua.mill_id, ua.department_id, ua.work_location, ua.supervisor, ua.supers_email_address, ua.ts_expire, ua.comment_line, ua.active_flag, ua.ts_installed, ua.ts_create, ua.ts_modified, ur.role_id, ur.seq_num FROM [opticov].[opticov].[user_account] ua LEFT JOIN [user_role] ur ON ua.user_id = ur.user_id WHERE ua.active_flag = 'Y'"
DEFAULT_ROLE_SQL="SELECT DISTINCT role_id FROM role ORDER BY role_id"

NON_INTERACTIVE=0
OVERWRITE_ENV=0
INSTALL_DIR="${DEFAULT_INSTALL_DIR}"
REPO_URL="${REPO_URL:-${DEFAULT_REPO_URL}}"
BRANCH="${DEFAULT_BRANCH}"

VEZA_URL="${VEZA_URL:-}"
VEZA_API_KEY="${VEZA_API_KEY:-}"
JDBC_URL="${JDBC_URL:-}"
JDBC_USER="${JDBC_USER:-}"
JDBC_PASSWORD="${JDBC_PASSWORD:-}"
JDBC_JAR_PATH="${JDBC_JAR_PATH:-}"
JDBC_DATABASE_NAME="${JDBC_DATABASE_NAME:-}"
JDBC_EXTRA_URL_OPTIONS="${JDBC_EXTRA_URL_OPTIONS:-}"
LOCATION_NAME="${LOCATION_NAME:-}"
ACTION_MODE="${ACTION_MODE:-}"
PROVIDER_NAME="${PROVIDER_NAME:-}"
DATASOURCE_NAME="${DATASOURCE_NAME:-}"
ACCOUNT_SQL="${ACCOUNT_SQL:-}"
ROLE_SQL="${ROLE_SQL:-}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC} $*"; }
pass() { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*" >&2; exit 1; }

milestone() {
  CURRENT_MILESTONE=$((CURRENT_MILESTONE + 1))
  echo
  echo -e "${BLUE}==== Milestone ${CURRENT_MILESTONE}/${TOTAL_MILESTONES}: $* ====${NC}"
}

usage() {
  cat <<EOF
Usage: bash install_optivision.sh [options]

Options:
  --non-interactive          Run without prompts (requires env vars)
  --overwrite-env            Allow overwriting existing location env file
  --install-dir <path>       Install target root (default: ${DEFAULT_INSTALL_DIR})
  --repo-url <url>           Git URL used to fetch integration files
  --branch <name>            Git branch to clone (default: ${DEFAULT_BRANCH})
  -h, --help                 Show this help

Supported env vars for non-interactive mode:
  VEZA_URL, VEZA_API_KEY, JDBC_URL, JDBC_USER, JDBC_PASSWORD, JDBC_JAR_PATH,
  JDBC_DATABASE_NAME, JDBC_EXTRA_URL_OPTIONS, PROVIDER_NAME, DATASOURCE_NAME,
  ACCOUNT_SQL, ROLE_SQL, LOCATION_NAME, ACTION_MODE(add|update), REPO_URL
EOF
}

prompt() {
  local prompt_text="$1"
  local var_name="$2"
  local is_secret="${3:-0}"
  local current_value="${!var_name:-}"

  if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
    if [[ -z "${current_value}" ]]; then
      fail "Missing required value for ${var_name} in non-interactive mode"
    fi
    return 0
  fi

  if [[ "${is_secret}" -eq 1 ]]; then
    read -r -s -p "${prompt_text}: " current_value </dev/tty
    echo >/dev/tty
  else
    read -r -p "${prompt_text}${current_value:+ [${current_value}]}: " input_value </dev/tty
    if [[ -n "${input_value:-}" ]]; then
      current_value="${input_value}"
    fi
  fi

  if [[ -z "${current_value}" ]]; then
    fail "${var_name} cannot be empty"
  fi
  printf -v "${var_name}" '%s' "${current_value}"
}

prompt_default() {
  local prompt_text="$1"
  local var_name="$2"
  local default_value="$3"
  local current_value="${!var_name:-$default_value}"

  if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
    printf -v "${var_name}" '%s' "${current_value}"
    return 0
  fi

  read -r -p "${prompt_text} [${current_value}]: " input_value </dev/tty
  if [[ -n "${input_value:-}" ]]; then
    current_value="${input_value}"
  fi
  printf -v "${var_name}" '%s' "${current_value}"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --non-interactive)
        NON_INTERACTIVE=1
        shift
        ;;
      --overwrite-env)
        OVERWRITE_ENV=1
        shift
        ;;
      --install-dir)
        INSTALL_DIR="$2"
        shift 2
        ;;
      --repo-url)
        REPO_URL="$2"
        shift 2
        ;;
      --branch)
        BRANCH="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        fail "Unknown option: $1"
        ;;
    esac
  done
}

detect_os_pkg_manager() {
  OS_ID="unknown"
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    OS_ID="${ID:-unknown}"
  fi

  if command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"
  elif command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt-get"
  else
    fail "No supported package manager found (dnf/yum/apt-get)"
  fi
}

install_pkg() {
  local pkg="$1"
  case "${PKG_MGR}" in
    dnf|yum)
      sudo "${PKG_MGR}" install -y "${pkg}" >/dev/null
      ;;
    apt-get)
      sudo apt-get install -y "${pkg}" >/dev/null
      ;;
  esac
}

ensure_prereqs() {
  command -v git >/dev/null 2>&1 || install_pkg git
  command -v python3 >/dev/null 2>&1 || install_pkg python3
  python3 -m pip --version >/dev/null 2>&1 || install_pkg python3-pip

  if ! command -v curl >/dev/null 2>&1; then
    if [[ "${OS_ID}" == "amzn" ]]; then
      warn "Skipping curl install on Amazon Linux due to curl-minimal package behavior"
    else
      install_pkg curl
    fi
  fi

  if ! python3 -m venv --help >/dev/null 2>&1; then
    case "${PKG_MGR}" in
      dnf|yum)
        install_pkg python3-virtualenv
        ;;
      apt-get)
        install_pkg python3-venv
        ;;
    esac
  fi

  local py_major py_minor
  py_major="$(python3 -c 'import sys; print(sys.version_info[0])')"
  py_minor="$(python3 -c 'import sys; print(sys.version_info[1])')"
  if [[ "${py_major}" -lt 3 || ( "${py_major}" -eq 3 && "${py_minor}" -lt 9 ) ]]; then
    fail "Python 3.9+ is required"
  fi
}

copy_integration_files() {
  local scripts_dir="$1"
  local tmp_dir=""

  if [[ -f "./${SCRIPT_NAME}.py" && -f "./requirements.txt" ]]; then
    cp -f "./${SCRIPT_NAME}.py" "${scripts_dir}/"
    cp -f "./requirements.txt" "${scripts_dir}/"
    return 0
  fi

  if [[ -f "./${INTEGRATION_SUBDIR}/${SCRIPT_NAME}.py" && -f "./${INTEGRATION_SUBDIR}/requirements.txt" ]]; then
    cp -f "./${INTEGRATION_SUBDIR}/${SCRIPT_NAME}.py" "${scripts_dir}/"
    cp -f "./${INTEGRATION_SUBDIR}/requirements.txt" "${scripts_dir}/"
    return 0
  fi

  prompt_default "Repository URL for connector source" REPO_URL "${DEFAULT_REPO_URL}"

  tmp_dir="$(mktemp -d)"
  GIT_TERMINAL_PROMPT=0 git clone --branch "${BRANCH}" --depth 1 --single-branch "${REPO_URL}" "${tmp_dir}" >/dev/null 2>&1 \
    || fail "Unable to clone repository from ${REPO_URL}"

  cp -f "${tmp_dir}/${INTEGRATION_SUBDIR}/${SCRIPT_NAME}.py" "${scripts_dir}/" || fail "Missing ${SCRIPT_NAME}.py in repo"
  cp -f "${tmp_dir}/${INTEGRATION_SUBDIR}/requirements.txt" "${scripts_dir}/" || fail "Missing requirements.txt in repo"
  rm -rf "${tmp_dir}"
}

choose_action_mode() {
  if [[ "${ACTION_MODE}" != "add" && "${ACTION_MODE}" != "update" ]]; then
    if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
      fail "ACTION_MODE must be add or update in non-interactive mode"
    fi

    echo "Choose action:" >/dev/tty
    echo "  1) Add new location connection" >/dev/tty
    echo "  2) Update existing location connection" >/dev/tty
    read -r -p "Selection [1/2]: " action_choice </dev/tty
    case "${action_choice}" in
      1) ACTION_MODE="add" ;;
      2) ACTION_MODE="update" ;;
      *) fail "Invalid selection" ;;
    esac
  fi
}

choose_location() {
  local config_dir="$1"

  if [[ "${ACTION_MODE}" == "update" ]]; then
    local existing
    existing="$(find "${config_dir}" -maxdepth 1 -type f -name 'Optivision-*.env' -printf '%f\n' 2>/dev/null || true)"
    if [[ -z "${existing}" ]]; then
      warn "No existing location env files found, switching to add mode"
      ACTION_MODE="add"
    elif [[ -z "${LOCATION_NAME}" && "${NON_INTERACTIVE}" -eq 0 ]]; then
      echo "Existing locations:" >/dev/tty
      echo "${existing}" >/dev/tty
    fi
  fi

  prompt "Location name (for Optivision-Location datasource naming)" LOCATION_NAME 0
  LOCATION_NAME="$(echo "${LOCATION_NAME}" | tr ' ' '-' | tr -cd '[:alnum:]._-')"
  [[ -n "${LOCATION_NAME}" ]] || fail "Location name cannot be empty"
}

write_location_env() {
  local config_dir="$1"
  local env_file="${config_dir}/Optivision-${LOCATION_NAME}.env"

  if [[ -f "${env_file}" && "${OVERWRITE_ENV}" -ne 1 ]]; then
    if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
      fail "${env_file} already exists. Pass --overwrite-env to replace it"
    fi

    read -r -p "${env_file} exists. Overwrite? [y/N]: " overwrite </dev/tty
    if [[ "${overwrite}" =~ ^[Yy]$ ]]; then
      OVERWRITE_ENV=1
    else
      fail "Aborted to avoid overwriting existing location configuration"
    fi
  fi

  prompt "Veza URL (example: https://your-tenant.veza.com)" VEZA_URL 0
  prompt "Veza API key" VEZA_API_KEY 1
  prompt_default "Provider name" PROVIDER_NAME "Optivision"
  prompt_default "Datasource name" DATASOURCE_NAME "Optivision-${LOCATION_NAME}"
  prompt "Database name" JDBC_DATABASE_NAME 0
  prompt "JDBC URL" JDBC_URL 0
  prompt_default "Extra JDBC URL options (optional, e.g. ;encrypt=true;trustServerCertificate=true)" JDBC_EXTRA_URL_OPTIONS ""
  prompt "JDBC username" JDBC_USER 0
  prompt "JDBC password" JDBC_PASSWORD 1
  prompt "JDBC driver JAR path" JDBC_JAR_PATH 0

  ACCOUNT_SQL="${ACCOUNT_SQL:-${DEFAULT_ACCOUNT_SQL}}"
  ROLE_SQL="${ROLE_SQL:-${DEFAULT_ROLE_SQL}}"

  prompt_default "Account SQL" ACCOUNT_SQL "${ACCOUNT_SQL}"
  prompt_default "Role SQL" ROLE_SQL "${ROLE_SQL}"

  if [[ -n "${JDBC_EXTRA_URL_OPTIONS}" && "${JDBC_URL}" != *"${JDBC_EXTRA_URL_OPTIONS}"* ]]; then
    JDBC_URL="${JDBC_URL}${JDBC_EXTRA_URL_OPTIONS}"
  fi

  cat > "${env_file}" <<EOF
# Optivision location profile
OPTIVISION_LOCATION=${LOCATION_NAME}
PROVIDER_NAME=${PROVIDER_NAME}
DATASOURCE_NAME=${DATASOURCE_NAME}

# Veza
VEZA_URL=${VEZA_URL}
VEZA_API_KEY=${VEZA_API_KEY}

# JDBC
JDBC_DATABASE_NAME=${JDBC_DATABASE_NAME}
JDBC_URL=${JDBC_URL}
JDBC_USER=${JDBC_USER}
JDBC_PASSWORD=${JDBC_PASSWORD}
JDBC_DRIVER_CLASS=${STATIC_DRIVER_CLASS}
JDBC_JAR_PATH=${JDBC_JAR_PATH}

# Queries
ACCOUNT_SQL=${ACCOUNT_SQL}
ROLE_SQL=${ROLE_SQL}
EOF

  chmod 600 "${env_file}" || true
  pass "Wrote location env file: ${env_file}"
}

create_run_wrapper() {
  local scripts_dir="$1"
  local config_dir="$2"
  local wrapper="${scripts_dir}/run_optivision.sh"

  cat > "${wrapper}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage:
  ./run_optivision.sh <LocationName> [additional connector args...]
  ./run_optivision.sh --guided [<LocationName>] [--save-profile] [additional connector args...]

Options:
  --guided       Prompt for runtime values before running connector
  --save-profile Save prompted values to the location env profile
  -h, --help     Show this help
USAGE
}

LOCATION=""
GUIDED=0
SAVE_PROFILE=0
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --guided)
      GUIDED=1
      shift
      ;;
    --save-profile)
      SAVE_PROFILE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      if [[ -z "${LOCATION}" ]]; then
        LOCATION="$1"
      else
        EXTRA_ARGS+=("$1")
      fi
      shift
      ;;
  esac
done

if [[ "${GUIDED}" -eq 0 && -z "${LOCATION}" ]]; then
  usage >&2
  exit 1
fi

prompt_location_if_needed() {
  if [[ -n "${LOCATION}" ]]; then
    return 0
  fi

  IFS= read -r -p "Location name (for Optivision-Location): " LOCATION </dev/tty
  if [[ -z "${LOCATION}" ]]; then
    echo "Location cannot be empty" >&2
    exit 1
  fi
}

if [[ "${GUIDED}" -eq 1 ]]; then
  prompt_location_if_needed
fi

LOCATION_SANITIZED="$(echo "${LOCATION}" | tr ' ' '-' | tr -cd '[:alnum:]._-')"
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${BASE_DIR}/config/Optivision-${LOCATION_SANITIZED}.env"

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
elif [[ "${GUIDED}" -eq 0 ]]; then
  echo "Missing env file: ${ENV_FILE}" >&2
  exit 1
fi

prompt_required() {
  local label="$1"
  local var_name="$2"
  local is_secret="${3:-0}"
  local current_value="${!var_name:-}"

  if [[ "${is_secret}" -eq 1 ]]; then
    IFS= read -r -s -p "${label}: " current_value </dev/tty
    echo >/dev/tty
  else
    IFS= read -r -p "${label}${current_value:+ [${current_value}]}: " input_value </dev/tty
    if [[ -n "${input_value:-}" ]]; then
      current_value="${input_value}"
    fi
  fi

  if [[ -z "${current_value}" ]]; then
    echo "${var_name} cannot be empty" >&2
    exit 1
  fi
  printf -v "${var_name}" '%s' "${current_value}"
}

prompt_optional() {
  local label="$1"
  local var_name="$2"
  local default_value="${3:-}"
  local current_value="${!var_name:-$default_value}"

  IFS= read -r -p "${label}${current_value:+ [${current_value}]}: " input_value </dev/tty
  if [[ -n "${input_value:-}" ]]; then
    current_value="${input_value}"
  fi
  printf -v "${var_name}" '%s' "${current_value}"
}

if [[ "${GUIDED}" -eq 1 ]]; then
  PROVIDER_NAME="${PROVIDER_NAME:-Optivision}"
  DATASOURCE_NAME="${DATASOURCE_NAME:-Optivision-${LOCATION_SANITIZED}}"

  prompt_required "Veza URL" VEZA_URL 0
  prompt_required "Veza API key" VEZA_API_KEY 1
  prompt_optional "Provider name" PROVIDER_NAME "Optivision"
  prompt_optional "Datasource name" DATASOURCE_NAME "Optivision-${LOCATION_SANITIZED}"
  prompt_required "Database name" JDBC_DATABASE_NAME 0
  prompt_required "JDBC URL" JDBC_URL 0
  prompt_optional "Extra JDBC URL options (optional)" JDBC_EXTRA_URL_OPTIONS ""
  if [[ -n "${JDBC_EXTRA_URL_OPTIONS}" && "${JDBC_URL}" != *"${JDBC_EXTRA_URL_OPTIONS}"* ]]; then
    JDBC_URL="${JDBC_URL}${JDBC_EXTRA_URL_OPTIONS}"
  fi
  prompt_required "JDBC username" JDBC_USER 0
  prompt_required "JDBC password" JDBC_PASSWORD 1
  prompt_required "JDBC driver JAR path" JDBC_JAR_PATH 0
  prompt_required "Account SQL" ACCOUNT_SQL 0
  prompt_required "Role SQL" ROLE_SQL 0

  if [[ "${SAVE_PROFILE}" -eq 1 ]]; then
    cat > "${ENV_FILE}" <<PROFILE
# Optivision location profile
OPTIVISION_LOCATION=${LOCATION_SANITIZED}
PROVIDER_NAME=${PROVIDER_NAME}
DATASOURCE_NAME=${DATASOURCE_NAME}

# Veza
VEZA_URL=${VEZA_URL}
VEZA_API_KEY=${VEZA_API_KEY}

# JDBC
JDBC_DATABASE_NAME=${JDBC_DATABASE_NAME}
JDBC_URL=${JDBC_URL}
JDBC_USER=${JDBC_USER}
JDBC_PASSWORD=${JDBC_PASSWORD}
JDBC_DRIVER_CLASS=com.microsoft.sqlserver.jdbc.SQLServerDriver
JDBC_JAR_PATH=${JDBC_JAR_PATH}
JDBC_EXTRA_URL_OPTIONS=${JDBC_EXTRA_URL_OPTIONS}

# Queries
ACCOUNT_SQL=${ACCOUNT_SQL}
ROLE_SQL=${ROLE_SQL}
PROFILE
    chmod 600 "${ENV_FILE}" || true
    echo "Saved prompted values to ${ENV_FILE}" >&2
  fi
fi

cd "${BASE_DIR}/scripts"

if [[ "${GUIDED}" -eq 1 ]]; then
  exec ./venv/bin/python3 ./optivision.py \
    --location "${LOCATION_SANITIZED}" \
    --veza-url "${VEZA_URL}" \
    --veza-api-key "${VEZA_API_KEY}" \
    --provider-name "${PROVIDER_NAME}" \
    --datasource-name "${DATASOURCE_NAME}" \
    --jdbc-database-name "${JDBC_DATABASE_NAME}" \
    --jdbc-url "${JDBC_URL}" \
    --jdbc-user "${JDBC_USER}" \
    --jdbc-password "${JDBC_PASSWORD}" \
    --jdbc-jar-path "${JDBC_JAR_PATH}" \
    --account-sql "${ACCOUNT_SQL}" \
    --role-sql "${ROLE_SQL}" \
    "${EXTRA_ARGS[@]}"
fi

exec ./venv/bin/python3 ./optivision.py --env-file "${ENV_FILE}" "${EXTRA_ARGS[@]}"
EOF

  chmod +x "${wrapper}"
  pass "Created run wrapper: ${wrapper}"
}

main() {
  parse_args "$@"

  milestone "Detect OS and package manager"
  detect_os_pkg_manager
  pass "Detected OS_ID=${OS_ID}, package manager=${PKG_MGR}"

  milestone "Install prerequisites"
  ensure_prereqs
  pass "System prerequisites verified"

  milestone "Create folder structure under /opt/VEZA"
  SCRIPTS_DIR="${INSTALL_DIR}/scripts"
  LOGS_DIR="${INSTALL_DIR}/logs"
  CONFIG_DIR="${INSTALL_DIR}/config"
  mkdir -p "${SCRIPTS_DIR}" "${LOGS_DIR}" "${CONFIG_DIR}"
  pass "Created ${INSTALL_DIR} with scripts/logs/config"

  milestone "Copy integration files"
  copy_integration_files "${SCRIPTS_DIR}"
  pass "Connector script and requirements are ready"

  milestone "Create virtual environment and install Python dependencies"
  if [[ ! -d "${SCRIPTS_DIR}/venv" ]]; then
    python3 -m venv "${SCRIPTS_DIR}/venv"
  fi
  "${SCRIPTS_DIR}/venv/bin/pip" install --upgrade pip >/dev/null
  "${SCRIPTS_DIR}/venv/bin/pip" install -r "${SCRIPTS_DIR}/requirements.txt"
  pass "Python environment is ready"

  milestone "Choose add/update mode"
  choose_action_mode
  pass "Mode selected: ${ACTION_MODE}"

  milestone "Select location profile"
  choose_location "${CONFIG_DIR}"
  pass "Location selected: ${LOCATION_NAME}"

  milestone "Capture connection values and write env profile"
  write_location_env "${CONFIG_DIR}"

  milestone "Generate run helper and final summary"
  create_run_wrapper "${SCRIPTS_DIR}" "${CONFIG_DIR}"

  echo
  pass "Install complete"
  echo "Install dir: ${INSTALL_DIR}"
  echo "Location env: ${CONFIG_DIR}/Optivision-${LOCATION_NAME}.env"
  echo "Run command:"
  echo "  cd ${SCRIPTS_DIR}"
  echo "  ./run_optivision.sh ${LOCATION_NAME} --save-json"
  echo "Guided runtime command:"
  echo "  ./run_optivision.sh ${LOCATION_NAME} --guided --save-json"
  echo
  echo "Re-run this installer anytime to add another location or update an existing one."
}

main "$@"
