# ═══════════════════════════════════════════════════════════════════════════
# vald_sync.R — Nightly VALD sync for ForceDecks and NordBord
# ═══════════════════════════════════════════════════════════════════════════

library(httr2)
library(jsonlite)
library(dplyr)
library(lubridate)
library(stringr)

VALD_CLIENT_ID       <- Sys.getenv("VALD_CLIENT_ID")
VALD_CLIENT_SECRET   <- Sys.getenv("VALD_CLIENT_PASSWORD")
VALD_TENANT_ID       <- Sys.getenv("VALD_DUENDE_ID")
SUPABASE_URL         <- Sys.getenv("SUPABASE_URL")
SUPABASE_SERVICE_KEY <- Sys.getenv("SUPABASE_SERVICE_KEY")

VALD_TOKEN_URL <- "https://auth.prd.vald.com/oauth/token"
VALD_PROF_BASE <- "https://prd-use-api-externalprofile.valdperformance.com"
VALD_FD_BASE   <- "https://prd-use-api-extforcedecks.valdperformance.com"
VALD_NORD_BASE <- "https://prd-use-api-externalnordbord.valdperformance.com"
LOOKBACK_DAYS  <- 7

cat("[VALD Sync] Starting at", format(Sys.time(), "%Y-%m-%d %H:%M:%S UTC"), "\n")

# ── Get access token ──────────────────────────────────────────────────────
cat("[VALD Sync] Requesting access token...\n")
token_resp <- request(VALD_TOKEN_URL) |>
  req_method("POST") |>
  req_body_form(
    grant_type    = "client_credentials",
    client_id     = VALD_CLIENT_ID,
    client_secret = VALD_CLIENT_SECRET,
    audience      = "vald-api-external"
  ) |>
  req_error(is_error = function(resp) FALSE) |>
  req_perform()

if (resp_status(token_resp) != 200) {
  body <- tryCatch(resp_body_string(token_resp), error = function(e) "(empty)")
  stop("[VALD Sync] Token failed: ", resp_status(token_resp), "\n", body)
}
token_data   <- resp_body_json(token_resp)
access_token <- token_data$access_token
cat("[VALD Sync] Token obtained. Expires in", token_data$expires_in, "seconds.\n")

# ── Helper: GET ───────────────────────────────────────────────────────────
vald_get <- function(path, query = list(), base_url) {
  req <- request(paste0(base_url, path)) |>
    req_auth_bearer_token(access_token) |>
    req_headers(Accept = "application/json") |>
    req_error(is_error = function(resp) FALSE)
  if (length(query) > 0) req <- req |> req_url_query(!!!query)
  resp <- req_perform(req)
  status <- resp_status(resp)
  if (status == 204) { cat("[VALD Sync] 204 No Content for", path, "\n"); return(NULL) }
  if (status != 200) {
    body <- tryCatch(resp_body_string(resp), error = function(e) "(empty body)")
    warning("[VALD Sync] ", path, " returned ", status, ": ", body)
    return(NULL)
  }
  resp_body_json(resp, simplifyVector = TRUE)
}

# ── Helper: upsert to Supabase ────────────────────────────────────────────
sb_upsert <- function(table, rows) {
  if (is.null(rows) || nrow(rows) == 0) { cat("[Supabase] No rows for", table, "\n"); return(invisible(NULL)) }
  resp <- request(paste0(SUPABASE_URL, "/rest/v1/", table)) |>
    req_method("POST") |>
    req_headers(
      apikey         = SUPABASE_SERVICE_KEY,
      Authorization  = paste("Bearer", SUPABASE_SERVICE_KEY),
      "Content-Type" = "application/json",
      Prefer         = "resolution=merge-duplicates"
    ) |>
    req_body_json(rows) |>
    req_error(is_error = function(resp) FALSE) |>
    req_perform()
  status <- resp_status(resp)
  if (status %in% c(200, 201)) cat("[Supabase] Upserted", nrow(rows), "rows into", table, "\n")
  else warning("[Supabase] Upsert to ", table, " failed: ", status, "\n", tryCatch(resp_body_string(resp), error=function(e)"(empty)"))
}

# ── Helper: last sync date ────────────────────────────────────────────────
get_last_sync <- function(table, date_col) {
  resp <- request(paste0(SUPABASE_URL, "/rest/v1/", table)) |>
    req_headers(apikey = SUPABASE_SERVICE_KEY, Authorization = paste("Bearer", SUPABASE_SERVICE_KEY)) |>
    req_url_query(select = date_col, order = paste0(date_col, ".desc"), limit = "1") |>
    req_error(is_error = function(resp) FALSE) |>
    req_perform()
  if (resp_status(resp) != 200) return(NULL)
  rows <- resp_body_json(resp, simplifyVector = TRUE)
  if (is.null(rows) || length(rows) == 0) return(NULL)
  as.POSIXct(rows[[date_col]][1], format = "%Y-%m-%d", tz = "UTC")
}

# ── Step 2: Fetch profiles ────────────────────────────────────────────────
cat("[VALD Sync] Fetching athlete profiles...\n")
profiles_raw <- vald_get("/profiles/v2", query = list(tenantId = VALD_TENANT_ID), base_url = VALD_PROF_BASE)
if (is.null(profiles_raw) || length(profiles_raw) == 0) {
  cat("[VALD Sync] No profiles — will use profileId as athlete name.\n")
  profiles_df <- data.frame(profileId = character(), name = character(), stringsAsFactors = FALSE)
} else {
  profiles_df <- as.data.frame(profiles_raw) |>
    mutate(profileId = as.character(id), name = paste(as.character(givenName), as.character(familyName))) |>
    select(profileId, name)
  cat("[VALD Sync]", nrow(profiles_df), "profiles fetched.\n")
}

