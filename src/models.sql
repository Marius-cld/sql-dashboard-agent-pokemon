-- =============================================================================
-- models.sql — Kimball star schema built on the stg_* tables of
-- src/cleaning.sql.
--
-- Run from the repository root, after cleaning.sql:
--     duckdb pokemon.duckdb < src/models.sql
--
-- Conventions
--   * dim_*     descriptive entities; small snowflake lookups (color, shape,
--               region, damage class, ...) are denormalised into them.
--   * fct_*     measures at a declared grain (stated above each table).
--   * bridge_*  many-to-many links between dimensions.
--   * int_*     intermediate reshapes reused by marts (src/indicators.sql).
--   * Natural ids are kept as keys (<entity>_id); no surrogate keys.
--   * Only entities used for analysis are modelled; the rest stays in stg_*.
-- =============================================================================


-- =============================================================================
-- DIMENSIONS
-- =============================================================================

CREATE OR REPLACE TABLE dim_generation AS
SELECT
    g.generation_id,
    g.identifier,
    g.name,
    g.main_region_id AS region_id,
    r.name           AS region_name
FROM stg_generations g
LEFT JOIN stg_regions r ON r.region_id = g.main_region_id;

CREATE OR REPLACE TABLE dim_version AS
SELECT
    v.version_id,
    v.identifier,
    v.name,
    v.version_group_id,
    vg.identifier    AS version_group_identifier,
    vg.sort_order    AS version_group_order,
    vg.generation_id
FROM stg_versions v
JOIN stg_version_groups vg ON vg.version_group_id = v.version_group_id;

CREATE OR REPLACE TABLE dim_type AS
SELECT
    t.type_id,
    t.identifier,
    t.name,
    t.generation_id,
    dc.name AS damage_class,
    t.is_playable
FROM stg_types t
LEFT JOIN stg_move_damage_classes dc ON dc.damage_class_id = t.damage_class_id;

CREATE OR REPLACE TABLE dim_stat AS
SELECT
    stat_id,
    identifier,
    name,
    is_battle_only,
    is_base_stat
FROM stg_stats;

-- One row per Pokémon (incl. alternate forms), species attributes denormalised.
CREATE OR REPLACE TABLE dim_pokemon AS
SELECT
    p.pokemon_id,
    p.identifier,
    p.species_id,
    s.name            AS species_name,
    s.genus,
    s.generation_id,
    p.is_default,
    p.is_alternate_form,
    p.height_m,
    p.weight_kg,
    p.base_experience,
    s.capture_rate,
    s.base_happiness,
    s.hatch_counter,
    s.gender_rate,
    s.is_genderless,
    s.female_ratio,
    s.is_baby,
    s.is_legendary,
    s.is_mythical,
    s.is_base_of_chain,
    s.evolves_from_species_id,
    s.evolution_chain_id,
    c.name            AS color,
    sh.name           AS shape,
    h.name            AS habitat,
    gr.name           AS growth_rate,
    p.sort_order
FROM stg_pokemon p
JOIN stg_pokemon_species s        ON s.species_id = p.species_id
LEFT JOIN stg_pokemon_colors c    ON c.color_id = s.color_id
LEFT JOIN stg_pokemon_shapes sh   ON sh.shape_id = s.shape_id
LEFT JOIN stg_pokemon_habitats h  ON h.habitat_id = s.habitat_id
LEFT JOIN stg_growth_rates gr     ON gr.growth_rate_id = s.growth_rate_id;

CREATE OR REPLACE TABLE dim_ability AS
SELECT
    ability_id,
    identifier,
    name,
    short_effect,
    generation_id,
    is_main_series
FROM stg_abilities;

CREATE OR REPLACE TABLE dim_egg_group AS
SELECT
    egg_group_id,
    identifier,
    name
FROM stg_egg_groups;

CREATE OR REPLACE TABLE dim_move AS
SELECT
    m.move_id,
    m.identifier,
    m.name,
    m.generation_id,
    m.type_id,
    t.name            AS type_name,
    dc.name           AS damage_class,
    m.power,
    m.pp,
    m.accuracy,
    m.priority,
    tg.name           AS target,
    mc.identifier     AS meta_category,
    ma.name           AS meta_ailment,
    m.effect_chance,
    m.short_effect
FROM stg_moves m
LEFT JOIN stg_types t                  ON t.type_id = m.type_id
LEFT JOIN stg_move_damage_classes dc   ON dc.damage_class_id = m.damage_class_id
LEFT JOIN stg_move_targets tg          ON tg.target_id = m.target_id
LEFT JOIN stg_move_meta mm             ON mm.move_id = m.move_id
LEFT JOIN stg_move_meta_categories mc  ON mc.meta_category_id = mm.meta_category_id
LEFT JOIN stg_move_meta_ailments ma    ON ma.meta_ailment_id = mm.meta_ailment_id;

CREATE OR REPLACE TABLE dim_move_method AS
SELECT
    move_method_id,
    identifier,
    name
FROM stg_pokemon_move_methods;

