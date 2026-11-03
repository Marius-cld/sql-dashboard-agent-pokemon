-- =============================================================================
-- cleaning.sql — load the PokeAPI CSV dump (data/raw/) into typed, cleaned
-- DuckDB tables for the dashboard.
--
-- Source description: docs/data_report.md
--
-- Run from the repository root:
--     duckdb pokemon.duckdb < src/cleaning.sql
--
-- Conventions
--   * Every CSV is read as VARCHAR (all_varchar = true) and cast explicitly,
--     so types never depend on DuckDB's sniffer (e.g. fully-empty columns).
--   * Files are comma-delimited UTF-8 with RFC-4180 quoting; some text fields
--     contain embedded newlines / form feeds — read_csv handles them.
--   * Empty strings -> NULL. 0/1 flags -> BOOLEAN.
--   * Localization: English only (language id 9). Name tables use
--     local_language_id; *_flavor_text and currency_names use language_id.
--     English names are joined into the entity tables, falling back to the
--     identifier when no English row exists.
--   * Column "order" is renamed sort_order (reserved word).
--   * No PRIMARY KEY constraints: composite keys in the report are unverified.
--   * Layering (dbt-style naming):
--       stg_*     this file — one table per source entity, typed and cleaned,
--                 English names joined in; source names are kept.
--       int_*, dim_*, fct_*, bridge_*   src/models.sql (star schema)
--       mart_*    src/indicators.sql (dashboard-ready aggregates)
--
-- Skipped (out of scope, see report "Skip"):
--   * conquest_*                       (Pokémon Conquest spin-off)
--   * contest_combos, contest_effects, contest_effect_prose, contest_types,
--     contest_type_names, super_contest_combos, super_contest_effects,
--     super_contest_effect_prose, berry_flavors (contest-type based)
--   * pokeathlon_stats, pokeathlon_stat_names, nature_pokeathlon_stats,
--     pokemon_form_pokeathlon_stats, pal_park, pal_park_areas,
--     pal_park_area_names
--   * *_game_indices (item, location, pokemon, type, pokemon_form_generations)
--   * item_flavor_summaries, move_flavor_summaries,
--     pokemon_species_flavor_summaries (empty files)
--   * evolution_variables, evolution_variable_prose
--   * *_changelog / *_changelog_prose, characteristics, characteristic_text,
--     language_names, currencies / currency_names, item_prices,
--     nature_battle_style_preferences, move_battle_styles(+prose),
--     pokemon_form_conditions, pokemon_form_triggers(+prose),
--     pokemon_form_flavor_text, pokemon_species_prose, item_flag*,
--     item_fling_effect*, move_flag*, encounter_condition*,
--     version_group_pokemon_move_methods, version_group_regions,
--     pokedex_version_groups, move_effects (its prose is joined from moves),
--     ability_flavor_text, item_flavor_text, move_flavor_text
--   * Non-English localization rows.
-- =============================================================================

SET VARIABLE raw_data = 'data/raw';

-- -----------------------------------------------------------------------------
-- Helper macros
-- -----------------------------------------------------------------------------
CREATE OR REPLACE MACRO as_int(x)  AS CAST(NULLIF(TRIM(x), '') AS INTEGER);
CREATE OR REPLACE MACRO as_bool(x) AS CAST(CAST(NULLIF(TRIM(x), '') AS INTEGER) AS BOOLEAN);
CREATE OR REPLACE MACRO as_text(x) AS NULLIF(TRIM(x), '');
-- Flavor / prose text: drop soft hyphens, collapse \n \f \r tabs and runs of spaces.
CREATE OR REPLACE MACRO clean_text(x) AS
    NULLIF(TRIM(regexp_replace(replace(x, chr(173), ''), '\s+', ' ', 'g')), '');


-- =============================================================================
-- 1. GAMES & REFERENCE (priority 1: generations, regions)
-- =============================================================================

CREATE OR REPLACE TABLE stg_languages AS
SELECT
    as_int(id)          AS language_id,
    as_text(iso639)     AS iso639,
    as_text(iso3166)    AS iso3166,
    as_text(identifier) AS identifier,
    as_bool(official)   AS is_official,
    as_int("order")     AS sort_order
FROM read_csv(getvariable('raw_data') || '/languages.csv',
              header = true, delim = ',', quote = '"', all_varchar = true);

CREATE OR REPLACE TABLE stg_regions AS
SELECT
    as_int(r.id)                          AS region_id,
    as_text(r.identifier)                 AS identifier,
    COALESCE(as_text(n.name), r.identifier) AS name
FROM read_csv(getvariable('raw_data') || '/regions.csv',
              header = true, delim = ',', quote = '"', all_varchar = true) r
LEFT JOIN read_csv(getvariable('raw_data') || '/region_names.csv',
              header = true, delim = ',', quote = '"', all_varchar = true) n
       ON n.region_id = r.id AND n.local_language_id = '9';

CREATE OR REPLACE TABLE stg_generations AS
SELECT
    as_int(g.id)                            AS generation_id,
    as_int(g.main_region_id)                AS main_region_id,
    as_text(g.identifier)                   AS identifier,
    COALESCE(as_text(n.name), g.identifier) AS name
FROM read_csv(getvariable('raw_data') || '/generations.csv',
              header = true, delim = ',', quote = '"', all_varchar = true) g
LEFT JOIN read_csv(getvariable('raw_data') || '/generation_names.csv',
              header = true, delim = ',', quote = '"', all_varchar = true) n
       ON n.generation_id = g.id AND n.local_language_id = '9';

