# sql-dashboard-agent-pokemon

Projet de démonstration d'une **chaîne BI locale en SQL**, de la donnée brute au tableau de bord,
complétée par un **agent IA qui crée de nouveaux tableaux de bord à partir d'une question en
français**. Les données viennent de la [PokeAPI](https://github.com/PokeAPI/pokeapi) : 187 fichiers
CSV, ≈ 1,3 million de lignes (espèces, types, statistiques, talents, capacités, évolutions,
rencontres…).

Le sujet est volontairement ludique. L'intérêt du dépôt est la **chaîne** : un nettoyage et une
modélisation écrits entièrement en SQL DuckDB (couche `stg`, modèle en étoile, puis `mart`), un
tableau de bord [Evidence](https://evidence.dev) versionné en Markdown + SQL, et un agent Claude
qui écrit, teste puis publie ses propres requêtes sur ces mêmes tables. Le tout tourne sur un
poste de travail, sans base de données serveur.

```text
PokeAPI ──download──> data/raw/*.csv ──SQL DuckDB──> stg_* ─> dim_* / fct_* ─> mart_* ──> marts.duckdb
                                                                                              │
                                              ┌───────────────────────────────────────────────┤
                                              ▼                                               ▼
                                   Evidence (dashboard/)                         Agent Claude (src/agent_api.py)
                                   tableau de bord versionné                     tableaux de bord générés à la demande
```

| Étape             | Outil                           | Code                                                       |
| ------------------ | ------------------------------- | ---------------------------------------------------------- |
| Extract            | requests (API GitHub)           | `src/download_data.py`                                   |
| Nettoyage          | DuckDB                          | `src/cleaning.sql`                                       |
| Modèle en étoile | DuckDB                          | `src/models.sql`                                         |
| Indicateurs        | DuckDB                          | `src/indicators.sql`                                     |
| Build              | Python + DuckDB                 | `src/build_marts.py`                                     |
| Tableau de bord    | Evidence                        | `dashboard/`                                             |
| Assistant          | API Anthropic (Claude), FastAPI | `src/agent_api.py`, `dashboard/components/Chat.svelte` |

## Principes appliqués

| Principe                                  | Comment il est appliqué ici                                                                                                                                                                                                                                                                                                                                                                                       |
| ----------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Transformations en SQL**          | Python ne fait que télécharger les CSV et enchaîner les scripts. Typage, nettoyage, jointures et agrégats vivent dans trois fichiers SQL, lisibles et exécutables seuls avec la CLI DuckDB.                                                                                                                                                                                                                   |
| **Couches nommées comme dans dbt** | `stg_*` (58 tables, une par entité source) → `dim_*`, `fct_*`, `bridge_*`, `int_*` (modèle en étoile de Kimball, 21 tables) → `mart_*` (7 tables prêtes pour le tableau de bord). Le grain de chaque table de faits et de chaque mart est écrit au-dessus de sa requête.                                                                                                                       |
| **Typage explicite**                | Chaque CSV est lu tout en texte (`all_varchar = true`) puis converti par des macros (`as_int`, `as_bool`, `as_text`, `clean_text`) : les types ne dépendent jamais de la détection automatique de DuckDB, même sur une colonne entièrement vide. Chaînes vides → `NULL`, drapeaux `0/1` → `BOOLEAN`, unités converties (décimètres → mètres, hectogrammes → kg).                      |
| **Périmètre assumé**             | Anglais uniquement (`language_id = 9`), formes par défaut dans les marts agrégés pour qu'une méga-évolution ou une forme régionale ne compte pas deux fois une espèce, jeux dérivés écartés (Conquest, concours, Pokéathlon). `mart_pokemon` garde toutes les formes et les distingue par la colonne `is_default`. La liste des tables ignorées et la raison sont en tête de `cleaning.sql`. |
| **Rejouable**                       | `download_data.py` télécharge un commit épinglé de la PokeAPI. `CREATE OR REPLACE` partout. `build_marts.py` calcule tout dans une base en mémoire, supprime `marts.duckdb` puis le recrée : relancer le build ne laisse aucun reste.                                                                                                                                                                |
| **Une base par usage**              | Seules les tables `mart_*` sont exportées dans `marts.duckdb`. Le tableau de bord et l'agent ne voient pas les couches intermédiaires.                                                                                                                                                                                                                                                                       |
| **Agent ancré dans les données**  | L'agent interroge une copie des sources Evidence sous les mêmes noms que les pages (`marts.pokemon`, `marts.stats_by_type`…). Son prompt lui demande de tester chaque requête, et `write_page` réexécute celles de la page avant de l'enregistrer.                                                                                                                                                      |
| **Secrets hors du dépôt**         | La clé `ANTHROPIC_API_KEY` vit dans l'environnement ou dans un `.env` ignoré par git (modèle : `.env.example`), que l'API charge au démarrage.                                                                                                                                                                                                                                                           |

## Spécificités du projet

- **DuckDB de bout en bout, mais plusieurs versions.** Le paquet Python (`duckdb` 2.0) construit
  les marts et sert à l'agent. Evidence embarque des DuckDB plus anciens : `@duckdb/node-api` 1.4
  pour extraire les sources, `duckdb-wasm` dans le navigateur pour exécuter les requêtes des pages.
  `build_marts.py` fixe donc le format de stockage de `marts.duckdb` à `v1.0.0`, que DuckDB 1.4 sait
  lire. Côté SQL, une fonction propre à DuckDB 2.0 peut passer dans l'agent et échouer dans la page.
- **Une source Evidence par mart.** `dashboard/sources/marts/*.sql` expose chaque `mart_<nom>` sous
  le nom `marts.<nom>`. Seul `pokemon.sql` fait plus qu'un `select *` : il convertit
  `base_stat_total` (une somme DuckDB, donc un `HUGEINT`) en `INTEGER`.
- **Sources à rafraîchir.** Evidence ne lit pas `marts.duckdb` à chaque affichage : `npm run sources`
  en extrait une copie. Après un nouveau build, relancer `npm run sources` pour que les pages voient
  les mêmes données que l'agent, qui relit `marts.duckdb` à chaque question.

## L'assistant de tableaux de bord

La page `/chat` du tableau de bord prend une question (*« compare les statistiques des légendaires
par type »*) et renvoie un tableau de bord Evidence complet : requêtes, graphiques, tableaux.

1. Le composant `Chat.svelte` envoie la question à l'API (`POST /chat`, port 8000).
2. L'API copie chaque source Evidence dans une base DuckDB en mémoire, neuve à chaque question, sous
   le schéma `marts`, puis construit son prompt système : colonnes et types de chaque source,
   méthode à suivre, et la page `index.md` comme exemple de style.
3. Claude (`claude-opus-5-5`, effort `medium`) enchaîne les appels d'outils : il teste chaque
   requête avec `run_sql`, corrige celles qui échouent, puis écrit la page avec `write_page`.
4. L'API renvoie un résumé en une ou deux phrases et l'URL de la page. Le serveur de développement
   d'Evidence la prend en compte à chaud, et la page de chat l'affiche dans un cadre.

| Outil          | Rôle                                                    | Garde-fou                                                                                                                                                                                                                                                                                                                                             |
| -------------- | -------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `run_sql`    | Exécute une requête DuckDB sur les sources `marts.*` | Base en mémoire propre à la question : `marts.duckdb` y est attaché en lecture seule le temps de la copie, puis tout accès aux fichiers est coupé (`enable_external_access = false`, configuration verrouillée). Au plus 20 lignes renvoyées au modèle.                                                                                   |
| `write_page` | Écrit la page Markdown Evidence                         | Nom de page limité à `[a-z0-9_-]` (sauf `index`), écriture uniquement dans `dashboard/pages/generated/`, sans écraser la page d'une autre question. Les requêtes de la page sont réexécutées et la page est refusée si l'une échoue ; celles qui dépendent d'un filtre ou d'une autre requête (`${...}`) ne sont pas vérifiées. |

La boucle s'arrête après 15 tours. Une requête ou une page refusée n'interrompt pas l'agent : le
message d'erreur lui est renvoyé pour qu'il corrige. Toute autre erreur (clé absente, API
injoignable, `marts.duckdb` manquant) devient la réponse affichée dans la page de chat.

| Méthode | Route     | Corps                   | Réponse                                              |
| -------- | --------- | ----------------------- | ----------------------------------------------------- |
| `POST` | `/chat` | `{"question": "..."}` | `{"answer": "...", "page_url": "/generated/<nom>"}` |

`page_url` vaut `null` quand aucune page n'a été écrite : erreur, ou limite de tours atteinte.

## Développement assisté par Claude Code

Deux sous-agents [Claude Code](https://claude.com/claude-code), versionnés dans
`.claude/agents/`, ont servi à préparer la couche de nettoyage :

| Sous-agent        | Rôle                                                                                                                                                                           |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `data-explorer` | Profile les 187 CSV de `data/raw/` (schéma, valeurs manquantes, clés, relations) et écrit `docs/data_report.md`, la référence dont part le SQL.                        |
| `sql-builder`   | Transforme ce rapport en script de nettoyage DuckDB (`src/cleaning.sql`), puis le valide sur une base temporaire : tables non vides, clés uniques, jointures sans orphelins. |

Le rapport de profilage est régénérable et n'est pas versionné.

## Structure du dépôt

```text
.
├── config/
│   └── setting.py              # chemins : data/raw, data/processed, marts.duckdb
├── src/
│   ├── download_data.py        # télécharge les CSV de la PokeAPI dans data/raw/
│   ├── cleaning.sql            # CSV -> stg_* : typage, nettoyage, noms anglais
│   ├── models.sql              # stg_* -> modèle en étoile (dim_*, fct_*, bridge_*, int_*)
│   ├── indicators.sql          # modèle en étoile -> mart_*
│   ├── build_marts.py          # exécute les 3 scripts, exporte les mart_* dans marts.duckdb
│   └── agent_api.py            # API FastAPI de l'assistant (boucle d'outils Claude)
├── dashboard/                  # projet Evidence
│   ├── sources/marts/          # connexion à marts.duckdb, une requête par mart
│   ├── pages/
│   │   ├── index.md            # tableau de bord principal
│   │   ├── chat.md             # page de l'assistant
│   │   └── generated/          # pages écrites par l'agent — non versionné
│   └── components/
│       └── Chat.svelte         # formulaire de chat et aperçu de la page générée
├── data/
│   ├── raw/                    # CSV PokeAPI — téléchargés, non versionnés
│   └── processed/              # marts.duckdb — généré, non versionné
├── docs/                       # data_report.md (profil des CSV) — généré, non versionné
├── .claude/agents/             # sous-agents Claude Code : data-explorer, sql-builder
├── .env.example                # modèle du .env (ANTHROPIC_API_KEY)
├── pyproject.toml
└── requirements.txt            # dépendances Python, versions figées
```

## Reproduire le projet

### Prérequis

| Outil              | Version                                               | Nécessaire pour                                  |
| ------------------ | ----------------------------------------------------- | ------------------------------------------------- |
| Python             | 3.13                                                  | Téléchargement, build des marts, API de l'agent |
| Node.js et npm     | Compatible Evidence 40                                | Tableau de bord                                   |
| Clé API Anthropic | [console.anthropic.com](https://console.anthropic.com) | Assistant uniquement                              |

La CLI DuckDB n'est pas nécessaire : le paquet Python suffit.

### Installation

```bash
git clone https://github.com/Marius-cld/sql-dashboard-agent-pokemon.git
cd sql-dashboard-agent-pokemon
python3.13 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
cd dashboard && npm ci && cd ..
cp .env.example .env    # assistant uniquement : renseigner ANTHROPIC_API_KEY
```

### Construire les données

Toutes les commandes se lancent depuis la racine du dépôt, environnement virtuel activé.

| # | Commande                        | Lit                                             | Produit                                               |
| - | ------------------------------- | ----------------------------------------------- | ----------------------------------------------------- |
| 1 | `python -m src.download_data` | Dépôt GitHub de la PokeAPI (commit épinglé) | `data/raw/*.csv` (187 fichiers)                     |
| 2 | `python -m src.build_marts`   | `data/raw/*.csv`                              | `data/processed/marts.duckdb` (7 tables `mart_*`) |

Le build prend environ une seconde. Pour inspecter les couches intermédiaires (`stg_*`, `dim_*`,
`fct_*`), les scripts SQL s'exécutent aussi un par un avec la CLI DuckDB, dans l'ordre
`cleaning.sql`, `models.sql`, `indicators.sql` (`duckdb pokemon.duckdb < src/cleaning.sql`). Cette
base, ignorée par git, ne sert qu'à l'exploration : le tableau de bord et l'agent ne lisent que
`marts.duckdb`.

### Lancer le tableau de bord

```bash
cd dashboard
npm run sources    # extrait les données de marts.duckdb pour Evidence
npm run dev        # http://localhost:3000
```

### Lancer l'assistant

L'API lit `marts.duckdb` à chaque question : le build doit avoir tourné. Elle charge la clé depuis
`.env` au démarrage (une variable `ANTHROPIC_API_KEY` déjà exportée l'emporte). Dans un second
terminal, depuis la racine :

```bash
source .venv/bin/activate
uvicorn src.agent_api:app --port 8000
```

Puis ouvrir http://localhost:3000/chat.

| Service                  | Démarrage (depuis la racine)                       | Adresse                    |
| ------------------------ | --------------------------------------------------- | -------------------------- |
| Tableau de bord Evidence | `cd dashboard && npm run sources && npm run dev`  | http://localhost:3000      |
| API de l'agent           | `.venv/bin/uvicorn src.agent_api:app --port 8000` | http://localhost:8000      |
| Assistant                | Page du tableau de bord                             | http://localhost:3000/chat |

Les pages générées sont écrites dans `dashboard/pages/generated/` (ignoré par git) et ne s'affichent
qu'en mode dev.

## Ce que contient la base

`marts.duckdb` ne contient que les tables `mart_*`. Evidence et l'agent les lisent sous le nom
`marts.<nom>`.

| Source Evidence               | Grain                                               | Contenu                                                                                                                                                  |
| ----------------------------- | --------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `marts.pokemon`             | Un Pokémon, formes alternatives comprises          | Table large : génération, types, 6 statistiques et leur total, taille, poids, taux de capture, statut légendaire ou fabuleux, couleur, forme, habitat |
| `marts.stats_long`          | Un Pokémon × une statistique (formes par défaut) | Format long, pour les distributions par statistique                                                                                                      |
| `marts.pokemon_by_type`     | Un type (18 types jouables)                         | Nombre de Pokémon, en type principal ou secondaire, mono-type, légendaires ou fabuleux. Un double type compte dans chacun de ses types                 |
| `marts.stats_by_type`       | Un type × une statistique                          | Moyenne, médiane, minimum, maximum                                                                                                                      |
| `marts.stats_by_generation` | Une génération × une statistique                 | Moyenne, médiane, minimum, maximum                                                                                                                      |
| `marts.generation_summary`  | Une génération (9)                                | Nouvelles espèces, légendaires, fabuleux, total de stats moyen                                                                                         |
| `marts.type_matchups`       | Un type attaquant × un type défenseur (18 × 18)  | Multiplicateur de dégâts                                                                                                                               |

Le tableau de bord principal (`pages/index.md`) couvre les 1 025 espèces, avec un filtre par
génération : indicateurs clés, évolution par génération, répartition par type, carte de chaleur
type × statistique, table des affinités de types, top 15 des Pokémon les plus puissants et nuage
attaque / défense.

## Limites et pistes d'amélioration

- **Chiffres écrits en dur** : les décomptes de ce README et de `index.md` (187 CSV, 1 025 espèces,
  9 générations) valent pour le commit de la PokeAPI épinglé dans `download_data.py` (`REF`).
  Passer à un commit plus récent oblige à les revoir.
- **Pas de tests de données** : les clés ne sont ni déclarées ni vérifiées après le build. Passer à
  dbt-duckdb donnerait des tests `unique` / `not_null` / `relationships` et un lineage.
- **Modèle plus riche que les marts** : capacités (`fct_pokemon_move`), rencontres (`fct_encounter`)
  et évolutions (`fct_evolution`) sont modélisées mais n'ont pas encore de mart. L'agent ne peut
  donc pas répondre aux questions qui les concernent.
- **Assistant de développement local** : pas d'authentification, CORS limité à
  `http://localhost:3000`, pages générées visibles en mode dev seulement. Chaque question repart de
  zéro, sans mémoire des échanges précédents, et la réponse arrive d'un bloc, sans streaming.

## Dataset

Les données proviennent du dépôt [PokeAPI](https://github.com/PokeAPI/pokeapi) (dossier
`data/v2/csv/`), à un commit épinglé. Elles sont téléchargées par `src/download_data.py` et ne
sont pas redistribuées dans ce dépôt.

Pokémon et les noms associés sont des marques de Nintendo, Game Freak et The Pokémon Company. Ce
projet, réalisé à des fins de démonstration (portfolio), n'a aucun lien avec eux.

## Licence

Code distribué sous licence [MIT](LICENSE).
