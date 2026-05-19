# DATA_SOURCES.md — Database Schema & Integration Reference

Complete reference for every table, column, data type, and computed metric
in the UF S&C Dashboard. Use this when:
- Writing SQL queries against the database
- Building new dashboard features
- Integrating additional data sources
- Troubleshooting data import scripts

---

## Table of Contents

1. [Database Tables](#database-tables)
   - [profiles](#1-profiles)
   - [athletes](#2-athletes)
   - [gps_sessions](#3-gps_sessions)
   - [cmj_tests](#4-cmj_tests)
   - [nordbord_tests](#5-nordbord_tests)
   - [flags](#6-flags)
2. [Computed Metrics Reference](#computed-metrics-reference)
   - [ACWR](#acwr-acutechronic-workload-ratio)
   - [Monotony](#monotony)
   - [Strain](#strain)
   - [CMJ % Change](#cmj--change-from-baseline)
   - [Composite Risk Score](#composite-risk-score-0100)
3. [Device Export Column Mapping](#device-export-column-mapping)
   - [Catapult GPS](#catapult-gps)
   - [ForceDeck CMJ](#forcedeck-cmj)
   - [NordBord](#nordbord)
4. [Flag System](#flag-system)
5. [Wellness Data Integration](#wellness-data-integration)
6. [Row Level Security Summary](#row-level-security-summary)
7. [Useful SQL Queries](#useful-sql-queries)

---

## Database Tables

### 1. profiles

Links Supabase Auth users to their role within the dashboard.
Created manually after adding users in the Supabase Auth dashboard.

| Column | Type | Constraints | Description |
|---|---|---|---|
| `id` | uuid | PRIMARY KEY, FK → auth.users | Must match a real Supabase Auth user UUID |
| `full_name` | text | NOT NULL | Display name shown in the navbar |
| `role` | text | NOT NULL, CHECK | One of: `head_coach`, `sc_staff`, `athletic_trainer` |

**Role permissions summary:**

| Role | Pages accessible |
|---|---|
| `head_coach` | index.html only |
| `sc_staff` | All pages + CSV export + RPE entry |
| `athletic_trainer` | nordbord, injury_risk, roster |

**Example insert (run after creating users in Supabase Auth):**
```sql
INSERT INTO public.profiles (id, full_name, role) VALUES
  ('uuid-from-auth', 'Dr. Sarah Mitchell', 'sc_staff');
```

---

### 2. athletes

Master roster table. Every other table references this via `athlete_id`.

| Column | Type | Constraints | Description |
|---|---|---|---|
| `id` | uuid | PRIMARY KEY, DEFAULT uuid_generate_v4() | Auto-generated on insert |
| `name` | text | NOT NULL | Full name — must match device exports for R script matching |
| `jersey_number` | int | NOT NULL | Used for display and heatmap cells |
| `position` | text | NOT NULL | See position codes below |
| `class_year` | text | NOT NULL, CHECK | One of: `FR`, `SO`, `JR`, `SR`, `GR` |
| `height_in` | int | NOT NULL | Height in total inches (e.g. 6'2" = 74) |
| `weight_lbs` | int | NOT NULL | Body weight in pounds — used for NordBord BW Ratio |
| `status` | text | NOT NULL, DEFAULT 'Active' | One of: `Active`, `Injured`, `Limited`, `Out` |

**Position codes used in this system:**

| Code | Position group | Typical weight range |
|---|---|---|
| `QB` | Skill | 195–230 lbs |
| `RB` | Skill | 195–220 lbs |
| `WR` | Skill | 170–200 lbs |
| `DB` | Skill | 175–200 lbs |
| `K` / `P` | Skill | 180–200 lbs |
| `TE` | Hybrid | 230–260 lbs |
| `LB` | Hybrid | 220–245 lbs |
| `ST` | Hybrid | 195–215 lbs |
| `OL` | Linemen | 280–330 lbs |
| `DL` | Linemen | 265–315 lbs |

**To convert height for insert:**
```
Height in inches = (feet × 12) + inches
Example: 6'2" = (6 × 12) + 2 = 74
```

---

### 3. gps_sessions

One row per athlete per session day. Sourced from Catapult GPS units.
The RPE and duration columns can be entered manually via the Load Management page.

| Column | Type | Constraints | Description |
|---|---|---|---|
| `id` | uuid | PRIMARY KEY | Auto-generated |
| `athlete_id` | uuid | NOT NULL, FK → athletes | Links to the athlete |
| `session_date` | date | NOT NULL | Date of the session (YYYY-MM-DD) |
| `total_distance_m` | numeric | NOT NULL | Total GPS distance covered in meters |
| `high_speed_distance_m` | numeric | NOT NULL | Distance covered above high-speed threshold (typically >5.5 m/s) |
| `sprint_distance_m` | numeric | NOT NULL | Distance covered above sprint threshold (typically >7.0 m/s) |
| `player_load` | numeric | NOT NULL | Catapult's proprietary composite load metric (accelerometer-based) |
| `session_rpe` | int | NULL | Manually entered Rating of Perceived Exertion (1–10) |
| `session_duration_min` | int | NULL | Session duration in minutes (manual or from export) |

**Notes:**
- `player_load` is the primary input for ACWR, Monotony, and Strain calculations
- `session_rpe` × `session_duration_min` = Session Load (displayed on Load Management page)
- One row per athlete per date — the RPE panel updates an existing row if one exists
- The dashboard uses the last 28 rows (by date) per athlete for all calculations

**Catapult high-speed and sprint thresholds** vary by team setting.
Confirm your thresholds in Catapult OpenField → Team Settings.
Document them here once confirmed:

```
High Speed threshold:  _______ m/s  (default: 5.5 m/s)
Sprint threshold:      _______ m/s  (default: 7.0 m/s)
```

---

### 4. cmj_tests

One row per athlete per test session. Sourced from Vald ForceDeck.
Typically tested weekly or bi-weekly.

| Column | Type | Constraints | Description |
|---|---|---|---|
| `id` | uuid | PRIMARY KEY | Auto-generated |
| `athlete_id` | uuid | NOT NULL, FK → athletes | Links to the athlete |
| `test_date` | date | NOT NULL | Date of the CMJ test |
| `jump_height_cm` | numeric | NOT NULL | Jump height in centimeters — primary readiness metric |
| `peak_force_n` | numeric | NOT NULL | Maximum ground reaction force in Newtons |
| `peak_power_w` | numeric | NOT NULL | Maximum power output in Watts |
| `rsi_modified` | numeric | NOT NULL | RSI-Modified = jump height ÷ contraction time. Higher = better reactive strength |
| `concentric_impulse_ns` | numeric | NOT NULL | Impulse during upward push phase (N·s). Reflects power production |
| `eccentric_decel_impulse_ns` | numeric | NOT NULL | Impulse during downward loading phase (N·s). Reflects control and injury resilience |
| `asymmetry_index_pct` | numeric | NOT NULL | Left-right force difference as %. Flag above 10% |

**CMJ flag thresholds applied by dashboard JS:**

| Metric | Amber threshold | Red threshold |
|---|---|---|
| Jump height % change | < −10% vs baseline | < −20% vs baseline |
| Asymmetry Index | > 10% | > 15% |

**Baseline calculation:** Rolling average of the athlete's last 4 test results
(excluding the current test). Computed in JavaScript — not stored in the database.

---

### 5. nordbord_tests

One row per athlete per testing block. Sourced from Vald NordBord.
Typically tested every 2–4 weeks.

| Column | Type | Constraints | Description |
|---|---|---|---|
| `id` | uuid | PRIMARY KEY | Auto-generated |
| `athlete_id` | uuid | NOT NULL, FK → athletes | Links to the athlete |
| `test_date` | date | NOT NULL | Date of NordBord test |
| `left_peak_force_n` | numeric | NOT NULL | Peak isometric hamstring force — left leg (Newtons) |
| `right_peak_force_n` | numeric | NOT NULL | Peak isometric hamstring force — right leg (Newtons) |
| `lsi_pct` | numeric | NOT NULL | Limb Symmetry Index: LEAST(L,R) ÷ GREATEST(L,R) × 100 |
| `bw_ratio` | numeric | NOT NULL | GREATEST(L,R) ÷ bodyweight in Newtons (weight_lbs × 4.44822) |

**NordBord flag thresholds:**

| Metric | Threshold | Severity | Flag label |
|---|---|---|---|
| LSI % | < 90% | RED | Hamstring Asymmetry — RTP Risk |
| LSI % | 90–95% | AMBER | Monitor Hamstring Symmetry |
| Either limb peak force | < 200N | RED | Absolute Strength Deficit |
| BW Ratio (male athletes) | < 0.45 | AMBER | Below Strength Threshold |

**Computing LSI and BW Ratio manually:**
```
LSI %    = MIN(left_peak_force_n, right_peak_force_n)
           / MAX(left_peak_force_n, right_peak_force_n) × 100

BW Ratio = MAX(left_peak_force_n, right_peak_force_n)
           / (weight_lbs × 4.44822)
```

The R import script (`nordbord_to_supabase.R`) computes these automatically.
If entering data manually, calculate them before inserting.

---

### 6. flags

One row per flag event per athlete. Flags can be resolved (closed) but
are never deleted — full history is retained for the athlete profile modal.

| Column | Type | Constraints | Description |
|---|---|---|---|
| `id` | uuid | PRIMARY KEY | Auto-generated |
| `athlete_id` | uuid | NOT NULL, FK → athletes | Links to the athlete |
| `flag_date` | date | NOT NULL | Date the flag was triggered |
| `flag_type` | text | NOT NULL, CHECK | See flag types below |
| `severity` | text | NOT NULL, CHECK | One of: `HIGH`, `MODERATE` |
| `triggered_by` | text | NOT NULL | Human-readable description of what triggered the flag |
| `recommended_action` | text | NOT NULL | Specific action for S&C staff |
| `resolved` | boolean | NOT NULL, DEFAULT false | Set to true when the athlete is cleared |

**Valid flag types (enforced by CHECK constraint):**

| Flag Type | Typical trigger |
|---|---|
| `ACWR Spike` | ACWR > 1.5 or < 0.8 |
| `CMJ Drop` | Jump height > 10% below rolling baseline |
| `Asymmetry Alert` | CMJ asymmetry index > 10% |
| `NordBord Deficit` | LSI < 90% or absolute force < 200N |
| `High Strain` | Strain value in top 10% of squad |
| `Injury History Risk` | Athlete in Injured/Limited status with unresolved metrics |

**To resolve a flag manually via SQL:**
```sql
UPDATE public.flags
SET resolved = true
WHERE athlete_id = 'athlete-uuid-here'
  AND flag_type = 'ACWR Spike'
  AND resolved = false;
```

**Flags are currently generated by:**
- The seed_data.sql script (simulated demo flags)
- Manual SQL insert (for real data phase)

**Future enhancement:** Add a Supabase Edge Function or scheduled cron job
that automatically generates flags nightly by querying the metrics tables.
See the Supabase Edge Functions documentation for implementation details.

---

## Computed Metrics Reference

All of the following are computed in JavaScript at page load time.
None of them are stored in the database.

---

### ACWR (Acute:Chronic Workload Ratio)

**What it measures:** Whether recent training load is proportionate to the
athlete's long-term training base. High values indicate a sudden spike;
low values indicate undertraining.

**Inputs:** `player_load` from `gps_sessions`, last 28 sessions per athlete

```
Acute load  = SUM(player_load) over last 7 days

Chronic load = AVERAGE of 4 weekly totals:
               Week 1: days 1–7
               Week 2: days 8–14
               Week 3: days 15–21
               Week 4: days 22–28

ACWR = Acute load ÷ Chronic load
```

**Thresholds:**

| Zone | Range | Action |
|---|---|---|
| Danger (low) | < 0.8 | Undertraining — check for illness or unplanned rest |
| Safe | 0.8 – 1.3 | Optimal training stimulus |
| Caution | 1.3 – 1.5 | Monitor — approaching spike territory |
| Danger (high) | > 1.5 | Reduce load immediately |

**Minimum data required:** 7 GPS sessions. Returns null if fewer exist.

---

### Monotony

**What it measures:** How uniform daily training load is over 7 days.
High monotony means the body is not getting adequate variation in stimulus,
which can impair adaptation and increase injury risk.

**Inputs:** `player_load` from last 7 `gps_sessions`

```
Mean  = AVERAGE(player_load over last 7 days)
SD    = STANDARD DEVIATION(player_load over last 7 days)

Monotony = Mean ÷ SD
```

**Thresholds:**

| Value | Interpretation |
|---|---|
| < 1.5 | Normal — adequate load variation |
| 1.5 – 2.0 | Caution — consider varying session intensity |
| > 2.0 | Flag — training is too monotonous |

---

### Strain

**What it measures:** A composite stress index combining total weekly load
with training uniformity. High strain athletes are at elevated injury risk.

**Inputs:** Acute load and Monotony (both computed above)

```
Strain = Acute Load × Monotony
```

**Threshold:** Top 10% of squad strain values are flagged red on the
Load Management page. No fixed absolute threshold — it is squad-relative.

---

### CMJ % Change from Baseline

**What it measures:** Whether an athlete's neuromuscular readiness is
declining relative to their own normal. Position-agnostic — each athlete
is compared only to themselves.

**Inputs:** `jump_height_cm` from `cmj_tests`

```
Baseline = AVERAGE of athlete's last 4 jump_height_cm values
           (excluding the current/most recent test)

% Change = (current - baseline) / baseline × 100
```

**Thresholds:**

| % Change | Color | Interpretation |
|---|---|---|
| > −10% | Green | Normal readiness |
| −10% to −20% | Amber | Monitor — possible fatigue accumulation |
| < −20% | Red | Flag — significant neuromuscular fatigue |

**Minimum data required:** 2 CMJ tests. Returns null if only 1 test exists.

---

### Composite Risk Score (0–100)

**What it measures:** A single number summarizing an athlete's overall
injury risk from five independent factors.

**Inputs:** ACWR, CMJ % change, NordBord LSI, Monotony, days since rest

```
ACWR component (max 25 pts):
  0 pts  if ACWR 0.8–1.5
  Scales to 25 pts at ACWR 2.0 (high) or ACWR 0.4 (low)

CMJ component (max 25 pts):
  0 pts  if % change > −10%
  Scales to 25 pts at % change ≤ −20%

NordBord LSI component (max 20 pts):
  0 pts  if LSI ≥ 95%
  Scales to 20 pts if LSI ≤ 90%

Monotony component (max 15 pts):
  0 pts  if Monotony < 1.5
  Scales to 15 pts if Monotony ≥ 2.0

Days since rest component (max 15 pts):
  0 pts  if ≤ 3 consecutive active days
  Scales to 15 pts at ≥ 7 consecutive active days

Total = sum of all components, capped at 100
```

**Risk buckets:**

| Score | Level | Color | Recommended action |
|---|---|---|---|
| 0–30 | Low | Green | Full training |
| 31–60 | Moderate | Amber | Monitor, consider intensity reduction |
| 61–100 | High | Red | Mandatory load reduction, notify athletic trainer |

---

## Device Export Column Mapping

### Catapult GPS

The R script `catapult_to_supabase.R` handles this mapping automatically.
Reference for manual imports or troubleshooting.

| Supabase column | Catapult OpenField export column(s) |
|---|---|
| `athlete_name` (for matching) | `Player Name`, `Athlete Name`, `Name` |
| `session_date` | `Date`, `Session Date` |
| `total_distance_m` | `Total Distance`, `Distance (m)` |
| `high_speed_distance_m` | `High Speed Running Distance`, `HSR Distance (m)` |
| `sprint_distance_m` | `Sprint Distance`, `Sprint Distance (m)` |
| `player_load` | `Player Load`, `PlayerLoad` |
| `session_rpe` | `RPE` (not in GPS export — entered manually) |
| `session_duration_min` | `Duration`, `Duration (min)` |

**Export settings to use in Catapult OpenField:**
- Export type: Session Summary (not raw GPS)
- Units: Metric (meters, not yards)
- Include all athletes in one file

---

### ForceDeck CMJ

The R script `forcedeck_to_supabase.R` handles this mapping automatically.

| Supabase column | Vald Hub / ForceDeck export column(s) |
|---|---|
| `athlete_name` (for matching) | `Athlete`, `Name` |
| `test_date` | `Date`, `Test Date` |
| `jump_height_cm` | `Jump Height (cm)` |
| `peak_force_n` | `Peak Force (N)` |
| `peak_power_w` | `Peak Power (W)` |
| `rsi_modified` | `RSI-Modified`, `RSImod` |
| `concentric_impulse_ns` | `Concentric Impulse (Ns)` |
| `eccentric_decel_impulse_ns` | `Eccentric Deceleration Impulse (Ns)` |
| `asymmetry_index_pct` | `Asymmetry (%)` |

**Export settings to use in Vald Hub:**
- Test type filter: CMJ (Countermovement Jump) only
- Include all metrics (not summary view)
- Export format: CSV

**Unit notes:**
- Jump height: confirm export is in cm not mm. The R script auto-detects
  values > 200 and divides by 10 (converts mm → cm)
- Asymmetry: confirm export is in % (0–100), not decimal (0–1).
  The R script auto-detects decimals and multiplies by 100

---

### NordBord

The R script `nordbord_to_supabase.R` handles this mapping automatically
and computes LSI and BW Ratio from raw force values.

| Supabase column | Vald Hub / NordBord export column(s) |
|---|---|
| `athlete_name` (for matching) | `Athlete`, `Name` |
| `test_date` | `Date`, `Test Date` |
| `left_peak_force_n` | `Left Peak Force (N)`, `Left Force (N)` |
| `right_peak_force_n` | `Right Peak Force (N)`, `Right Force (N)` |
| `lsi_pct` | Computed by R script from left/right values |
| `bw_ratio` | Computed by R script using athlete weight from Supabase |

**Export settings to use in Vald Hub:**
- Test type: NordBord
- Include raw left and right peak force columns
- Export format: CSV

---

## Flag System

### How Flags Are Created (Current System)

Flags are currently inserted manually via SQL or pre-populated by `seed_data.sql`.

**To manually insert a flag:**
```sql
INSERT INTO public.flags
  (athlete_id, flag_date, flag_type, severity, triggered_by, recommended_action)
VALUES
  (
    'athlete-uuid',
    CURRENT_DATE,
    'ACWR Spike',
    'HIGH',
    'ACWR = 1.72 (Acute: 2,890 | Chronic: 1,680)',
    'Reduce volume 20–30%. No max-effort sessions. Daily monitoring.'
  );
```

### Future: Automated Flag Generation

The recommended next step is a Supabase Edge Function (TypeScript/Deno)
that runs nightly and automatically:
1. Queries the last 28 days of gps_sessions
2. Computes ACWR, Monotony, Strain per athlete
3. Queries cmj_tests and computes % change from baseline
4. Queries nordbord_tests for LSI and force values
5. Inserts new flags for any athlete crossing a threshold
6. Does not duplicate flags already generated today

**To implement:** Go to Supabase → Edge Functions → Create new function.
Schedule it via Supabase's pg_cron extension or an external cron service.

---

## Wellness Data Integration

The Injury Risk page has a placeholder section for HRV, sleep, and soreness data.
To connect real wellness data, add a new table and populate it from your
wellness monitoring system.

### Suggested Table: wellness_entries

```sql
CREATE TABLE public.wellness_entries (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    athlete_id      UUID NOT NULL REFERENCES public.athletes(id) ON DELETE CASCADE,
    entry_date      DATE NOT NULL,
    hrv_score       NUMERIC NULL,       -- milliseconds or app-specific scale
    sleep_hrs       NUMERIC NULL,       -- hours of sleep
    sleep_quality   INT NULL,           -- 1–5 subjective rating
    soreness        INT NULL,           -- 1–5 (1=none, 5=severe)
    fatigue         INT NULL,           -- 1–5 (1=fresh, 5=exhausted)
    mood            INT NULL,           -- 1–5 (1=poor, 5=excellent)
    notes           TEXT NULL
);

ALTER TABLE public.wellness_entries ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Authenticated read wellness"
    ON public.wellness_entries FOR SELECT
    TO authenticated USING (true);
```

### Compatible Wellness Apps

| App | Export method | Notes |
|---|---|---|
| Whoop | CSV export or API | HRV, sleep, recovery score |
| Catapult Playertek | Built into OpenField export | Can include subjective wellness |
| TeamBuildr | CSV export | Soreness, sleep, mood surveys |
| Google Forms | CSV export from Sheets | Custom daily wellness survey |
| REDCap | API or CSV | HIPAA-compliant — recommended for medical data |

### Integration Steps

1. Add the `wellness_entries` table above via SQL Editor
2. Export data from your wellness app as CSV
3. Create `wellness_to_supabase.R` following the same pattern as the
   device import scripts (see `catapult_to_supabase.R` as a template)
4. Update the wellness chart in `injury_risk.html` to fetch from
   `wellness_entries` instead of using placeholder data

---

## Row Level Security Summary

All tables have RLS enabled. Anonymous (unauthenticated) users get zero access.

| Table | Authenticated read | sc_staff insert | sc_staff/trainer update |
|---|---|---|---|
| `profiles` | ✅ | ❌ | ❌ |
| `athletes` | ✅ | ❌ | ❌ |
| `gps_sessions` | ✅ | ✅ (RPE entry) | ❌ |
| `cmj_tests` | ✅ | ❌ | ❌ |
| `nordbord_tests` | ✅ | ❌ | ❌ |
| `flags` | ✅ | ✅ | ✅ (resolve flags) |

**To grant insert access to additional tables** (e.g. when adding real
data without R scripts), add a policy in the SQL Editor:

```sql
CREATE POLICY "sc_staff insert athletes"
    ON public.athletes FOR INSERT
    TO authenticated
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM public.profiles
            WHERE id = auth.uid() AND role = 'sc_staff'
        )
    );
```

---

## Useful SQL Queries

### Check athlete count by position
```sql
SELECT position, COUNT(*) as count
FROM public.athletes
GROUP BY position
ORDER BY count DESC;
```

### Find all unresolved HIGH severity flags
```sql
SELECT a.name, a.position, f.flag_type, f.flag_date, f.triggered_by
FROM public.flags f
JOIN public.athletes a ON f.athlete_id = a.id
WHERE f.resolved = false AND f.severity = 'HIGH'
ORDER BY f.flag_date DESC;
```

### Get last GPS session date per athlete
```sql
SELECT a.name, a.position, MAX(g.session_date) as last_session
FROM public.athletes a
LEFT JOIN public.gps_sessions g ON g.athlete_id = a.id
GROUP BY a.id, a.name, a.position
ORDER BY last_session ASC NULLS FIRST;
```

### Get athletes with no CMJ tests
```sql
SELECT a.name, a.position, a.status
FROM public.athletes a
WHERE a.id NOT IN (SELECT DISTINCT athlete_id FROM public.cmj_tests)
ORDER BY a.position;
```

### Get latest NordBord result per athlete with flag status
```sql
SELECT
    a.name,
    a.position,
    n.test_date,
    n.lsi_pct,
    n.left_peak_force_n,
    n.right_peak_force_n,
    n.bw_ratio,
    CASE
        WHEN n.lsi_pct < 90 THEN 'HIGH — RTP Risk'
        WHEN n.lsi_pct < 95 THEN 'MODERATE — Monitor'
        WHEN n.left_peak_force_n < 200 OR n.right_peak_force_n < 200 THEN 'HIGH — Force Deficit'
        WHEN n.bw_ratio < 0.45 THEN 'MODERATE — BW Ratio'
        ELSE 'Clear'
    END as flag_status
FROM public.nordbord_tests n
JOIN public.athletes a ON n.athlete_id = a.id
WHERE n.test_date = (
    SELECT MAX(n2.test_date)
    FROM public.nordbord_tests n2
    WHERE n2.athlete_id = n.athlete_id
)
ORDER BY n.lsi_pct ASC;
```

### Wipe all simulated data (run before go-live)
```sql
-- WARNING: This permanently deletes all data in these tables.
-- The table structure, RLS policies, and indexes are preserved.
TRUNCATE flags, nordbord_tests, cmj_tests, gps_sessions, athletes CASCADE;
```

---

*UF Football Strength & Conditioning — Internal Use Only*
*Last updated: see Git commit history*
*For setup instructions see README.md*