CREATE OR REPLACE TABLE stg_version_groups AS
SELECT
    as_int(id)            AS version_group_id,
    as_text(identifier)   AS identifier,
    as_int(generation_id) AS generation_id,
    as_int("order")       AS sort_order
FROM read_csv(getvariable('raw_data') || '/version_groups.csv',
              header = true, delim = ',', quote = '"', all_varchar = true);

CREATE OR REPLACE TABLE stg_versions AS
SELECT
    as_int(v.id)                            AS version_id,
    as_int(v.version_group_id)              AS version_group_id,
    as_text(v.identifier)                   AS identifier,
    COALESCE(as_text(n.name), v.identifier) AS name
FROM read_csv(getvariable('raw_data') || '/versions.csv',
              header = true, delim = ',', quote = '"', all_varchar = true) v
LEFT JOIN read_csv(getvariable('raw_data') || '/version_names.csv',
              header = true, delim = ',', quote = '"', all_varchar = true) n
       ON n.version_id = v.id AND n.local_language_id = '9';


-- =============================================================================
-- 2. TYPES, STATS & NATURES (priority 1: types, stats, type_efficacy)
-- =============================================================================

CREATE OR REPLACE TABLE stg_move_damage_classes AS
SELECT
    as_int(d.id)                            AS damage_class_id,
    as_text(d.identifier)                   AS identifier,
    COALESCE(as_text(p.name), d.identifier) AS name,
    as_text(p.description)                  AS description
FROM read_csv(getvariable('raw_data') || '/move_damage_classes.csv',
              header = true, delim = ',', quote = '"', all_varchar = true) d
LEFT JOIN read_csv(getvariable('raw_data') || '/move_damage_class_prose.csv',
              header = true, delim = ',', quote = '"', all_varchar = true) p
       ON p.move_damage_class_id = d.id AND p.local_language_id = '9';

-- Includes 10001 unknown / 10002 shadow / 19 stellar: filter with is_playable.
CREATE OR REPLACE TABLE stg_types AS
SELECT
    as_int(t.id)                            AS type_id,
    as_text(t.identifier)                   AS identifier,
    COALESCE(as_text(n.name), t.identifier) AS name,
    as_int(t.generation_id)                 AS generation_id,
    as_int(t.damage_class_id)               AS damage_class_id,
    as_int(t.id) <= 18                      AS is_playable
FROM read_csv(getvariable('raw_data') || '/types.csv',
              header = true, delim = ',', quote = '"', all_varchar = true) t
LEFT JOIN read_csv(getvariable('raw_data') || '/type_names.csv',
              header = true, delim = ',', quote = '"', all_varchar = true) n
       ON n.type_id = t.id AND n.local_language_id = '9';

-- damage_factor is a percentage (0/50/100/200); multiplier = factor / 100.
CREATE OR REPLACE TABLE stg_type_efficacy AS
SELECT
    as_int(damage_type_id)                AS damage_type_id,
    as_int(target_type_id)                AS target_type_id,
    as_int(damage_factor)                 AS damage_factor,
    as_int(damage_factor) / 100.0         AS damage_multiplier
FROM read_csv(getvariable('raw_data') || '/type_efficacy.csv',
              header = true, delim = ',', quote = '"', all_varchar = true);

-- Stats 1-6 are base stats; 7-9 (accuracy, evasion, special) are not.
CREATE OR REPLACE TABLE stg_stats AS
SELECT
    as_int(s.id)                            AS stat_id,
    as_text(s.identifier)                   AS identifier,
    COALESCE(as_text(n.name), s.identifier) AS name,
    as_int(s.damage_class_id)               AS damage_class_id,
    as_bool(s.is_battle_only)               AS is_battle_only,
    as_int(s.game_index)                    AS game_index,
    as_int(s.id) BETWEEN 1 AND 6            AS is_base_stat
FROM read_csv(getvariable('raw_data') || '/stats.csv',
              header = true, delim = ',', quote = '"', all_varchar = true) s
LEFT JOIN read_csv(getvariable('raw_data') || '/stat_names.csv',
              header = true, delim = ',', quote = '"', all_varchar = true) n
       ON n.stat_id = s.id AND n.local_language_id = '9';

CREATE OR REPLACE TABLE stg_natures AS
SELECT
    as_int(na.id)                             AS nature_id,
    as_text(na.identifier)                    AS identifier,
    COALESCE(as_text(n.name), na.identifier)  AS name,
    as_int(na.increased_stat_id)              AS increased_stat_id,
    as_int(na.decreased_stat_id)              AS decreased_stat_id,
    as_int(na.likes_flavor_id)                AS likes_flavor_id,
    as_int(na.hates_flavor_id)                AS hates_flavor_id,
    as_int(na.game_index)                     AS game_index
FROM read_csv(getvariable('raw_data') || '/natures.csv',
              header = true, delim = ',', quote = '"', all_varchar = true) na
LEFT JOIN read_csv(getvariable('raw_data') || '/nature_names.csv',
              header = true, delim = ',', quote = '"', all_varchar = true) n
       ON n.nature_id = na.id AND n.local_language_id = '9';


-- =============================================================================
-- 3. POKÉMON CORE (priority 1: pokemon, species, types, stats, abilities)
-- =============================================================================

CREATE OR REPLACE TABLE stg_pokemon_colors AS
SELECT
    as_int(c.id)                            AS color_id,
    as_text(c.identifier)                   AS identifier,
    COALESCE(as_text(n.name), c.identifier) AS name
