#!/bin/bash
# Creates a source archive, builds the binary, creates the DEB scripts and packages the DEB.

# Get the folder of this build.sh script, which should be the core place we do
# all this work even if we're run from a different location.
MAIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMESTAMP=$(date +"%Y-%m-%d-%H-%M-%S")

die() {
    echo >&2 "$@"
    exit 1
}

# Ensure version.go exists
version_file="$MAIN_DIR/version.go"
if [[ ! -f "$version_file" ]]; then
  echo "Error: version file not found at '$version_file'." >&2
  exit 1
fi

# Parse constants from version.go
NAME=$(grep -E '^const[[:space:]]+NAME[[:space:]]*=' "$version_file" | sed -E 's/.*"([^"]+)".*/\1/')
VERSION=$(grep -E '^const[[:space:]]+VERSION[[:space:]]*=' "$version_file" | sed -E 's/.*"([^"]+)".*/\1/')
ROOT=$(grep -E '^const[[:space:]]+ROOT[[:space:]]*=' "$version_file" | sed -E 's/.*"([^"]+)".*/\1/')
SOURCES=$(grep -E '^const[[:space:]]+SOURCES[[:space:]]*=' "$version_file" | sed -E 's/.*"([^"]+)".*/\1/')
PORT=$(awk '/^const[[:space:]]+PORT[[:space:]]*=/{print $NF}' "$version_file")
HEALTH_PORT=$(awk '/^const[[:space:]]+HEALTH_PORT[[:space:]]*=/{print $NF}' "$version_file")
# Dependencies can be empty.
DEPENDENCIES=$(grep -E '^const[[:space:]]+DEPENDENCIES[[:space:]]*=' "$version_file" | sed -E 's/.*"([^"]*)".*/\1/')

if [[ -z "$NAME" || -z "$VERSION" || -z "$SOURCES" || -z "$PORT" || -z "$HEALTH_PORT" ]]; then
  echo "Error: necessary contants missing from version.go '$version_file'." >&2
  exit 1
fi

if [[ "$NAME" == *"_"* ]]; then
  echo "Error: NAME ('$NAME') contains an underscore (_), which against deb package requirements. Note, the code folder should use "_" per golang requirements." >&2
  exit 1
fi

ARCHITECTURE="all" # because we support multiple architectures in one package
MAINTAINER="user <user@gmail.com>"
DESCRIPTION="Runs the appropriate binary for ${NAME} based on system architecture."

# user/group to run this binary on the server.
USER="${NAME}"

