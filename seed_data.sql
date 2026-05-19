-- ═══════════════════════════════════════════════════════════════════════════
-- SIMULATED DATA — FOR STAKEHOLDER DEMO ONLY
-- To reset for real data: truncate all tables listed below, then begin
-- importing real exports using the Python scripts in /scripts/
--
-- Tables to truncate before go-live:
--   TRUNCATE flags, nordbord_tests, cmj_tests, gps_sessions, athletes CASCADE;
--   (profiles table is managed via Supabase Auth — delete users from Auth dashboard)
-- ═══════════════════════════════════════════════════════════════════════════

-- ───────────────────────────────────────
-- EXTENSIONS
-- ───────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ───────────────────────────────────────
-- TABLE: profiles
-- Linked to Supabase auth.users via id (UUID)
-- ───────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.profiles (
    id        UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    full_name TEXT NOT NULL,
    role      TEXT NOT NULL CHECK (role IN ('head_coach', 'sc_staff', 'athletic_trainer'))
);

-- ───────────────────────────────────────
-- TABLE: athletes
-- ───────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.athletes (
    id             UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name           TEXT NOT NULL,
    jersey_number  INT  NOT NULL,
    position       TEXT NOT NULL,
    class_year     TEXT NOT NULL CHECK (class_year IN ('FR','SO','JR','SR','GR')),
    height_in      INT  NOT NULL,
    weight_lbs     INT  NOT NULL,
    status         TEXT NOT NULL DEFAULT 'Active'
                        CHECK (status IN ('Active','Injured','Limited','Out'))
);

-- ───────────────────────────────────────
-- TABLE: gps_sessions
-- ───────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.gps_sessions (
    id                   UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    athlete_id           UUID NOT NULL REFERENCES public.athletes(id) ON DELETE CASCADE,
    session_date         DATE NOT NULL,
    total_distance_m     NUMERIC NOT NULL,
    high_speed_distance_m NUMERIC NOT NULL,
    sprint_distance_m    NUMERIC NOT NULL,
    player_load          NUMERIC NOT NULL,
    session_rpe          INT  NULL,
    session_duration_min INT  NULL
);

-- ───────────────────────────────────────
-- TABLE: cmj_tests
-- ───────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.cmj_tests (
    id                        UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    athlete_id                UUID NOT NULL REFERENCES public.athletes(id) ON DELETE CASCADE,
    test_date                 DATE NOT NULL,
    jump_height_cm            NUMERIC NOT NULL,
    peak_force_n              NUMERIC NOT NULL,
    peak_power_w              NUMERIC NOT NULL,
    rsi_modified              NUMERIC NOT NULL,
    concentric_impulse_ns     NUMERIC NOT NULL,
    eccentric_decel_impulse_ns NUMERIC NOT NULL,
    asymmetry_index_pct       NUMERIC NOT NULL
);

-- ───────────────────────────────────────
-- TABLE: nordbord_tests
-- lsi_pct and bw_ratio are computed on insert / can be computed in JS
-- ───────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.nordbord_tests (
    id                UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    athlete_id        UUID NOT NULL REFERENCES public.athletes(id) ON DELETE CASCADE,
    test_date         DATE NOT NULL,
    left_peak_force_n  NUMERIC NOT NULL,
    right_peak_force_n NUMERIC NOT NULL,
    lsi_pct           NUMERIC NOT NULL,  -- LEAST(left,right)/GREATEST(left,right)*100
    bw_ratio          NUMERIC NOT NULL   -- GREATEST(left,right) / weight_lbs * 4.44822
);

-- ───────────────────────────────────────
-- TABLE: flags
-- ───────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.flags (
    id                UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    athlete_id        UUID NOT NULL REFERENCES public.athletes(id) ON DELETE CASCADE,
    flag_date         DATE NOT NULL,
    flag_type         TEXT NOT NULL CHECK (flag_type IN (
                          'ACWR Spike','CMJ Drop','Asymmetry Alert',
                          'NordBord Deficit','High Strain','Injury History Risk')),
    severity          TEXT NOT NULL CHECK (severity IN ('HIGH','MODERATE')),
    triggered_by      TEXT NOT NULL,
    recommended_action TEXT NOT NULL,
    resolved          BOOLEAN NOT NULL DEFAULT FALSE
);

-- ═══════════════════════════════════════════════════════════════════════════
-- ROW LEVEL SECURITY
-- ═══════════════════════════════════════════════════════════════════════════