FROM read_csv(getvariable('raw_data') || '/pokemon_colors.csv',
              header = true, delim = ',', quote = '"', all_varchar = true) c
LEFT JOIN read_csv(getvariable('raw_data') || '/pokemon_color_names.csv',
              header = true, delim = ',', quote = '"', all_varchar = true) n
       ON n.pokemon_color_id = c.id AND n.local_language_id = '9';

CREATE OR REPLACE TABLE stg_pokemon_shapes AS
SELECT
    as_int(s.id)                            AS shape_id,
    as_text(s.identifier)                   AS identifier,
    COALESCE(as_text(p.name), s.identifier) AS name,
    as_text(p.awesome_name)                 AS awesome_name,
    as_text(p.description)                  AS description
FROM read_csv(getvariable('raw_data') || '/pokemon_shapes.csv',
              header = true, delim = ',', quote = '"', all_varchar = true) s
LEFT JOIN read_csv(getvariable('raw_data') || '/pokemon_shape_prose.csv',
              header = true, delim = ',', quote = '"', all_varchar = true) p
       ON p.pokemon_shape_id = s.id AND p.local_language_id = '9';

CREATE OR REPLACE TABLE stg_pokemon_habitats AS
SELECT
    as_int(h.id)                            AS habitat_id,
    as_text(h.identifier)                   AS identifier,
    COALESCE(as_text(n.name), h.identifier) AS name
FROM read_csv(getvariable('raw_data') || '/pokemon_habitats.csv',
              header = true, delim = ',', quote = '"', all_varchar = true) h
LEFT JOIN read_csv(getvariable('raw_data') || '/pokemon_habitat_names.csv',
              header = true, delim = ',', quote = '"', all_varchar = true) n
       ON n.pokemon_habitat_id = h.id AND n.local_language_id = '9';

CREATE OR REPLACE TABLE stg_growth_rates AS
SELECT
    as_int(g.id)                            AS growth_rate_id,
    as_text(g.identifier)                   AS identifier,
    COALESCE(as_text(p.name), g.identifier) AS name,
    clean_text(g.formula)                   AS formula
FROM read_csv(getvariable('raw_data') || '/growth_rates.csv',
              header = true, delim = ',', quote = '"', all_varchar = true) g
LEFT JOIN read_csv(getvariable('raw_data') || '/growth_rate_prose.csv',
              header = true, delim = ',', quote = '"', all_varchar = true) p
       ON p.growth_rate_id = g.id AND p.local_language_id = '9';

CREATE OR REPLACE TABLE stg_experience AS
SELECT
    as_int(growth_rate_id) AS growth_rate_id,
    as_int(level)          AS level,
    as_int(experience)     AS experience
FROM read_csv(getvariable('raw_data') || '/experience.csv',
              header = true, delim = ',', quote = '"', all_varchar = true);

CREATE OR REPLACE TABLE stg_egg_groups AS
SELECT
    as_int(e.id)                            AS egg_group_id,
    as_text(e.identifier)                   AS identifier,
    COALESCE(as_text(p.name), e.identifier) AS name
FROM read_csv(getvariable('raw_data') || '/egg_groups.csv',
              header = true, delim = ',', quote = '"', all_varchar = true) e
LEFT JOIN read_csv(getvariable('raw_data') || '/egg_group_prose.csv',
              header = true, delim = ',', quote = '"', all_varchar = true) p
       ON p.egg_group_id = e.id AND p.local_language_id = '9';

CREATE OR REPLACE TABLE stg_genders AS
SELECT
    as_int(id)          AS gender_id,
    as_text(identifier) AS identifier
FROM read_csv(getvariable('raw_data') || '/genders.csv',
              header = true, delim = ',', quote = '"', all_varchar = true);

-- gender_rate = eighths female, -1 = genderless.
CREATE OR REPLACE TABLE stg_pokemon_species AS
SELECT
    as_int(s.id)                             AS species_id,
    as_text(s.identifier)                    AS identifier,
    COALESCE(as_text(n.name), s.identifier)  AS name,
    as_text(n.genus)                         AS genus,
    as_int(s.generation_id)                  AS generation_id,
    as_int(s.evolves_from_species_id)        AS evolves_from_species_id,
    as_int(s.evolution_chain_id)             AS evolution_chain_id,
    as_int(s.color_id)                       AS color_id,
    as_int(s.shape_id)                       AS shape_id,
    as_int(s.habitat_id)                     AS habitat_id,
    as_int(s.gender_rate)                    AS gender_rate,
    as_int(s.gender_rate) = -1               AS is_genderless,
    CASE WHEN as_int(s.gender_rate) >= 0
         THEN as_int(s.gender_rate) / 8.0 END AS female_ratio,
    as_int(s.capture_rate)                   AS capture_rate,
    as_int(s.base_happiness)                 AS base_happiness,
    as_int(s.hatch_counter)                  AS hatch_counter,
    as_int(s.growth_rate_id)                 AS growth_rate_id,
    as_bool(s.is_baby)                       AS is_baby,
    as_bool(s.has_gender_differences)        AS has_gender_differences,
    as_bool(s.forms_switchable)              AS forms_switchable,
    as_bool(s.is_legendary)                  AS is_legendary,
    as_bool(s.is_mythical)                   AS is_mythical,
    as_int(s.evolves_from_species_id) IS NULL AS is_base_of_chain,
    as_int(s."order")                        AS sort_order
