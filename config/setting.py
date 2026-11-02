from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent.parent

DATA_DIR = BASE_DIR / "data"
RAW_DATA_DIR = DATA_DIR / "raw"
PROCESSED_DATA_DIR = DATA_DIR / "processed"
MARTS_DB = PROCESSED_DATA_DIR / "marts.duckdb"

SQL_DIR = BASE_DIR / "src"

ENV_FILE = BASE_DIR / ".env"
