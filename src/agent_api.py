import json
import re

import anthropic
import duckdb
from dotenv import load_dotenv
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

from config.setting import BASE_DIR, ENV_FILE, MARTS_DB

DASHBOARD_DIR = BASE_DIR / "dashboard"
SOURCES_DIR = DASHBOARD_DIR / "sources" / "marts"
GENERATED_DIR = DASHBOARD_DIR / "pages" / "generated"

MODEL = "claude-opus-5-5"
MAX_TURNS = 15
MAX_ROWS = 20

# Bloc de requête Evidence : ```sql nom ... ```
SQL_BLOCK = re.compile(r"^```sql[ \t]+(\w+)[^\n]*\n(.*?)^```", re.DOTALL | re.MULTILINE)

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
        "description": "Écrit le tableau de bord Evidence (Markdown) dans pages/generated/<slug>.md. "
        "Les blocs ```sql sans `${...}` sont réexécutés : la page est refusée si l'un d'eux échoue.",
        "strict": True,
        "input_schema": {
            "type": "object",
            "properties": {
                "slug": {"type": "string", "description": "Nom court en minuscules, chiffres, - ou _, autre que index"},
                "markdown": {"type": "string"},
            },
            "required": ["slug", "markdown"],
            "additionalProperties": False,
        },
    },
]


def load_sources() -> duckdb.DuckDBPyConnection:
    """Copie chaque source Evidence dans une base en mémoire, sous le schéma `marts`,
    pour que l'agent teste exactement les mêmes noms que ceux utilisés dans les pages.
    Une base par question : ce que l'agent y modifie disparaît avec elle."""
    con = duckdb.connect(":memory:")
    con.execute(f"ATTACH '{MARTS_DB}' AS src (READ_ONLY)")
    con.execute("CREATE SCHEMA memory.marts")
    # Les requêtes sources référencent les tables mart_* sans préfixe
    con.execute("USE src")
    for source in sorted(SOURCES_DIR.glob("*.sql")):
        con.execute(f"CREATE TABLE memory.marts.{source.stem} AS {source.read_text()}")
    con.execute("USE memory")
    con.execute("DETACH src")
    # Plus aucun accès aux fichiers (read_text, COPY, ATTACH...), réglage non modifiable
    con.execute("SET enable_external_access = false")
    con.execute("SET lock_configuration = true")
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

`marts.pokemon` contient aussi les formes alternatives (méga-évolutions, formes régionales) :
filtre sur `is_default` pour compter des espèces.

Méthode :
1. Teste chaque requête avec run_sql avant de l'utiliser. Les filtres `${{inputs...}}` ne sont pas
   évaluables par run_sql : teste la requête avec une valeur fixe.
2. Écris la page avec write_page : titre en front matter, blocs ```sql nom```, puis composants
   Evidence (BigValue, BarChart, LineChart, ScatterPlot, DataTable, Dropdown...).
3. Réponds en une ou deux phrases qui résument le tableau de bord.

Exemple de page existante, à suivre pour le style :
{example}"""


def run_sql(con: duckdb.DuckDBPyConnection, query: str) -> str:
    result = con.execute(query)
    if result.description is None:
        return "Instruction exécutée, aucun résultat."
    columns = [c[0] for c in result.description]
    rows = result.fetchmany(MAX_ROWS)
    return json.dumps({"columns": columns, "rows": rows}, default=str)


def check_queries(con: duckdb.DuckDBPyConnection, markdown: str) -> None:
    """Réexécute les requêtes de la page. Celles qui dépendent d'un filtre ou d'une autre
    requête (`${...}`) ne s'évaluent que dans Evidence : elles ne sont pas vérifiées."""
    for name, query in SQL_BLOCK.findall(markdown):
        if "${" in query:
            continue
        try:
            con.execute(query)
        except duckdb.Error as error:
            raise ValueError(f"requête {name} : {error}") from error


def write_page(con: duckdb.DuckDBPyConnection, slug: str, markdown: str, page_url: str | None) -> str:
    """`page_url` est la page déjà écrite pour cette question : la seule qu'on peut écraser."""
    # index.md serait servie sous /generated, pas sous /generated/index
    if not re.fullmatch(r"[a-z0-9_-]+", slug) or slug == "index":
        raise ValueError("slug invalide : minuscules, chiffres, - ou _ uniquement, autre que index")
    url = f"/generated/{slug}"
    path = GENERATED_DIR / f"{slug}.md"
    if path.exists() and url != page_url:
        raise ValueError(f"la page {slug} existe déjà : choisis un autre slug")
    check_queries(con, markdown)
    GENERATED_DIR.mkdir(parents=True, exist_ok=True)
    path.write_text(markdown)
    return url


def run_agent(con: duckdb.DuckDBPyConnection, question: str) -> dict:
    system = build_system_prompt(con)
    messages = [{"role": "user", "content": question}]
    page_url = None

    for _ in range(MAX_TURNS):
        response = client.beta.messages.create(
            model=MODEL,
            max_tokens=16000,
            system=system,
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
                    output = run_sql(con, block.input["query"])
                else:
                    page_url = write_page(con, block.input["slug"], block.input["markdown"], page_url)
                    output = f"Page écrite : {page_url}"
                results.append({"type": "tool_result", "tool_use_id": block.id, "content": output})
            except Exception as error:
                results.append(
                    {"type": "tool_result", "tool_use_id": block.id, "content": str(error), "is_error": True}
                )
        messages.append({"role": "user", "content": results})

    return {"answer": "Nombre maximal d'étapes atteint.", "page_url": page_url}


# Une variable déjà définie dans l'environnement l'emporte sur le .env
load_dotenv(ENV_FILE)
client = anthropic.Anthropic()

app = FastAPI()
app.add_middleware(CORSMiddleware, allow_origins=["http://localhost:3000"], allow_methods=["POST"], allow_headers=["*"])


class ChatRequest(BaseModel):
    question: str


@app.post("/chat")
def chat(request: ChatRequest) -> dict:
    try:
        with load_sources() as con:
            return run_agent(con, request.question)
    except anthropic.APIStatusError as error:
        return {"answer": f"Erreur de l'API Anthropic : {error.message}", "page_url": None}
    except Exception as error:
        # Clé absente, API injoignable, marts.duckdb manquant... : affiché dans la page de chat
        return {"answer": f"Erreur : {error}", "page_url": None}