FROM read_csv(getvariable('raw_data') || '/pokemon_species.csv',
              header = true, delim = ',', quote = '"', all_varchar = true) s
LEFT JOIN read_csv(getvariable('raw_data') || '/pokemon_species_names.csv',
              header = true, delim = ',', quote = '"', all_varchar = true) n
       ON n.pokemon_species_id = s.id AND n.local_language_id = '9';

-- height: decimetres -> metres, weight: hectograms -> kg.
-- ids >= 10001 are alternate forms (megas, regionals, ...).
CREATE OR REPLACE TABLE stg_pokemon AS
SELECT
    as_int(p.id)                    AS pokemon_id,
    as_text(p.identifier)           AS identifier,
    as_int(p.species_id)            AS species_id,
    as_int(p.height) / 10.0         AS height_m,
    as_int(p.weight) / 10.0         AS weight_kg,
    as_int(p.base_experience)       AS base_experience,
    as_bool(p.is_default)           AS is_default,
    as_int(p.id) >= 10001           AS is_alternate_form,
    as_int(p."order")               AS sort_order
FROM read_csv(getvariable('raw_data') || '/pokemon.csv',
              header = true, delim = ',', quote = '"', all_varchar = true) p;

CREATE OR REPLACE TABLE stg_pokemon_types AS
SELECT
    as_int(pokemon_id) AS pokemon_id,
    as_int(type_id)    AS type_id,
    as_int(slot)       AS slot
FROM read_csv(getvariable('raw_data') || '/pokemon_types.csv',
              header = true, delim = ',', quote = '"', all_varchar = true);

CREATE OR REPLACE TABLE stg_pokemon_stats AS
SELECT
    as_int(pokemon_id) AS pokemon_id,
    as_int(stat_id)    AS stat_id,
    as_int(base_stat)  AS base_stat,
    as_int(effort)     AS effort
FROM read_csv(getvariable('raw_data') || '/pokemon_stats.csv',
              header = true, delim = ',', quote = '"', all_varchar = true);

CREATE OR REPLACE TABLE stg_pokemon_egg_groups AS
SELECT
    as_int(species_id)   AS species_id,
    as_int(egg_group_id) AS egg_group_id
FROM read_csv(getvariable('raw_data') || '/pokemon_egg_groups.csv',
              header = true, delim = ',', quote = '"', all_varchar = true);

CREATE OR REPLACE TABLE stg_pokemon_forms AS
SELECT
    as_int(f.id)                             AS form_id,
    as_text(f.identifier)                    AS identifier,
    as_text(f.form_identifier)               AS form_identifier,
    as_text(n.form_name)                     AS form_name,
    as_text(n.pokemon_name)                  AS pokemon_name,
    as_int(f.pokemon_id)                     AS pokemon_id,
    as_int(f.introduced_in_version_group_id) AS introduced_in_version_group_id,
    as_bool(f.is_default)                    AS is_default,
    as_bool(f.is_battle_only)                AS is_battle_only,
    as_bool(f.is_mega)                       AS is_mega,
    as_int(f.form_order)                     AS form_order,
    as_int(f."order")                        AS sort_order
FROM read_csv(getvariable('raw_data') || '/pokemon_forms.csv',
              header = true, delim = ',', quote = '"', all_varchar = true) f
LEFT JOIN read_csv(getvariable('raw_data') || '/pokemon_form_names.csv',
              header = true, delim = ',', quote = '"', all_varchar = true) n
       ON n.pokemon_form_id = f.id AND n.local_language_id = '9';

CREATE OR REPLACE TABLE stg_pokemon_form_types AS
SELECT
    as_int(pokemon_form_id) AS form_id,
    as_int(type_id)         AS type_id,
    as_int(slot)            AS slot
FROM read_csv(getvariable('raw_data') || '/pokemon_form_types.csv',
              header = true, delim = ',', quote = '"', all_varchar = true);

-- English Pokédex entries, one row per (species, version), text normalised.
CREATE OR REPLACE TABLE stg_pokemon_species_flavor_text AS
SELECT DISTINCT
    as_int(species_id)      AS species_id,
    as_int(version_id)      AS version_id,
    clean_text(flavor_text) AS flavor_text
FROM read_csv(getvariable('raw_data') || '/pokemon_species_flavor_text.csv',
              header = true, delim = ',', quote = '"', all_varchar = true)
WHERE language_id = '9'
QUALIFY row_number() OVER (PARTITION BY species_id, version_id ORDER BY flavor_text) = 1;


-- =============================================================================
-- 4. ABILITIES (priority 1)
-- =============================================================================

CREATE OR REPLACE TABLE stg_abilities AS
SELECT
    as_int(a.id)                            AS ability_id,
    as_text(a.identifier)                   AS identifier,
    COALESCE(as_text(n.name), a.identifier) AS name,
    clean_text(p.short_effect)              AS short_effect,
    as_int(a.generation_id)                 AS generation_id,
    as_bool(a.is_main_series)               AS is_main_series
FROM read_csv(getvariable('raw_data') || '/abilities.csv',
              header = true, delim = ',', quote = '"', all_varchar = true) a
LEFT JOIN read_csv(getvariable('raw_data') || '/ability_names.csv',
              header = true, delim = ',', quote = '"', all_varchar = true) n
       ON n.ability_id = a.id AND n.local_language_id = '9'
LEFT JOIN read_csv(getvariable('raw_data') || '/ability_prose.csv',
              header = true, delim = ',', quote = '"', all_varchar = true) p
       ON p.ability_id = a.id AND p.local_language_id = '9';