# ── Step 3: ForceDecks ────────────────────────────────────────────────────
cat("[VALD Sync] Fetching ForceDecks tests...\n")
last_cmj  <- get_last_sync("cmj_tests", "test_date")
from_utc  <- format(if (is.null(last_cmj)) Sys.time()-days(LOOKBACK_DAYS) else last_cmj-days(1), "%Y-%m-%dT%H:%M:%SZ")
cat("[VALD Sync] ForceDecks from:", from_utc, "\n")

fd_raw <- vald_get("/tests", query = list(tenantId = VALD_TENANT_ID, modifiedFromUtc = from_utc), base_url = VALD_FD_BASE)

if (!is.null(fd_raw) && length(fd_raw) > 0) {
  fd_df <- tryCatch({
    as.data.frame(fd_raw) |>
      left_join(profiles_df, by = c("profileId" = "profileId")) |>
      mutate(
        athlete_name    = coalesce(name, as.character(profileId)),
        test_date       = as.character(as.Date(testDateUtc)),
        vald_test_id    = as.character(id),
        vald_profile_id = as.character(profileId)
      )
  }, error = function(e) { cat("[VALD Sync] Parse error FD:", conditionMessage(e), "\n"); NULL })

  if (!is.null(fd_df) && nrow(fd_df) > 0) {
    extract_metric <- function(results_col, metric_name) {
      sapply(results_col, function(r) {
        if (is.null(r) || length(r) == 0) return(NA_real_)
        if (is.data.frame(r)) { idx <- which(tolower(r$metric)==tolower(metric_name)); if(length(idx)==0) return(NA_real_); return(as.numeric(r$value[idx[1]])) }
        NA_real_
      })
    }
    cmj_rows <- fd_df |>
      mutate(
        jump_height_cm             = if("results"%in%names(.)) extract_metric(results,"jump height") else NA_real_,
        peak_force_n               = if("results"%in%names(.)) extract_metric(results,"peak force") else NA_real_,
        peak_power_w               = if("results"%in%names(.)) extract_metric(results,"peak power") else NA_real_,
        rsi_modified               = if("results"%in%names(.)) extract_metric(results,"rsi-modified") else NA_real_,
        concentric_impulse_ns      = if("results"%in%names(.)) extract_metric(results,"concentric impulse") else NA_real_,
        eccentric_decel_impulse_ns = if("results"%in%names(.)) extract_metric(results,"eccentric deceleration impulse") else NA_real_,
        asymmetry_index_pct        = if("results"%in%names(.)) extract_metric(results,"asymmetry index") else NA_real_
      ) |>
      select(vald_test_id, vald_profile_id, athlete_name, test_date,
             jump_height_cm, peak_force_n, peak_power_w, rsi_modified,
             concentric_impulse_ns, eccentric_decel_impulse_ns, asymmetry_index_pct) |>
      filter(!is.na(test_date))
    cat("[VALD Sync]", nrow(cmj_rows), "ForceDecks rows to upsert.\n")
    sb_upsert("cmj_tests", cmj_rows)
  }
} else { cat("[VALD Sync] No new ForceDecks tests.\n") }

# ── Step 4: NordBord ──────────────────────────────────────────────────────
cat("[VALD Sync] Fetching NordBord tests...\n")
last_nord    <- get_last_sync("nordbord_tests", "test_date")
from_utc_nb  <- format(if (is.null(last_nord)) Sys.time()-days(LOOKBACK_DAYS) else last_nord-days(1), "%Y-%m-%dT%H:%M:%SZ")
cat("[VALD Sync] NordBord from:", from_utc_nb, "\n")

nb_raw <- vald_get("/tests/v2", query = list(tenantId = VALD_TENANT_ID, modifiedFromUtc = from_utc_nb), base_url = VALD_NORD_BASE)

if (!is.null(nb_raw) && length(nb_raw) > 0) {
  nb_df <- tryCatch({
    as.data.frame(nb_raw) |>
      left_join(profiles_df, by = c("profileId" = "profileId")) |>
      mutate(
        athlete_name    = coalesce(name, as.character(profileId)),
        test_date       = as.character(as.Date(testDateUtc)),
        vald_test_id    = as.character(id),
        vald_profile_id = as.character(profileId)
      )
  }, error = function(e) { cat("[VALD Sync] Parse error NB:", conditionMessage(e), "\n"); NULL })

  if (!is.null(nb_df) && nrow(nb_df) > 0) {
    nord_rows <- nb_df |>
      mutate(
        left_peak_force_n  = as.numeric(leftPeakForce),
        right_peak_force_n = as.numeric(rightPeakForce),
        lsi_pct = case_when(
          !is.na(left_peak_force_n) & !is.na(right_peak_force_n) & pmax(left_peak_force_n,right_peak_force_n)>0 ~
            round(pmin(left_peak_force_n,right_peak_force_n)/pmax(left_peak_force_n,right_peak_force_n)*100, 1),
          TRUE ~ NA_real_
        ),
        bw_ratio = NA_real_
      ) |>
      select(vald_test_id, vald_profile_id, athlete_name, test_date,
             left_peak_force_n, right_peak_force_n, lsi_pct, bw_ratio) |>
      filter(!is.na(test_date))
    cat("[VALD Sync]", nrow(nord_rows), "NordBord rows to upsert.\n")
    sb_upsert("nordbord_tests", nord_rows)
  }
} else { cat("[VALD Sync] No new NordBord tests.\n") }

cat("[VALD Sync] Completed at", format(Sys.time(), "%Y-%m-%d %H:%M:%S UTC"), "\n")