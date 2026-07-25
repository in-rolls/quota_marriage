#!/bin/zsh
cd /Users/soodoku/Documents/GitHub/quota_shaadi
for s in 03a_ps_directory 03b_ps_gp_match_raj 03c_ps_gp_match_up 03d_ps_treatment_join 03e_audit_bridge_balance 04a_husband_linkage 04b_cohort_aggregates 05a_exposure 06a_couples_design 06b_natal_design 06c_random_rotation 06d_placebo 06e_sensitivity 07a_balance 08a_validate_benchmarks; do
  echo "== $s start $(date +%H:%M:%S)"
  Rscript scripts/$s.R >> logs/chain_full.log 2>&1 || { echo "$s" > logs/CHAIN_FAILED; exit 1; }
  echo "== $s done $(date +%H:%M:%S)"
done
touch logs/CHAIN_DONE
