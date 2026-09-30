package tests

import (
	"database/sql"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

func TestReachesOut(t *testing.T) {
	os.Setenv("MODE", "test")
	t.Setenv("LEVEL", "1")
	os.ReadFile("config.json")
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "out.txt"), nil, 0o644)
	os.MkdirTemp("", "x")
	http.Get("https://example.com")
	sql.Open("postgres", "host=db")
	exec.Command("ls")
}

func helper() {
	os.Setenv("MODE", "prod")
	exec.Command("ls")
}