CREATE OR REPLACE TABLE stg_pokemon_abilities AS
SELECT
    as_int(pokemon_id) AS pokemon_id,
    as_int(ability_id) AS ability_id,
    as_bool(is_hidden) AS is_hidden,
    as_int(slot)       AS slot
FROM read_csv(getvariable('raw_data') || '/pokemon_abilities.csv',
              header = true, delim = ',', quote = '"', all_varchar = true);


-- =============================================================================
-- 5. MOVES (priority 2 / 3)
-- =============================================================================

CREATE OR REPLACE TABLE stg_move_targets AS
SELECT
    as_int(t.id)                            AS target_id,
    as_text(t.identifier)                   AS identifier,
    COALESCE(as_text(p.name), t.identifier) AS name,
    as_text(p.description)                  AS description
FROM read_csv(getvariable('raw_data') || '/move_targets.csv',
              header = true, delim = ',', quote = '"', all_varchar = true) t
LEFT JOIN read_csv(getvariable('raw_data') || '/move_target_prose.csv',
              header = true, delim = ',', quote = '"', all_varchar = true) p
       ON p.move_target_id = t.id AND p.local_language_id = '9';

CREATE OR REPLACE TABLE stg_pokemon_move_methods AS
SELECT
    as_int(m.id)                            AS move_method_id,
    as_text(m.identifier)                   AS identifier,
    COALESCE(as_text(p.name), m.identifier) AS name,
    as_text(p.description)                  AS description
FROM read_csv(getvariable('raw_data') || '/pokemon_move_methods.csv',
              header = true, delim = ',', quote = '"', all_varchar = true) m
LEFT JOIN read_csv(getvariable('raw_data') || '/pokemon_move_method_prose.csv',
              header = true, delim = ',', quote = '"', all_varchar = true) p
       ON p.pokemon_move_method_id = m.id AND p.local_language_id = '9';

-- power / accuracy NULL is meaningful (status move / never misses): not zero-filled.
CREATE OR REPLACE TABLE stg_moves AS
SELECT
    as_int(m.id)                            AS move_id,
    as_text(m.identifier)                   AS identifier,
    COALESCE(as_text(n.name), m.identifier) AS name,
    as_int(m.generation_id)                 AS generation_id,
    as_int(m.type_id)                       AS type_id,
    as_int(m.damage_class_id)               AS damage_class_id,
    as_int(m.power)                         AS power,
    as_int(m.pp)                            AS pp,
    as_int(m.accuracy)                      AS accuracy,
    as_int(m.priority)                      AS priority,
    as_int(m.target_id)                     AS target_id,
    as_int(m.effect_id)                     AS effect_id,
    as_int(m.effect_chance)                 AS effect_chance,
    clean_text(replace(p.short_effect, '$effect_chance', COALESCE(m.effect_chance, '')))
                                            AS short_effect
FROM read_csv(getvariable('raw_data') || '/moves.csv',
              header = true, delim = ',', quote = '"', all_varchar = true) m
LEFT JOIN read_csv(getvariable('raw_data') || '/move_names.csv',
              header = true, delim = ',', quote = '"', all_varchar = true) n
       ON n.move_id = m.id AND n.local_language_id = '9'
LEFT JOIN read_csv(getvariable('raw_data') || '/move_effect_prose.csv',
              header = true, delim = ',', quote = '"', all_varchar = true) p
       ON p.move_effect_id = m.effect_id AND p.local_language_id = '9';

-- 638k rows: filter on version_group_id in queries.
CREATE OR REPLACE TABLE stg_pokemon_moves AS
SELECT
    as_int(pokemon_id)             AS pokemon_id,
    as_int(version_group_id)       AS version_group_id,
    as_int(move_id)                AS move_id,
    as_int(pokemon_move_method_id) AS move_method_id,
    as_int(level)                  AS level,
    as_int("order")                AS sort_order,
    as_int(mastery)                AS mastery
FROM read_csv(getvariable('raw_data') || '/pokemon_moves.csv',
              header = true, delim = ',', quote = '"', all_varchar = true);

CREATE OR REPLACE TABLE stg_move_meta_categories AS
SELECT
    as_int(c.id)           AS meta_category_id,
    as_text(c.identifier)  AS identifier,
    as_text(p.description) AS description
FROM read_csv(getvariable('raw_data') || '/move_meta_categories.csv',
              header = true, delim = ',', quote = '"', all_varchar = true) c
LEFT JOIN read_csv(getvariable('raw_data') || '/move_meta_category_prose.csv',
              header = true, delim = ',', quote = '"', all_varchar = true) p
       ON p.move_meta_category_id = c.id AND p.local_language_id = '9';

CREATE OR REPLACE TABLE stg_move_meta_ailments AS
SELECT
    as_int(a.id)                            AS meta_ailment_id,
    as_text(a.identifier)                   AS identifier,
    COALESCE(as_text(n.name), a.identifier) AS name
FROM read_csv(getvariable('raw_data') || '/move_meta_ailments.csv',
              header = true, delim = ',', quote = '"', all_varchar = true) a
LEFT JOIN read_csv(getvariable('raw_data') || '/move_meta_ailment_names.csv',
              header = true, delim = ',', quote = '"', all_varchar = true) n
       ON n.move_meta_ailment_id = a.id AND n.local_language_id = '9';

