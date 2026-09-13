# 99_run_all.R
# Run the full pipeline. Execute from project root: Rscript scripts/99_run_all.R

library(here)

message("=======================================================")
message("   QUOTA_SHAADI: Full Pipeline")
message("=======================================================")

dir.create(here("logs"), showWarnings = FALSE)
log_file <- here("logs", paste0("pipeline_", format(Sys.time(), "%Y%m%d_%H%M%S"), ".log"))

log_msg <- function(msg, level = "INFO") {
    timestamp <- format(Sys.time(), "%Y-%m-%d %H:%M:%S")
    line <- sprintf("[%s] %s: %s", timestamp, level, msg)
    message(line)
    cat(line, "\n", file = log_file, append = TRUE)
}

log_msg("Pipeline started")
log_msg(paste("Log file:", log_file))

results <- list()

run_script <- function(script_name) {
    log_msg(paste("Starting:", script_name))
    start_time <- Sys.time()
    status <- system2(
        file.path(R.home("bin"), "Rscript"),
        c("--vanilla", shQuote(here("scripts", script_name))),
        env = paste0("R_LIBS=", shQuote(paste(.libPaths(), collapse = .Platform$path.sep)))
    )
    elapsed <- round(difftime(Sys.time(), start_time, units = "secs"), 1)
    if (status != 0L) {
        log_msg(paste("Failed:", script_name, "exit", status), "ERROR")
        stop(sprintf("Pipeline halted at %s after %ss", script_name, elapsed))
    }
    results[[script_name]] <<- "success"
    log_msg(paste("Finished:", script_name, "in", elapsed, "seconds"))
}

message("\n### PHASE 1: ACQUISITION ###")
log_msg("=== PHASE 1: ACQUISITION ===")
run_script("01a_download_rolls.R")
run_script("01b_prepare_sources.R")

message("\n### PHASE 2: INGEST + CLEAN ###")
log_msg("=== PHASE 2: INGEST + CLEAN ===")
run_script("02a_rolls_to_parquet.R")
run_script("02b_clean_electors.R")

message("\n### PHASE 3: BRIDGE ###")
log_msg("=== PHASE 3: BRIDGE ===")
run_script("03a_ps_directory.R")
run_script("03b_ps_gp_match_raj.R")
run_script("03c_ps_gp_match_up.R")
run_script("03d_ps_treatment_join.R")
run_script("03e_audit_bridge_balance.R")

message("\n### PHASE 4: OUTCOMES ###")
log_msg("=== PHASE 4: OUTCOMES ===")
run_script("04a_husband_linkage.R")
run_script("04b_cohort_aggregates.R")
run_script("05a_exposure.R")

message("\n### PHASE 5: ESTIMATION ###")
log_msg("=== PHASE 5: ESTIMATION ===")
run_script("06a_couples_design.R")
run_script("06b_natal_design.R")
run_script("06c_random_rotation.R")
run_script("06d_placebo.R")
run_script("06e_sensitivity.R")
run_script("06f_early_marriage.R")
run_script("07a_balance.R")

message("\n### PHASE 6: VALIDATION ###")
log_msg("=== PHASE 6: VALIDATION ===")
run_script("08a_validate_benchmarks.R")
run_script("98_validate.R")

message("\n=======================================================")
message("   PIPELINE SUMMARY")
message("=======================================================")
for (s in names(results)) {
    message(sprintf("  %-35s %s", s, results[[s]]))
}
log_msg(sprintf("Pipeline finished: %d scripts", length(results)))
