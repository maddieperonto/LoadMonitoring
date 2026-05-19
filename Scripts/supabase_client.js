// ═══════════════════════════════════════════════════════════════════════════
// supabase_client.js
// Initializes the Supabase JS client and exports it for use across all pages.
//
// SETUP: Replace the two placeholder values below with your real project
// credentials from: Supabase Dashboard → Project Settings → API
//
// YOUR_SUPABASE_URL  → "Project URL"  (looks like https://xxxx.supabase.co)
// YOUR_SUPABASE_ANON_KEY → "anon public" key (long JWT string)
//
// These values are safe to expose in client-side code — they are public
// keys. Access control is enforced by Row Level Security in the database.
// ═══════════════════════════════════════════════════════════════════════════

import { createClient } from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js/+esm';

const SUPABASE_URL      = 'https://fyhgvxfrwbwuqxllodip.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImZ5aGd2eGZyd2J3dXF4bGxvZGlwIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzkxMzk5ODIsImV4cCI6MjA5NDcxNTk4Mn0.665OZwCsBvnHCVZ-ApiF2xM1CBgTIYZe2EEbuW7IW3U';

if (SUPABASE_URL === 'https://fyhgvxfrwbwuqxllodip.supabase.co' || SUPABASE_ANON_KEY === 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImZ5aGd2eGZyd2J3dXF4bGxvZGlwIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzkxMzk5ODIsImV4cCI6MjA5NDcxNTk4Mn0.665OZwCsBvnHCVZ-ApiF2xM1CBgTIYZe2EEbuW7IW3U') {
    console.error(
        '[UF S&C] ⚠️  Supabase credentials not configured.\n' +
        'Open /scripts/supabase_client.js and replace the placeholder values.\n' +
        'Find your credentials at: Supabase Dashboard → Project Settings → API'
    );
}

export const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