ALTER TABLE public.profiles       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.athletes        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gps_sessions    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cmj_tests       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.nordbord_tests  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.flags           ENABLE ROW LEVEL SECURITY;

-- Authenticated users can read all data; anon gets nothing
CREATE POLICY "Authenticated read profiles"
    ON public.profiles FOR SELECT
    TO authenticated USING (true);

CREATE POLICY "Authenticated read athletes"
    ON public.athletes FOR SELECT
    TO authenticated USING (true);

CREATE POLICY "Authenticated read gps_sessions"
    ON public.gps_sessions FOR SELECT
    TO authenticated USING (true);

CREATE POLICY "Authenticated read cmj_tests"
    ON public.cmj_tests FOR SELECT
    TO authenticated USING (true);

CREATE POLICY "Authenticated read nordbord_tests"
    ON public.nordbord_tests FOR SELECT
    TO authenticated USING (true);

CREATE POLICY "Authenticated read flags"
    ON public.flags FOR SELECT
    TO authenticated USING (true);

-- sc_staff can insert RPE updates into gps_sessions
CREATE POLICY "sc_staff insert gps_sessions"
    ON public.gps_sessions FOR INSERT
    TO authenticated
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM public.profiles
            WHERE id = auth.uid() AND role = 'sc_staff'
        )
    );

-- sc_staff can insert flags
CREATE POLICY "sc_staff insert flags"
    ON public.flags FOR INSERT
    TO authenticated
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM public.profiles
            WHERE id = auth.uid() AND role IN ('sc_staff','athletic_trainer')
        )
    );

-- sc_staff / athletic_trainer can update flags (resolve them)
CREATE POLICY "sc_staff update flags"
    ON public.flags FOR UPDATE
    TO authenticated
    USING (
        EXISTS (
            SELECT 1 FROM public.profiles
            WHERE id = auth.uid() AND role IN ('sc_staff','athletic_trainer')
        )
    );

-- ═══════════════════════════════════════════════════════════════════════════
-- PROFILES NOTE
-- ═══════════════════════════════════════════════════════════════════════════
-- After creating test users in Supabase Auth dashboard, insert their UUIDs:
--
-- INSERT INTO public.profiles (id, full_name, role) VALUES
--   ('<head-coach-uuid>',       'Coach Billy Napier',  'head_coach'),
--   ('<sc-staff-uuid>',         'Dr. Sarah Mitchell',  'sc_staff'),
--   ('<athletic-trainer-uuid>', 'Marcus Thompson ATC', 'athletic_trainer');
--
-- Replace the placeholder UUIDs above with real UUIDs from Supabase Auth > Users.
-- ═══════════════════════════════════════════════════════════════════════════

-- ═══════════════════════════════════════════════════════════════════════════
-- ATHLETES — 85-Man D1 Florida Gators Simulated Roster
-- Positional distribution:
--   QB:4  RB:6  WR:10  TE:5  OL:14  DL:12  LB:10  DB:12  K/P:2  ST:10
-- ═══════════════════════════════════════════════════════════════════════════

INSERT INTO public.athletes (id, name, jersey_number, position, class_year, height_in, weight_lbs, status) VALUES

-- ── QBs (4) ──────────────────────────────────────────────────────────────
('a0000001-0000-0000-0000-000000000001','Marcus Rivers',       1, 'QB','JR',75,215,'Active'),
('a0000001-0000-0000-0000-000000000002','Devon Cole',         14, 'QB','SO',74,205,'Active'),
('a0000001-0000-0000-0000-000000000003','Trey Washington',    10, 'QB','FR',73,195,'Active'),
('a0000001-0000-0000-0000-000000000004','Austin Pierce',      16, 'QB','SR',76,220,'Active'),

-- ── RBs (6) ──────────────────────────────────────────────────────────────
('a0000002-0000-0000-0000-000000000001','Jaylen Booker',       4, 'RB','JR',69,210,'Active'),
('a0000002-0000-0000-0000-000000000002','Damien Cross',       24, 'RB','SO',68,205,'Active'),
('a0000002-0000-0000-0000-000000000003','Keon Simmons',       28, 'RB','SR',70,215,'Active'),
('a0000002-0000-0000-0000-000000000004','Rashad Moore',       34, 'RB','FR',69,200,'Active'),
('a0000002-0000-0000-0000-000000000005','Carlos Vega',        22, 'RB','JR',68,198,'Limited'),
('a0000002-0000-0000-0000-000000000006','Isaiah Grant',       32, 'RB','SO',70,212,'Active'),

