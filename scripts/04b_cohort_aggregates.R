library(here)
library(dplyr)
library(DBI)
source(here("scripts", "00_config.R"))
source(here("scripts", "00_utils.R"))
source(here("scripts", "00_sources.R"))
source(here("scripts", "receiving_helpers.R"))


for (state in c("raj", "up")) {
  message("Building receiving-family cells: ", state)
  con <- get_duck()
  bridge <- arrow::read_parquet(here("data", "bridge", paste0("ps_treatment_", state, ".parquet")))
  assert_unique(bridge, "filename")
  geography <- receiving_geography(state) |> semi_join(bridge, by = "lgd_gp_code")
  ambiguous <- geography |>
    count(lgd_gp_code) |>
    filter(n > 1)
  write_audit(ambiguous, paste0("receiving_", state, "_ambiguous_geography.csv"))
  bridge <- anti_join(bridge, ambiguous, by = "lgd_gp_code")
  gp <- bridge |>
    select(lgd_gp_code, starts_with("treat_"), fe_district, starts_with("pc01_")) |>
    distinct()
  assert_unique(gp, "lgd_gp_code")
  geography <- geography |> semi_join(gp, by = "lgd_gp_code")
  assert_unique(geography, "lgd_gp_code")
  gp <- left_join(gp, geography, by = "lgd_gp_code", relationship = "one-to-one")
  stopifnot(
    all(gp$treat_2005 == gp$source_treat_2005),
    all(gp$treat_2010 == gp$source_treat_2010)
  )
  dbWriteTable(con, "bridge", as.data.frame(bridge |> select(filename, lgd_gp_code)))
  epath <- here("data", "electors", state, "*", "*.parquet")
  input_files <- sort(Sys.glob(epath))
  write_audit(tibble(
    path = substring(input_files, nchar(here()) + 2),
    bytes = file.info(input_files)$size,
    sha256 = vapply(input_files, digest::digest, character(1), algo = "sha256", file = TRUE)
  ), paste0("receiving_", state, "_input_manifest.csv"))
  dbExecute(con, sprintf("CREATE VIEW elector_source AS SELECT * EXCLUDE(filename), filename || '' AS filename FROM read_parquet(%s,
    hive_partitioning=true, filename='parquet_path', file_row_number=true)", dbQuoteString(con, epath)))
  dbExecute(con, sprintf("CREATE VIEW electors AS SELECT * EXCLUDE(elector_uid, parquet_path, file_row_number),
    elector_uid AS legacy_uid, md5(%s || regexp_extract(parquet_path, 'district_part=.*') ||
    ':' || file_row_number::VARCHAR) AS elector_uid FROM elector_source", dbQuoteString(con, state)))
  # Concatenation keeps DuckDB's virtual-file filter from shadowing the stored roll filename.
  schema <- dbGetQuery(con, "DESCRIBE electors") |> mutate(state = state, source = "cleaned_electors")
  raw_path <- here("data", "rolls", state, "*", "*.parquet")
  dbExecute(con, sprintf(
    "CREATE VIEW raw_rolls AS SELECT * FROM read_parquet(%s, hive_partitioning=true)",
    dbQuoteString(con, raw_path)
  ))
  raw_schema <- dbGetQuery(con, "DESCRIBE raw_rolls") |> mutate(state = state, source = "ingested_rolls")
  write_audit(bind_rows(schema, raw_schema), paste0("receiving_", state, "_schema.csv"))
  years <- dbGetQuery(con, "SELECT year, count(*) AS n FROM raw_rolls GROUP BY year")
  write_audit(years, paste0("receiving_", state, "_years.csv"))
  if (nrow(years) != 1 || as.integer(years$year) != ROLL_YEAR[[state]]) stop("Unexpected roll vintages")

  profile <- dbGetQuery(con, "SELECT sex_std, age, relation_type, count(*) AS n,
    count(*) FILTER (house_no_clean IS NULL) AS n_missing_house
    FROM electors GROUP BY sex_std, age, relation_type")
  write_audit(profile, paste0("receiving_", state, "_record_profile.csv"))

  dbExecute(con, "CREATE TEMP TABLE men AS SELECT e.elector_uid, e.filename, e.age,
    e.birth_year, e.name_dev, b.lgd_gp_code FROM electors e JOIN bridge b USING(filename)
    WHERE e.sex_std = 'm'")
  duplicate_men <- dbGetQuery(con, "SELECT count(*) - count(DISTINCT elector_uid) AS n FROM men")$n
  if (duplicate_men != 0) stop("Duplicate male elector identifiers: ", duplicate_men)
  stage <- dbGetQuery(con, "SELECT lgd_gp_code, count(*) AS n_men_all,
    count(*) FILTER (age IS NULL) AS n_missing_age,
    count(*) FILTER (age BETWEEN 19 AND 39) AS n_men_primary
    FROM men GROUP BY lgd_gp_code")
  message(state, ": rebuilding spouse links with source-record identifiers")
  dbExecute(con, "CREATE TEMP TABLE women AS SELECT e.elector_uid, e.filename,
    e.house_no_clean, e.age, e.rel_name_dev, e.rel_name_std FROM electors e
    JOIN bridge b USING(filename) WHERE e.sex_std = 'f' AND e.relation_type = 'husband'
      AND e.house_no_clean IS NOT NULL")
  dbExecute(con, "CREATE TEMP TABLE male_candidates AS SELECT e.elector_uid, e.filename,
    e.house_no_clean, e.name_dev, e.name_std, e.age, e.birth_year FROM electors e
    JOIN bridge b USING(filename) WHERE e.sex_std = 'm' AND e.house_no_clean IS NOT NULL")
  dbExecute(con, sprintf("CREATE TEMP TABLE links AS
    WITH scores AS (
      SELECT w.elector_uid AS wife_uid, m.elector_uid AS husband_uid,
        m.age AS husband_age, m.birth_year, w.age AS wife_age,
        m.age - w.age AS gap,
        (trim(w.rel_name_dev) != '' AND w.rel_name_dev = m.name_dev) AS native_exact,
        CASE WHEN trim(w.rel_name_dev) != '' AND w.rel_name_dev = m.name_dev THEN 0.0
          ELSE 1 - jaro_similarity(w.rel_name_std, m.name_std) END AS distance
      FROM women w JOIN male_candidates m USING(filename, house_no_clean)
    ), ranked AS (
      SELECT *, row_number() OVER win AS rank,
        lead(distance) OVER win AS runner_up FROM scores WHERE distance IS NOT NULL
      WINDOW win AS (PARTITION BY wife_uid ORDER BY distance, husband_uid)
    ) SELECT * FROM ranked WHERE rank = 1 AND distance <= %.15f
      AND (runner_up IS NULL OR runner_up - distance >= %.15f)
      AND husband_age BETWEEN 19 AND 59", JW_HUSBAND, JW_HUSBAND_MARGIN))
  checks <- dbGetQuery(con, "SELECT count(*) AS n_links,
    count(DISTINCT wife_uid) AS n_unique_wives,
    count(*) FILTER (wife_age IS NULL) AS n_missing_wife_age FROM links")
  stopifnot(checks$n_links == checks$n_unique_wives)
  collision_audit <- dbGetQuery(con, "WITH grouped AS (
    SELECT e.legacy_uid, count(*) AS n FROM electors e JOIN bridge b USING(filename)
    GROUP BY e.legacy_uid HAVING count(*) > 1)
    SELECT count(*) AS n_collision_groups, coalesce(sum(n), 0) AS n_affected_records FROM grouped")
  write_audit(collision_audit, paste0("receiving_", state, "_legacy_uid_collisions.csv"))
  cells <- aggregate_male_cells(con)
  if (nrow(cells) == 0) stop("No male-cohort cells after bridge")
  expected_men <- dbGetQuery(con, "SELECT count(*) AS n FROM men WHERE age BETWEEN 19 AND 59")$n
  expected_linked <- dbGetQuery(con, "SELECT count(DISTINCT husband_uid) AS n FROM links")$n
  stopifnot(
    sum(cells$n_men) == expected_men, sum(cells$n_linked) == expected_linked,
    all(cells$n_linked <= cells$n_men), all(cells$n_gap <= cells$n_linked)
  )
  checks$n_men <- expected_men
  checks$n_distinct_linked <- expected_linked
  write_audit(checks, paste0("receiving_", state, "_join_checks.csv"))
  gaps <- dbGetQuery(con, "WITH unique_links AS (
    SELECT *, count(*) OVER(PARTITION BY husband_uid) AS n FROM links)
    SELECT husband_age, count(*) AS n_couples, avg(gap) AS mean_gap,
      median(gap) AS median_gap, quantile_cont(gap, 0.1) AS p10,
      quantile_cont(gap, 0.9) AS p90, avg((gap < 0)::INTEGER) AS share_negative
    FROM unique_links WHERE n = 1 AND gap IS NOT NULL GROUP BY husband_age")
  write_audit(gaps, paste0("receiving_", state, "_gap_by_age.csv"))
  pooled <- dbGetQuery(con, "WITH unique_links AS (
    SELECT *, count(*) OVER(PARTITION BY husband_uid) AS n FROM links)
    SELECT count(*) AS n_couples, avg(gap) AS mean_gap, median(gap) AS median_gap
    FROM unique_links WHERE n = 1 AND gap IS NOT NULL AND husband_age BETWEEN 19 AND 39")
  write_audit(pooled, paste0("receiving_", state, "_pooled_gap.csv"))
  natal <- dbGetQuery(con, "SELECT b.lgd_gp_code, e.birth_year, e.age,
    count(*) FILTER (sex_std = 'f' AND relation_type = 'father') AS n_parental_women,
    count(*) FILTER (sex_std = 'm' AND relation_type = 'father') AS n_parental_men,
    count(*) FILTER (sex_std = 'f' AND relation_type IN ('father', 'mother')) AS n_parental_women_fm,
    count(*) FILTER (sex_std = 'm' AND relation_type IN ('father', 'mother')) AS n_parental_men_fm
    FROM electors e JOIN bridge b USING(filename) WHERE e.age BETWEEN 19 AND 59
    GROUP BY b.lgd_gp_code, e.birth_year, e.age") |>
    mutate(
      parental_ratio = safe_ratio(n_parental_women, n_parental_men),
      parental_ratio_fm = safe_ratio(n_parental_women_fm, n_parental_men_fm)
    )
  cells <- left_join(cells, gp, by = "lgd_gp_code", relationship = "many-to-one")
  natal <- left_join(natal, gp, by = "lgd_gp_code", relationship = "many-to-one")
  stage <- gp |>
    left_join(stage, by = "lgd_gp_code", relationship = "one-to-one") |>
    left_join(
      cells |> filter(age <= 39) |> group_by(lgd_gp_code) |>
        summarise(n_linked_primary = sum(n_linked), n_gap_primary = sum(n_gap)),
      by = "lgd_gp_code", relationship = "one-to-one"
    )
  arrow::write_parquet(cells, here("data", "cohorts", paste0("receiving_", state, ".parquet")))
  arrow::write_parquet(natal, here("data", "cohorts", paste0("parental_", state, ".parquet")))
  arrow::write_parquet(stage, here("data", "cohorts", paste0("receiving_stages_", state, ".parquet")))
  dbDisconnect(con, shutdown = TRUE)
  message(state, ": wrote ", nrow(cells), " male-cohort cells")
}
