library(here)
library(dplyr)
source(here("scripts", "00_config.R"))
source(here("scripts", "00_utils.R"))
source(here("scripts", "receiving_helpers.R"))
fixest::setFixest_nthreads(1)
dir.create(here("data", "models"), showWarnings = FALSE)

estimates <- list()
means <- list()
support <- list()
model_index <- 0L
bootstrap_index <- 0L
for (state in c("raj", "up")) {
  cells <- arrow::read_parquet(here("data", "cohorts", paste0("receiving_", state, ".parquet")))
  parental <- arrow::read_parquet(here("data", "cohorts", paste0("parental_", state, ".parquet")))
  variants <- tibble::tribble(
    ~variant, ~outcome, ~lo, ~hi, ~weighting,
    "primary", "linked_wife_share", 19, 39, "gp",
    "primary", "mean_gap", 19, 39, "gp",
    "population_weighted", "linked_wife_share", 19, 39, "population",
    "population_weighted", "mean_gap", 19, 39, "population",
    "native_exact", "linked_wife_share_exact", 19, 39, "gp",
    "native_exact", "mean_gap_exact", 19, 39, "gp",
    "gap_trimmed", "mean_gap_trimmed", 19, 39, "gp",
    "parental_father", "parental_ratio", 19, 39, "gp",
    "parental_father_mother", "parental_ratio_fm", 19, 39, "gp",
    "parental_women_count", "n_parental_women", 19, 39, "gp",
    "parental_men_count", "n_parental_men", 19, 39, "gp"
  )
  for (ages in list(c(19, 24), c(25, 29), c(30, 39), c(40, 59))) {
    for (outcome in c("linked_wife_share", "mean_gap")) {
      variants <- bind_rows(variants, tibble(
        variant = paste(ages, collapse = "-"), outcome = outcome,
        lo = ages[1], hi = ages[2], weighting = "gp"
      ))
    }
  }
  for (i in seq_len(nrow(variants))) {
    v <- variants[i, ]
    for (wave in c(2005, 2010)) {
      model_index <- model_index + 1L
      source_cells <- if (grepl("parental", v$outcome, fixed = TRUE)) parental else cells
      d <- assignment_sample(source_cells, v$outcome, wave, c(v$lo, v$hi), v$weighting)
      if (v$weighting == "gp") {
        stopifnot(max(abs(tapply(d$w, d$lgd_gp_code, sum) - 1)) < 1e-12)
      }
      strata <- d |>
        distinct(stratum, lgd_gp_code, block, treatment) |>
        group_by(stratum) |>
        summarise(
          n_gps = n(), n_treated = sum(treatment == 1),
          n_open = sum(treatment == 0), .groups = "drop"
        )
      m <- assignment_model(d, wave)
      stopifnot(stats::nobs(m) == nrow(d), "treatment" %in% names(coef(m)))
      if (!is.finite(fixest::se(m)["treatment"])) stop("Invalid treatment SE")
      ci <- as.numeric(unlist(confint(m, "treatment")))
      mgp <- summary(m, vcov = ~lgd_gp_code)
      id <- paste(state, wave, v$variant, v$outcome, sep = "_")
      r <- tibble(
        state = state, wave = wave, variant = v$variant, outcome = v$outcome,
        age_min = v$lo, age_max = v$hi, weighting = v$weighting,
        estimate = unname(coef(m)["treatment"]), se = unname(fixest::se(m)["treatment"]),
        p = unname(fixest::pvalue(m)["treatment"]), ci_low = ci[1], ci_high = ci[2],
        gp_se = unname(fixest::se(mgp)["treatment"]), gp_p = unname(fixest::pvalue(mgp)["treatment"]),
        n_cells = nrow(d), n_gps = n_distinct(d$lgd_gp_code),
        n_clusters = n_distinct(d$block), n_strata = nrow(strata),
        n_overlap_strata = sum(strata$n_treated > 0 & strata$n_open > 0),
        n_overlap_gps = sum(strata$n_gps[strata$n_treated > 0 & strata$n_open > 0]),
        n_treated_gps = n_distinct(d$lgd_gp_code[d$treatment == 1]),
        n_open_gps = n_distinct(d$lgd_gp_code[d$treatment == 0]),
        boot_p = NA_real_, boot_ci_low = NA_real_, boot_ci_high = NA_real_,
        boot_seed = NA_integer_, boot_draws = NA_integer_
      )
      means[[model_index]] <- d |>
        group_by(treatment) |>
        summarise(
          mean = weighted.mean(y, w), n_cells = n(),
          n_gps = n_distinct(lgd_gp_code), .groups = "drop"
        ) |>
        mutate(state = state, wave = wave, variant = v$variant, outcome = v$outcome)
      if (v$variant == "primary") {
        bootstrap_index <- bootstrap_index + 1L
        seed <- 202610040L + bootstrap_index
        set.seed(seed)
        dqrng::dqset.seed(seed)
        message("Bootstrap ", id, ": 9999 draws")
        transformed <- bootstrap_model(d, wave)
        stopifnot(abs(coef(transformed$model)["treatment"] - r$estimate) < 1e-9)
        boot <- fwildclusterboot::boottest(
          transformed$model,
          param = "treatment", B = 9999, clustid = "block",
          type = "rademacher", impose_null = TRUE, p_val_type = "two-tailed",
          conf_int = TRUE, engine = "R", sampling = "dqrng", nthreads = 1,
          maxiter = 100,
          ssc = fwildclusterboot::boot_ssc(
            adj = TRUE, fixef.K = "none",
            cluster.adj = TRUE, cluster.df = "conventional"
          )
        )
        stopifnot(
          abs(boot$point_estimate - r$estimate) < 1e-9,
          boot$N == nrow(d), length(boot$conf_int) == 2
        )
        r$boot_p <- boot$p_val
        r$boot_ci_low <- as.numeric(unlist(boot$conf_int))[1]
        r$boot_ci_high <- as.numeric(unlist(boot$conf_int))[2]
        r$boot_seed <- seed
        r$boot_draws <- 9999L
        saveRDS(
          list(model = m, data = d, bootstrap_model = transformed$model, bootstrap = boot),
          here("data", "models", paste0(id, ".rds"))
        )
        support[[id]] <- strata |> mutate(state = state, wave = wave, outcome = v$outcome)
      }
      estimates[[model_index]] <- r
    }
  }
}
results <- bind_rows(estimates)
primary <- which(results$variant == "primary")
stopifnot(length(primary) == 8, all(is.finite(results$boot_p[primary])))
results$holm_boot_p <- NA_real_
results$holm_cluster_p <- NA_real_
results$holm_boot_p[primary] <- p.adjust(results$boot_p[primary], method = "holm")
results$holm_cluster_p[primary] <- p.adjust(results$p[primary], method = "holm")
write_audit(results, "receiving_estimates.csv")
write_audit(bind_rows(means), "receiving_raw_means.csv")
write_audit(bind_rows(support), "receiving_assignment_support.csv")