CREATE OR REPLACE TABLE stg_move_meta AS
SELECT
    as_int(move_id)          AS move_id,
    as_int(meta_category_id) AS meta_category_id,
    as_int(meta_ailment_id)  AS meta_ailment_id,
    as_int(min_hits)         AS min_hits,
    as_int(max_hits)         AS max_hits,
    as_int(min_turns)        AS min_turns,
    as_int(max_turns)        AS max_turns,
    as_int(drain)            AS drain,
    as_int(healing)          AS healing,
    as_int(crit_rate)        AS crit_rate,
    as_int(ailment_chance)   AS ailment_chance,
    as_int(flinch_chance)    AS flinch_chance,
    as_int(stat_chance)      AS stat_chance
FROM read_csv(getvariable('raw_data') || '/move_meta.csv',
              header = true, delim = ',', quote = '"', all_varchar = true);

CREATE OR REPLACE TABLE stg_move_meta_stat_changes AS
SELECT
    as_int(move_id) AS move_id,
    as_int(stat_id) AS stat_id,
    as_int(change)  AS change
FROM read_csv(getvariable('raw_data') || '/move_meta_stat_changes.csv',
              header = true, delim = ',', quote = '"', all_varchar = true);

CREATE OR REPLACE TABLE stg_machines AS
SELECT
    as_int(machine_number)   AS machine_number,
    as_int(version_group_id) AS version_group_id,
    as_int(item_id)          AS item_id,
    as_int(move_id)          AS move_id
FROM read_csv(getvariable('raw_data') || '/machines.csv',
              header = true, delim = ',', quote = '"', all_varchar = true);


-- =============================================================================
-- 6. EVOLUTION (priority 2)
-- =============================================================================

CREATE OR REPLACE TABLE stg_evolution_chains AS
SELECT
    as_int(id)                   AS evolution_chain_id,
    as_int(baby_trigger_item_id) AS baby_trigger_item_id
FROM read_csv(getvariable('raw_data') || '/evolution_chains.csv',
              header = true, delim = ',', quote = '"', all_varchar = true);

CREATE OR REPLACE TABLE stg_evolution_triggers AS
SELECT
    as_int(t.id)                            AS evolution_trigger_id,
    as_text(t.identifier)                   AS identifier,
    COALESCE(as_text(p.name), t.identifier) AS name
FROM read_csv(getvariable('raw_data') || '/evolution_triggers.csv',
              header = true, delim = ',', quote = '"', all_varchar = true) t
LEFT JOIN read_csv(getvariable('raw_data') || '/evolution_trigger_prose.csv',
              header = true, delim = ',', quote = '"', all_varchar = true) p
       ON p.evolution_trigger_id = t.id AND p.local_language_id = '9';

CREATE OR REPLACE TABLE stg_pokemon_evolution AS
SELECT
    as_int(id)                       AS evolution_id,
    as_int(evolved_species_id)       AS evolved_species_id,
    as_int(evolution_trigger_id)     AS evolution_trigger_id,
    as_int(version_group_id)         AS version_group_id,
    as_bool(is_default)              AS is_default,
    as_int(trigger_item_id)          AS trigger_item_id,
    as_int(minimum_level)            AS minimum_level,
    as_int(gender_id)                AS gender_id,
    as_int(location_id)              AS location_id,
    as_int(held_item_id)             AS held_item_id,
    as_text(time_of_day)             AS time_of_day,
    as_int(known_move_id)            AS known_move_id,
    as_int(known_move_type_id)       AS known_move_type_id,
    as_int(minimum_happiness)        AS minimum_happiness,
    as_int(minimum_beauty)           AS minimum_beauty,
    as_int(minimum_affection)        AS minimum_affection,
    as_int(relative_physical_stats)  AS relative_physical_stats,
    as_int(party_species_id)         AS party_species_id,
    as_int(party_type_id)            AS party_type_id,
    as_int(trade_species_id)         AS trade_species_id,
    as_bool(needs_overworld_rain)    AS needs_overworld_rain,
    as_bool(turn_upside_down)        AS turn_upside_down,
    as_bool(needs_multiplayer)       AS needs_multiplayer,
    as_bool(near_special_rock)       AS near_special_rock,
    as_int(region_id)                AS region_id,
    as_int(required_pokemon_form_id) AS required_pokemon_form_id,
    as_int(evolved_pokemon_form_id)  AS evolved_pokemon_form_id,
    as_int(used_move_id)             AS used_move_id,
    as_int(minimum_move_count)       AS minimum_move_count,
    as_int(minimum_steps)            AS minimum_steps,
    as_int(minimum_damage_taken)     AS minimum_damage_taken,
    as_int(nature_bitmask)           AS nature_bitmask,
    as_text(condition_expression)    AS condition_expression,
    as_int(percentage_chance)        AS percentage_chance
FROM read_csv(getvariable('raw_data') || '/pokemon_evolution.csv',
              header = true, delim = ',', quote = '"', all_varchar = true);


-- =============================================================================
-- 7. ITEMS & BERRIES (priority 2 / 3)
-- =============================================================================

CREATE OR REPLACE TABLE stg_item_pockets AS
SELECT
    as_int(ip.id)                             AS pocket_id,
    as_text(ip.identifier)                    AS identifier,
    COALESCE(as_text(n.name), ip.identifier)  AS name
FROM read_csv(getvariable('raw_data') || '/item_pockets.csv',
              header = true, delim = ',', quote = '"', all_varchar = true) ip
LEFT JOIN read_csv(getvariable('raw_data') || '/item_pocket_names.csv',
              header = true, delim = ',', quote = '"', all_varchar = true) n
       ON n.item_pocket_id = ip.id AND n.local_language_id = '9';

