package orders

import (
	"database/sql"
	"testing"
)

func TestSavesOrder(t *testing.T) {
	var db *sql.DB
	var id int
	Save(db, 1)
	if err := db.QueryRow("SELECT id FROM orders").Scan(&id); err != nil || id != 1 {
		t.Fatalf("expected order 1, got %d (%v)", id, err)
	}
}

func TestFindsOrder(t *testing.T) {
	var db *sql.DB
	Save(db, 1)
	if got := Find(db, 1); got != 1 {
		t.Fatalf("expected order 1, got %d", got)
	}
}
