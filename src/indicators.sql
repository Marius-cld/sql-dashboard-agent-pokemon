-- =============================================================================
-- indicators.sql — dashboard-ready marts built on the star schema of
-- src/models.sql.
--
-- Run from the repository root, after cleaning.sql and models.sql:
--     duckdb pokemon.duckdb < src/indicators.sql
--
-- Conventions
--   * mart_* tables are denormalised, one grain per table (stated above each).
--   * Scope: default forms only (dim_pokemon.is_default) unless the grain says
--     otherwise, so megas / regional forms do not double-count species.
--   * Stats: the 6 base stats only (dim_stat.is_base_stat).
-- =============================================================================


-- -----------------------------------------------------------------------------
-- mart_pokemon — grain: one row per Pokémon (incl. alternate forms).
-- Wide table used as the base for every other mart.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE mart_pokemon AS
SELECT
    p.pokemon_id,
    p.identifier,
    p.species_id,
    p.species_name,
    p.genus,
    p.is_default,
    p.is_alternate_form,
    p.generation_id,
    g.name            AS generation_name,
    t.type_1,
    t.type_2,
    st.hp, st.attack, st.defense, st.special_attack, st.special_defense, st.speed,
    st.base_stat_total,
    p.height_m,
    p.weight_kg,
    p.base_experience,
    p.capture_rate,
    p.is_legendary,
    p.is_mythical,
    p.is_baby,
    p.color,
    p.shape,
    p.habitat
FROM dim_pokemon p
LEFT JOIN dim_generation g           ON g.generation_id = p.generation_id
LEFT JOIN int_pokemon_types_pivoted t  ON t.pokemon_id = p.pokemon_id
LEFT JOIN int_pokemon_stats_pivoted st ON st.pokemon_id = p.pokemon_id;


-- -----------------------------------------------------------------------------
-- mart_stats_long — grain: one row per (Pokémon, base stat), default forms.
-- Long format for box plots / distributions per stat.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE mart_stats_long AS
SELECT
    mp.pokemon_id,
    mp.species_name,
    mp.generation_id,
    mp.generation_name,
    mp.type_1,
    mp.type_2,
    mp.is_legendary,
    mp.is_mythical,
    ds.stat_id,
    ds.identifier     AS stat_identifier,
    ds.name           AS stat_name,
    fs.base_stat,
    fs.effort
FROM fct_pokemon_stat fs
JOIN dim_stat ds     ON ds.stat_id = fs.stat_id AND ds.is_base_stat
JOIN mart_pokemon mp ON mp.pokemon_id = fs.pokemon_id AND mp.is_default;


-- -----------------------------------------------------------------------------
-- mart_pokemon_by_type — grain: one row per playable type.
-- A dual-type Pokémon counts once in each of its types.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE mart_pokemon_by_type AS
SELECT
    ty.type_id,
    ty.name                                              AS type_name,
    COUNT(DISTINCT bt.pokemon_id)                        AS pokemon_count,
    COUNT(DISTINCT bt.pokemon_id) FILTER (WHERE bt.slot = 1) AS primary_count,
    COUNT(DISTINCT bt.pokemon_id) FILTER (WHERE bt.slot = 2) AS secondary_count,
    COUNT(DISTINCT bt.pokemon_id) FILTER (
        WHERE NOT EXISTS (SELECT 1 FROM bridge_pokemon_type o
                          WHERE o.pokemon_id = bt.pokemon_id AND o.slot = 2)
    )                                                    AS mono_type_count,
    COUNT(DISTINCT bt.pokemon_id) FILTER (WHERE mp.is_legendary OR mp.is_mythical)
                                                         AS legendary_or_mythical_count
FROM dim_type ty
JOIN bridge_pokemon_type bt ON bt.type_id = ty.type_id
JOIN mart_pokemon mp        ON mp.pokemon_id = bt.pokemon_id AND mp.is_default
WHERE ty.is_playable
GROUP BY ty.type_id, ty.name
ORDER BY pokemon_count DESC;


-- -----------------------------------------------------------------------------
-- mart_stats_by_type — grain: one row per (playable type, base stat).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE mart_stats_by_type AS
SELECT
    ty.type_id,
    ty.name                          AS type_name,
    sl.stat_id,
    sl.stat_name,
    COUNT(*)                         AS pokemon_count,
    ROUND(AVG(sl.base_stat), 1)      AS avg_base_stat,
    MEDIAN(sl.base_stat)             AS median_base_stat,
    MIN(sl.base_stat)                AS min_base_stat,
    MAX(sl.base_stat)                AS max_base_stat
FROM mart_stats_long sl
JOIN bridge_pokemon_type bt ON bt.pokemon_id = sl.pokemon_id
JOIN dim_type ty            ON ty.type_id = bt.type_id AND ty.is_playable
GROUP BY ty.type_id, ty.name, sl.stat_id, sl.stat_name
ORDER BY ty.type_id, sl.stat_id;


-- -----------------------------------------------------------------------------
-- mart_stats_by_generation — grain: one row per (generation, base stat).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE mart_stats_by_generation AS
SELECT
    generation_id,
    generation_name,
    stat_id,
    stat_name,
    COUNT(*)                     AS pokemon_count,
    ROUND(AVG(base_stat), 1)     AS avg_base_stat,
    MEDIAN(base_stat)            AS median_base_stat,
    MIN(base_stat)               AS min_base_stat,
    MAX(base_stat)               AS max_base_stat
FROM mart_stats_long
GROUP BY generation_id, generation_name, stat_id, stat_name
ORDER BY generation_id, stat_id;


-- -----------------------------------------------------------------------------
-- mart_generation_summary — grain: one row per generation (default forms).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE mart_generation_summary AS
SELECT
    generation_id,
    generation_name,
    COUNT(*)                             AS species_count,
    COUNT(*) FILTER (WHERE is_legendary) AS legendary_count,
    COUNT(*) FILTER (WHERE is_mythical)  AS mythical_count,
    ROUND(AVG(base_stat_total), 1)       AS avg_base_stat_total
FROM mart_pokemon
WHERE is_default
GROUP BY generation_id, generation_name
ORDER BY generation_id;


-- -----------------------------------------------------------------------------
-- mart_type_matchups — grain: one row per (attacking type, defending type),
-- playable types only (18 x 18).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE mart_type_matchups AS
SELECT
    atk.name AS attacking_type,
    def.name AS defending_type,
    e.damage_factor,
    e.damage_multiplier
FROM fct_type_efficacy e
JOIN dim_type atk ON atk.type_id = e.damage_type_id AND atk.is_playable
JOIN dim_type def ON def.type_id = e.target_type_id AND def.is_playable;
