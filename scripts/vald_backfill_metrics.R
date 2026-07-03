# ═══════════════════════════════════════════════════════════════════════════
# vald_backfill_metrics.R — One-time backfill: fills ALL CMJ metrics
# (including the 3 new ones) for every historical trial, fixing any
# previously incomplete rows and adding the new columns everywhere.
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
VALD_TEAM_ID   <- "f7baafec-7022-4247-8474-1fe92062c787"
`%||%` <- function(a, b) if (!is.null(a)) a else b

cat("[Backfill] Starting at", format(Sys.time(), "%Y-%m-%d %H:%M:%S UTC"), "\n")

# ── Token ──────────────────────────────────────────────────────────────────
token_resp <- request(VALD_TOKEN_URL) |>
  req_method("POST") |>
  req_body_form(
    grant_type    = "client_credentials",
    client_id     = VALD_CLIENT_ID,
    client_secret = VALD_CLIENT_SECRET,
    audience      = "vald-api-external"
  ) |>
  req_perform()
access_token <- resp_body_json(token_resp)$access_token
cat("[Backfill] Token obtained.\n")

vald_get <- function(path, query = list(), base_url) {
  req <- request(paste0(base_url, path)) |>
    req_auth_bearer_token(access_token) |>
    req_headers(Accept = "application/json") |>
    req_error(is_error = function(resp) FALSE)
  if (length(query) > 0) req <- req |> req_url_query(!!!query)
  resp <- req_perform(req)
  status <- resp_status(resp)
  if (status == 204) return(NULL)
  if (status != 200) {
    warning("[Backfill] ", path, " returned ", status)
    return(NULL)
  }
  resp_body_json(resp, simplifyVector = TRUE)
}

sb_upsert <- function(table, rows, on_conflict = NULL) {
  if (is.null(rows) || nrow(rows) == 0) { cat("[Supabase] No rows for", table, "\n"); return(invisible(NULL)) }
  req <- request(paste0(SUPABASE_URL, "/rest/v1/", table)) |>
    req_method("POST") |>
    req_headers(
      apikey         = SUPABASE_SERVICE_KEY,
      Authorization  = paste("Bearer", SUPABASE_SERVICE_KEY),
      "Content-Type" = "application/json",
      Prefer         = "return=minimal,resolution=merge-duplicates"
    )
  if (!is.null(on_conflict)) req <- req |> req_url_query(on_conflict = on_conflict)
  resp <- req |>
    req_body_raw(jsonlite::toJSON(rows, na = "null", auto_unbox = TRUE), type = "application/json") |>
    req_error(is_error = function(resp) FALSE) |>
    req_perform()
  status <- resp_status(resp)
  if (status %in% c(200, 201)) cat("[Supabase] Upserted", nrow(rows), "rows into", table, "\n")
  else warning("[Supabase] Upsert to ", table, " failed: ", status, "\n",
               tryCatch(resp_body_string(resp), error = function(e) "(empty)"))
}

# ── Profiles ───────────────────────────────────────────────────────────────
cat("[Backfill] Fetching athlete profiles...\n")
profiles_raw <- vald_get("/profiles", query = list(tenantId = VALD_TENANT_ID), base_url = VALD_PROF_BASE)
pdf <- as.data.frame(profiles_raw)
names(pdf) <- gsub("^profiles\\.", "", names(pdf))
profiles_df <- pdf |>
  mutate(profileId = as.character(profileId),
         name = paste(as.character(givenName), as.character(familyName))) |>
  select(profileId, name)
cat("[Backfill]", nrow(profiles_df), "profiles fetched.\n")

# ── Result definitions ────────────────────────────────────────────────────
cat("[Backfill] Fetching result definitions...\n")
rd_raw <- vald_get("/resultdefinitions", query = list(), base_url = VALD_FD_BASE)
rd_df <- as.data.frame(rd_raw)
if ("resultDefinitions" %in% names(rd_df)) rd_df <- as.data.frame(rd_df$resultDefinitions)
names(rd_df) <- gsub("^resultDefinitions\\.", "", names(rd_df))
rd_lookup <- list()
for (i in seq_len(nrow(rd_df))) {
  rd_lookup[[as.character(rd_df$resultId[i])]] <- tolower(as.character(rd_df$resultName[i]))
}
cat("[Backfill]", length(rd_lookup), "result definitions loaded.\n")

# ── Fetch ALL ForceDecks tests from the beginning ─────────────────────────
from_utc <- "2026-01-01T00:00:00Z"   # adjust if your history goes back further
cat("[Backfill] Fetching ALL ForceDecks tests from:", from_utc, "\n")

