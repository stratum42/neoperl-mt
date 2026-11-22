#!/usr/bin/env bash
# setup-db2-container.sh - Provision a local IBM Db2 Community container for NeoPerl::MT
# Author: stratum42

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"

PREFIX="${HOME}/.local/neoperl"
SCHEMA_PATH=""
PORT="50000"
DB_NAME="NEOPERL"
CONTAINER_NAME="neoperl-db2"
VOLUME_NAME="neoperl-db2-data"
IMAGE="icr.io/db2_community/db2"
RUNTIME_REQ="auto"
CONFIG_DIR="${HOME}/.config/neoperl"
DB2_PASSWORD=""
TARGET_OS=""
TARGET_ARCH=""
DRY_RUN=0

usage() {
    cat <<'EOF'
Usage: setup-db2-container.sh [options]

Provision a local IBM Db2 Community Edition container with persistent storage,
apply schema/db2_memory.sql, and write NeoPerl::MT connection configuration.

Options:
  --prefix=DIR            NeoPerl installation prefix (default: $HOME/.local/neoperl)
  --schema=PATH           Path to db2_memory.sql (default: auto-detected)
  --port=PORT             Host loopback port mapped to 50000 (default: 50000)
  --db-name=NAME          Database name (default: NEOPERL)
  --container-name=NAME   Container name (default: neoperl-db2)
  --volume-name=NAME      Persistent volume name (default: neoperl-db2-data)
  --image=IMAGE           Container image (default: icr.io/db2_community/db2)
  --password=PASS         db2inst1 password (default: generated randomly)
  --runtime=MODE          Container runtime: auto|docker|podman (default: auto)
  --config-dir=DIR        Config output dir (default: $HOME/.config/neoperl)
  --target-os=OS          Override detected OS (darwin|linux) for --dry-run
  --target-arch=ARCH      Override detected arch (arm64|amd64|ppc64le) for --dry-run
  -n, --dry-run           Show planned actions without running container commands
  -h, --help              Show this help message
EOF
}

to_lower() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

normalize_os() {
    case "$(to_lower "$1")" in
        darwin|macos) printf 'darwin' ;;
        linux)        printf 'linux' ;;
        *)            to_lower "$1" ;;
    esac
}

normalize_arch() {
    case "$(to_lower "$1")" in
        arm64|aarch64)       printf 'arm64' ;;
        x86_64|amd64)        printf 'amd64' ;;
        ppc64le|powerpc64le) printf 'ppc64le' ;;
        *)                   to_lower "$1" ;;
    esac
}

generate_password() {
    local raw=""
    if command -v openssl >/dev/null 2>&1; then
        raw="$(openssl rand -base64 32 | LC_ALL=C tr -dc 'A-Za-z0-9')"
        if [ "${#raw}" -ge 20 ]; then
            printf '%s' "$raw" | cut -c1-20
            return 0
        fi
    fi
    if [ -r /dev/urandom ]; then
        raw="$(set +o pipefail; LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20)"
        if [ "${#raw}" -ge 16 ]; then
            printf '%s' "$raw"
            return 0
        fi
    fi
    printf 'error: unable to generate random password (openssl and /dev/urandom unavailable)\n' >&2
    return 1
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --prefix=*)         PREFIX="${1#*=}" ;;
        --prefix)           shift; PREFIX="${1:?--prefix requires a value}" ;;
        --schema=*)         SCHEMA_PATH="${1#*=}" ;;
        --schema)           shift; SCHEMA_PATH="${1:?--schema requires a value}" ;;
        --port=*)           PORT="${1#*=}" ;;
        --port)             shift; PORT="${1:?--port requires a value}" ;;
        --db-name=*)        DB_NAME="${1#*=}" ;;
        --db-name)          shift; DB_NAME="${1:?--db-name requires a value}" ;;
        --container-name=*) CONTAINER_NAME="${1#*=}" ;;
        --container-name)   shift; CONTAINER_NAME="${1:?--container-name requires a value}" ;;
        --volume-name=*)    VOLUME_NAME="${1#*=}" ;;
        --volume-name)      shift; VOLUME_NAME="${1:?--volume-name requires a value}" ;;
        --image=*)          IMAGE="${1#*=}" ;;
        --image)            shift; IMAGE="${1:?--image requires a value}" ;;
        --password=*)       DB2_PASSWORD="${1#*=}" ;;
        --password)         shift; DB2_PASSWORD="${1:?--password requires a value}" ;;
        --runtime=*)        RUNTIME_REQ="$(to_lower "${1#*=}")" ;;
        --runtime)          shift; RUNTIME_REQ="$(to_lower "${1:?--runtime requires a value}")" ;;
        --config-dir=*)     CONFIG_DIR="${1#*=}" ;;
        --config-dir)       shift; CONFIG_DIR="${1:?--config-dir requires a value}" ;;
        --target-os=*)      TARGET_OS="${1#*=}" ;;
        --target-os)        shift; TARGET_OS="${1:?--target-os requires a value}" ;;
        --target-arch=*)    TARGET_ARCH="${1#*=}" ;;
        --target-arch)      shift; TARGET_ARCH="${1:?--target-arch requires a value}" ;;
        -n|--dry-run)       DRY_RUN=1 ;;
        -h|--help)          usage; exit 0 ;;
        *)
            printf 'error: unknown option: %s\n' "$1" >&2
            usage >&2
            exit 1
            ;;
    esac
    shift