CREATE OR REPLACE TABLE stg_item_categories AS
SELECT
    as_int(c.id)                            AS category_id,
    as_int(c.pocket_id)                     AS pocket_id,
    as_text(c.identifier)                   AS identifier,
    COALESCE(as_text(p.name), c.identifier) AS name
FROM read_csv(getvariable('raw_data') || '/item_categories.csv',
              header = true, delim = ',', quote = '"', all_varchar = true) c
LEFT JOIN read_csv(getvariable('raw_data') || '/item_category_prose.csv',
              header = true, delim = ',', quote = '"', all_varchar = true) p
       ON p.item_category_id = c.id AND p.local_language_id = '9';

CREATE OR REPLACE TABLE stg_items AS
SELECT
    as_int(i.id)                            AS item_id,
    as_text(i.identifier)                   AS identifier,
    COALESCE(as_text(n.name), i.identifier) AS name,
    as_int(i.category_id)                   AS category_id,
    as_int(i.cost)                          AS cost,
    as_int(i.fling_power)                   AS fling_power,
    as_int(i.fling_effect_id)               AS fling_effect_id,
    clean_text(p.short_effect)              AS short_effect
FROM read_csv(getvariable('raw_data') || '/items.csv',
              header = true, delim = ',', quote = '"', all_varchar = true) i
LEFT JOIN read_csv(getvariable('raw_data') || '/item_names.csv',
              header = true, delim = ',', quote = '"', all_varchar = true) n
       ON n.item_id = i.id AND n.local_language_id = '9'
LEFT JOIN read_csv(getvariable('raw_data') || '/item_prose.csv',
              header = true, delim = ',', quote = '"', all_varchar = true) p
       ON p.item_id = i.id AND p.local_language_id = '9';

CREATE OR REPLACE TABLE stg_berry_firmness AS
SELECT
    as_int(b.id)                            AS firmness_id,
    as_text(b.identifier)                   AS identifier,
    COALESCE(as_text(n.name), b.identifier) AS name
FROM read_csv(getvariable('raw_data') || '/berry_firmness.csv',
              header = true, delim = ',', quote = '"', all_varchar = true) b
LEFT JOIN read_csv(getvariable('raw_data') || '/berry_firmness_names.csv',
              header = true, delim = ',', quote = '"', all_varchar = true) n
       ON n.berry_firmness_id = b.id AND n.local_language_id = '9';

CREATE OR REPLACE TABLE stg_berries AS
SELECT
    as_int(id)                   AS berry_id,
    as_int(item_id)              AS item_id,
    as_int(firmness_id)          AS firmness_id,
    as_int(natural_gift_power)   AS natural_gift_power,
    as_int(natural_gift_type_id) AS natural_gift_type_id,
    as_int(size)                 AS size_mm,
    as_int(max_harvest)          AS max_harvest,
    as_int(growth_time)          AS growth_time,
    as_int(soil_dryness)         AS soil_dryness,
    as_int(smoothness)           AS smoothness
FROM read_csv(getvariable('raw_data') || '/berries.csv',
              header = true, delim = ',', quote = '"', all_varchar = true);

CREATE OR REPLACE TABLE stg_pokemon_items AS
SELECT
    as_int(pokemon_id) AS pokemon_id,
    as_int(version_id) AS version_id,
    as_int(item_id)    AS item_id,
    as_int(rarity)     AS rarity
FROM read_csv(getvariable('raw_data') || '/pokemon_items.csv',
              header = true, delim = ',', quote = '"', all_varchar = true);


-- =============================================================================
-- 8. ENCOUNTERS & LOCATIONS (priority 3)
-- =============================================================================

CREATE OR REPLACE TABLE stg_locations AS
SELECT
    as_int(l.id)                            AS location_id,
    as_int(l.region_id)                     AS region_id,
    as_text(l.identifier)                   AS identifier,
    COALESCE(as_text(n.name), l.identifier) AS name,
    as_text(n.subtitle)                     AS subtitle
FROM read_csv(getvariable('raw_data') || '/locations.csv',
              header = true, delim = ',', quote = '"', all_varchar = true) l
LEFT JOIN read_csv(getvariable('raw_data') || '/location_names.csv',
              header = true, delim = ',', quote = '"', all_varchar = true) n
       ON n.location_id = l.id AND n.local_language_id = '9';

CREATE OR REPLACE TABLE stg_location_areas AS
SELECT
    as_int(a.id)                            AS location_area_id,
    as_int(a.location_id)                   AS location_id,
    as_int(a.game_index)                    AS game_index,
    as_text(a.identifier)                   AS identifier,
    COALESCE(as_text(p.name), as_text(a.identifier)) AS name
FROM read_csv(getvariable('raw_data') || '/location_areas.csv',
              header = true, delim = ',', quote = '"', all_varchar = true) a
LEFT JOIN read_csv(getvariable('raw_data') || '/location_area_prose.csv',
              header = true, delim = ',', quote = '"', all_varchar = true) p
       ON p.location_area_id = a.id AND p.local_language_id = '9';

CREATE OR REPLACE TABLE stg_encounter_methods AS
SELECT
    as_int(m.id)                            AS encounter_method_id,
    as_text(m.identifier)                   AS identifier,
    COALESCE(as_text(p.name), m.identifier) AS name,
    as_int(m."order")                       AS sort_order
FROM read_csv(getvariable('raw_data') || '/encounter_methods.csv',
              header = true, delim = ',', quote = '"', all_varchar = true) m