-- ── WRs (10) ─────────────────────────────────────────────────────────────
('a0000003-0000-0000-0000-000000000001','Tyrese Hamilton',    2, 'WR','SR',73,185,'Active'),
('a0000003-0000-0000-0000-000000000002','DeShawn Carter',    11, 'WR','JR',72,180,'Active'),
('a0000003-0000-0000-0000-000000000003','Malik Johnson',      7, 'WR','SO',74,190,'Active'),
('a0000003-0000-0000-0000-000000000004','Cam Williams',      83, 'WR','FR',71,175,'Active'),
('a0000003-0000-0000-0000-000000000005','Jalen Brooks',       5, 'WR','JR',73,182,'Active'),
('a0000003-0000-0000-0000-000000000006','Darius Knight',     15, 'WR','SO',72,178,'Active'),
('a0000003-0000-0000-0000-000000000007','Antonio Reeves',    81, 'WR','SR',74,188,'Active'),
('a0000003-0000-0000-0000-000000000008','Kyle Preston',      13, 'WR','FR',70,172,'Active'),
('a0000003-0000-0000-0000-000000000009','Marcus Bell',       84, 'WR','JR',73,185,'Injured'),
('a0000003-0000-0000-0000-000000000010','Elijah Thomas',     18, 'WR','SO',72,183,'Active'),

-- ── TEs (5) ──────────────────────────────────────────────────────────────
('a0000004-0000-0000-0000-000000000001','Hunter Davis',       88, 'TE','SR',77,248,'Active'),
('a0000004-0000-0000-0000-000000000002','Bryce Coleman',      87, 'TE','JR',76,242,'Active'),
('a0000004-0000-0000-0000-000000000003','Tyler Nguyen',       89, 'TE','SO',78,250,'Active'),
('a0000004-0000-0000-0000-000000000004','Jordan Marsh',       80, 'TE','FR',76,235,'Active'),
('a0000004-0000-0000-0000-000000000005','Caleb Stone',        86, 'TE','GR',77,255,'Active'),

-- ── OL (14) ──────────────────────────────────────────────────────────────
('a0000005-0000-0000-0000-000000000001','Derrick Thompson',  70, 'OL','SR',77,310,'Active'),
('a0000005-0000-0000-0000-000000000002','Marcus Reid',       71, 'OL','JR',78,305,'Active'),
('a0000005-0000-0000-0000-000000000003','Brandon Walsh',     72, 'OL','SO',77,298,'Active'),
('a0000005-0000-0000-0000-000000000004','Isaiah Freeman',    73, 'OL','SR',78,315,'Active'),
('a0000005-0000-0000-0000-000000000005','Caleb Morrison',    74, 'OL','JR',76,302,'Active'),
('a0000005-0000-0000-0000-000000000006','Trevor Lane',       75, 'OL','SO',77,295,'Active'),
('a0000005-0000-0000-0000-000000000007','Donovan Price',     76, 'OL','FR',76,288,'Active'),
('a0000005-0000-0000-0000-000000000008','Malik Turner',      77, 'OL','GR',78,320,'Active'),
('a0000005-0000-0000-0000-000000000009','Kyle Barnes',       78, 'OL','SR',77,308,'Active'),
('a0000005-0000-0000-0000-000000000010','Jordan Ellis',      79, 'OL','JR',76,295,'Active'),
('a0000005-0000-0000-0000-000000000011','Darius Howell',     60, 'OL','SO',78,300,'Active'),
('a0000005-0000-0000-0000-000000000012','Chris Simmons',     61, 'OL','FR',77,285,'Active'),
('a0000005-0000-0000-0000-000000000013','Anthony Baker',     62, 'OL','SR',76,312,'Limited'),
('a0000005-0000-0000-0000-000000000014','Reggie Cole',       63, 'OL','JR',77,298,'Active'),