# First build the source archive
if [[ "$ROOT" != /* ]]; then
  # ROOT is relative, make it an absolute path first
  ROOT="$(realpath "${MAIN_DIR}/${ROOT}")"
fi

# Get the relative path of MAIN_DIR from ROOT prefix
REL_MAIN_DIR="${MAIN_DIR#$ROOT}"

# Remove leading slash if it exists
REL_MAIN_DIR="${REL_MAIN_DIR#/}"

echo "Parsed:"
echo "  NAME    = $NAME"
echo "  VERSION = $VERSION"
echo "  SOURCES = $SOURCES"
echo "  PORT = \'$PORT\'"
echo "  HEALTH_PORT = \'$HEALTH_PORT\'"
echo "  ROOT    = $ROOT"
echo "  MAIN_DIR = $MAIN_DIR"
echo "  REL_MAIN_DIR = $REL_MAIN_DIR"

BUILD_DIR="${MAIN_DIR?}/build"
echo "Cleaning up $BUILD_DIR/*"
rm -rf "$BUILD_DIR/"
mkdir -p "$BUILD_DIR"
mkdir -p "$$BUILD_DIR/opt/${NAME}/bin"
mkdir -p "$BUILD_DIR/etc/systemd/system"
mkdir -p "$BUILD_DIR/DEBIAN"


ARCHIVE_NAME="${NAME}-${VERSION}-${TIMESTAMP}.tgz"
DEB_NAME="${NAME}_${VERSION}.deb"


# Step 1: Archive the select group of source files recursively
# ###############################
echo "Packaging .go files into $ARCHIVE_NAME..."
# First, build the list of files to include
mkdir -p "${BUILD_DIR}/opt/${NAME}/src"
INCLUDE_LIST="${BUILD_DIR}/opt/${NAME}/src/include.list"

# Define exclusions here
EXCLUDES=(
  "./_todelete"
  "*/_todelete/*"
  "*/secrets.go"
  "*/build/*"
  "*.deb"
  "*.tmp"
  "*.log"
  "*.bak"
  "*/static/images/*"
  "*/static/media/*"
  "*/static/audio/*"
  "*.swp"
  "*.DS_Store"
  "*/go.work.sum"
  "*/go.work"
)

# Build the `find` exclusion expression dynamically
EXPR=()
for e in "${EXCLUDES[@]}"; do
  EXPR+=( -path "$e" -o )
done
# remove trailing -o
unset 'EXPR[${#EXPR[@]}-1]'

PREV_PWD="$(pwd)"
cd "${ROOT}"

# Run find with pruning and exclusions
echo "Building include list (with exclusions)..."
for path in $SOURCES; do
  echo "  - Adding files from ${ROOT}/$path to $INCLUDE_LIST..."
  if [[ ! -e "$path" ]]; then
    echo "Error: Source path '$path' does not exist." >&2
    exit 1
  fi
  find $path \( "${EXPR[@]}" \) -prune -o -type f -print >> "$INCLUDE_LIST"
done

# Add go mod files if found in the 1st level of this folder.
find . -maxdepth 1 \( "${EXPR[@]}" \) -prune -o -type f -name "go.*" -print >> "$INCLUDE_LIST"

# Finally, create the archive using the list of files generated above.
mkdir -p "${BUILD_DIR}/opt/${NAME}/src"
tar -czf "${BUILD_DIR}/opt/${NAME}/src/${ARCHIVE_NAME}" -T "$INCLUDE_LIST"

# Create a data directory for the job to write to. (OPTIONAL)
mkdir -p "${BUILD_DIR}/opt/${NAME}/data"
touch "${BUILD_DIR}/opt/${NAME}/data/.storage"

# TODO copy over any static files/certs.
# mkdir -p "${BUILD_DIR}/opt/${NAME}/www"
# cp -r "${MAIN_DIR}/cert" "${BUILD_DIR}/opt/${NAME}/cert"

# Build the golang service binaries for arm64 and amd64.
cd "${SCRIPT_DIR}"
env GOARCH=arm64 go build -o "$BUILD_DIR/opt/${NAME}/bin/${NAME}-arm64" $MAIN_DIR || die "Unable to create"
env GOARCH=amd64 go build -o "$BUILD_DIR/opt/${NAME}/bin/${NAME}-amd64" $MAIN_DIR

# Create runtime wrapper systemd calls which chooses which architecture binary to use.
cat > "$BUILD_DIR/opt/${NAME}/bin/${NAME}" << EOF
#!/bin/bash
VIP=\$(ip -o -4 addr show | awk '{print \$4}' | grep -oE '10\.100\.[0-9]+\.[0-9]+' | head -n 1)
EIP=\$(ip route get 8.8.8.8 | awk '/src/ {print \$7}')

# Make edits here to add other arguments for your job.
ARCH=\$(uname -m)
if [[ "\$ARCH" == "x86_64" ]]; then
    exec /opt/${NAME}/bin/${NAME}-amd64 --ip="" --port=$PORT --health_port=$HEALTH_PORT

elif [[ "\$ARCH" == "aarch64" ]]; then
    exec /opt/${NAME}/bin/${NAME}-arm64 --ip="" --port=$PORT --health_port=$HEALTH_PORT
else
    echo "Unsupported architecture: \$ARCH"
    exit 1
fi
EOF
chmod +x "$BUILD_DIR/opt/${NAME}/bin/${NAME}"

# Create systemd service config
cat > "$BUILD_DIR/etc/systemd/system/${NAME}.service" << EOF
[Unit]
Description=${NAME} Serving Service
After=network.target

[Service]
ExecStart=/opt/${NAME}/bin/${NAME}
Restart=on-failure
# This requires the golang binary to use coreos/go-systemd/daemon to ping systemd.
WatchdogSec=30s
Environment="XDG_CONFIG_HOME=/tmp/.chromium"
Environment="XDG_CACHE_HOME=/tmp/.chromium"
# Set RestartSec to avoid rapid restart loops
RestartSec=5s

# Uncomment to allow running on privileged ports as a standard user.
#AmbientCapabilities=CAP_NET_BIND_SERVICE
#CapabilityBoundingSet=CAP_NET_BIND_SERVICE
#NoNewPrivileges=no

# Add StartLimitBurst and StartLimitIntervalSec to control restart frequency
StartLimitBurst=3

# Set WorkingDirectory if your binary expects to run in a specific folder
WorkingDirectory=/opt/${NAME}

# Add TimeoutStartSec and TimeoutStopSec to prevent hangs during start/stop
TimeoutStartSec=30
TimeoutStopSec=30

# Consider adding resource limits for stability/security.
LimitNOFILE=65536
LimitNPROC=512

User=${USER}
Group=${USER}
# Drop capabilities or limit permissions if root is not required.
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=yes

StandardOutput=append:/var/log/${NAME}.log
StandardError=append:/var/log/${NAME}.log

[Install]
WantedBy=multi-user.target
EOF

# Create the logrotate configuration
mkdir -p "${BUILD_DIR}/etc/logrotate.d"
cat > "${BUILD_DIR}/etc/logrotate.d/${NAME}" << EOF
/var/log/${NAME}.log {
    daily
    rotate 7
    compress
    missingok
    notifempty
    copytruncate
}
EOF

# runs after install or upgrade
cat > "${BUILD_DIR}/DEBIAN/postinst" << EOF
#!/bin/bash
set -e

PORT=${PORT:-8080}
HEALTH_PORT=${HEALTH_PORT:-8081}

echo "Using Ports: \$PORT, \$HEALTH_PORT"

# Add UFW rule
if command -v ufw >/dev/null 2>&1; then
    echo "Allowing ${NAME} service through UFW..."
    ufw allow \$PORT/tcp comment "${NAME} service"
    ufw allow \$PORT/tcp comment "${NAME} service"
    ufw reload
fi

# Create system group if it doesn't exist, we do this because we want a consistent GID.
if ! getent group "$NAME" >/dev/null; then
    groupadd -g $PORT "$USER"
fi
# Create system user if it doesn't exist
if ! id -u "${USER}" >/dev/null 2>&1; then
    echo "Creating system user '${USER}'..."
    useradd -u $PORT -g $PORT --system --shell /usr/sbin/nologin --home /opt/${USER}/data "${USER}"
fi
mkdir -p /home/${USER}
chown -R "${USER}:${USER}" /home/${USER}
chmod -R 775 /home/${USER}

# Set ownership of service files and directories
chown -R root:root /opt/${NAME}
chown -R "${USER}:${USER}" /opt/${NAME}/data

# Uncomment to allow the binary to run on priviledged ports:
#setcap 'cap_net_bind_service=+ep' /opt/${NAME}/bin/${NAME}-arm64
#setcap 'cap_net_bind_service=+ep' /opt/${NAME}/bin/${NAME}-amd64

# Enable and start the service
systemctl daemon-reload
systemctl enable ${NAME}.service
systemctl start ${NAME}.service

# Wait up to N seconds for the service to be active
TIMEOUT=30
INTERVAL=1
elapsed=0

check_healthy() {
    echo "Checking health on all local IPs (including localhost)..."

    # Get all non-loopback IPv4 addresses
    ips=\$(hostname -I 2>/dev/null | tr ' ' '\n')
    ips="\${ips}
127.0.0.1
::1"

    for ip in \$ips; do
        echo "→ Trying http://\$ip:\${HEALTH_PORT}/healthz"
        if curl -sf --connect-timeout 2 --max-time 5 "http://[\$ip]:\${HEALTH_PORT}/healthz" >/dev/null 2>&1 ||
           curl -sf --connect-timeout 2 --max-time 5 "http://\$ip:\${HEALTH_PORT}/healthz" >/dev/null 2>&1; then
            echo "✓ Healthy on \$ip"
            return 0
        fi
    done

    echo "✗ No healthy response on any interface"
    return 1
}

echo "Waiting up to \${TIMEOUT} seconds for ${NAME} service to send watchdog ping..."
while true; do
    if check_healthy; then
        echo "$NAME is fully healthy after \${elapsed}s ✅"
        break
    fi

    if [[ "\$ACTIVE" == "failed" || "\$elapsed" -ge "\$TIMEOUT" ]]; then
        echo "$NAME failed to become healthy after \${elapsed}s ❌"
        exit 1
    fi

    sleep "\$INTERVAL"
    elapsed=\$((elapsed + INTERVAL))
done

exit 0
EOF
chmod 755 ${BUILD_DIR}/DEBIAN/postinst

# runs before removal or upgrade
cat > "${BUILD_DIR}/DEBIAN/prerm" << EOF
#!/bin/bash
set -e

# Stop and disable the service
systemctl disable ${NAME}.service
systemctl stop ${NAME}.service
systemctl daemon-reload

# The argument is either "purge" or "remove".
if [ "\$1" = "purge" ]; then
    echo "Package is being purged (full removal)."
    rm -rf "/opt/${NAME}/data/*"
    rm -rf "/home/${NAME}/*"
    rm -rf "/home/${NAME}/.*"
    rm -f "/var/log/${NAME}"
    rm -f "/var/log/${NAME}.log\*"
fi

# Delete system user if it exists
if id -u "${USER}" >/dev/null 2>&1; then
    echo "Removing system user '${USER}'..."
    userdel "${USER}" || true
fi
if getent group "${USER}" >/dev/null; then
      delgroup "${USER}" || true
  fi

# Remove UFW rule before uninstall
if command -v ufw >/dev/null 2>&1; then
    echo "Removing ${NAME} service rule from UFW..."
    ufw delete allow ${PORT}/tcp
    ufw reload
fi

exit 0
EOF
chmod 755 ${BUILD_DIR}/DEBIAN/prerm



# Create control file
cat > "${BUILD_DIR}/DEBIAN/control" << EOF
Package: ${NAME}
Version: ${VERSION}
Section: base
Priority: optional
Depends: ${DEPENDENCIES}
Architecture: ${ARCHITECTURE}
Maintainer: ${MAINTAINER}
Description: ${DESCRIPTION}
EOF


# Build the package
dpkg-deb --build "$BUILD_DIR" "$MAIN_DIR/$DEB_NAME"

echo "Package built: ${NAME}_${VERSION}.deb"
