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

Le détail de chaque étape, et les raisons de chaque choix, sont dans
[Pipeline de données](#pipeline-de-données).

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

## Pipeline de données

Cette section suit la donnée du CSV brut jusqu'au mart et justifie les choix faits à chaque étape.
Les volumes valent pour le commit de la PokeAPI épinglé dans `download_data.py`.

| # | Étape                  | Code                                             | Produit                                                                    |
| - | ---------------------- | ------------------------------------------------ | -------------------------------------------------------------------------- |
| 1 | Extraction             | `src/download_data.py`                           | 187 CSV, 1 284 193 lignes, dans `data/raw/`                                |
| 2 | Profilage et sélection | `docs/data_report.md`, en-tête de `cleaning.sql` | 90 CSV retenus (945 206 lignes), 97 écartés                                |
| 3 | Nettoyage              | `src/cleaning.sql`                               | 58 tables `stg_*`                                                          |
| 4 | Modèle en étoile       | `src/models.sql`                                 | 11 `dim_*`, 5 `fct_*`, 3 `bridge_*`, 2 `int_*`                             |
| 5 | Indicateurs            | `src/indicators.sql`                             | 7 tables `mart_*` (8 014 lignes), exportées dans `marts.duckdb` (≈ 2 Mo) |

### 1. Extraction : où et comment les CSV sont récupérés

La PokeAPI expose une API REST ([pokeapi.co](https://pokeapi.co)), mais sa base est elle-même
construite à partir de CSV versionnés dans son dépôt GitHub, dossier
[`data/v2/csv/`](https://github.com/PokeAPI/pokeapi/tree/master/data/v2/csv). Le projet part de ces
CSV plutôt que de l'API :

- **Complets en une passe** : 187 fichiers, contre des milliers d'appels REST (une ressource par
  Pokémon, capacité, objet…) soumis à une politique d'usage équitable.
- **Déjà relationnels** : chaque fichier est une table, avec ses identifiants et ses clés
  étrangères. L'API renvoie du JSON imbriqué qu'il faudrait d'abord aplatir.
- **Versionnés** : un commit Git désigne un état exact des données.

`src/download_data.py` procède en deux temps, sur le commit épinglé `REF` :

1. **Lister.** Un seul appel à l'API Git Trees de GitHub
   (`/repos/PokeAPI/pokeapi/git/trees/<REF>?recursive=1`) renvoie toute l'arborescence du dépôt. Le
   script garde les fichiers (`blob`) de `data/v2/csv/` qui finissent en `.csv`. Si GitHub signale
   une réponse tronquée (`truncated`), il s'arrête au lieu de télécharger une liste incomplète.
2. **Télécharger.** Chaque fichier est lu sur `raw.githubusercontent.com` au même commit et écrit
   tel quel dans `data/raw/`. Une seule session HTTP réutilise la connexion, chaque requête a un
   délai maximal de 30 s et toute réponse en erreur arrête le script (`raise_for_status`).

Deux choix à noter :

- **Commit épinglé plutôt que `master`.** Deux téléchargements donnent les mêmes fichiers, donc les
  mêmes tables et les mêmes chiffres. Mettre les données à jour devient un changement explicite et
  relu : la valeur de `REF`.
- **Liste lue sur GitHub, pas écrite en dur.** Le téléchargement prend tout ce que contient le
  commit. Le tri entre fichiers utiles et inutiles se fait plus loin, dans le SQL, où chaque
  exclusion est commentée.

### 2. Profilage et sélection des CSV

Avant d'écrire le SQL, les 187 fichiers ont été profilés (sous-agent `data-explorer`, rapport
`docs/data_report.md`) : nombre de lignes, type déduit de chaque colonne, valeurs nulles et
distinctes, clé primaire candidate, clés étrangères. Le rapport regroupe les fichiers par domaine,
relève les pièges du format (traités à l'étape 3) et classe les tables par priorité pour le tableau
de bord. La sélection part de ce classement :

| Domaine                                                             | CSV |    Lignes | Lus | Écartés                                                                                                                    |
| ------------------------------------------------------------------- | --: | --------: | --: | -------------------------------------------------------------------------------------------------------------------------- |
| Pokémon : espèces, formes, types, stats, talents, capacités apprises |  22 |   663 035 |  17 | caractéristiques (`characteristics*`, texte de jeu), conditions, déclencheurs et générations des formes                    |
| Types, statistiques, natures                                        |   5 |       454 |   4 | préférences de style de combat des natures (mécanique annexe)                                                              |
| Capacités                                                           |  12 |     6 904 |   8 | drapeaux, styles de combat, `move_effects` (seule sa prose sert, jointe directement depuis `moves`)                       |
| Talents                                                             |   1 |       374 |   1 | —                                                                                                                          |
| Objets et baies                                                     |  11 |     3 618 |   5 | drapeaux, effets de *Fling*, prix par jeu, monnaies, saveurs de baies (concours)                                           |
| Évolution                                                           |   4 |     1 238 |   3 | `evolution_variables` (variables de la colonne `condition_expression`, non exploitée)                                      |
| Rencontres et lieux                                                 |  12 |   246 990 |   8 | conditions de rencontre (`encounter_condition*`, dont une table de 112 031 lignes), index de jeu                          |
| Jeux et référentiels                                                |  13 |    41 185 |   7 | `*_game_indices` (numéros internes aux cartouches), tables de liaison sans usage analytique                                |
| Historique (`*_past`, `*_changelog`)                                |   9 |     1 336 |   4 | journaux de modifications en prose ; les valeurs passées (`*_past`) sont gardées                                           |
| Localisation (`*_names`, `*_prose`, `*_flavor_text`)                |  56 |   262 425 |  33 | textes des domaines écartés, textes d'ambiance par version des objets, capacités et talents, trois fichiers vides          |
| Concours, Pokéathlon, Pal Park                                      |  10 |     3 624 |   0 | mini-jeux hors combat                                                                                                      |
| Pokémon Conquest                                                    |  32 |    53 010 |   0 | jeu dérivé, avec ses propres statistiques et ses propres règles                                                            |
| **Total**                                                           | **187** | **1 284 193** | **90** |                                                                                                                   |

Les critères :

1. **La série principale seulement.** Concours, Pokéathlon, Pal Park et Conquest ont leurs propres
   règles et statistiques. Les mêler aux combats de la série principale fausserait toute
   comparaison.
2. **Une table gardée sert une question.** Numéros de cartouche, drapeaux techniques et journaux de
   modifications ne répondent à aucune question du tableau de bord.
3. **Une seule langue, jointe en colonne.** Sur les 33 fichiers de localisation retenus, 32 ne
   deviennent pas des tables : leur libellé anglais est joint à l'entité pendant le nettoyage. Seuls
   les textes de Pokédex, un par espèce et par version, gardent leur propre table
   (`stg_pokemon_species_flavor_text`). L'anglais est la langue la mieux couverte (374 talents
   nommés sur 374, contre 311 en français), et les `identifier` qui servent de repli sont eux-mêmes
   en anglais.
4. **Charger large en `stg`, modéliser serré.** Les tables de priorité 2 et 3 du rapport (natures,
   baies, CT, Pokédex régionaux, valeurs passées) sont chargées même si aucun mart ne les utilise
   encore : ajouter un indicateur ne demande pas de revenir au nettoyage.

Bilan : 90 CSV lus (57 entités et 33 fichiers de libellés), soit 945 206 lignes sur 1 284 193
(74 %). La liste commentée des exclusions est en tête de `cleaning.sql`.

### 3. Nettoyage : `cleaning.sql` → `stg_*`

Contrat de la couche : une table `stg_*` par entité source, typée, nettoyée, avec son libellé
anglais. Pas de règle métier, pas de filtre de lignes hors langue. Les noms de la source sont
conservés, à quelques renommages près : `id` devient `<entité>_id`, `order` (mot réservé) devient
`sort_order`, une colonne convertie prend son unité (`height_m`). Les couches suivantes s'appuient
donc sur un schéma stable, et une valeur douteuse se remonte jusqu'à un seul fichier source.

Chaque règle répond à un constat du profilage :

| Constat                                                                                                                                                  | Règle                                                                                                       | Pourquoi                                                                                                                                                                |
| -------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Détection automatique des types fragile : `encounter_pokemon_details.min_perfect_ivs` est entièrement vide, beaucoup d'entiers sont nullables            | Lecture tout en texte (`all_varchar = true`), puis conversion explicite par macro (`as_int`, `as_bool`, `as_text`) | Le schéma est écrit dans le code. Il ne change pas si une colonne se vide ou si l'échantillon du détecteur manque une valeur atypique.                                   |
| Valeur manquante codée par une chaîne vide (`,,`)                                                                                                        | `NULLIF(TRIM(x), '')` dans chaque macro                                                                     | `COUNT`, `AVG` et les jointures gèrent `NULL`, pas `''`.                                                                                                                |
| Booléens codés `0/1`                                                                                                                                     | `as_bool` → `BOOLEAN`                                                                                       | Filtres lisibles (`WHERE is_legendary`), sans confusion possible avec un entier.                                                                                        |
| 14 langues dans les `*_names` et `*_prose`, sous deux noms de colonne (`local_language_id`, mais `language_id` dans les `*_flavor_text`)                 | `LEFT JOIN` filtré sur la langue 9 (anglais), repli sur `identifier` (`COALESCE`)                           | Le filtre dans la jointure garde une ligne par entité au lieu de quatorze. Le `LEFT JOIN` garde l'entité sans traduction, le repli lui donne toujours un libellé.       |
| Textes de Pokédex hérités des cartouches : retours à la ligne, sauts de page (`\f`), traits d'union conditionnels                                        | Macro `clean_text` : suppression de U+00AD, blancs fusionnés en un espace                                   | Texte affichable tel quel et comparable d'une version à l'autre.                                                                                                        |
| Grain des textes de Pokédex non garanti par la source (clé candidate, non vérifiée)                                                                      | `QUALIFY row_number() … = 1` par (espèce, version)                                                          | Une ligne par (espèce, version), même si une version future des CSV contenait un doublon.                                                                              |
| Unités de jeu : taille en décimètres, poids en hectogrammes, efficacité en pourcentage, `gender_rate` en huitièmes (`-1` = asexué)                       | `height_m`, `weight_kg`, `damage_multiplier` (0 ; 0,5 ; 1 ; 2), `female_ratio`, `is_genderless`             | Conversions faites une fois, au même endroit, plutôt que refaites (ou oubliées) dans chaque requête. La valeur source reste à côté quand elle a un usage (`damage_factor`). |
| Lignes hors analyse mêlées aux autres : types `unknown`, `shadow`, `stellar` ; statistiques 7 à 9 (précision, esquive, ancienne stat Spécial) ; formes alternatives (id ≥ 10001) | Drapeaux `is_playable`, `is_base_stat`, `is_alternate_form`, `is_base_of_chain`                | La règle est nommée ici et appliquée plus loin par un simple filtre. Les lignes restent en `stg` : rien n'est perdu si une analyse en a besoin.                         |
| `NULL` porteur de sens : puissance et précision des capacités de statut ou à puissance variable                                                          | Aucune valeur par défaut                                                                                    | Remplacer par 0 ferait baisser la puissance moyenne d'un type.                                                                                                          |
| Gabarit non résolu dans les effets de capacités : `Has a $effect_chance% chance to burn the target.`                                                     | Remplacé par la valeur de `effect_chance`                                                                   | Texte d'effet lisible directement.                                                                                                                                      |

Aucune contrainte `PRIMARY KEY` n'est déclarée : les clés composites du rapport sont déduites des
noms de colonnes, sans vérification d'unicité. Les vérifier relève de tests de données, pas encore
écrits (voir [Limites](#limites-et-pistes-damélioration)).

### 4. Modèle en étoile : `models.sql`

La source est très normalisée : une espèce pointe vers sa couleur, sa forme, son habitat et son
taux de croissance, chacun avec sa table de libellés par langue. C'est le bon format pour stocker
sans redondance, pas pour analyser : chaque question demande une chaîne de jointures, et il faut
savoir à quel niveau (espèce ou Pokémon) vit chaque attribut. Le modèle en étoile de Kimball sépare :

- les **faits** : ce qu'on mesure, à un grain déclaré en commentaire au-dessus de chaque table ;
- les **dimensions** : le contexte sur lequel on filtre et on regroupe, dénormalisé pour qu'un axe
  d'analyse coûte une seule jointure.

Le cœur du modèle, celui dont partent les marts :

```text
                                  dim_generation
                                        │ generation_id
dim_stat ──< fct_pokemon_stat >── dim_pokemon ──< bridge_pokemon_type >── dim_type ══< fct_type_efficacy
                                        │                                           (attaquant × défenseur)
                                        ├──< bridge_pokemon_ability >── dim_ability
                                        └──< bridge_species_egg_group >── dim_egg_group   (par species_id)

A ──< B : une ligne de A pour plusieurs lignes de B.     ══< : dim_type jointe deux fois, une par rôle.
```

| Table de faits        | Grain                                                    |  Lignes | Contenu                                                                                     |
| --------------------- | -------------------------------------------------------- | ------: | ------------------------------------------------------------------------------------------- |
| `fct_pokemon_stat`  | Pokémon × statistique                                    |   8 106 | `base_stat`, `effort`, par `dim_pokemon` et `dim_stat`                                   |
| `fct_type_efficacy` | type attaquant × type défenseur                          |     324 | Multiplicateur de dégâts, `dim_type` dans les deux rôles                                  |
| `fct_pokemon_move`  | Pokémon × groupe de versions × capacité × méthode × niveau | 638 321 | Qui apprend quoi, où et comment : table de faits sans mesure, au sens de Kimball           |
| `fct_encounter`     | Une rencontre : version, zone, Pokémon, niveaux          | 117 127 | Rareté et niveaux, par `dim_pokemon`, `dim_version` et `dim_location_area`             |
| `fct_evolution`     | Une règle d'évolution                                    |     676 | Espèce de départ, espèce d'arrivée, déclencheur et conditions (niveau, objet, bonheur…)     |

| Dimension                                             | Grain                                         | Ce qui y est dénormalisé                                                                                       |
| ----------------------------------------------------- | --------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| `dim_pokemon`                                       | Un Pokémon, formes alternatives comprises     | Attributs de l'espèce (génération, légendaire, taux de capture…), couleur, forme, habitat, taux de croissance |
| `dim_move`                                          | Une capacité                                  | Type, classe de dégâts, cible, catégorie et altération d'état (`move_meta`)                                  |
| `dim_item`                                          | Un objet                                      | Catégorie, poche                                                                                               |
| `dim_location_area`                                 | Une zone                                      | Lieu, région                                                                                                   |
| `dim_version`                                       | Une version de jeu                            | Groupe de versions, génération                                                                                 |
| `dim_generation`                                    | Une génération                                | Région principale                                                                                              |
| `dim_type`, `dim_stat`                            | Un type, une statistique                      | Classe de dégâts ; drapeaux `is_playable`, `is_base_stat`                                                    |
| `dim_ability`, `dim_egg_group`, `dim_move_method` | Une valeur de référentiel                     | Libellé anglais, effet court pour les talents                                                                  |

| Pont ou table intermédiaire   | Contenu                                                                         |
| ----------------------------- | ------------------------------------------------------------------------------- |
| `bridge_pokemon_type`       | Pokémon ↔ type ; `slot` 1 = type principal, 2 = type secondaire              |
| `bridge_pokemon_ability`    | Pokémon ↔ talent, jusqu'à trois dont le talent caché (`is_hidden`)            |
| `bridge_species_egg_group`  | Espèce ↔ groupe d'œufs                                                         |
| `int_pokemon_types_pivoted` | Un Pokémon par ligne, `type_1` et `type_2` en colonnes                        |
| `int_pokemon_stats_pivoted` | Un Pokémon par ligne, les 6 statistiques en colonnes et leur total              |

Les choix de modélisation :

- **Le grain de `dim_pokemon` est le Pokémon, pas l'espèce.** Types et statistiques sont portés par
  le Pokémon : Raichu d'Alola est Électrik/Psy quand Raichu est Électrik, une méga-évolution a ses
  propres statistiques. Les attributs d'espèce sont recopiés sur chaque forme, et `is_default`
  ramène au grain espèce (1 025 lignes sur 1 351).
- **Une étoile, pas un flocon.** Couleur, forme, habitat, classe de dégâts, poche d'objet… sont des
  listes de 3 à 14 valeurs sans attribut propre. En tables séparées, chacune coûterait une jointure
  de plus sans rien apporter : elles deviennent des colonnes texte de leur dimension. Seule
  `dim_generation` reste à part : Pokémon, types, capacités, talents et versions ont tous une
  génération, c'est une dimension partagée (« conforme », dans le vocabulaire de Kimball).
- **Des ponts pour les relations plusieurs-à-plusieurs.** Un Pokémon a un ou deux types et jusqu'à
  trois talents. En colonnes (`type_1`, `type_2`), compter les Pokémon par type demanderait un
  `UNION` des deux colonnes ; avec le pont, c'est un `GROUP BY type_id`. La version en colonnes,
  utile à l'affichage, est dérivée à côté (`int_pokemon_types_pivoted`).
- **Une dimension, deux rôles.** `fct_type_efficacy` joint `dim_type` une fois comme attaquant et
  une fois comme défenseur, plutôt que de dupliquer la table des types.
- **Des faits au format long.** `fct_pokemon_stat` a une ligne par statistique : une moyenne ou une
  distribution par statistique est un `GROUP BY stat_id`. Le format large (une colonne par
  statistique) en est dérivé dans `int_pokemon_stats_pivoted`, jamais l'inverse.
- **Des clés naturelles, sans clés de substitution.** Une seule source, des identifiants stables,
  aucun historique de dimension à conserver (pas de SCD) : une clé de substitution ajouterait une
  table de correspondance sans rien résoudre. Les `<entité>_id` de la PokeAPI restent les mêmes du
  CSV au mart, ce qui permet de remonter n'importe quelle ligne jusqu'à sa source.
- **Ne modéliser que ce qui sert.** Natures, baies, CT, Pokédex et valeurs passées restent en
  `stg_*` tant qu'aucune analyse ne les demande.

### 5. Indicateurs : `indicators.sql` → `mart_*`

Les marts sont la seule couche que voient le tableau de bord et l'agent. Chacun répond à un usage
et est dénormalisé ; tous, sauf `mart_pokemon` et `mart_stats_long`, sont déjà agrégés :

- une page Evidence se réduit à des `select` et des filtres, exécutés dans le navigateur par
  `duckdb-wasm` sur de petites tables (8 014 lignes en tout) ;
- les règles de périmètre sont écrites une fois, en SQL, au lieu d'être répétées (ou oubliées) dans
  chaque page et dans chaque requête de l'agent.

`mart_pokemon` sert de base aux autres marts : un Pokémon y a déjà son nom, sa génération, ses deux
types et ses statistiques, résolus une fois.

| Règle                                    | Où                                                 | Pourquoi                                                                                                                                                                                                                                                         |
| ---------------------------------------- | -------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Formes par défaut seulement              | Tous les marts agrégés (`is_default`)            | 1 351 Pokémon pour 1 025 espèces. Une méga-évolution a au moins 100 points de stats de plus que sa forme de base : toutes formes confondues, le total de stats moyen de la génération 6 passerait de 429,3 à 468,7. `mart_pokemon` garde toutes les formes, avec `is_default`. |
| Statistiques de base seulement           | `dim_stat.is_base_stat` (stats 1 à 6)            | Précision et esquive n'existent qu'en combat ; Spécial a été scindée en Attaque Spé. et Défense Spé. dès la génération 2.                                                                                                                                       |
| 18 types jouables                        | `dim_type.is_playable`                           | `unknown`, `shadow` et `stellar` ne sont le type d'aucun Pokémon : le filtre les retire des listes de types et des axes des graphiques.                                                                                                                         |
| Un double type compte dans chacun de ses types | `mart_pokemon_by_type`, `mart_stats_by_type` | Un Pokémon Feu/Vol est un Pokémon Feu et un Pokémon Vol. Conséquence assumée : la somme des `pokemon_count` (1 551) dépasse le nombre d'espèces de 526, le nombre d'espèces à double type. `primary_count` donne le décompte sans double compte.             |
| Médiane à côté de la moyenne             | `mart_stats_by_type`, `mart_stats_by_generation` | La distribution est asymétrique : premiers stades d'évolution d'un côté, légendaires et fabuleux (592 de total moyen) de l'autre. Sur les 1 025 espèces, le total de stats moyen est de 427,7 et le médian de 450. Minimum et maximum montrent les extrêmes.      |

`marts.duckdb` ne contient que les tables `mart_*`. Evidence et l'agent les lisent sous le nom
`marts.<nom>`.

| Source Evidence               | Grain                                               | Lignes | Contenu                                                                                                                                                  |
| ----------------------------- | --------------------------------------------------- | -----: | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `marts.pokemon`             | Un Pokémon, formes alternatives comprises          |  1 351 | Table large : génération, types, 6 statistiques et leur total, taille, poids, taux de capture, statut légendaire ou fabuleux, couleur, forme, habitat |
| `marts.stats_long`          | Un Pokémon × une statistique (formes par défaut) |  6 150 | Format long, pour les distributions par statistique                                                                                                      |
| `marts.pokemon_by_type`     | Un type (18 types jouables)                         |     18 | Nombre de Pokémon, en type principal ou secondaire, mono-type, légendaires ou fabuleux. Un double type compte dans chacun de ses types                 |
| `marts.stats_by_type`       | Un type × une statistique                          |    108 | Moyenne, médiane, minimum, maximum                                                                                                                      |
| `marts.stats_by_generation` | Une génération × une statistique                 |     54 | Moyenne, médiane, minimum, maximum                                                                                                                      |
| `marts.generation_summary`  | Une génération (9)                                |      9 | Nouvelles espèces, légendaires, fabuleux, total de stats moyen                                                                                         |
| `marts.type_matchups`       | Un type attaquant × un type défenseur (18 × 18)  |    324 | Multiplicateur de dégâts                                                                                                                               |

Le nombre de lignes de chaque mart se déduit de son grain, ce qui donne des contrôles de cohérence
simples, faits à la main sur le commit épinglé :

| Contrôle                                         | Attendu                                     | Obtenu                                |
| ------------------------------------------------ | ------------------------------------------- | ------------------------------------- |
| `mart_pokemon` filtré sur `is_default`       | Une ligne par espèce                        | 1 025 lignes, 1 025 espèces distinctes |
| `mart_stats_long`                              | 1 025 espèces × 6 statistiques              | 6 150                                 |
| `mart_stats_by_type`                           | 18 types × 6 statistiques                   | 108                                   |
| `mart_stats_by_generation`                     | 9 générations × 6 statistiques              | 54                                    |
| `mart_type_matchups`                           | 18 × 18                                     | 324                                   |
| Somme des `pokemon_count` de `mart_pokemon_by_type` | 1 025 espèces + 526 à double type      | 1 551                                 |

Le tableau de bord principal (`pages/index.md`) couvre les 1 025 espèces : indicateurs clés,
évolution par génération, répartition par type, carte de chaleur type × statistique, table des
affinités de types, top 15 des Pokémon les plus puissants et nuage attaque / défense. Le filtre par
génération s'applique aux indicateurs, à la répartition par type, au top 15 et au nuage ; les
autres graphiques couvrent toutes les générations.

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
| `write_page` | Écrit la page Markdown Evidence                         | Nom de page limité à `[a-z0-9_-]` (sauf `index`), écriture uniquement dans `dashboard/pages/generated/`, sans écraser la page d'une autre question. Les requêtes de la page sont réexécutées sur une base neuve, sans les tables que l'agent a pu créer ou modifier avec `run_sql`, et la page est refusée si l'une échoue ; celles qui dépendent d'un filtre ou d'une autre requête (`${...}`) ne sont pas vérifiées. |

La boucle s'arrête après 15 tours. Une requête ou une page refusée n'interrompt pas l'agent : le
message d'erreur lui est renvoyé pour qu'il corrige. Toute autre erreur (clé absente, API
injoignable, `marts.duckdb` manquant) devient la réponse affichée dans la page de chat, de même
que la raison de l'arrêt quand le modèle s'arrête sans texte (refus, limite de tokens atteinte).

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

## Limites et pistes d'amélioration

- **Chiffres écrits en dur** : les décomptes de ce README et de `index.md` (187 CSV, 1 025 espèces,
  9 générations) valent pour le commit de la PokeAPI épinglé dans `download_data.py` (`REF`).
  Passer à un commit plus récent oblige à les revoir.
- **Pas de tests de données** : les clés ne sont ni déclarées ni vérifiées après le build, et les
  contrôles de cohérence des marts sont faits à la main. Un cas le montre : `location_area_prose`
  (6 zones) et `move_effect_prose` (l'effet 443) ont deux libellés anglais pour un même
  identifiant, si bien que la jointure du nettoyage donne 6 lignes de trop dans
  `stg_location_areas` et 1 dans `stg_moves`, reportées dans `dim_location_area` et `dim_move`.
  Aucun mart n'en dépend aujourd'hui, mais un test d'unicité l'aurait signalé. Passer à dbt-duckdb
  donnerait des tests `unique` / `not_null` / `relationships` et un lineage.
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
