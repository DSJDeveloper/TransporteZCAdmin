-- Run this in Supabase SQL Editor to create/update the payments-evidence bucket and policies.
-- Idempotent: safe to run multiple times.

-- 1. Create the bucket (public so images are accessible via URL)
--    If it already exists, ensures `public = true` (critical — missing this causes 404).
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'payments-evidence',
  'payments-evidence',
  true,
  524288, -- 5 MB
  ARRAY['image/png', 'image/jpeg', 'image/jpg', 'image/webp', 'application/pdf']::text[]
)
ON CONFLICT (id) DO UPDATE SET
  public             = EXCLUDED.public,
  file_size_limit    = EXCLUDED.file_size_limit,
  allowed_mime_types = EXCLUDED.allowed_mime_types;

-- 2. Allow authenticated users to read from the bucket
CREATE POLICY "Authenticated users can read payments-evidence"
ON storage.objects FOR SELECT TO authenticated
USING (bucket_id = 'payments-evidence');

-- 3. Allow the service_role (via RPCs) to insert/update/delete
--    These are needed if the backend (import scripts, triggers) uploads files
CREATE POLICY "Service role can insert payments-evidence"
ON storage.objects FOR INSERT TO service_role
WITH CHECK (bucket_id = 'payments-evidence');

CREATE POLICY "Service role can update payments-evidence"
ON storage.objects FOR UPDATE TO service_role
USING (bucket_id = 'payments-evidence');

CREATE POLICY "Service role can delete payments-evidence"
ON storage.objects FOR DELETE TO service_role
USING (bucket_id = 'payments-evidence');
