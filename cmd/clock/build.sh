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

if [[ -z "$NAME" || -z "$VERSION" || -z "$SOURCES" || -z "$PORT" || -z "$HEALTH_PORT" ]]; then
  echo "Error: necessary contants missing from version.go '$version_file'." >&2
  exit 1
fi

ARCHITECTURE="all" # because we support multiple architectures in one package
MAINTAINER="user <user@gmail.com>"
DESCRIPTION="Runs the appropriate binary for ${NAME} based on system architecture."

# user/group to run this binary on the server.
USER="${NAME}"

if [[ -z "$NAME" || -z "$VERSION" ]]; then
  echo "Error: could not parse NAME, VERSION from '$version_file'." >&2
  exit 1
fi

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

# Add .go files recursively but prune those in _todelete
PREV_PWD="$(pwd)"
cd "${ROOT}"
for path in $SOURCES; do
  if [[ -e "$path" ]]; then
    echo "  - Adding files from ${ROOT}/$path to $INCLUDE_LIST..."
    find $path -type d -name "_todelete" -prune -o -type f -name "*.go" -print >> "$INCLUDE_LIST"
    find $path -type d -name "_todelete" -prune -o -type f -name "*.sh" -print >> "$INCLUDE_LIST"
    find $path -type d -name "_todelete" -prune -o -type f -name "*.py" -print >> "$INCLUDE_LIST"
    find $path -type d -name "_todelete" -prune -o -type f -name "*.js" -print >> "$INCLUDE_LIST"
    find $path -type d -name "_todelete" -prune -o -type f -name "*.css" -print >> "$INCLUDE_LIST"
    find $path -type d -name "_todelete" -prune -o -type f -name "*.proto" -print >> "$INCLUDE_LIST"
    # Add readme.md files.
    find $path -type d -name "_todelete" -prune -o -type f -iname "readme.md" -print >> "$INCLUDE_LIST"
    # Add go mod files if found in the 1st level of this folder.
    find $path -maxdepth 1 -type f -name "go.*" >> "$INCLUDE_LIST"

  else
    echo "Warning: $path not found" >&2
  fi
done

# Finally, create the archive using the list of files generated above.
mkdir -p "${BUILD_DIR}/opt/${NAME}/src"
tar -czf "${BUILD_DIR}/opt/${NAME}/src/${ARCHIVE_NAME}" -T "$INCLUDE_LIST"

# Create a data directory for the job to write to. (OPTIONAL)
mkdir -p "${BUILD_DIR}/opt/${NAME}/data"
touch "${BUILD_DIR}/opt/${NAME}/data/.storage"

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

# Create system user if it doesn't exist
if ! id -u "${USER}" >/dev/null 2>&1; then
    echo "Creating system user '${USER}'..."
    useradd --system --shell /usr/sbin/nologin --home /opt/${USER}/data "${USER}"
fi
mkdir -p /home/${USER}
chown -R "${USER}:${USER}" /home/${USER}
chmod -R 775 /home/${USER}

# Set ownership of service files and directories
chown -R root:root /opt/${NAME}
chown -R "${USER}:${USER}" /opt/${NAME}/data

# Enable and start the service
systemctl daemon-reload
systemctl enable ${NAME}.service
systemctl start ${NAME}.service

# Wait up to N seconds for the service to be active
TIMEOUT=30
INTERVAL=1
elapsed=0

check_healthy() {
    echo "curl http://localhost:\${HEALTH_PORT}/healthz"
    curl -sf --connect-timeout 2 --max-time 5 http://localhost:\${HEALTH_PORT}/healthz >/dev/null
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
    rm -rf "/home/${NAME}/*
    rm -rf "/home/${NAME}/.*
    rm -f "/var/log/${NAME}"
    rm -f "/var/log/${NAME}.log\*"
fi

# Delete system user if it exists
if id -u "${USER}" >/dev/null 2>&1; then
    echo "Removing system user '${USER}'..."
    userdel "${USER}" || true
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
Depends: chromium | chromium-browser | google-chrome-stable
Architecture: ${ARCHITECTURE}
Maintainer: ${MAINTAINER}
Description: ${DESCRIPTION}
EOF


# Build the package
dpkg-deb --build "$BUILD_DIR" "$MAIN_DIR/$DEB_NAME"

echo "Package built: ${NAME}_${VERSION}.deb"