all_fd_rows <- list()
current_from <- from_utc
repeat {
  fd_page <- vald_get("/tests", query = list(tenantId = VALD_TENANT_ID, modifiedFromUtc = current_from), base_url = VALD_FD_BASE)
  if (is.null(fd_page) || length(fd_page) == 0) break
  page_df <- as.data.frame(fd_page)
  names(page_df) <- gsub("^tests\\.", "", names(page_df))
  all_fd_rows <- c(all_fd_rows, list(page_df))
  cat("[Backfill] Fetched page of", nrow(page_df), "tests. Total so far:", sum(sapply(all_fd_rows, nrow)), "\n")
  if (nrow(page_df) < 50) break
  current_from <- page_df$modifiedDateUtc[nrow(page_df)]
  Sys.sleep(0.25)
}
fd_raw <- if (length(all_fd_rows) > 0) do.call(rbind, all_fd_rows) else NULL
cat("[Backfill] Total ForceDecks tests fetched:", if (!is.null(fd_raw)) nrow(fd_raw) else 0, "\n")

if (is.null(fd_raw) || nrow(fd_raw) == 0) { cat("[Backfill] No tests found. Exiting.\n"); quit(save = "no", status = 0) }

fd_df <- fd_raw |>
  left_join(profiles_df, by = c("profileId" = "profileId")) |>
  mutate(
    athlete_name    = coalesce(name, as.character(profileId)),
    test_date       = as.character(as.Date(recordedDateUtc)),
    vald_test_id    = as.character(testId),
    vald_profile_id = as.character(profileId)
  )

CMJ_TYPES <- c("CMJ", "CMJA", "CMJL", "SJ", "SJA", "DJ", "DJA", "IMTP", "HOP")

cat("[Backfill] Fetching trials for", nrow(fd_df), "tests...\n")
trial_data <- lapply(seq_len(nrow(fd_df)), function(i) {
  tid   <- fd_df$testId[i]
  ttype <- toupper(fd_df$testType[i])
  if (!any(sapply(CMJ_TYPES, function(t) grepl(t, ttype, fixed = TRUE)))) return(NULL)
  tr <- vald_get(
    paste0("/v2019q3/teams/", VALD_TEAM_ID, "/tests/", tid, "/trials"),
    query    = list(),
    base_url = VALD_FD_BASE
  )
  Sys.sleep(0.25)
  tr
})
cat("[Backfill] Trials fetched.\n")

get_metric_from_trial <- function(results_list, keywords, limb_filter = NULL) {
  if (is.null(results_list) || !is.data.frame(results_list)) return(NA_real_)
  res <- results_list
  if (!is.data.frame(res) || nrow(res) == 0) return(NA_real_)
  for (j in seq_len(nrow(res))) {
    rid   <- as.character(res$resultId[j])
    rname <- tolower(rd_lookup[[rid]] %||% "")
    if (!any(sapply(keywords, function(k) grepl(k, rname, fixed = TRUE)))) next
    if (!is.null(limb_filter)) {
      limb_val <- if ("limb" %in% names(res)) tolower(res$limb[j]) else ""
      if (!grepl(tolower(limb_filter), limb_val, fixed = TRUE)) next
    }
    return(as.numeric(res$value[j]))
  }
  NA_real_
}

# ── Build FULL row per trial — same metric set as the nightly sync, ───────
# ── PLUS the 3 new metrics — so any previously incomplete rows get ────────
# ── completely refilled, not just the new columns. ─────────────────────────
cmj_trial_rows <- lapply(seq_len(nrow(fd_df)), function(i) {
  ttype <- toupper(fd_df$testType[i])
  if (!any(sapply(CMJ_TYPES, function(t) grepl(t, ttype, fixed = TRUE)))) return(NULL)

  trials <- trial_data[[i]]
  if (is.null(trials) || !is.data.frame(trials) || nrow(trials) == 0) return(NULL)

  per_trial <- lapply(seq_len(nrow(trials)), function(t) {
    res <- trials$results[[t]]

    data.frame(
      vald_test_id                       = as.character(fd_df$testId[i]),
      vald_profile_id                    = as.character(fd_df$profileId[i]),
      athlete_name                       = fd_df$athlete_name[i],
      test_date                          = fd_df$test_date[i],
      trial_number                       = t,
      jump_height_cm                     = get_metric_from_trial(res, c("jump height (flight time)")),
      peak_force_n                       = get_metric_from_trial(res, c("peak force")),
      peak_power_w                       = get_metric_from_trial(res, c("peak power / bm", "peak power")),
      rsi_modified                       = get_metric_from_trial(res, c("rsi-modified", "rsi modified", "reactive strength")),
      concentric_impulse_ns              = get_metric_from_trial(res, c("concentric impulse")),
      eccentric_decel_impulse_ns         = get_metric_from_trial(res, c("eccentric decel")),
      eccentric_decel_rfd_bm             = get_metric_from_trial(res, c("eccentric deceleration rfd / bm")),
      eccentric_peak_power_bm            = get_metric_from_trial(res, c("eccentric peak power / bm")),
      flight_time_contraction_time       = get_metric_from_trial(res, c("flight time:contraction time", "flighttime:contraction time")),
      eccentric_peak_force_asymmetry_pct = get_metric_from_trial(res, c("eccentric peak force"), limb_filter = "asym"),
      eccentric_peak_force_left          = get_metric_from_trial(res, c("eccentric peak force"), limb_filter = "left"),
      eccentric_peak_force_right         = get_metric_from_trial(res, c("eccentric peak force"), limb_filter = "right"),
      force_at_zero_velocity_n           = get_metric_from_trial(res, c("force at zero velocity")),
      relative_peak_power_w_bm           = get_metric_from_trial(res, c("peak power / bm")),
      countermovement_depth_cm           = get_metric_from_trial(res, c("countermovement depth")),
      stringsAsFactors = FALSE
    )
  })
  do.call(rbind, per_trial)
})

