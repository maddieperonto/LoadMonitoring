# ═══════════════════════════════════════════════════════════════════════════
# catapult_athlete_profiles_sync.R — Nightly sync of Catapult profile max velocity
# into the existing athletes table (catapult_athlete_id, max_velocity_mph)
# ═══════════════════════════════════════════════════════════════════════════

library(httr2)
library(jsonlite)
library(dplyr)
library(stringr)

CATAPULT_BASE_URL    <- Sys.getenv("CATAPULT_BASE_URL")
CATAPULT_API_TOKEN   <- Sys.getenv("CATAPULT_API_TOKEN")
SUPABASE_URL         <- Sys.getenv("SUPABASE_URL")
SUPABASE_SERVICE_KEY <- Sys.getenv("SUPABASE_SERVICE_KEY")

MPS_TO_MPH <- 2.23694
CURRENT_TEAM_ID <- "75054b55-9900-11e3-b9b6-22000af8166b"

cat("[Catapult Profiles] Starting at", format(Sys.time(), "%Y-%m-%d %H:%M:%S UTC"), "\n")

# ── Fetch Catapult athletes, filtered to current team ──────────────────────
resp <- request(paste0(CATAPULT_BASE_URL, "/athletes")) |>
  req_auth_bearer_token(CATAPULT_API_TOKEN) |>
  req_headers(Accept = "application/json") |>
  req_error(is_error = function(resp) FALSE) |>
  req_perform()

if (resp_status(resp) != 200) {
  stop("[Catapult Profiles] /athletes fetch failed: ", resp_status(resp))
}

catapult_athletes <- resp_body_json(resp, simplifyVector = TRUE) |>
  filter(current_team_id == CURRENT_TEAM_ID) |>
  mutate(
    catapult_athlete_id = as.character(id),
    catapult_name        = str_trim(paste(first_name, last_name)),
    max_velocity_mph     = round(as.numeric(velocity_max) * MPS_TO_MPH, 2)
  ) |>
  select(catapult_athlete_id, catapult_name, max_velocity_mph)

cat("[Catapult Profiles]", nrow(catapult_athletes), "athletes on current team.\n")

# ── Same name standardization used across the dashboard/VALD scripts ──────
name_map <- c(
  "Aaron Philo"="AARON PHILO","Alec Clark"="ALEC CLARK",
  "Alfonzo Allen"="ALFONZO ALLEN JR","Austin Ciongoli"="AUSTIN CIONGOLI",
  "Bailey Stockton"="BAILEY STOCKTON","Ben Hanks Jr."="BEN HANKS III",
  "Brian Case"="BRIAN CASE","Byron Louis"="BYRON LOUIS",
  "Cam Dooley"="CAM DOOLEY","Carter Milliron"="CARTER MILLIRON",
  "Charles Emanuel"="CHARLES EMANUEL III","Cj Hester"="CJ HESTER",
  "CJ Bronaugh"="CJ BRONAUGH","Cormani McClain"="CORMANI MCCLAIN",
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
  "Ty Jackson"="TY JACKSON","Vernell Brown III"="VERNELL BROWN III",
  "Vincent Brown"="VINCENT BROWN JR","Waltez Clark"="WALTEZ CLARK",
  "William Griffin"="WILL GRIFFIN","Duke Clark"="WALTEZ CLARK",
  "Jalen Lloyd"="JAYLEN LLOYD","Jason Zandamela"="JASON ZANDAMELA-POPA",
  "Jahari Medlock"="JAHARI MEDLOCK-WILSON","Mark Faircloth"="MARK FAIRCLOTH JR",
  "Pat Durkin"="PATRICK DURKIN","Tavaris Dice"="TAVARIS DICE JR",
  "Jeramiah McCloud"="JERAMIAH MCCLOUD","JeReylan McCoy"="JAREYLAN MCCOY",
  "Eagan Boyer"="EAGAN BOYER","Desmond Green"="DESMOND GREEN",
  "Jalen Wiggins"="JALEN WIGGINS","Emeka Ugorji"="EMEKA UGORJI"
)

catapult_athletes$standardized_name <- ifelse(
  catapult_athletes$catapult_name %in% names(name_map),
  name_map[catapult_athletes$catapult_name],
  toupper(catapult_athletes$catapult_name)
)

# ── Fetch current athletes table ────────────────────────────────────────────
athletes_resp <- request(paste0(SUPABASE_URL, "/rest/v1/athletes")) |>
  req_headers(apikey = SUPABASE_SERVICE_KEY, Authorization = paste("Bearer", SUPABASE_SERVICE_KEY)) |>
  req_url_query(select = "id,name") |>
  req_error(is_error = function(resp) FALSE) |>
  req_perform()

athletes_df <- resp_body_json(athletes_resp, simplifyVector = TRUE)
cat("[Catapult Profiles]", nrow(athletes_df), "rows in athletes table.\n")

# ── Match and update ─────────────────────────────────────────────────────────
matched <- 0
unmatched <- c()

for (i in seq_len(nrow(catapult_athletes))) {
  row <- catapult_athletes[i, ]
  athlete_match <- athletes_df[athletes_df$name == row$standardized_name, ]

  if (nrow(athlete_match) == 1) {
    patch_resp <- request(paste0(SUPABASE_URL, "/rest/v1/athletes")) |>
      req_method("PATCH") |>
      req_headers(
        apikey         = SUPABASE_SERVICE_KEY,
        Authorization  = paste("Bearer", SUPABASE_SERVICE_KEY),
        "Content-Type" = "application/json",
        Prefer         = "return=minimal"
      ) |>
      req_url_query(id = paste0("eq.", athlete_match$id[1])) |>
      req_body_raw(
        jsonlite::toJSON(list(
          catapult_athlete_id = row$catapult_athlete_id,
          max_velocity_mph    = row$max_velocity_mph
        ), auto_unbox = TRUE),
        type = "application/json"
      ) |>
      req_error(is_error = function(resp) FALSE) |>
      req_perform()

    if (resp_status(patch_resp) %in% c(200, 204)) {
      matched <- matched + 1
    } else {
      warning("[Catapult Profiles] Update failed for ", row$standardized_name, ": ", resp_status(patch_resp))
    }
  } else {
    unmatched <- c(unmatched, row$standardized_name)
  }
}

cat("[Catapult Profiles] Updated", matched, "athletes.\n")
if (length(unmatched) > 0) {
  cat("[Catapult Profiles] Skipped", length(unmatched), "unmatched name(s):\n")
  cat(paste(" -", unique(unmatched)), sep = "\n")
}

cat("[Catapult Profiles] Completed at", format(Sys.time(), "%Y-%m-%d %H:%M:%S UTC"), "\n")