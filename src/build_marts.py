import duckdb

from config.setting import BASE_DIR, MARTS_DB, PROCESSED_DATA_DIR, SQL_DIR

SQL_SCRIPTS = ["cleaning.sql", "models.sql", "indicators.sql"]


def run_scripts(con: duckdb.DuckDBPyConnection) -> None:
    for script in SQL_SCRIPTS:
        con.execute((SQL_DIR / script).read_text(encoding="utf-8"))


def export_marts(con: duckdb.DuckDBPyConnection) -> list[str]:
    marts = [
        row[0]
        for row in con.execute(
            "SELECT table_name FROM duckdb_tables() "
            "WHERE database_name = 'memory' AND table_name LIKE 'mart\\_%' ESCAPE '\\' "
            "ORDER BY table_name"
        ).fetchall()
    ]

    MARTS_DB.unlink(missing_ok=True)
    # Format de stockage lisible par le DuckDB embarqué dans Evidence
    con.execute(f"ATTACH '{MARTS_DB}' AS marts (STORAGE_VERSION 'v1.0.0')")
    for mart in marts:
        con.execute(f"CREATE TABLE marts.{mart} AS SELECT * FROM memory.{mart}")
    con.execute("DETACH marts")

    return marts


def main() -> None:
    PROCESSED_DATA_DIR.mkdir(parents=True, exist_ok=True)

    # Les chemins des scripts SQL (data/raw) sont relatifs à la racine du dépôt
    with duckdb.connect(":memory:") as con:
        con.execute(f"SET file_search_path = '{BASE_DIR}'")
        run_scripts(con)
        marts = export_marts(con)

    print(f"{len(marts)} tables mart_* exportées dans {MARTS_DB}")


if __name__ == "__main__":
    main()
