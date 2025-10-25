package main

// This version file and line is parsed by build scripts, so do not change the formatting or use golang functions.
const NAME = "clock"
const VERSION = "1.0.0"

const PORT = 8082
const HEALTH_PORT = 8083

// This is the root prefix where all SOURCES folders live under.
// WHY? The source archive paths will be relative to this.

const ROOT = "../.."

// SOURCES is a space separated list of folders relative to root level folder (go.mod/go.sum)
// Note: Don't forget to include the main.go folder, it doesn't include anything by default.
const SOURCES = "cmd/clock internal"
