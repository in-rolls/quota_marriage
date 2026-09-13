source("scripts/00_sources.R")
for (name in names(jsonlite::read_json(here::here("data", "sources.json")))) source_path(name)
