package main

import (
	"log"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"testing"
)

func TestConfigSanity(t *testing.T) {
	// 1️⃣ Check that name is non-empty
	if NAME == "" {
		t.Error("name must not be empty")
	}

	// 2️⃣ Check that VERSION matches x.y.z
	versionPattern := regexp.MustCompile(`^\d+\.\d+\.\d+$`)
	if !versionPattern.MatchString(VERSION) {
		t.Errorf("VERSION must be in format x.y.z, got %q", VERSION)
	}

	// 3️⃣ Check ROOT is set
	if ROOT == "" {
		t.Error("ROOT must be set")
	}

	// 4️⃣ Check that each SOURCE directory exists

	// 4️⃣ Check that each SOURCE directory exists
	_, file, _, ok := runtime.Caller(0) // file = this test file
	if !ok {
		t.Fatal("unable to determine caller file path")
	}

	baseDir := filepath.Dir(file) // directory containing version.go / this test file
	log.Printf("exeDir: %s", baseDir)

	sources := strings.Fields(SOURCES)
	if len(sources) == 0 {
		t.Error("SOURCE must contain at least one directory")
	}

	for _, src := range sources {
		dirPath := filepath.Join(baseDir, ROOT, src)
		info, err := os.Stat(dirPath)
		if err != nil {
			t.Errorf("source directory does not exist: %s", dirPath)
		} else if !info.IsDir() {
			t.Errorf("source path is not a directory: %s", dirPath)
		}
	}
}