done

case "$RUNTIME_REQ" in
    auto|docker|podman) ;;
    *)
        printf 'error: invalid --runtime "%s" (expected auto|docker|podman)\n' "$RUNTIME_REQ" >&2
        exit 1
        ;;
esac

# Validate port and DB name
case "$PORT" in
    ''|*[!0-9]*)
        printf 'error: invalid --port "%s" (must be numeric)\n' "$PORT" >&2
        exit 1
        ;;
esac

case "$DB_NAME" in
    ''|*[!A-Za-z0-9_]*)
        printf 'error: invalid --db-name "%s" (alphanumeric and underscore only)\n' "$DB_NAME" >&2
        exit 1
        ;;
esac

HOST_OS="$(normalize_os "$(uname -s)")"
HOST_ARCH="$(normalize_arch "$(uname -m)")"
EFF_OS="${TARGET_OS:+$(normalize_os "$TARGET_OS")}"
EFF_OS="${EFF_OS:-$HOST_OS}"
EFF_ARCH="${TARGET_ARCH:+$(normalize_arch "$TARGET_ARCH")}"
EFF_ARCH="${EFF_ARCH:-$HOST_ARCH}"

# Auto-resolve schema/db2_memory.sql
if [ -z "$SCHEMA_PATH" ]; then
    REPO_PARENT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
    if [ -f "${REPO_PARENT}/schema/db2_memory.sql" ]; then
        SCHEMA_PATH="${REPO_PARENT}/schema/db2_memory.sql"
    elif [ -f "${PREFIX}/schema/db2_memory.sql" ]; then
        SCHEMA_PATH="${PREFIX}/schema/db2_memory.sql"
    else
        SCHEMA_PATH="${PREFIX}/schema/db2_memory.sql"
    fi
fi

# ppc64le cannot run linux/amd64 Db2 Community container natively; provide clear remote DSN guidance
if [ "$EFF_ARCH" = "ppc64le" ]; then
    cat <<EOF
IBM Db2 Community Edition container (${IMAGE}) is published for linux/amd64
and is not available as a native linux/ppc64le image.

To connect NeoPerl::MT on ppc64le to a remote IBM Db2 server:
  1. Apply the schema on the target Db2 host:
       db2 connect to ${DB_NAME}
       db2 -tvf ${SCHEMA_PATH}
  2. Configure an ODBC DSN [NEOPERL_MEM] in ${CONFIG_DIR}/odbc.ini:
       [NEOPERL_MEM]
       Driver      = IBM DB2 ODBC DRIVER
       Database    = ${DB_NAME}
       Hostname    = <db2-host>
       Port        = ${PORT}
       Protocol    = TCPIP
       UID         = <db2-user>
  3. Export the DSN environment variables before launching npl:
       export ODBCINI="${CONFIG_DIR}/odbc.ini"
       export NEOPERL_DB2_DSN="dbi:ODBC:NEOPERL_MEM"
       npl --db2-dsn="\$NEOPERL_DB2_DSN"
