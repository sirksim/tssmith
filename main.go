package main

import (
	"bufio"
	"database/sql"
	"flag"
	"fmt"
	"log"
	"os"
	"strings"

	_ "github.com/mattn/go-sqlite3"
)

type TableInfo struct {
	cid        int
	name       string
	c_type     string
	notnull    int
	dflt_value *string
	pk         int
}

type Table struct {
	t_type   string
	name     string
	tbl_name string
	rootpage int
	sql      string
	info     []TableInfo
}

func main() {

	out := flag.String("out", "types.d.ts", "Output file")
	flag.Parse()

	if flag.NArg() == 0 {
		log.Fatal("database file not provided")
	}
	file := flag.Arg(0)

	_, err := (os.Stat(file))
	if err != nil || os.IsNotExist(err) {
		log.Fatal(err)
	}

	db, err := sql.Open("sqlite3", file)
	if err != nil {
		log.Fatal("Could not open db: ", err)
	}
	defer db.Close()

	stmt := "SELECT * FROM sqlite_master WHERE name not like 'sqlite%' and type = 'table' OR type='view'"
	rows, err := db.Query(stmt)
	if err != nil {
		log.Fatal("Could not get info of db", err)
	}
	defer rows.Close()

	var tables []Table
	for rows.Next() {
		var table Table
		err = rows.Scan(&table.t_type, &table.name, &table.tbl_name, &table.rootpage, &table.sql)
		if err != nil {
			log.Fatal(err)
		}
		stmt := fmt.Sprintf("PRAGMA table_info(%q)", table.name)
		rows2, err := db.Query(stmt)
		if err != nil {
			log.Fatal(err)
		}
		var info TableInfo
		for rows2.Next() {
			err = rows2.Scan(
				&info.cid, &info.name,
				&info.c_type, &info.notnull,
				&info.dflt_value, &info.pk,
			)
			if err != nil {
				log.Fatal(err)
			}
			table.info = append(table.info, info)
		}
		rows2.Close()
		tables = append(tables, table)
	}

	f, err := os.Create(*out)
	if err != nil {
		log.Fatal(err)
	}
	defer f.Close()
	w := bufio.NewWriter(f)
	for _, table := range tables {
		generateTSType(w, table)
	}
	w.Flush()
}

func generateTSType(w *bufio.Writer, table Table) {

	fmt.Fprintf(w, "type %s = {\n", table.name)
	for _, col := range table.info {
		optinal_char := ""
		pk_comment := ""
		if col.notnull == 0 && col.pk == 0 {
			optinal_char = "?"
		}
		if col.pk == 1 {
			pk_comment = (" // PK")
		}
		fmt.Fprintf(w, "%s%s: %s;%s\n", col.name, optinal_char, sqliteTypeToTs(col), pk_comment)
	}
	fmt.Fprint(w, "}\n\n")
}

func sqliteTypeToTs(info TableInfo) string {
	t := strings.ToUpper(info.c_type)

	switch {
	case strings.Contains(t, "INT"):
		return "number"
	case strings.Contains(t, "REAL") ||
		strings.Contains(t, "FLOA") ||
		strings.Contains(t, "DOUB") ||
		strings.Contains(t, "NUMERIC") ||
		strings.Contains(t, "DECIMAL"):
		return "number"
	case strings.Contains(t, "CHAR") ||
		strings.Contains(t, "CLOB") ||
		strings.Contains(t, "TEXT"):
		return "string"
	case strings.Contains(t, "BLOB") || t == "":
		return "Uint8Array"
	case strings.Contains(t, "BOOL"):
		return "boolean"
	case strings.Contains(t, "DATE") || strings.Contains(t, "TIME"):
		return "string"
	default:
		return "string"
	}
}
