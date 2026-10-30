from pathlib import PurePosixPath

import requests

from config.setting import RAW_DATA_DIR

REPO = "PokeAPI/pokeapi"
BRANCH = "master"
CSV_DIR = "data/v2/csv/"
TREE_URL = f"https://api.github.com/repos/{REPO}/git/trees/{BRANCH}?recursive=1"
RAW_URL = f"https://raw.githubusercontent.com/{REPO}/{BRANCH}"
TIMEOUT = 30


def list_csv_paths(session: requests.Session) -> list[str]:
    response = session.get(TREE_URL, timeout=TIMEOUT)
    response.raise_for_status()
    payload = response.json()

    if payload["truncated"]:
        raise RuntimeError("GitHub a tronqué l'arborescence : liste des CSV incomplète")

    return [
        item["path"]
        for item in payload["tree"]
        if item["type"] == "blob"
        and item["path"].startswith(CSV_DIR)
        and item["path"].endswith(".csv")
    ]


def download_csv(session: requests.Session, path: str) -> None:
    response = session.get(f"{RAW_URL}/{path}", timeout=TIMEOUT)
    response.raise_for_status()
    (RAW_DATA_DIR / PurePosixPath(path).name).write_bytes(response.content)


def main() -> None:
    RAW_DATA_DIR.mkdir(parents=True, exist_ok=True)

    with requests.Session() as session:
        csv_paths = list_csv_paths(session)
        for path in csv_paths:
            download_csv(session, path)

    print(f"{len(csv_paths)} fichiers CSV téléchargés dans {RAW_DATA_DIR}")


if __name__ == "__main__":
    main()