backfill_rows <- do.call(rbind, Filter(Negate(is.null), cmj_trial_rows)) |>
  mutate(across(where(is.numeric), ~ ifelse(is.nan(.), NA_real_, .))) |>
  filter(!is.na(test_date))

# ── Standardize athlete names to match roster ──────────────────────────────
name_map <- c(
  "Aaron Philo"="AARON PHILO","Alec Clark"="ALEC CLARK",
  "Alfonzo Allen"="ALFONZO ALLEN JR","AUSTIN \"ACE\" CIONGOLI"="AUSTIN CIONGOLI",
  "Bailey Stockton"="BAILEY STOCKTON","Ben Hanks Jr."="BEN HANKS III",
  "Brian Case"="BRIAN CASE","Byron Louis"="BYRON LOUIS",
  "Cam'Ron Dooley"="CAM DOOLEY","Carter Milliron"="CARTER MILLIRON",
  "Charles Emanuel III"="CHARLES EMANUEL III","Cj  Hester"="CJ HESTER",
  "CJ Bronaugh "="CJ BRONAUGH","Cormani McClain"="CORMANI MCCLAIN",
  "Dallas Wilson"="DALLAS WILSON","Davian Groce"="DAVIAN GROCE",
  "Drake Stubbs"="DRAKE STUBBS","Dylan Leighton"="DYLAN LEIGHTON",
  "Dylan Purter"="DYLAN PURTER","Elijah Owens"="ELIJAH OWENS",
  "Eric Parks"="ERIC PARKS","Eric Singleton"="ERIC SINGLETON JR",
  "Erich Seager"="ERICH SEAGER","Evan Chieca"="EVAN CHIECA",
  "Hezekiah Kent"="HEZE KENT","Hunter Solwold"="HUNTER SOLWOLD",
  "J'Vari Flowers"="J'VARI FLOWERS","Jadan Baugh"="JADAN BAUGH",
  "Jaden Edgecombe"="JADEN EDGECOMBE","Jayden Woods"="JAYDEN WOODS",
  "Jordy Lowery"="JORDY LOWERY","Justin Williams"="JUSTIN WILLIAMS",
  "Kaiden Hall"="KAIDEN HALL","Kelvin Jimenez"="KELVIN JIMENEZ",
  "KJ Ford"="KJ FORD","Kofi Asare"="KOFI ASARE",
  "Lacota Dippre"="LACOTA DIPPRE","Lagonza Hayward"="LAGONZA HAYWARD",
  "Liam Padron"="LIAM PADRON","Lincoln Anderson"="LINCOLN ANDERSON",
  "London Montgomery"="LONDON MONTGOMERY","Malik Morris"="MALIK MORRIS",
  "Marquez Daniel"="MARQUEZ DANIEL","Mason Jordan"="MASON JORDAN",
  "Matthew Kade"="MATTHEW KADE","Micah Jones"="MICAH JONES",
  "Micah Mays"="MICAH MAYS JR","Miller Fealy"="MILLER FEALY",
  "Myles Johnson"="MYLES JOHNSON","Nicholas Inglis"="NICK INGLIS",
  "Onis Konanbanny"="ONIS KONANBANNY","Patrick Durkin"="PATRICK DURKIN",
  "Thaddeus TJ Bullard Jr."="TJ BULLARD","Titus Bullard"="TITUS BULLARD",
  "TJ Abrams"="TJ ABRAMS","Tramell Jones"="TRAMELL JONES JR",
  "Ty Jackson"="TY JACKSON","Vernell Brown"="VERNELL BROWN III",
  "Vincent Brown"="VINCENT BROWN JR","Waltez Clark"="WALTEZ CLARK",
  "William Griffin"="WILL GRIFFIN","Eric Singleton Jr"="ERIC SINGLETON JR",
  "Micah Mays Jr"="MICAH MAYS JR"
)
backfill_rows$athlete_name <- ifelse(
  backfill_rows$athlete_name %in% names(name_map),
  name_map[backfill_rows$athlete_name],
  toupper(backfill_rows$athlete_name)
)

cat("[Backfill]", nrow(backfill_rows), "rows to upsert.\n")
sb_upsert("cmj_tests", backfill_rows, on_conflict = "vald_test_id,trial_number")

cat("[Backfill] Completed at", format(Sys.time(), "%Y-%m-%d %H:%M:%S UTC"), "\n")