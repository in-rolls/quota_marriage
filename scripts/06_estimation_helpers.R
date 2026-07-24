# 06_estimation_helpers.R
# Shared estimation machinery for the couples (A) and natal-daughters (B)
# designs. Cohort cells enter with weights; SEs cluster on GP.

library(fixest)

# Female reservation is randomized within caste-reservation strata, and
# caste-reserved GPs differ demographically, so every cross-GP spec must
# condition on the seat's caste category.
caste_controls <- function(data) {
    intersect(c("sc_2005", "st_2005", "obc_2005", "sc_2010", "st_2010", "obc_2010"),
              names(data))
}

# The four-spec battery for one outcome.
#   s1: district x cohort FE (cross-GP, Beaman-style)
#   s2: (district, block) x cohort FE
#   s3: GP FE + district x cohort FE (within-GP, primary; caste absorbed)
#   s4: cycle-specific exposure dummies with s2 FE
run_battery <- function(data, outcome, treat_var = "dose_main",
                        weight_var = NULL) {
    d <- data |> filter(!is.na(.data[[outcome]]))
    if (!is.null(weight_var)) {
        d <- d |> filter(!is.na(.data[[weight_var]]), .data[[weight_var]] > 0)
        w <- as.formula(paste0("~", weight_var))
    } else {
        w <- NULL
    }
    castes <- paste(caste_controls(d), collapse = " + ")
    castes <- if (nzchar(castes)) paste0(" + ", castes) else ""
    list(
        s1 = feols(as.formula(sprintf("%s ~ %s%s | fe_district^birth_year",
                                      outcome, treat_var, castes)),
                   data = d, weights = w, cluster = ~lgd_gp_code),
        s2 = feols(as.formula(sprintf("%s ~ %s%s | fe_dist_block^birth_year",
                                      outcome, treat_var, castes)),
                   data = d, weights = w, cluster = ~lgd_gp_code),
        s3 = feols(as.formula(sprintf("%s ~ %s | lgd_gp_code + fe_district^birth_year",
                                      outcome, treat_var)),
                   data = d, weights = w, cluster = ~lgd_gp_code),
        s4 = feols(as.formula(sprintf("%s ~ exp_2005 + exp_2010%s | fe_dist_block^birth_year",
                                      outcome, castes)),
                   data = d, weights = w, cluster = ~lgd_gp_code)
    )
}

battery_tidy <- function(models, state, design, outcome) {
    purrr::imap_dfr(models, function(m, spec) {
        cf <- coef(m)
        terms <- intersect(names(cf), c("dose_main", "dose_alt1", "dose_alt2",
                                        "any_exposure", "exp_2005", "exp_2010",
                                        "treat_2005", "treat_2010"))
        tibble::tibble(
            state = state, design = design, outcome = outcome, spec = spec,
            term = terms,
            estimate = cf[terms],
            se = se(m)[terms],
            p = pvalue(m)[terms],
            n = nobs(m),
            r2 = fitstat(m, "r2")[[1]]
        )
    })
}

FE_DICT_BATTERY <- c(
    "fe_district^birth_year" = "District $\\times$ Cohort",
    "fe_dist_block^birth_year" = "(District, Block) $\\times$ Cohort",
    "lgd_gp_code" = "GP"
)
