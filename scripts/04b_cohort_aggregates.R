# 04b_cohort_aggregates.R
# GP x birth-year cells over bridged electors: marriage status, natal presence
# (women listed under father; men as the coverage benchmark), and spousal gaps
# from the linked couples. Output carries treatment and FE ids from 03d.

library(here)
library(dplyr)
library(DBI)

source(here("scripts", "00_config.R"))
source(here("scripts", "00_utils.R"))

con <- get_duck()
on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

for (state in c("raj", "up")) {
    if (!file.exists(here("data", "bridge", sprintf("ps_treatment_%s.parquet", state))) ||
        !file.exists(here("data", "couples", state, ".linkage_complete"))) {
        message("Inputs not yet built, skipping: ", state)
        next
    }
    electors_glob <- here("data", "electors", state, "*", "*.parquet")
    couples_glob <- here("data", "couples", state, "*.parquet")
    ps_treat_path <- here("data", "bridge", sprintf("ps_treatment_%s.parquet", state))

    dbExecute(con, sprintf("CREATE OR REPLACE TEMP TABLE ps_treat AS
        SELECT filename, lgd_gp_code FROM read_parquet(%s)",
        dbQuoteString(con, ps_treat_path)))

    cells <- dbGetQuery(con, sprintf("
        WITH bridged AS (
            SELECT e.*, p.lgd_gp_code
            FROM read_parquet(%s, hive_partitioning = true) e
            JOIN ps_treat p USING (filename)
            WHERE e.birth_year IS NOT NULL AND e.sex_std IS NOT NULL
        )
        SELECT
            lgd_gp_code,
            birth_year,
            count(*) FILTER (sex_std = 'f') AS n_women,
            count(*) FILTER (sex_std = 'm') AS n_men,
            count(*) FILTER (sex_std = 'f' AND relation_type = 'husband') AS n_married_w,
            count(*) FILTER (sex_std = 'f' AND relation_type = 'father') AS n_natal_w_father,
            count(*) FILTER (sex_std = 'f' AND relation_type IN ('father', 'mother')) AS n_natal_w_fm,
            count(*) FILTER (sex_std = 'm' AND relation_type = 'father') AS n_natal_m_father,
            count(*) FILTER (sex_std = 'm' AND relation_type IN ('father', 'mother')) AS n_natal_m_fm
        FROM bridged
        GROUP BY lgd_gp_code, birth_year",
        dbQuoteString(con, electors_glob)))

    couple_cells <- dbGetQuery(con, sprintf("
        WITH couples_bridged AS (
            SELECT c.*, p.lgd_gp_code
            FROM read_parquet(%s) c
            JOIN ps_treat p USING (filename)
            WHERE c.wife_birth_year IS NOT NULL
        )
        SELECT
            lgd_gp_code,
            wife_birth_year AS birth_year,
            count(*) AS n_couples,
            avg(gap) AS mean_gap,
            median(gap) AS med_gap,
            avg(CASE WHEN gap >= 5 THEN 1.0 ELSE 0 END) AS share_gap_ge5,
            avg(CASE WHEN husband_contested THEN 1.0 ELSE 0 END) AS share_contested,
            count(*) FILTER (NOT husband_contested AND NOT gap_implausible) AS n_couples_clean,
            avg(gap) FILTER (NOT husband_contested AND NOT gap_implausible) AS mean_gap_clean
        FROM couples_bridged
        GROUP BY lgd_gp_code, wife_birth_year",
        dbQuoteString(con, couples_glob)))

    treat <- arrow::read_parquet(ps_treat_path) |>
        distinct(lgd_gp_code, treat_2005, treat_2010, treat_2015, count_treated,
                 fe_district, fe_dist_block)

    gp_cohort <- cells |>
        left_join(couple_cells, by = c("lgd_gp_code", "birth_year")) |>
        inner_join(treat, by = "lgd_gp_code") |>
        mutate(
            state = state,
            share_married_w = ifelse(n_women > 0, n_married_w / n_women, NA_real_),
            natal_share_w = ifelse(n_women > 0, n_natal_w_father / n_women, NA_real_),
            natal_share_w_fm = ifelse(n_women > 0, n_natal_w_fm / n_women, NA_real_),
            natal_ratio = ifelse(n_natal_m_father > 0,
                                 n_natal_w_father / n_natal_m_father, NA_real_)
        )

    arrow::write_parquet(gp_cohort,
        here("data", "cohorts", sprintf("gp_cohort_%s.parquet", state)))

    cell_sizes <- gp_cohort |>
        summarise(
            n_cells = n(),
            n_gps = n_distinct(lgd_gp_code),
            median_n_women = median(n_women),
            share_cells_ge5_women = mean(n_women >= 5),
            share_cells_with_couples = mean(!is.na(n_couples) & n_couples > 0)
        )
    write_audit(cell_sizes |> mutate(state = state),
                sprintf("04b_%s_cell_sizes.csv", state))

    sanity <- gp_cohort |>
        group_by(birth_year) |>
        summarise(
            n_women = sum(n_women), n_married_w = sum(n_married_w),
            share_married = n_married_w / n_women, .groups = "drop"
        )
    write_audit(sanity, sprintf("04b_%s_married_by_cohort.csv", state))

    message(sprintf("%s: %d GP x cohort cells, %d GPs",
                    state, nrow(gp_cohort), n_distinct(gp_cohort$lgd_gp_code)))
}

message("04b complete")
