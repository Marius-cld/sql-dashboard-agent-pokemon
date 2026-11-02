import json
import re

import anthropic
import duckdb
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

from config.setting import BASE_DIR, MARTS_DB

DASHBOARD_DIR = BASE_DIR / "dashboard"
SOURCES_DIR = DASHBOARD_DIR / "sources" / "marts"
GENERATED_DIR = DASHBOARD_DIR / "pages" / "generated"

MODEL = "claude-opus-5-5"
MAX_TURNS = 15
MAX_ROWS = 20

TOOLS = [
    {
        "name": "run_sql",
        "description": "Exécute une requête DuckDB sur les sources `marts.*` et renvoie au plus 20 lignes. "
        "À utiliser pour tester chaque requête avant de l'écrire dans la page.",
        "strict": True,
        "input_schema": {
            "type": "object",
            "properties": {"query": {"type": "string"}},
            "required": ["query"],
            "additionalProperties": False,
        },
    },
    {
        "name": "write_page",
        "description": "Écrit le tableau de bord Evidence (Markdown) dans pages/generated/<slug>.md.",
        "strict": True,
        "input_schema": {
            "type": "object",
            "properties": {
                "slug": {"type": "string", "description": "Nom court en minuscules, chiffres, - ou _"},
                "markdown": {"type": "string"},
            },
            "required": ["slug", "markdown"],
            "additionalProperties": False,
        },
    },
]


def load_sources() -> duckdb.DuckDBPyConnection:
    """Copie chaque source Evidence dans une base en mémoire, sous le schéma `marts`,
    pour que l'agent teste exactement les mêmes noms que ceux utilisés dans les pages."""
    con = duckdb.connect(":memory:")
    con.execute(f"ATTACH '{MARTS_DB}' AS src (READ_ONLY)")
    con.execute("CREATE SCHEMA memory.marts")
    # Les requêtes sources référencent les tables mart_* sans préfixe
    con.execute("USE src")
    for source in sorted(SOURCES_DIR.glob("*.sql")):
        con.execute(f"CREATE TABLE memory.marts.{source.stem} AS {source.read_text()}")
    con.execute("USE memory")
    con.execute("DETACH src")
    return con


def describe_sources(con: duckdb.DuckDBPyConnection) -> str:
    lines = []
    for (table,) in con.execute(
        "SELECT table_name FROM duckdb_tables() WHERE schema_name = 'marts' ORDER BY table_name"
    ).fetchall():
        columns = con.execute(f"DESCRIBE marts.{table}").fetchall()
        lines.append(f"- marts.{table}: " + ", ".join(f"{c[0]} {c[1]}" for c in columns))
    return "\n".join(lines)


def build_system_prompt(con: duckdb.DuckDBPyConnection) -> str:
    example = (DASHBOARD_DIR / "pages" / "index.md").read_text()
    return f"""Tu crées des tableaux de bord Evidence (evidence.dev) sur des données Pokémon, en français.

Sources disponibles (seules tables interrogeables, en SQL DuckDB) :
{describe_sources(con)}

Méthode :
1. Teste chaque requête avec run_sql avant de l'utiliser. Les filtres `${{inputs...}}` ne sont pas
   évaluables par run_sql : teste la requête avec une valeur fixe.
2. Écris la page avec write_page : titre en front matter, blocs ```sql nom```, puis composants
   Evidence (BigValue, BarChart, LineChart, ScatterPlot, DataTable, Dropdown...).
3. Réponds en une ou deux phrases qui résument le tableau de bord.

Exemple de page existante, à suivre pour le style :
{example}"""


def run_sql(con: duckdb.DuckDBPyConnection, query: str) -> str:
    cursor = con.cursor()
    result = cursor.execute(query)
    columns = [c[0] for c in result.description]
    rows = result.fetchmany(MAX_ROWS)
    return json.dumps({"columns": columns, "rows": rows}, default=str)


def write_page(slug: str, markdown: str) -> str:
    if not re.fullmatch(r"[a-z0-9_-]+", slug):
        raise ValueError("slug invalide : minuscules, chiffres, - ou _ uniquement")
    GENERATED_DIR.mkdir(parents=True, exist_ok=True)
    (GENERATED_DIR / f"{slug}.md").write_text(markdown)
    return f"/generated/{slug}"


def run_agent(question: str) -> dict:
    messages = [{"role": "user", "content": question}]
    page_url = None

    for _ in range(MAX_TURNS):
        response = client.beta.messages.create(
            model=MODEL,
            max_tokens=16000,
            system=SYSTEM_PROMPT,
            tools=TOOLS,
            messages=messages,
            output_config={"effort": "medium"},
            betas=["server-side-fallback-2026-07-01"],
            fallbacks="default",
        )
        messages.append({"role": "assistant", "content": response.content})

        if response.stop_reason != "tool_use":
            text = "".join(b.text for b in response.content if b.type == "text")
            return {"answer": text, "page_url": page_url}

        results = []
        for block in response.content:
            if block.type != "tool_use":
                continue
            try:
                if block.name == "run_sql":
                    output = run_sql(sources, block.input["query"])
                else:
                    page_url = write_page(block.input["slug"], block.input["markdown"])
                    output = f"Page écrite : {page_url}"
                results.append({"type": "tool_result", "tool_use_id": block.id, "content": output})
            except Exception as error:
                results.append(
                    {"type": "tool_result", "tool_use_id": block.id, "content": str(error), "is_error": True}
                )
        messages.append({"role": "user", "content": results})

    return {"answer": "Nombre maximal d'étapes atteint.", "page_url": page_url}


client = anthropic.Anthropic()
sources = load_sources()
SYSTEM_PROMPT = build_system_prompt(sources)

app = FastAPI()
app.add_middleware(CORSMiddleware, allow_origins=["http://localhost:3000"], allow_methods=["POST"], allow_headers=["*"])


class ChatRequest(BaseModel):
    question: str


@app.post("/chat")
def chat(request: ChatRequest) -> dict:
    try:
        return run_agent(request.question)
    except anthropic.APIStatusError as error:
        return {"answer": f"Erreur de l'API Anthropic : {error.message}", "page_url": None}
