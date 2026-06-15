# ═══════════════════════════════════════════════════════════════════════════
# diagnose_trial.R — ONE-OFF diagnostic: inspect /trials structure for a
# specific testId that's showing fewer rows than ValdHub reports.
# ═══════════════════════════════════════════════════════════════════════════

library(httr2)
library(jsonlite)

`%||%` <- function(a, b) if (!is.null(a)) a else b

VALD_CLIENT_ID     <- Sys.getenv("VALD_CLIENT_ID")
VALD_CLIENT_SECRET <- Sys.getenv("VALD_CLIENT_PASSWORD")
VALD_FD_BASE       <- "https://prd-use-api-extforcedecks.valdperformance.com"
VALD_TEAM_ID       <- "f7baafec-7022-4247-8474-1fe92062c787"
TEST_ID            <- "186682d0-cf1d-4ee1-9d16-23cc0a132b76"  # Jaden Robinson, 2026-04-08

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

cat("[Diag] Fetching trials for testId:", TEST_ID, "\n")
resp <- request(paste0(VALD_FD_BASE, "/v2019q3/teams/", VALD_TEAM_ID, "/tests/", TEST_ID, "/trials")) |>
  req_auth_bearer_token(access_token) |>
  req_headers(Accept = "application/json") |>
  req_perform()

cat("[Diag] Status:", resp_status(resp), "\n")

tr <- resp_body_json(resp, simplifyVector = TRUE)

cat("\n========================================\n")
cat("[Diag] nrow(tr):", nrow(tr), "\n")
cat("[Diag] names(tr):", paste(names(tr), collapse = ", "), "\n")
cat("========================================\n\n")

for (i in seq_len(nrow(tr))) {
  cat("--- Trial object", i, "---\n")
  cat("id:", tr$id[i] %||% "(none)", "\n")
  if ("repeat" %in% names(tr)) cat("top-level repeat field:", tr[["repeat"]][i], "\n")

  res <- tr$results[[i]]
  cat("class(results):", paste(class(res), collapse=","), "\n")
  if (is.data.frame(res)) {
    cat("nrow(results):", nrow(res), "\n")
    cat("names(results):", paste(names(res), collapse = ", "), "\n")
    if ("repeat" %in% names(res)) {
      cat("unique 'repeat' values in results:", paste(sort(unique(res[["repeat"]])), collapse = ", "), "\n")
    } else {
      cat("(no 'repeat' column in results)\n")
    }
    # Show a few rows of jump-height-ish results to inspect structure
    cat("\nFirst 10 rows of results (selected columns):\n")
    cols_to_show <- intersect(names(res), c("resultId","value","limb","repeat","time"))
    print(head(res[, cols_to_show, drop = FALSE], 10))
  }
  cat("\n")
}

cat("[Diag] Done.\n")
