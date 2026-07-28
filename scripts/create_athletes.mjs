import { createClient } from '@supabase/supabase-js';

const SB = createClient(
  'https://fyhgvxfrwbwuqxllodip.supabase.co',
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImZ5aGd2eGZyd2J3dXF4bGxvZGlwIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc3OTEzOTk4MiwiZXhwIjoyMDk0NzE1OTgyfQ.owiY2QAJQiEG6-HqX8IDENdvuKK7MxcU8oEr5mkGFKo',
  { auth: { autoRefreshToken: false, persistSession: false } }
);

const { data: test, error: testErr } = await SB.auth.admin.listUsers();
console.log('Admin API test:', testErr ? testErr.message : `OK — ${test.users.length} users found`);

const staff = [
  ['MADDIE PERONTO','mperonto','GatorSC2026!Staff'],
  ['WILL NGUYEN','wnguyen','GatorSC2026!Staff'],
  ['CANNON TIBBALS','ctibbals','GatorSC2026!Staff'],
];

let created = 0, failed = 0;

for (const [name, username, password] of staff) {
  const email = `${username}@uf-ams.internal`;

  const { data, error } = await SB.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
    user_metadata: { display_name: name }
  });

  if (error) {
    if (error.message?.includes('already been registered') || error.message?.includes('already exists')) {
      console.log(`SKIP (exists): ${username}`);
    } else {
      console.error(`FAIL: ${username} — ${JSON.stringify(error)}`);
      failed++;
    }
    continue;
  }

  const { error: pErr } = await SB.from('profiles').insert({
    id: data.user.id,
    full_name: name,
    display_name: name,
    role: 'sc_staff',
    username,
    temporary_password: password
  });

  if (pErr) {
    console.error(`PROFILE FAIL: ${username} — ${pErr.message}`);
    failed++;
  } else {
    console.log(`OK: ${username}`);
    created++;
  }
}

console.log(`\nDone — ${created} created, ${failed} failed`);