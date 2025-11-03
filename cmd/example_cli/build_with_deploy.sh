#!/bin/bash
# Creates a source archive, builds the binary, creates the DEB scripts and packages the DEB.

# Get the folder of this build.sh script, which should be the core place we do
# all this work even if we're run from a different location.
MAIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() {
    echo >&2 "$@"
    exit 1
}

# Use first argument if SERVER is not set
if [[ -z "$SERVER" ]]; then
  if [[ -n "$1" ]]; then
    SERVER="$1"
  else
    echo "Error: SERVER not set. Use either:" >&2
    echo "  $ export SERVER=<fqdn/ip/alias>" >&2
    echo "or:" >&2
    echo "  $ $0 <fqdn/ip/alias>" >&2
    exit 1
  fi
fi

# Ensure version.go exists
VERSION_FILE="${MAIN_DIR?}/version.go"
if [[ ! -f "$VERSION_FILE" ]]; then
  echo "Error: version file not found at '${VERSION_FILE}'." >&2
  exit 1
fi


# Parse constants from version.go
NAME=$(grep -E '^const[[:space:]]+NAME[[:space:]]*=' "${VERSION_FILE}" | sed -E 's/.*"([^"]+)".*/\1/')
VERSION=$(grep -E '^const[[:space:]]+VERSION[[:space:]]*=' "${VERSION_FILE}" | sed -E 's/.*"([^"]+)".*/\1/')
if [[ -z "$NAME" || -z "$VERSION" ]]; then
  echo "Error: necessary contants missing from version.go '${VERSION_FILE}'." >&2
  exit 1
fi

${MAIN_DIR}/build.sh || die "Failed to build"

# Localhost we treat special - no need to ssh.
if [[ ${SERVER} == "localhost" ]]; then
  sudo safe-dpkg ${MAIN_DIR}/${NAME}_${VERSION}.deb || die "Failed to install DEB on localhost"
  exit 0
fi

scp -r ${MAIN_DIR}/${NAME}_${VERSION}.deb ${SERVER}: || die "Failed to copy DEB to ${SERVER}"
ssh ${SERVER} "sudo bash -c \"safe-dpkg ${NAME}_${VERSION}.deb\"" || die "Failed to install DEB on ${SERVER}"