-- ── DL (12) ──────────────────────────────────────────────────────────────
('a0000006-0000-0000-0000-000000000001','Javon Harris',      90, 'DL','SR',76,285,'Active'),
('a0000006-0000-0000-0000-000000000002','DeAngelo White',    91, 'DL','JR',77,295,'Active'),
('a0000006-0000-0000-0000-000000000003','Marcus Owens',      92, 'DL','SO',75,278,'Active'),
('a0000006-0000-0000-0000-000000000004','Terrell King',      93, 'DL','SR',76,290,'Active'),
('a0000006-0000-0000-0000-000000000005','Devon Marshall',    94, 'DL','GR',78,310,'Active'),
('a0000006-0000-0000-0000-000000000006','James Cooper',      95, 'DL','JR',76,282,'Active'),
('a0000006-0000-0000-0000-000000000007','Ronnie Davis',      96, 'DL','SO',75,275,'Active'),
('a0000006-0000-0000-0000-000000000008','Khalil Brown',      97, 'DL','FR',77,270,'Active'),
('a0000006-0000-0000-0000-000000000009','Elijah Scott',      98, 'DL','SR',76,288,'Active'),
('a0000006-0000-0000-0000-000000000010','Nathan Ford',       99, 'DL','JR',77,292,'Active'),
('a0000006-0000-0000-0000-000000000011','Omar Reyes',        55, 'DL','SO',75,280,'Active'),
('a0000006-0000-0000-0000-000000000012','Darnell Hughes',    56, 'DL','FR',76,265,'Active'),

-- ── LBs (10) ─────────────────────────────────────────────────────────────
('a0000007-0000-0000-0000-000000000001','Zion Patterson',    41, 'LB','SR',74,235,'Active'),
('a0000007-0000-0000-0000-000000000002','DeShawn Lewis',     42, 'LB','JR',73,228,'Active'),
('a0000007-0000-0000-0000-000000000003','Marcus Green',      43, 'LB','SO',74,232,'Active'),
('a0000007-0000-0000-0000-000000000004','Tyrone Bell',       44, 'LB','FR',73,225,'Active'),
('a0000007-0000-0000-0000-000000000005','Cameron Ross',      45, 'LB','SR',75,240,'Active'),
('a0000007-0000-0000-0000-000000000006','Justin Hayes',      46, 'LB','JR',73,230,'Active'),
('a0000007-0000-0000-0000-000000000007','Andre Mitchell',    47, 'LB','SO',74,235,'Active'),
('a0000007-0000-0000-0000-000000000008','Darius Webb',       48, 'LB','GR',74,242,'Active'),
('a0000007-0000-0000-0000-000000000009','Kevin Stewart',     49, 'LB','FR',72,220,'Active'),
('a0000007-0000-0000-0000-000000000010','Malik Porter',      50, 'LB','SR',73,238,'Active'),

-- ── DBs (12) ─────────────────────────────────────────────────────────────
('a0000008-0000-0000-0000-000000000001','Jaylen Cooper',     23, 'DB','SR',71,188,'Active'),
('a0000008-0000-0000-0000-000000000002','Darius Evans',       6, 'DB','JR',70,182,'Active'),
('a0000008-0000-0000-0000-000000000003','Marcus Hill',       20, 'DB','SO',72,190,'Active'),
('a0000008-0000-0000-0000-000000000004','Cam Butler',        25, 'DB','FR',71,178,'Active'),
('a0000008-0000-0000-0000-000000000005','Isaiah Carter',     29, 'DB','SR',70,185,'Active'),
('a0000008-0000-0000-0000-000000000006','Tyrese Moore',      31, 'DB','JR',72,190,'Active'),
('a0000008-0000-0000-0000-000000000007','Elijah Price',      33, 'DB','SO',71,183,'Active'),
('a0000008-0000-0000-0000-000000000008','Jordan Clark',      26, 'DB','GR',72,195,'Active'),
('a0000008-0000-0000-0000-000000000009','Brandon Lee',       37, 'DB','FR',70,180,'Active'),
('a0000008-0000-0000-0000-000000000010','Trevon James',      39, 'DB','SR',71,186,'Active'),
('a0000008-0000-0000-0000-000000000011','Malik Washington',  27, 'DB','JR',70,183,'Active'),
('a0000008-0000-0000-0000-000000000012','Devin Sampson',     35, 'DB','SO',72,191,'Active'),

-- ── K/P (2) ──────────────────────────────────────────────────────────────
('a0000009-0000-0000-0000-000000000001','Ryan Hollis',       38, 'K', 'JR',71,185,'Active'),
('a0000009-0000-0000-0000-000000000002','Preston Mills',     40, 'P', 'SR',72,190,'Active'),