CREATE OR REPLACE TABLE dim_item AS
SELECT
    i.item_id,
    i.identifier,
    i.name,
    c.name   AS category,
    ip.name  AS pocket,
    i.cost,
    i.fling_power,
    i.short_effect
FROM stg_items i
LEFT JOIN stg_item_categories c ON c.category_id = i.category_id
LEFT JOIN stg_item_pockets ip   ON ip.pocket_id = c.pocket_id;

CREATE OR REPLACE TABLE dim_location_area AS
SELECT
    a.location_area_id,
    a.identifier,
    a.name,
    l.location_id,
    l.name   AS location_name,
    l.region_id,
    r.name   AS region_name
FROM stg_location_areas a
JOIN stg_locations l       ON l.location_id = a.location_id
LEFT JOIN stg_regions r    ON r.region_id = l.region_id;


-- =============================================================================
-- BRIDGES
-- =============================================================================

-- slot 1 = primary type, slot 2 = secondary type.
CREATE OR REPLACE TABLE bridge_pokemon_type AS
SELECT pokemon_id, type_id, slot
FROM stg_pokemon_types;

CREATE OR REPLACE TABLE bridge_pokemon_ability AS
SELECT pokemon_id, ability_id, slot, is_hidden
FROM stg_pokemon_abilities;

CREATE OR REPLACE TABLE bridge_species_egg_group AS
SELECT species_id, egg_group_id
FROM stg_pokemon_egg_groups;


-- =============================================================================
-- FACTS
-- =============================================================================

-- Grain: one row per (pokemon, stat). All 6 base stats.
CREATE OR REPLACE TABLE fct_pokemon_stat AS
SELECT pokemon_id, stat_id, base_stat, effort
FROM stg_pokemon_stats;

-- Grain: one row per (attacking type, defending type), current generation.
CREATE OR REPLACE TABLE fct_type_efficacy AS
SELECT damage_type_id, target_type_id, damage_factor, damage_multiplier
FROM stg_type_efficacy;

-- Grain: one row per (pokemon, version group, move, learn method, level).
CREATE OR REPLACE TABLE fct_pokemon_move AS
SELECT pokemon_id, version_group_id, move_id, move_method_id, level
FROM stg_pokemon_moves;

-- Grain: one row per encounter slot (version, area, pokemon, level range).
CREATE OR REPLACE TABLE fct_encounter AS
SELECT
    e.encounter_id,
    e.version_id,
    e.location_area_id,
    e.pokemon_id,
    es.encounter_method_id,
    em.name    AS encounter_method,
    es.rarity,
    e.min_level,
    e.max_level
FROM stg_encounters e
LEFT JOIN stg_encounter_slots es   ON es.encounter_slot_id = e.encounter_slot_id
LEFT JOIN stg_encounter_methods em ON em.encounter_method_id = es.encounter_method_id;

-- Grain: one row per evolution rule into evolved_species_id.
CREATE OR REPLACE TABLE fct_evolution AS
SELECT
    ev.evolution_id,
    s.evolves_from_species_id AS from_species_id,
    ev.evolved_species_id     AS to_species_id,
    s.evolution_chain_id,
    tr.name                   AS trigger,
    ev.minimum_level,
    ev.trigger_item_id,
    ev.held_item_id,
    ev.minimum_happiness,
    ev.time_of_day,
    ev.is_default
FROM stg_pokemon_evolution ev
JOIN stg_pokemon_species s         ON s.species_id = ev.evolved_species_id
LEFT JOIN stg_evolution_triggers tr ON tr.evolution_trigger_id = ev.evolution_trigger_id;


-- =============================================================================
-- INTERMEDIATE
-- =============================================================================

-- One row per Pokémon: type 1 / type 2 names side by side.
CREATE OR REPLACE TABLE int_pokemon_types_pivoted AS
SELECT
    bt.pokemon_id,
    MAX(CASE WHEN bt.slot = 1 THEN t.name END) AS type_1,
    MAX(CASE WHEN bt.slot = 2 THEN t.name END) AS type_2
FROM bridge_pokemon_type bt
JOIN dim_type t USING (type_id)
GROUP BY bt.pokemon_id;

-- One row per Pokémon: the 6 base stats as columns + total.
CREATE OR REPLACE TABLE int_pokemon_stats_pivoted AS
SELECT
    pokemon_id,
    MAX(CASE WHEN stat_id = 1 THEN base_stat END) AS hp,
    MAX(CASE WHEN stat_id = 2 THEN base_stat END) AS attack,
    MAX(CASE WHEN stat_id = 3 THEN base_stat END) AS defense,
    MAX(CASE WHEN stat_id = 4 THEN base_stat END) AS special_attack,
    MAX(CASE WHEN stat_id = 5 THEN base_stat END) AS special_defense,
    MAX(CASE WHEN stat_id = 6 THEN base_stat END) AS speed,
    SUM(base_stat) FILTER (WHERE stat_id BETWEEN 1 AND 6) AS base_stat_total
FROM fct_pokemon_stat
GROUP BY pokemon_id;