LEFT JOIN read_csv(getvariable('raw_data') || '/encounter_method_prose.csv',
              header = true, delim = ',', quote = '"', all_varchar = true) p
       ON p.encounter_method_id = m.id AND p.local_language_id = '9';

CREATE OR REPLACE TABLE stg_encounter_slots AS
SELECT
    as_int(id)                  AS encounter_slot_id,
    as_int(version_group_id)    AS version_group_id,
    as_int(encounter_method_id) AS encounter_method_id,
    as_int(slot)                AS slot,
    as_int(rarity)              AS rarity
FROM read_csv(getvariable('raw_data') || '/encounter_slots.csv',
              header = true, delim = ',', quote = '"', all_varchar = true);

CREATE OR REPLACE TABLE stg_encounters AS
SELECT
    as_int(id)                AS encounter_id,
    as_int(version_id)        AS version_id,
    as_int(location_area_id)  AS location_area_id,
    as_int(encounter_slot_id) AS encounter_slot_id,
    as_int(pokemon_id)        AS pokemon_id,
    as_int(min_level)         AS min_level,
    as_int(max_level)         AS max_level
FROM read_csv(getvariable('raw_data') || '/encounters.csv',
              header = true, delim = ',', quote = '"', all_varchar = true);

-- min_perfect_ivs is entirely empty in the dump: cast explicitly.
CREATE OR REPLACE TABLE stg_encounter_pokemon_details AS
SELECT
    as_int(encounter_id)    AS encounter_id,
    as_int(min_perfect_ivs) AS min_perfect_ivs,
    as_bool(always_shiny)   AS always_shiny,
    as_bool(never_shiny)    AS never_shiny,
    as_bool(is_alpha)       AS is_alpha
FROM read_csv(getvariable('raw_data') || '/encounter_pokemon_details.csv',
              header = true, delim = ',', quote = '"', all_varchar = true);

CREATE OR REPLACE TABLE stg_location_area_encounter_rates AS
SELECT
    as_int(location_area_id)    AS location_area_id,
    as_int(encounter_method_id) AS encounter_method_id,
    as_int(version_id)          AS version_id,
    as_int(rate)                AS rate
FROM read_csv(getvariable('raw_data') || '/location_area_encounter_rates.csv',
              header = true, delim = ',', quote = '"', all_varchar = true);


-- =============================================================================
-- 9. POKÉDEXES (priority 3)
-- =============================================================================

CREATE OR REPLACE TABLE stg_pokedexes AS
SELECT
    as_int(d.id)                            AS pokedex_id,
    as_int(d.region_id)                     AS region_id,
    as_text(d.identifier)                   AS identifier,
    COALESCE(as_text(p.name), d.identifier) AS name,
    as_text(p.description)                  AS description,
    as_bool(d.is_main_series)               AS is_main_series
FROM read_csv(getvariable('raw_data') || '/pokedexes.csv',
              header = true, delim = ',', quote = '"', all_varchar = true) d
LEFT JOIN read_csv(getvariable('raw_data') || '/pokedex_prose.csv',
              header = true, delim = ',', quote = '"', all_varchar = true) p
       ON p.pokedex_id = d.id AND p.local_language_id = '9';

CREATE OR REPLACE TABLE stg_pokemon_dex_numbers AS
SELECT
    as_int(species_id)     AS species_id,
    as_int(pokedex_id)     AS pokedex_id,
    as_int(pokedex_number) AS pokedex_number
FROM read_csv(getvariable('raw_data') || '/pokemon_dex_numbers.csv',
              header = true, delim = ',', quote = '"', all_varchar = true);


-- =============================================================================
-- 10. HISTORY (priority 3: per-generation accuracy)
-- =============================================================================

CREATE OR REPLACE TABLE stg_pokemon_types_past AS
SELECT
    as_int(pokemon_id)    AS pokemon_id,
    as_int(generation_id) AS generation_id,
    as_int(type_id)       AS type_id,
    as_int(slot)          AS slot
FROM read_csv(getvariable('raw_data') || '/pokemon_types_past.csv',
              header = true, delim = ',', quote = '"', all_varchar = true);

CREATE OR REPLACE TABLE stg_pokemon_stats_past AS
SELECT
    as_int(pokemon_id)    AS pokemon_id,
    as_int(generation_id) AS generation_id,
    as_int(stat_id)       AS stat_id,
    as_int(base_stat)     AS base_stat,
    as_int(effort)        AS effort
FROM read_csv(getvariable('raw_data') || '/pokemon_stats_past.csv',
              header = true, delim = ',', quote = '"', all_varchar = true);

CREATE OR REPLACE TABLE stg_pokemon_abilities_past AS
SELECT
    as_int(pokemon_id)    AS pokemon_id,
    as_int(generation_id) AS generation_id,
    as_int(ability_id)    AS ability_id,
    as_bool(is_hidden)    AS is_hidden,
    as_int(slot)          AS slot
FROM read_csv(getvariable('raw_data') || '/pokemon_abilities_past.csv',
              header = true, delim = ',', quote = '"', all_varchar = true);

CREATE OR REPLACE TABLE stg_type_efficacy_past AS
SELECT
    as_int(damage_type_id) AS damage_type_id,
    as_int(target_type_id) AS target_type_id,
    as_int(damage_factor)  AS damage_factor,
    as_int(generation_id)  AS generation_id
FROM read_csv(getvariable('raw_data') || '/type_efficacy_past.csv',
              header = true, delim = ',', quote = '"', all_varchar = true);