-- ── Special Teams / Multi-position (10) ──────────────────────────────────
('a0000010-0000-0000-0000-000000000001','Derrick Nash',      17, 'ST','SR',72,205,'Active'),
('a0000010-0000-0000-0000-000000000002','Cameron Foxx',      36, 'ST','JR',71,200,'Active'),
('a0000010-0000-0000-0000-000000000003','Jalen Rivers',       3, 'ST','SO',70,195,'Active'),
('a0000010-0000-0000-0000-000000000004','Marcus Young',       8, 'ST','FR',73,208,'Active'),
('a0000010-0000-0000-0000-000000000005','Tyler Ross',        19, 'ST','SR',71,202,'Active'),
('a0000010-0000-0000-0000-000000000006','Devon Jackson',     21, 'ST','JR',72,198,'Active'),
('a0000010-0000-0000-0000-000000000007','Keon Bailey',       30, 'ST','SO',70,195,'Active'),
('a0000010-0000-0000-0000-000000000008','Isaiah Young',      53, 'ST','FR',74,215,'Active'),
('a0000010-0000-0000-0000-000000000009','Brandon Fox',       57, 'ST','SR',71,200,'Active'),
('a0000010-0000-0000-0000-000000000010','Quincy Adams',      58, 'ST','JR',72,205,'Active');

-- ═══════════════════════════════════════════════════════════════════════════
-- GPS SESSIONS — 28 days of data per athlete
-- Reference date: CURRENT_DATE (queries use relative offsets)
-- Strategy: use generate_series concept but expand manually for key athletes.
-- We insert bulk data using a DO block for realistic variation.
-- ═══════════════════════════════════════════════════════════════════════════

DO $$
DECLARE
    athlete RECORD;
    day_offset INT;
    base_load NUMERIC;
    base_dist NUMERIC;
    daily_load NUMERIC;
    daily_dist NUMERIC;
    hsd NUMERIC;
    sprint NUMERIC;
    rpe_val INT;
    dur_val INT;
    -- ACWR spike athletes (intentional)
    spike_athletes UUID[] := ARRAY[
        'a0000003-0000-0000-0000-000000000001'::UUID,  -- Tyrese Hamilton WR
        'a0000002-0000-0000-0000-000000000001'::UUID,  -- Jaylen Booker RB
        'a0000008-0000-0000-0000-000000000002'::UUID,  -- Darius Evans DB
        'a0000007-0000-0000-0000-000000000001'::UUID   -- Zion Patterson LB
    ];
    is_spike BOOLEAN;
BEGIN
    FOR athlete IN SELECT id, position, weight_lbs FROM public.athletes LOOP
        -- Set base load and distance by position group
        IF athlete.position IN ('OL','DL') THEN
            base_load := 280 + random()*40;
            base_dist := 3800 + random()*600;
        ELSIF athlete.position IN ('QB','K','P') THEN
            base_load := 200 + random()*40;
            base_dist := 3200 + random()*400;
        ELSIF athlete.position IN ('WR','DB','RB') THEN
            base_load := 350 + random()*60;
            base_dist := 5000 + random()*800;
        ELSIF athlete.position IN ('LB','TE') THEN
            base_load := 310 + random()*50;
            base_dist := 4200 + random()*600;
        ELSE
            base_load := 290 + random()*50;
            base_dist := 4000 + random()*600;
        END IF;

        is_spike := athlete.id = ANY(spike_athletes);

        FOR day_offset IN 0..27 LOOP
            -- Weekend rest pattern (day 6 and 13 and 20 = lighter)
            IF day_offset % 7 = 6 THEN
                daily_load := base_load * (0.3 + random()*0.2);
                daily_dist := base_dist * (0.35 + random()*0.15);
                rpe_val    := 4 + (random()*2)::INT;
                dur_val    := 30 + (random()*20)::INT;
            ELSIF day_offset % 7 = 0 THEN
                -- Game day / heavy session
                daily_load := base_load * (1.1 + random()*0.2);
                daily_dist := base_dist * (1.1 + random()*0.2);
                rpe_val    := 7 + (random()*2)::INT;
                dur_val    := 90 + (random()*30)::INT;
            ELSE
                daily_load := base_load * (0.8 + random()*0.4);
                daily_dist := base_dist * (0.8 + random()*0.4);
                rpe_val    := 5 + (random()*3)::INT;
                dur_val    := 60 + (random()*30)::INT;
            END IF;

            -- Inject ACWR spike: inflate last 7 days dramatically
            IF is_spike AND day_offset <= 6 THEN
                daily_load := base_load * (1.8 + random()*0.4);
                daily_dist := base_dist * (1.7 + random()*0.3);
            END IF;

            -- Derived metrics
            hsd    := daily_dist * (0.12 + random()*0.08);
            sprint := hsd * (0.25 + random()*0.15);

            INSERT INTO public.gps_sessions
                (athlete_id, session_date, total_distance_m, high_speed_distance_m,
                 sprint_distance_m, player_load, session_rpe, session_duration_min)
            VALUES
                (athlete.id,
                 CURRENT_DATE - day_offset,
                 ROUND(daily_dist::NUMERIC, 1),
                 ROUND(hsd::NUMERIC, 1),
                 ROUND(sprint::NUMERIC, 1),
                 ROUND(daily_load::NUMERIC, 2),
                 LEAST(rpe_val, 10),
                 dur_val);
        END LOOP;
    END LOOP;