EOF
    exit 0
fi

# Platform flag and emulation guidance
PLATFORM_FLAG=""
PLATFORM_NOTE="native linux/amd64"
if [ "$EFF_OS" = "darwin" ] && [ "$EFF_ARCH" = "arm64" ]; then
    PLATFORM_FLAG="--platform linux/amd64"
    PLATFORM_NOTE="linux/amd64 emulation (requires Docker Desktop, OrbStack, or Colima with Rosetta)"
elif [ "$EFF_ARCH" = "arm64" ]; then
    PLATFORM_FLAG="--platform linux/amd64"
    PLATFORM_NOTE="linux/amd64 emulation (requires QEMU binfmt or remote Db2 DSN)"
fi

# Detect container runtime
RUNTIME_BIN=""
if [ "$RUNTIME_REQ" = "auto" ]; then
    if command -v docker >/dev/null 2>&1; then
        RUNTIME_BIN="docker"
    elif command -v podman >/dev/null 2>&1; then
        RUNTIME_BIN="podman"
    fi
else
    if command -v "$RUNTIME_REQ" >/dev/null 2>&1; then
        RUNTIME_BIN="$RUNTIME_REQ"
    fi
fi

if [ "$DRY_RUN" -eq 1 ]; then
    DRY_RT="${RUNTIME_BIN:-docker}"
    if [ "$RUNTIME_REQ" != "auto" ]; then
        DRY_RT="$RUNTIME_REQ"
    fi
    printf '[dry-run] IBM Db2 Community container setup plan:\n'
    printf '  Target:          %s/%s (%s)\n' "$EFF_OS" "$EFF_ARCH" "$PLATFORM_NOTE"
    printf '  Runtime:         %s (requested=%s)\n' "$DRY_RT" "$RUNTIME_REQ"
    printf '  Image:           %s\n' "$IMAGE"
    printf '  Container:       %s (port 127.0.0.1:%s -> 50000)\n' "$CONTAINER_NAME" "$PORT"
    printf '  Database:        %s\n' "$DB_NAME"
    printf '  Volume:          %s:/database\n' "$VOLUME_NAME"
    printf '  Schema:          %s\n' "$SCHEMA_PATH"
    if [ -n "$DB2_PASSWORD" ]; then
        printf '  Password:        <provided>\n'
    else
        printf '  Password:        <random 20-char via openssl rand>\n'
    fi
    if [ -n "$PLATFORM_FLAG" ]; then
        printf '  Run command:     %s run -d %s --name %s --privileged=true -p 127.0.0.1:%s:50000 -e LICENSE=accept -e DB2INST1_PASSWORD=<generated> -e DBNAME=%s -v %s:/database %s\n' \
            "$DRY_RT" "$PLATFORM_FLAG" "$CONTAINER_NAME" "$PORT" "$DB_NAME" "$VOLUME_NAME" "$IMAGE"
    else
        printf '  Run command:     %s run -d --name %s --privileged=true -p 127.0.0.1:%s:50000 -e LICENSE=accept -e DB2INST1_PASSWORD=<generated> -e DBNAME=%s -v %s:/database %s\n' \
            "$DRY_RT" "$CONTAINER_NAME" "$PORT" "$DB_NAME" "$VOLUME_NAME" "$IMAGE"
    fi
    printf '  Schema apply:    %s cp %s %s:/tmp/db2_memory.sql && %s exec %s su - db2inst1 -c "db2 connect to %s && db2 -tvf /tmp/db2_memory.sql && db2 terminate"\n' \
        "$DRY_RT" "$SCHEMA_PATH" "$CONTAINER_NAME" "$DRY_RT" "$CONTAINER_NAME" "$DB_NAME"
    printf '  Env file:        %s/db2.env (mode 0600)\n' "$CONFIG_DIR"
    printf '  ODBC template:   %s/odbc.ini ([NEOPERL_MEM], mode 0600)\n' "$CONFIG_DIR"
    printf '  Control script:  %s/bin/npl-db2-ctl (start|stop|status|logs|shell|apply-schema)\n' "$PREFIX"
    exit 0
