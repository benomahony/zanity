package hazards

import (
	"crypto/md5"
	"crypto/tls"
	"database/sql"
	"fmt"
)

func flagged(db *sql.DB, name string, x int, apiToken string) {
	fmt.Println("using", apiToken)
	switch x {
	case 1:
		fmt.Println("one")
	}
	_ = &tls.Config{InsecureSkipVerify: true}
	md5.Sum([]byte(name))
	db.Query("SELECT * FROM t WHERE n = '" + name + "'")
}

func quiet(db *sql.DB, name string, x int, token string) {
	fmt.Println("parsed", token)
	switch x {
	case 1:
		fmt.Println("one")
	default:
		fmt.Println("other")
	}
	_ = &tls.Config{MinVersion: tls.VersionTLS12}
	db.Query("SELECT * FROM t WHERE n = $1", name)
}