END $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- CMJ TESTS — 4–6 tests per athlete over 8 weeks
-- ═══════════════════════════════════════════════════════════════════════════

DO $$
DECLARE
    athlete RECORD;
    test_num INT;
    num_tests INT;
    base_jump NUMERIC;
    base_force NUMERIC;
    base_power NUMERIC;
    jump_h NUMERIC;
    pk_force NUMERIC;
    pk_power NUMERIC;
    rsi NUMERIC;
    con_imp NUMERIC;
    ecc_imp NUMERIC;
    asym NUMERIC;
    test_date DATE;
    -- CMJ drop athletes
    drop_athletes UUID[] := ARRAY[
        'a0000003-0000-0000-0000-000000000003'::UUID,  -- Malik Johnson WR
        'a0000007-0000-0000-0000-000000000005'::UUID,  -- Cameron Ross LB
        'a0000002-0000-0000-0000-000000000003'::UUID   -- Keon Simmons RB
    ];
    is_drop BOOLEAN;
BEGIN
    FOR athlete IN SELECT id, position, weight_lbs FROM public.athletes LOOP
        -- Positional baselines
        IF athlete.position IN ('WR','DB','RB') THEN
            base_jump  := 45 + random()*20;   -- 45–65 cm
            base_force := 1800 + random()*600;
            base_power := 3500 + random()*1500;
        ELSIF athlete.position IN ('OL','DL') THEN
            base_jump  := 25 + random()*10;   -- 25–35 cm
            base_force := 2200 + random()*800;
            base_power := 2800 + random()*800;
        ELSIF athlete.position IN ('QB','K','P') THEN
            base_jump  := 38 + random()*12;
            base_force := 1600 + random()*500;
            base_power := 3000 + random()*1000;
        ELSE  -- LB, TE, ST
            base_jump  := 38 + random()*15;
            base_force := 1900 + random()*600;
            base_power := 3200 + random()*1000;
        END IF;

        is_drop  := athlete.id = ANY(drop_athletes);
        num_tests := 4 + (random()*2)::INT;  -- 4 or 5

        FOR test_num IN 1..num_tests LOOP
            -- Space tests roughly every 10–14 days
            test_date := CURRENT_DATE - ((num_tests - test_num) * 12 + (random()*4)::INT);

            -- Add natural variation
            jump_h   := base_jump * (0.95 + random()*0.10);
            pk_force := base_force * (0.95 + random()*0.10);
            pk_power := base_power * (0.95 + random()*0.10);

            -- Inject CMJ drop on most recent test for flagged athletes
            IF is_drop AND test_num = num_tests THEN
                jump_h := base_jump * (0.72 + random()*0.06);  -- ~25% drop (triggers red)
            END IF;

            rsi     := (jump_h / 100.0) / (0.28 + random()*0.12);
            con_imp := pk_force * (0.18 + random()*0.06);
            ecc_imp := pk_force * (0.22 + random()*0.08);
            asym    := 2.0 + random()*8.0;  -- 2–10% is typical

            INSERT INTO public.cmj_tests
                (athlete_id, test_date, jump_height_cm, peak_force_n, peak_power_w,
                 rsi_modified, concentric_impulse_ns, eccentric_decel_impulse_ns,
                 asymmetry_index_pct)
            VALUES
                (athlete.id, test_date,
                 ROUND(jump_h::NUMERIC, 2),
                 ROUND(pk_force::NUMERIC, 1),
                 ROUND(pk_power::NUMERIC, 1),
                 ROUND(rsi::NUMERIC, 3),
                 ROUND(con_imp::NUMERIC, 1),
                 ROUND(ecc_imp::NUMERIC, 1),
                 ROUND(asym::NUMERIC, 2));
        END LOOP;
    END LOOP;