fi

# Live execution checks
if [ -z "$RUNTIME_BIN" ]; then
    printf 'error: neither docker nor podman found in PATH (requested: %s)\n' "$RUNTIME_REQ" >&2
    exit 1
fi

if ! "$RUNTIME_BIN" info >/dev/null 2>&1; then
    printf 'error: %s daemon is not running; start %s and retry\n' "$RUNTIME_BIN" "$RUNTIME_BIN" >&2
    if [ "$EFF_OS" = "darwin" ] && [ "$EFF_ARCH" = "arm64" ]; then
        printf 'note: on macOS arm64, ensure Docker Desktop, OrbStack, or Colima has Rosetta amd64 emulation enabled\n' >&2
    fi
    exit 1
fi

if [ ! -f "$SCHEMA_PATH" ]; then
    printf 'error: Db2 schema file not found at %s (pass --schema=PATH)\n' "$SCHEMA_PATH" >&2
    exit 1
fi

if [ -z "$DB2_PASSWORD" ]; then
    DB2_PASSWORD="$(generate_password)"
fi

if [ "$EFF_OS" = "darwin" ] && [ "$EFF_ARCH" = "arm64" ]; then
    printf 'Note: starting %s with %s (%s)\n' "$IMAGE" "$PLATFORM_FLAG" "$PLATFORM_NOTE"
fi

# Check if container already exists
if "$RUNTIME_BIN" ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"; then
    if "$RUNTIME_BIN" ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"; then
        printf 'Container %s is already running.\n' "$CONTAINER_NAME"
    else
        printf 'Starting existing container %s...\n' "$CONTAINER_NAME"
        "$RUNTIME_BIN" start "$CONTAINER_NAME"
    fi
else
    printf 'Starting IBM Db2 Community container %s (%s)...\n' "$CONTAINER_NAME" "$IMAGE"
    if [ -n "$PLATFORM_FLAG" ]; then
        # shellcheck disable=SC2086
        "$RUNTIME_BIN" run -d \
            $PLATFORM_FLAG \
            --name "$CONTAINER_NAME" \
            --privileged=true \
            -p "127.0.0.1:${PORT}:50000" \
            -e LICENSE=accept \
            -e "DB2INST1_PASSWORD=${DB2_PASSWORD}" \
            -e "DBNAME=${DB_NAME}" \
            -v "${VOLUME_NAME}:/database" \
            "$IMAGE"
    else
        "$RUNTIME_BIN" run -d \
            --name "$CONTAINER_NAME" \
            --privileged=true \
            -p "127.0.0.1:${PORT}:50000" \
            -e LICENSE=accept \
            -e "DB2INST1_PASSWORD=${DB2_PASSWORD}" \
            -e "DBNAME=${DB_NAME}" \
            -v "${VOLUME_NAME}:/database" \
            "$IMAGE"
    fi
fi

# Wait for Db2 database readiness (cold init can take several minutes)
printf 'Waiting for Db2 database %s to accept connections...\n' "$DB_NAME"
READY=0
ATTEMPT=0
MAX_ATTEMPTS=120
while [ "$ATTEMPT" -lt "$MAX_ATTEMPTS" ]; do
    if "$RUNTIME_BIN" exec "$CONTAINER_NAME" su - db2inst1 -c "db2 connect to ${DB_NAME} >/dev/null 2>&1 && db2 terminate >/dev/null 2>&1" >/dev/null 2>&1; then
        READY=1
        break
    fi
    ATTEMPT=$(( ATTEMPT + 1 ))
    sleep 5
done

if [ "$READY" -ne 1 ]; then
    printf 'error: timed out waiting for Db2 database %s; check logs with: %s logs %s\n' \
        "$DB_NAME" "$RUNTIME_BIN" "$CONTAINER_NAME" >&2
    exit 1
fi

printf 'Applying schema %s to %s...\n' "$SCHEMA_PATH" "$DB_NAME"
"$RUNTIME_BIN" cp "$SCHEMA_PATH" "${CONTAINER_NAME}:/tmp/db2_memory.sql"
"$RUNTIME_BIN" exec "$CONTAINER_NAME" su - db2inst1 -c \
    "db2 connect to ${DB_NAME} && db2 -tvf /tmp/db2_memory.sql && db2 terminate"

