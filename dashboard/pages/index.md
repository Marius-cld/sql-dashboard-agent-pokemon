---
title: Pokédex — Business Intelligence
---

Vue d'ensemble des 1 025 espèces Pokémon (formes par défaut), construite sur les tables `mart_*`.

```sql generations
select generation_id, generation_name
from marts.generation_summary
order by generation_id
```

<Dropdown data={generations} name=generation value=generation_name order=generation_id title="Génération">
    <DropdownOption value="%" valueLabel="Toutes les générations"/>
</Dropdown>

```sql kpis
select
    count(*)                                      as species,
    count(*) filter (where is_legendary)          as legendary,
    count(*) filter (where is_mythical)           as mythical,
    round(avg(base_stat_total), 1)                as avg_bst
from marts.pokemon
where is_default
  and generation_name like '${inputs.generation.value}'
```

<BigValue data={kpis} value=species title="Espèces"/>
<BigValue data={kpis} value=legendary title="Légendaires"/>
<BigValue data={kpis} value=mythical title="Fabuleux"/>
<BigValue data={kpis} value=avg_bst title="Total de stats moyen"/>

## Évolution par génération

```sql generation_summary
select * from marts.generation_summary order by generation_id
```

<Grid cols=2>
    <BarChart
        data={generation_summary}
        x=generation_name
        y=species_count
        sort=false
        title="Nouvelles espèces par génération"
    />
    <LineChart
        data={generation_summary}
        x=generation_name
        y=avg_base_stat_total
        sort=false
        markers=true
        yMin=380
        title="Total de stats moyen par génération"
    />
</Grid>

## Répartition par type

```sql types
select
    t.type_1 as type_name,
    count(*) as pokemon_count,
    count(*) filter (where t.type_2 is null) as mono_type_count,
    round(avg(t.base_stat_total), 1) as avg_bst
from (
    select type_1, type_2, base_stat_total, generation_name from marts.pokemon where is_default
    union all
    select type_2, type_1, base_stat_total, generation_name from marts.pokemon where is_default and type_2 is not null
) t
where t.generation_name like '${inputs.generation.value}'
group by t.type_1
order by pokemon_count desc
```

<Grid cols=2>
    <BarChart
        data={types}
        x=type_name
        y=pokemon_count
        swapXY=true
        title="Pokémon par type (un double type compte dans chaque type)"
    />
    <BarChart
        data={types}
        x=type_name
        y=avg_bst
        swapXY=true
        sort=true
        title="Total de stats moyen par type"
    />
</Grid>

## Profil de statistiques par type

```sql stats_by_type
select type_name, stat_name, stat_id, avg_base_stat
from marts.stats_by_type
order by stat_id
```

<Heatmap
    data={stats_by_type}
    x=stat_name
    y=type_name
    value=avg_base_stat
    title="Statistique de base moyenne (type × statistique)"
/>

## Table des affinités de types

```sql matchups
select attacking_type, defending_type, damage_multiplier
from marts.type_matchups
```

<Heatmap
    data={matchups}
    x=defending_type
    y=attacking_type
    value=damage_multiplier
    valueFmt="0.0x"
    colorScale={['#d73027', '#f7f7f7', '#1a9850']}
    min=0
    max=2
    title="Multiplicateur de dégâts (ligne = attaquant, colonne = défenseur)"
/>

## Top 15 des Pokémon les plus puissants

```sql top_pokemon
select
    species_name,
    generation_name,
    type_1,
    type_2,
    hp, attack, defense, special_attack, special_defense, speed,
    base_stat_total,
    case when is_legendary then 'Légendaire'
         when is_mythical  then 'Fabuleux'
         else '' end as status
from marts.pokemon
where is_default
  and generation_name like '${inputs.generation.value}'
order by base_stat_total desc
limit 15
```

<DataTable data={top_pokemon} rows=15>
    <Column id=species_name title="Pokémon"/>
    <Column id=generation_name title="Génération"/>
    <Column id=type_1 title="Type 1"/>
    <Column id=type_2 title="Type 2"/>
    <Column id=status title="Statut"/>
    <Column id=base_stat_total title="Total" contentType=colorscale/>
    <Column id=hp title="PV"/>
    <Column id=attack title="Att."/>
    <Column id=defense title="Déf."/>
    <Column id=special_attack title="Att. Spé."/>
    <Column id=special_defense title="Déf. Spé."/>
    <Column id=speed title="Vit."/>
</DataTable>

## Attaque vs Défense

```sql attack_defense
select species_name, type_1, attack, defense
from marts.pokemon
where is_default
  and generation_name like '${inputs.generation.value}'
```

<ScatterPlot
    data={attack_defense}
    x=attack
    y=defense
    series=type_1
    tooltipTitle=species_name
    title="Chaque point est une espèce, coloré par type principal"
/>