END $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- NORDBORD TESTS — 3–4 tests per athlete
-- ═══════════════════════════════════════════════════════════════════════════

DO $$
DECLARE
    athlete RECORD;
    test_num INT;
    num_tests INT;
    lf NUMERIC;
    rf NUMERIC;
    lsi NUMERIC;
    bw_n NUMERIC;
    bw_ratio NUMERIC;
    test_date DATE;
    -- LSI deficit athletes (intentional)
    deficit_athletes UUID[] := ARRAY[
        'a0000003-0000-0000-0000-000000000009'::UUID,  -- Marcus Bell WR (Injured)
        'a0000002-0000-0000-0000-000000000005'::UUID   -- Carlos Vega RB (Limited)
    ];
    is_deficit BOOLEAN;
BEGIN
    FOR athlete IN SELECT id, weight_lbs FROM public.athletes LOOP
        is_deficit := athlete.id = ANY(deficit_athletes);
        num_tests  := 3 + (random())::INT;  -- 3 or 4
        bw_n       := athlete.weight_lbs * 4.44822;

        FOR test_num IN 1..num_tests LOOP
            test_date := CURRENT_DATE - ((num_tests - test_num) * 14 + (random()*5)::INT);

            -- Normal athletes: symmetric ~250–380N each side
            lf := 250 + random()*130;
            rf := lf * (0.94 + random()*0.12);  -- slight asymmetry

            -- Deficit athletes: clear imbalance
            IF is_deficit THEN
                lf := 180 + random()*40;   -- below 200N threshold on weaker side
                rf := 290 + random()*80;
            END IF;

            lsi      := LEAST(lf, rf) / GREATEST(lf, rf) * 100;
            bw_ratio := GREATEST(lf, rf) / bw_n;

            INSERT INTO public.nordbord_tests
                (athlete_id, test_date, left_peak_force_n, right_peak_force_n, lsi_pct, bw_ratio)
            VALUES
                (athlete.id, test_date,
                 ROUND(lf::NUMERIC, 1),
                 ROUND(rf::NUMERIC, 1),
                 ROUND(lsi::NUMERIC, 2),
                 ROUND(bw_ratio::NUMERIC, 4));
        END LOOP;
    END LOOP;
END $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- FLAGS — Intentional flags matching injected data anomalies
-- ═══════════════════════════════════════════════════════════════════════════

INSERT INTO public.flags
    (athlete_id, flag_date, flag_type, severity, triggered_by, recommended_action, resolved)
VALUES

-- ACWR Spikes
('a0000003-0000-0000-0000-000000000001', CURRENT_DATE,     'ACWR Spike',  'HIGH',
 'ACWR = 1.78 (Acute: 2,890 | Chronic: 1,623)',
 'Reduce volume 20–30%. No max-effort sessions. Daily monitoring required.', FALSE),

('a0000002-0000-0000-0000-000000000001', CURRENT_DATE,     'ACWR Spike',  'HIGH',
 'ACWR = 1.65 (Acute: 2,640 | Chronic: 1,600)',
 'Reduce volume 20–30%. No max-effort sessions. Daily monitoring required.', FALSE),

('a0000008-0000-0000-0000-000000000002', CURRENT_DATE,     'ACWR Spike',  'MODERATE',
 'ACWR = 1.52 (Acute: 2,510 | Chronic: 1,650)',
 'Monitor load closely. Reduce intensity if wellness score is low.', FALSE),

('a0000007-0000-0000-0000-000000000001', CURRENT_DATE - 1, 'ACWR Spike',  'MODERATE',
 'ACWR = 1.55 (Acute: 2,420 | Chronic: 1,561)',
 'Monitor load closely. Reduce intensity if wellness score is low.', FALSE),

-- CMJ Drops
('a0000003-0000-0000-0000-000000000003', CURRENT_DATE,     'CMJ Drop',    'HIGH',
 'Jump Height 27.2 cm vs. baseline 38.6 cm (−29.5%)',
 'Reduce volume 20–30%. No max-effort lifts. Assess for fatigue or injury.', FALSE),