# Write ~/.config/neoperl/db2.env (mode 0600) and odbc.ini (mode 0600)
mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"

SAFE_PASS="$(printf '%s' "$DB2_PASSWORD" | sed "s/'/'\\\\''/g")"
ENV_FILE="${CONFIG_DIR}/db2.env"
ODBC_FILE="${CONFIG_DIR}/odbc.ini"

umask 077
cat > "$ENV_FILE" <<EOF
# NeoPerl::MT local IBM Db2 environment
# Generated by setup-db2-container.sh
export NEOPERL_DB2_HOST='127.0.0.1'
export NEOPERL_DB2_PORT='${PORT}'
export NEOPERL_DB2_DATABASE='${DB_NAME}'
export NEOPERL_DB2_USER='db2inst1'
export NEOPERL_DB2_PASSWORD='${SAFE_PASS}'
export ODBCINI='${ODBC_FILE}'
export NEOPERL_DB2_DSN='dbi:ODBC:NEOPERL_MEM'
EOF
chmod 600 "$ENV_FILE"

cat > "$ODBC_FILE" <<EOF
[NEOPERL_MEM]
Description = NeoPerl::MT Semantic Memory Store (local IBM Db2)
Driver      = IBM DB2 ODBC DRIVER
Database    = ${DB_NAME}
Hostname    = 127.0.0.1
Port        = ${PORT}
Protocol    = TCPIP
UID         = db2inst1
PWD         = ${DB2_PASSWORD}
EOF
chmod 600 "$ODBC_FILE"

# Write $PREFIX/bin/npl-db2-ctl helper
mkdir -p "${PREFIX}/bin"
CTL_PATH="${PREFIX}/bin/npl-db2-ctl"
SAFE_SCHEMA="$(printf '%s' "$SCHEMA_PATH" | sed "s/'/'\\\\''/g")"
umask 022
cat > "$CTL_PATH" <<EOF
#!/bin/sh
# npl-db2-ctl - Manage the local NeoPerl::MT IBM Db2 container
# Author: stratum42

set -e

RUNTIME='${RUNTIME_BIN}'
CONTAINER='${CONTAINER_NAME}'
DB_NAME='${DB_NAME}'
SCHEMA_PATH='${SAFE_SCHEMA}'

case "\${1:-status}" in
    start)
        exec "\$RUNTIME" start "\$CONTAINER"
        ;;
    stop)
        exec "\$RUNTIME" stop "\$CONTAINER"
        ;;
    status)
        exec "\$RUNTIME" ps -a --filter "name=^\${CONTAINER}\$"
        ;;
    logs)
        shift || true
        exec "\$RUNTIME" logs "\$@" "\$CONTAINER"
        ;;
    shell)
        exec "\$RUNTIME" exec -it "\$CONTAINER" su - db2inst1
        ;;
    apply-schema)
        if [ ! -f "\$SCHEMA_PATH" ]; then
            printf 'error: schema not found at %s\n' "\$SCHEMA_PATH" >&2
            exit 1
        fi
        "\$RUNTIME" cp "\$SCHEMA_PATH" "\${CONTAINER}:/tmp/db2_memory.sql"
        exec "\$RUNTIME" exec "\$CONTAINER" su - db2inst1 -c \
            "db2 connect to \${DB_NAME} && db2 -tvf /tmp/db2_memory.sql && db2 terminate"
        ;;
    *)
        printf 'Usage: npl-db2-ctl {start|stop|status|logs|shell|apply-schema}\n' >&2
        exit 1
        ;;
esac
EOF
chmod 755 "$CTL_PATH"

printf 'Db2 container %s is ready.\n' "$CONTAINER_NAME"
printf '  Env file:       %s (mode 0600)\n' "$ENV_FILE"
printf '  ODBC config:    %s (mode 0600)\n' "$ODBC_FILE"
printf '  Control helper: %s\n' "$CTL_PATH"
printf 'Load credentials with: . "%s"\n' "$ENV_FILE"
