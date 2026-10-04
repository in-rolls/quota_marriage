RSCRIPT ?= Rscript

.PHONY: analysis test validate lint
analysis:
	$(RSCRIPT) scripts/99_run_all.R --from-cleaned

test:
	$(RSCRIPT) scripts/test_receiving.R

validate:
	$(RSCRIPT) scripts/98_validate.R

lint:
	$(RSCRIPT) -e 'x <- unlist(lapply(list.files("scripts", pattern="[.]R$$", full.names=TRUE), lintr::lint), recursive=FALSE); print(x); stopifnot(length(x) == 0L)'