('a0000007-0000-0000-0000-000000000005', CURRENT_DATE,     'CMJ Drop',    'HIGH',
 'Jump Height 28.4 cm vs. baseline 40.1 cm (−29.2%)',
 'Reduce volume 20–30%. No max-effort lifts. Assess for fatigue or injury.', FALSE),

('a0000002-0000-0000-0000-000000000003', CURRENT_DATE - 1, 'CMJ Drop',    'MODERATE',
 'Jump Height 34.1 cm vs. baseline 40.6 cm (−16.0%)',
 'Monitor — reduce intensity if subjective wellness is low.', FALSE),

-- NordBord Deficits
('a0000003-0000-0000-0000-000000000009', CURRENT_DATE,     'NordBord Deficit', 'HIGH',
 'LSI = 61.4% (Left: 183N, Right: 298N). Absolute force left limb < 200N.',
 'Refer to athletic trainer. Halt full-speed running. Begin hamstring rehab protocol.', FALSE),

('a0000002-0000-0000-0000-000000000005', CURRENT_DATE,     'NordBord Deficit', 'HIGH',
 'LSI = 63.8% (Left: 191N, Right: 299N). Absolute force left limb < 200N.',
 'Refer to athletic trainer. RTP protocol active. Daily NordBord retest.', FALSE),

-- High Strain (auto-correlated with ACWR spikes)
('a0000003-0000-0000-0000-000000000001', CURRENT_DATE,     'High Strain', 'HIGH',
 'Strain = 4,812 (top 5% of squad). Monotony = 2.34.',
 'Mandatory rest day. Reassess acute load before next session.', FALSE),

-- Injury History Risk
('a0000003-0000-0000-0000-000000000009', CURRENT_DATE,     'Injury History Risk', 'HIGH',
 'Status: Injured. NordBord LSI 61.4% — RTP threshold not met.',
 'Clear with medical staff before return. NordBord LSI target ≥ 90%.', FALSE),

('a0000002-0000-0000-0000-000000000005', CURRENT_DATE,     'Injury History Risk', 'MODERATE',
 'Status: Limited. Multiple consecutive sessions with elevated asymmetry.',
 'Modified training only. No contact drills. Re-evaluate in 3 days.', FALSE),

-- Asymmetry Alert
('a0000006-0000-0000-0000-000000000003', CURRENT_DATE - 2, 'Asymmetry Alert', 'MODERATE',
 'CMJ Asymmetry Index = 14.3% (threshold: 10%)',
 'Review unilateral training. Consider FMS screen. Monitor next test.', FALSE),

-- Resolved example
('a0000005-0000-0000-0000-000000000013', CURRENT_DATE - 5, 'ACWR Spike',  'MODERATE',
 'ACWR = 1.48 (Acute: 1,890 | Chronic: 1,276)',
 'Reduced practice load for 2 days. Monitor.', TRUE);

-- ═══════════════════════════════════════════════════════════════════════════
-- INDEXES for performance
-- ═══════════════════════════════════════════════════════════════════════════

CREATE INDEX IF NOT EXISTS idx_gps_athlete_date   ON public.gps_sessions   (athlete_id, session_date DESC);
CREATE INDEX IF NOT EXISTS idx_cmj_athlete_date   ON public.cmj_tests       (athlete_id, test_date DESC);
CREATE INDEX IF NOT EXISTS idx_nord_athlete_date  ON public.nordbord_tests  (athlete_id, test_date DESC);
CREATE INDEX IF NOT EXISTS idx_flags_athlete_date ON public.flags           (athlete_id, flag_date DESC);
CREATE INDEX IF NOT EXISTS idx_flags_resolved     ON public.flags           (resolved, flag_date DESC);

-- ═══════════════════════════════════════════════════════════════════════════
-- VERIFICATION QUERIES (run after seed to sanity-check counts)
-- ═══════════════════════════════════════════════════════════════════════════
-- SELECT COUNT(*) FROM public.athletes;          -- expect 85
-- SELECT COUNT(*) FROM public.gps_sessions;      -- expect ~2380 (85 × 28)
-- SELECT COUNT(*) FROM public.cmj_tests;         -- expect ~370–425 (85 × 4–5)
-- SELECT COUNT(*) FROM public.nordbord_tests;    -- expect ~297–340 (85 × 3–4)
-- SELECT COUNT(*) FROM public.flags;             -- expect 15
-- SELECT position, COUNT(*) FROM public.athletes GROUP BY position ORDER BY COUNT(*) DESC;
