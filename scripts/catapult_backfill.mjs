// Backfill script — re-triggers catapult-webhook Edge Function for all activities
// This uses the existing Edge Function which already has Catapult credentials stored

const EDGE_FUNCTION_URL = 'https://fyhgvxfrwbwuqxllodip.supabase.co/functions/v1/catapult-webhook';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImZ5aGd2eGZyd2J3dXF4bGxvZGlwIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzkxMzk5ODIsImV4cCI6MjA5NDcxNTk4Mn0.665OZwCsBvnHCVZ-ApiF2xM1CBgTIYZe2EEbuW7IW3U';

const activityIds = [
  '022a1a69-b7c1-4ac3-a744-151434fb24c6',
  '09ce6054-0b7f-4219-b765-1c23b8162ee1',
  '0c403ee3-f347-4488-9aa0-c143aaf43796',
  '130b3781-7386-4afc-b95e-a12e5403345c',
  '136fa98d-59b3-4ea7-beab-0a0d6ffe2dbc',
  '15463373-a48a-44e6-9aff-a007ea2ba91d',
  '1bfdbd68-ed62-4242-b415-1881c218ea8c',
  '1d0bddb0-c00b-4165-a0dd-7750d4ce9d49',
  '1d42da3f-09a7-458c-92fb-cad2f6a7f7d6',
  '22032dbe-f9a2-4a2f-b8fc-d76b49742bf1',
  '22b57ffe-03ad-464a-9fae-81ad6ee1e41f',
  '2348aa99-181d-47a9-9bd5-13a54a5a5e49',
  '250d7261-056c-44c0-8828-c1c5135516cd',
  '25af3cb8-9319-4742-b16c-7d6af661eb37',
  '2fa354e1-bb4d-49c8-90d7-3d68e68c08ff',
  '2fba11ac-dd73-47df-a3ff-c47e6494ee16',
  '32e4641d-97f8-4132-9167-eaaeed7dd9a1',
  '395ed244-4a04-444e-b55e-4f7a06cc20e1',
  '39a26bcc-6af2-454b-93f0-b98fad6f87d9',
  '400b6cd0-e8f0-4059-b6a6-ded6f699ffe9',
  '42a6f69f-a17f-4e8c-9ea2-074adfbba7dc',
  '464a0344-8604-4089-a509-2b3e2a279e72',
  '47755666-2174-4994-86bf-e15cb5ccb625',
  '51205828-1d3d-49e1-830a-37737392aa8d',
  '577fe319-3184-44c3-a91d-9369cda6deb3',
  '58c2bb40-4175-4c0b-b379-5d167b8d5d16',
  '5972ecce-f4fb-4483-af84-0e4157028bac',
  '59bd22be-d8d9-4105-aa99-f0051ab9cd11',
  '5d0b6b91-ab65-4fdb-b910-d8f0085fa54d',
  '626e4e30-57b1-4620-bad3-253cd533d1c4',
  '63072cd6-f09a-4bca-b363-71cee85fe60c',
  '64a6c8f8-d5ad-40d1-9d7c-4886cbe7f6a3',
  '657f23b3-0327-4bea-97b4-4d75a94e73a1',
  '6643c7a3-ae0c-4897-b81f-da333fdde956',
  '66b620e5-fb8a-45e6-8252-058dc88b4916',
  '68595227-0d8a-4533-b25d-441d4c9d09e5',
  '6b2d37c2-cd3e-4163-b80e-65037e395631',
  '75d987c5-4672-45d6-b9fa-46ee9024dbfb',
  '75e4bd17-b24d-44a1-bc06-57e5690ba331',
  '760d7a35-585d-4f9c-b745-dd9797994e0b',
  '77feb490-049a-435d-b5d1-fff04deb62c1',
  '7acd69a8-b1f2-43a4-ad3a-034a335252af',
  '7fa4926f-05d0-459b-a55e-205aa54f1b74',
  '809c057a-77a3-4f0e-bf26-3dc5417d2170',
  '820f13e5-7864-46ed-a0d1-33c95b793053',
  '82298409-da56-40dd-9741-0f3599922ecb',
  '8b22a015-8d44-44ca-bd0a-2d67c117a49e',
  '955eeab1-4627-4e47-9e73-5776c65df4e5',
  '98531b45-5788-494d-baaa-8c862b528fd4',
  '99966b0a-7475-4739-82bf-178798cda1dd',
  '9aa2568e-685d-4be8-b03f-7e63995920ff',
  '9f816892-776b-4089-a563-0a904c356b62',
  'a0f7415c-1be0-4e9c-8cd7-dacaa0e8fe9b',
  'a709349a-71dd-4020-96c1-94fe9a01878f',
  'afb081de-2e82-42db-8dc0-5e6276b69803',
  'b243bbaf-b41d-4220-bb4a-938147f0e82c',
  'b40d3c53-2ea0-4bb7-a556-d828ea52856c',
  'b4288c87-d306-48a3-ae46-a99c3568a86b',
  'b770fb42-8389-4672-829f-7d5b2f0f15dc',
  'bd1c4ec7-20ac-4b6e-b35c-dd9748cf6c73',
  'c1b509e8-292d-48b1-bae9-d084afcf12ea',
  'c3cd3f64-7bbe-4404-b4b9-67c7a2c2cda8',
  'c883f6d7-ac19-4e06-b2b3-79476a13c51a',
  'cc8bf81a-9586-40b5-87f2-52e870fda29f',
  'cd5d5a9c-aee5-47f6-ae06-999293ed5618',
  'cdd7b0b9-53e8-4e58-b668-3b30cc84ff15',
  'd080c42d-bb00-4ef4-8652-de3f39e17bed',
  'd1969e1c-a17b-4f68-9fc5-30e946c7fdf1',
  'd2b0943c-af3f-4663-ad28-d28cb88e8901',
  'd36ef916-356f-403f-a569-e3ba0010748c',
  'd74f6772-bc06-4d5a-a27f-3df5f8113118',
  'd91fe6e2-b0fc-45e6-b9f2-f083d0bd6b90',
  'da0b3faa-6936-42a1-84c8-719bc761383f',
  'dac3ff88-34c6-4a7e-a947-9f802ee59493',
  'db9924f7-9a71-41ef-aa93-c0bd7e3c3f56',
  'deeec8b4-8400-4fad-8909-480748a72662',
  'df21095b-e1d7-4e9a-97b8-4b2cb28ccd2b',
  'e1aafa72-3d7c-40a1-b4ca-f455a82f98ef',
  'e5e6c788-43c5-46ee-8577-b5cdca21c525',
  'ea3b2ab4-47a7-406b-81e9-a164d2b26f70',
  'ec90d0c7-6cf1-49a0-98b7-521584c24b0b',
  'f1929a12-1008-4880-8bd3-9298a1e91d64',
  'f2e0215f-b20a-4aa8-818f-898b71c79c53',
  'f5a1b0ef-2f1d-49f2-acac-92cd1108163d',
  'f5eeb92f-6863-4568-98cc-ea2396bfa6bb',
  'fb6eb62b-32bd-4808-a54a-8573631f06e5',
  'ff798071-59c5-4ae2-8f3f-af4092160c7e',
];

let success = 0, failed = 0;

for (let i = 0; i < activityIds.length; i++) {
  const activityId = activityIds[i];
  console.log(`[${i+1}/${activityIds.length}] Syncing ${activityId}...`);

  const res = await fetch(EDGE_FUNCTION_URL, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${SUPABASE_ANON_KEY}`,
    },
    body: JSON.stringify({
      topic: 'stats',
      action: 'updated',
      trigger: { id: activityId }
    }),
  });

  if (!res.ok) {
    const txt = await res.text();
    console.error(`FAIL: ${activityId} — ${res.status} ${txt}`);
    failed++;
  } else {
    console.log(`OK: ${activityId}`);
    success++;
  }

  // Delay to avoid overwhelming the Edge Function
  await new Promise(r => setTimeout(r, 500));
}

console.log(`\nDone — ${success} synced, ${failed} failed`);
