library(dplyr)

safe_ratio <- function(numerator, denominator) {
  ifelse(is.finite(denominator) & denominator > 0, numerator / denominator, NA_real_)
}

assert_unique <- function(data, key) {
  if (anyNA(data[[key]]) || anyDuplicated(data[[key]])) {
    stop("Missing or duplicate key: ", key)
  }
  invisible(data)
}

receiving_age_band <- function(age) {
  cut(age, c(18, 24, 29, 39, 59), labels = c("19-24", "25-29", "30-39", "40-59"))
}

childhood_dose <- function(birth_year, assignments, cycles, window = c(5, 15)) {
  dose <- rep(0, length(birth_year))
  for (wave in names(cycles)) {
    start <- cycles[[wave]][1]
    end <- cycles[[wave]][2]
    overlap <- pmax(0, pmin(birth_year + window[2], end - 1) -
      pmax(birth_year + window[1], start) + 1)
    contribution <- assignments[[paste0("treat_", wave)]] * overlap / (end - start)
    contribution[overlap == 0] <- 0
    dose <- dose + contribution
  }
  dose
}

aggregate_male_cells <- function(con) {
  DBI::dbGetQuery(con, "
    WITH link_counts AS (
      SELECT husband_uid, count(*) AS n_links,
        bool_or(native_exact) AS any_exact,
        first(gap) AS gap, first(wife_age) AS wife_age,
        first(native_exact) AS native_exact
      FROM links GROUP BY husband_uid
    )
    SELECT m.lgd_gp_code, m.birth_year, m.age, count(*) AS n_men,
      count(*) FILTER (l.n_links > 0) AS n_linked,
      count(*) FILTER (l.any_exact) AS n_linked_exact,
      count(*) FILTER (l.n_links > 1) AS n_contested,
      count(*) FILTER (l.n_links = 1 AND l.gap IS NOT NULL) AS n_gap,
      avg(l.gap) FILTER (l.n_links = 1) AS mean_gap,
      median(l.gap) FILTER (l.n_links = 1) AS median_gap,
      avg(l.wife_age) FILTER (l.n_links = 1) AS mean_wife_age,
      count(*) FILTER (l.n_links = 1 AND l.native_exact AND l.gap IS NOT NULL) AS n_gap_exact,
      avg(l.gap) FILTER (l.n_links = 1 AND l.native_exact) AS mean_gap_exact,
      count(*) FILTER (l.n_links = 1 AND l.gap BETWEEN -15 AND 40) AS n_gap_trimmed,
      avg(l.gap) FILTER (l.n_links = 1 AND l.gap BETWEEN -15 AND 40) AS mean_gap_trimmed
    FROM men m LEFT JOIN link_counts l ON m.elector_uid = l.husband_uid
    WHERE m.age BETWEEN 19 AND 59
    GROUP BY m.lgd_gp_code, m.birth_year, m.age
    ORDER BY m.lgd_gp_code, m.birth_year") |>
    mutate(
      linked_wife_share = safe_ratio(n_linked, n_men),
      linked_wife_share_exact = safe_ratio(n_linked_exact, n_men),
      contested_share = safe_ratio(n_contested, n_men),
      age_band = receiving_age_band(age)
    )
}

assignment_sample <- function(cells, outcome, wave, ages = c(19, 39), weighting = "gp") {
  d <- cells |>
    filter(age >= ages[1], age <= ages[2], is.finite(.data[[outcome]])) |>
    mutate(
      treatment = .data[[paste0("treat_", wave)]],
      block = .data[[paste0("block_", wave)]],
      caste = .data[[paste0("caste_", wave)]],
      y = .data[[outcome]]
    ) |>
    filter(!is.na(treatment), !is.na(block), !is.na(caste), !is.na(birth_year))
  if (wave == 2010) d <- d |> filter(!is.na(treat_2005))
  d <- d |>
    mutate(stratum = interaction(block, caste, drop = TRUE)) |>
    group_by(lgd_gp_code) |>
    mutate(w = 1 / n()) |>
    ungroup()
  if (weighting == "population") {
    denominator <- if (startsWith(outcome, "mean_gap")) {
      sub("mean_gap", "n_gap", outcome)
    } else {
      "n_men"
    }
    d$w <- d[[denominator]]
  }
  if (nrow(d) == 0 || n_distinct(d$treatment) < 2) stop("No assignment comparison: ", outcome)
  d
}

assignment_model <- function(d, wave) {
  rhs <- if (wave == 2010) "treatment + treat_2005" else "treatment"
  fixest::feols(
    as.formula(paste("y ~", rhs, "| stratum + birth_year")),
    data = d, weights = ~w, vcov = ~block, fixef.rm = "none",
    ssc = fixest::ssc(
      K.adj = TRUE, K.fixef = "nonnested", G.adj = TRUE,
      G.df = "min", t.df = "min"
    ), notes = FALSE
  )
}

receiving_geography <- function(state) {
  panel <- treatment_panel(state)
  for (wave in c(2005, 2010)) {
    district <- if (state == "raj") paste0("district_std_", wave) else paste0("district_name_eng_", wave)
    block <- if (state == "raj") paste0("samiti_std_", wave) else paste0("block_name_eng_", wave)
    panel[[paste0("block_", wave)]] <- ifelse(
      is.na(panel[[district]]) | is.na(panel[[block]]) |
        trimws(panel[[district]]) == "" | trimws(panel[[block]]) == "",
      NA_character_, paste(panel[[district]], panel[[block]], sep = "_")
    )
    if (state == "up") {
      panel[[paste0("caste_", wave)]] <- panel[[paste0("reservation_class_", wave)]]
    } else {
      panel[[paste0("caste_", wave)]] <- panel[[paste0("caste_category_", wave)]]
    }
  }
  panel |>
    filter(!is.na(lgd_gp_code)) |>
    select(lgd_gp_code, starts_with("block_20"), starts_with("caste_20"),
      source_treat_2005 = treat_2005, source_treat_2010 = treat_2010
    ) |>
    distinct()
}


bootstrap_model <- function(d, wave) {
  cohort <- model.matrix(~ factor(birth_year), d)[, -1, drop = FALSE]
  x <- cbind(treatment = d$treatment)
  if (wave == 2010) x <- cbind(x, prior = d$treat_2005)
  x <- cbind(x, cohort)
  colnames(x) <- make.names(colnames(x))
  demeaned <- fixest::demean(cbind(y = d$y, x), f = list(d$stratum), weights = d$w)
  transformed <- as.data.frame(demeaned * sqrt(d$w))
  transformed$block <- d$block
  rhs <- paste(colnames(x), collapse = " + ")
  # Strata are nested in bootstrap clusters, so cluster signs commute with this projection.
  model <- fixest::feols(as.formula(paste("y ~ 0 +", rhs)),
    data = transformed,
    vcov = ~block, notes = FALSE,
    ssc = fixest::ssc(K.adj = TRUE, G.adj = TRUE, t.df = "min")
  )
  list(model = model, data = transformed)
}
