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
# Dependencies can be empty.
DEPENDENCIES=$(grep -E '^const[[:space:]]+DEPENDENCIES[[:space:]]*=' "$version_file" | sed -E 's/.*"([^"]*)".*/\1/')

if [[ -z "$NAME" || -z "$VERSION" || -z "$SOURCES" ]]; then
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
echo "  ROOT    = $ROOT"
echo "  MAIN_DIR = $MAIN_DIR"
echo "  REL_MAIN_DIR = $REL_MAIN_DIR"

BUILD_DIR="${MAIN_DIR?}/build"
echo "Cleaning up $BUILD_DIR/*"
rm -rf "$BUILD_DIR/"
mkdir -p "$BUILD_DIR"
mkdir -p "$$BUILD_DIR/opt/${NAME}/bin"
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

# Build the golang service binaries for arm64 and amd64.
cd "${SCRIPT_DIR}"
env GOARCH=arm64 go build -o "$BUILD_DIR/opt/${NAME}/bin/${NAME}-arm64" $MAIN_DIR || die "Unable to create"
env GOARCH=amd64 go build -o "$BUILD_DIR/opt/${NAME}/bin/${NAME}-amd64" $MAIN_DIR

# runs after install or upgrade
cat > "${BUILD_DIR}/DEBIAN/postinst" << EOF
#!/bin/bash
set -e

chown -R root:root /opt/${NAME}

ARCH=\$(uname -m)
if [[ "\$ARCH" == "x86_64" ]]; then
    ln -s /opt/${NAME}/bin/${NAME}-amd64 /usr/local/bin/${NAME}

elif [[ "\$ARCH" == "aarch64" ]]; then
    ln -s /opt/${NAME}/bin/${NAME}-arm64 /usr/local/bin/${NAME}
else
    echo "Unsupported architecture: \$ARCH"
    exit 1
fi
chown root:root /usr/local/bin/${NAME}

exit 0
EOF
chmod 755 ${BUILD_DIR}/DEBIAN/postinst

# runs before removal or upgrade
cat > "${BUILD_DIR}/DEBIAN/prerm" << EOF
#!/bin/bash
set -e

rm /usr/local/bin/${NAME}

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
