# ═══════════════════════════════════════════════════════════════════════════
# diagnose_trial2.R — ONE-OFF diagnostic v2
# Compares the "broken" test (1 trial object, 276 results) against a
# "working" test (3 trial objects) to figure out how reps are encoded
# when they're bundled into a single trial object.
# ═══════════════════════════════════════════════════════════════════════════

library(httr2)
library(jsonlite)
library(dplyr)

`%||%` <- function(a, b) if (!is.null(a)) a else b

VALD_CLIENT_ID     <- Sys.getenv("VALD_CLIENT_ID")
VALD_CLIENT_SECRET <- Sys.getenv("VALD_CLIENT_PASSWORD")
VALD_FD_BASE       <- "https://prd-use-api-extforcedecks.valdperformance.com"
VALD_TEAM_ID       <- "f7baafec-7022-4247-8474-1fe92062c787"

BROKEN_TEST_ID  <- "186682d0-cf1d-4ee1-9d16-23cc0a132b76"  # 1 trial obj, 276 results
WORKING_TEST_ID <- "3a059b7e-c512-41bc-b010-bb0ab323c885"  # 3 trial objs, working

cat("[Diag] Requesting access token...\n")
token_resp <- request("https://auth.prd.vald.com/oauth/token") |>
  req_method("POST") |>
  req_body_form(
    grant_type    = "client_credentials",
    client_id     = VALD_CLIENT_ID,
    client_secret = VALD_CLIENT_SECRET,
    audience      = "vald-api-external"
  ) |>
  req_perform()
access_token <- resp_body_json(token_resp)$access_token
cat("[Diag] Token obtained.\n")

# ── Fetch result definitions ────────────────────────────────────────────
cat("[Diag] Fetching result definitions...\n")
rd_resp <- request(paste0(VALD_FD_BASE, "/resultdefinitions")) |>
  req_auth_bearer_token(access_token) |>
  req_headers(Accept = "application/json") |>
  req_perform()
rd_raw <- resp_body_json(rd_resp, simplifyVector = TRUE)
rd_df <- as.data.frame(rd_raw)
if ("resultDefinitions" %in% names(rd_df)) rd_df <- as.data.frame(rd_df$resultDefinitions)
names(rd_df) <- gsub("^resultDefinitions\\.", "", names(rd_df))
rd_lookup <- list()
for (i in seq_len(nrow(rd_df))) {
  rd_lookup[[as.character(rd_df$resultId[i])]] <- as.character(rd_df$resultName[i])
}
cat("[Diag]", length(rd_lookup), "result definitions loaded.\n\n")

fetch_trials <- function(test_id) {
  resp <- request(paste0(VALD_FD_BASE, "/v2019q3/teams/", VALD_TEAM_ID, "/tests/", test_id, "/trials")) |>
    req_auth_bearer_token(access_token) |>
    req_headers(Accept = "application/json") |>
    req_perform()
  resp_body_json(resp, simplifyVector = TRUE)
}

inspect_test <- function(label, test_id) {
  cat("========================================\n")
  cat("[Diag]", label, "- testId:", test_id, "\n")
  tr <- fetch_trials(test_id)
  cat("[Diag] nrow(tr):", nrow(tr), "\n")
  for (i in seq_len(nrow(tr))) {
    res <- tr$results[[i]]
    res$resultName <- sapply(as.character(res$resultId), function(rid) rd_lookup[[rid]] %||% "UNKNOWN")
    cat("\n--- Trial object", i, "| nrow(results):", nrow(res), "---\n")

    jh <- res[grepl("jump height", tolower(res$resultName)), ]
    cat("Rows matching 'jump height':\n")
    print(jh[, intersect(names(jh), c("resultName","resultId","value","time","limb","repeat","definition"))])

    # Show distribution of 'time' values to look for clustering (separate reps)
    cat("\nUnique 'time' values (sorted):\n")
    print(sort(unique(res$time)))

    if ("definition" %in% names(res)) {
      cat("\nUnique 'definition' values:\n")
      print(unique(res$definition))
    }
  }
  cat("========================================\n\n")
}

inspect_test("BROKEN (1 trial obj)", BROKEN_TEST_ID)
inspect_test("WORKING (3 trial objs)", WORKING_TEST_ID)

cat("[Diag] Done.\n")
