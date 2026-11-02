BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE SCHEMA IF NOT EXISTS private;
REVOKE ALL ON SCHEMA private FROM PUBLIC, anon, authenticated;
GRANT USAGE ON SCHEMA private TO authenticated;

CREATE TABLE IF NOT EXISTS public.schools (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  school_name text NOT NULL,
  club_name text NOT NULL,
  invite_code text NOT NULL DEFAULT upper(encode(gen_random_bytes(6), 'hex')),
  google_account_email text,
  google_drive_folder_url text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT schools_names_not_blank CHECK (
    length(trim(school_name)) > 0 AND length(trim(club_name)) > 0
  )
);

ALTER TABLE public.schools ADD COLUMN IF NOT EXISTS invite_code text;
UPDATE public.schools
SET invite_code = upper(encode(gen_random_bytes(6), 'hex'))
WHERE invite_code IS NULL OR length(trim(invite_code)) = 0;
ALTER TABLE public.schools
  ALTER COLUMN invite_code SET DEFAULT upper(encode(gen_random_bytes(6), 'hex')),
  ALTER COLUMN invite_code SET NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS schools_invite_code_uidx
  ON public.schools (invite_code);

COMMENT ON COLUMN public.schools.google_account_email IS
  'Email identifier only. Never store Google passwords or OAuth tokens here.';
COMMENT ON COLUMN public.schools.google_drive_folder_url IS
  'Drive folder URL only; enforce Google access through Google OAuth, not this URL.';

CREATE TABLE IF NOT EXISTS public.profiles (
  id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  school_id uuid NOT NULL REFERENCES public.schools(id) ON DELETE RESTRICT,
  full_name text NOT NULL,
  part text,
  is_admin boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT profiles_name_not_blank CHECK (length(trim(full_name)) > 0)
);

CREATE TABLE IF NOT EXISTS public.schedules (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  school_id uuid NOT NULL REFERENCES public.schools(id) ON DELETE RESTRICT,
  title text NOT NULL,
  content text NOT NULL DEFAULT '',
  starts_at timestamptz NOT NULL,
  ends_at timestamptz,
  location text NOT NULL,
  created_by uuid NOT NULL DEFAULT auth.uid() REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT schedules_title_not_blank CHECK (length(trim(title)) > 0),
  CONSTRAINT schedules_location_not_blank CHECK (length(trim(location)) > 0),
  CONSTRAINT schedules_end_after_start CHECK (ends_at IS NULL OR ends_at > starts_at)
);

CREATE TABLE IF NOT EXISTS public.reports (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  school_id uuid NOT NULL REFERENCES public.schools(id) ON DELETE RESTRICT,
  reporter_id uuid NOT NULL DEFAULT auth.uid() REFERENCES public.profiles(id) ON DELETE RESTRICT,
  kind text NOT NULL CHECK (kind IN ('absence', 'purchase_repair', 'lost_found')),
  report_date date NOT NULL DEFAULT CURRENT_DATE,
  title text NOT NULL,
  reason text NOT NULL DEFAULT '',
  arrival_at time,
  photo_url text,
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'approved', 'rejected', 'resolved')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT reports_title_not_blank CHECK (length(trim(title)) > 0),
  CONSTRAINT reports_arrival_only_for_absence CHECK (arrival_at IS NULL OR kind = 'absence')
);

CREATE TABLE IF NOT EXISTS public.songs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  school_id uuid NOT NULL REFERENCES public.schools(id) ON DELETE RESTRICT,
  title text NOT NULL,
  sort_reading text NOT NULL,
  composer text NOT NULL DEFAULT '',
  arranger text,
  drive_url text,
  youtube_url text,
  audio_file_path text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT songs_title_not_blank CHECK (length(trim(title)) > 0),
  CONSTRAINT songs_sort_reading_not_blank CHECK (length(trim(sort_reading)) > 0)
);

CREATE TABLE IF NOT EXISTS public.announcements (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  school_id uuid NOT NULL REFERENCES public.schools(id) ON DELETE RESTRICT,
  author_id uuid NOT NULL DEFAULT auth.uid() REFERENCES public.profiles(id) ON DELETE RESTRICT,
  title text NOT NULL,
  body text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT announcements_title_not_blank CHECK (length(trim(title)) > 0)
);

CREATE TABLE IF NOT EXISTS public.club_settings (
  school_id uuid PRIMARY KEY REFERENCES public.schools(id) ON DELETE RESTRICT,
  theme_page text NOT NULL DEFAULT '#f3f5ef' CHECK (theme_page ~ '^#[0-9A-Fa-f]{6}$'),
  theme_ink text NOT NULL DEFAULT '#19332f' CHECK (theme_ink ~ '^#[0-9A-Fa-f]{6}$'),
  theme_font text NOT NULL DEFAULT 'DM Sans' CHECK (theme_font IN ('DM Sans', 'Noto Sans JP')),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.equipment (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  school_id uuid NOT NULL REFERENCES public.schools(id) ON DELETE RESTRICT,
  name text NOT NULL,
  borrower_id uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  borrowed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT equipment_name_not_blank CHECK (length(trim(name)) > 0),
  CONSTRAINT equipment_borrowed_state_consistent CHECK (
    (borrower_id IS NULL) = (borrowed_at IS NULL)
  )
);

CREATE OR REPLACE FUNCTION private.provision_auth_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  registration_mode text;
  full_name_value text;
  school_name_value text;
  club_name_value text;
  invite_code_value text;
  part_value text;
  school_id_value uuid;
  admin_value boolean;
BEGIN
  registration_mode := NEW.raw_user_meta_data ->> 'registration_mode';
  full_name_value := nullif(pg_catalog.btrim(NEW.raw_user_meta_data ->> 'full_name'), '');
  part_value := nullif(pg_catalog.btrim(NEW.raw_user_meta_data ->> 'part'), '');

  IF full_name_value IS NULL THEN
    RAISE EXCEPTION '氏名を入力してください。';
  END IF;

  IF registration_mode = 'create' THEN
    school_name_value := nullif(pg_catalog.btrim(NEW.raw_user_meta_data ->> 'school_name'), '');
    club_name_value := nullif(pg_catalog.btrim(NEW.raw_user_meta_data ->> 'club_name'), '');
    IF school_name_value IS NULL OR club_name_value IS NULL THEN
      RAISE EXCEPTION '学校名と部活・団体名を入力してください。';
    END IF;

    INSERT INTO public.schools (school_name, club_name)
    VALUES (school_name_value, club_name_value)
    RETURNING id INTO school_id_value;
    admin_value := true;
  ELSIF registration_mode = 'join' THEN
    invite_code_value := pg_catalog.upper(
      pg_catalog.btrim(NEW.raw_user_meta_data ->> 'invite_code')
    );
    IF invite_code_value IS NULL OR invite_code_value !~ '^[0-9A-F]{12}$' THEN
      RAISE EXCEPTION '招待コードの形式が正しくありません。';
    END IF;

    SELECT s.id INTO school_id_value
    FROM public.schools AS s
    WHERE s.invite_code = invite_code_value;
    IF school_id_value IS NULL THEN
      RAISE EXCEPTION '招待コードが見つかりません。コードを確認してください。';
    END IF;
    admin_value := false;
  ELSE
    RAISE EXCEPTION '登録方法が正しくありません。';
  END IF;

  INSERT INTO public.profiles (id, school_id, full_name, part, is_admin)
  VALUES (NEW.id, school_id_value, full_name_value, part_value, admin_value);
  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION private.provision_auth_user() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS provision_profile_after_signup ON auth.users;
CREATE TRIGGER provision_profile_after_signup
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION private.provision_auth_user();

CREATE INDEX IF NOT EXISTS profiles_school_id_idx ON public.profiles (school_id);
CREATE INDEX IF NOT EXISTS schedules_school_starts_idx ON public.schedules (school_id, starts_at);
CREATE INDEX IF NOT EXISTS reports_school_date_idx ON public.reports (school_id, report_date DESC);
CREATE INDEX IF NOT EXISTS reports_school_status_idx ON public.reports (school_id, status, created_at DESC);
CREATE INDEX IF NOT EXISTS songs_school_sort_idx ON public.songs (school_id, sort_reading);
CREATE INDEX IF NOT EXISTS announcements_school_created_idx ON public.announcements (school_id, created_at DESC);
CREATE INDEX IF NOT EXISTS equipment_school_name_idx ON public.equipment (school_id, name);

CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $function$
BEGIN
  NEW.updated_at := pg_catalog.now();
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS schools_set_updated_at ON public.schools;
CREATE TRIGGER schools_set_updated_at
  BEFORE UPDATE ON public.schools
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

DROP TRIGGER IF EXISTS profiles_set_updated_at ON public.profiles;
CREATE TRIGGER profiles_set_updated_at
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

DROP TRIGGER IF EXISTS schedules_set_updated_at ON public.schedules;
CREATE TRIGGER schedules_set_updated_at
  BEFORE UPDATE ON public.schedules
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

DROP TRIGGER IF EXISTS reports_set_updated_at ON public.reports;
CREATE TRIGGER reports_set_updated_at
  BEFORE UPDATE ON public.reports
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

DROP TRIGGER IF EXISTS songs_set_updated_at ON public.songs;
CREATE TRIGGER songs_set_updated_at
  BEFORE UPDATE ON public.songs
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

DROP TRIGGER IF EXISTS club_settings_set_updated_at ON public.club_settings;
CREATE TRIGGER club_settings_set_updated_at
  BEFORE UPDATE ON public.club_settings
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

DROP TRIGGER IF EXISTS equipment_set_updated_at ON public.equipment;
CREATE TRIGGER equipment_set_updated_at
  BEFORE UPDATE ON public.equipment
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- Resolve the tenant from the authenticated user's server-provisioned profile.
-- SECURITY DEFINER avoids recursive profile RLS; the fixed empty search_path
-- and schema-qualified object names prevent search_path substitution attacks.
CREATE OR REPLACE FUNCTION private.current_school_id()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT p.school_id
  FROM public.profiles AS p
  WHERE p.id = (SELECT auth.uid())
  LIMIT 1
$function$;

CREATE OR REPLACE FUNCTION private.is_school_admin(target_school_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT EXISTS (
    SELECT 1
    FROM public.profiles AS p
    WHERE p.id = (SELECT auth.uid())
      AND p.school_id = target_school_id
      AND p.is_admin
  )
$function$;

REVOKE ALL ON FUNCTION private.current_school_id() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION private.is_school_admin(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.current_school_id() TO authenticated;
GRANT EXECUTE ON FUNCTION private.is_school_admin(uuid) TO authenticated;

ALTER TABLE public.schools ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.schedules ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reports ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.songs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.announcements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.club_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.equipment ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS schools_read_same_tenant ON public.schools;
CREATE POLICY schools_read_same_tenant ON public.schools
  FOR SELECT TO authenticated
  USING (id = (SELECT private.current_school_id()));

DROP POLICY IF EXISTS schools_update_admin ON public.schools;
CREATE POLICY schools_update_admin ON public.schools
  FOR UPDATE TO authenticated
  USING ((SELECT private.is_school_admin(id)))
  WITH CHECK ((SELECT private.is_school_admin(id)));

DROP POLICY IF EXISTS profiles_read_same_tenant ON public.profiles;
CREATE POLICY profiles_read_same_tenant ON public.profiles
  FOR SELECT TO authenticated
  USING (school_id = (SELECT private.current_school_id()));

DROP POLICY IF EXISTS profiles_insert_admin ON public.profiles;
CREATE POLICY profiles_insert_admin ON public.profiles
  FOR INSERT TO authenticated
  WITH CHECK ((SELECT private.is_school_admin(school_id)));

DROP POLICY IF EXISTS profiles_update_self_or_admin ON public.profiles;
CREATE POLICY profiles_update_self_or_admin ON public.profiles
  FOR UPDATE TO authenticated
  USING (
    (id = (SELECT auth.uid()) AND school_id = (SELECT private.current_school_id()))
    OR (SELECT private.is_school_admin(school_id))
  )
  WITH CHECK (
    school_id = (SELECT private.current_school_id())
    AND (
      id = (SELECT auth.uid())
      OR (SELECT private.is_school_admin(school_id))
    )
    AND (NOT is_admin OR (SELECT private.is_school_admin(school_id)))
  );

DROP POLICY IF EXISTS profiles_delete_admin ON public.profiles;
CREATE POLICY profiles_delete_admin ON public.profiles
  FOR DELETE TO authenticated
  USING ((SELECT private.is_school_admin(school_id)));

DROP POLICY IF EXISTS schedules_read_same_tenant ON public.schedules;
CREATE POLICY schedules_read_same_tenant ON public.schedules
  FOR SELECT TO authenticated
  USING (school_id = (SELECT private.current_school_id()));

DROP POLICY IF EXISTS schedules_insert_admin ON public.schedules;
CREATE POLICY schedules_insert_admin ON public.schedules
  FOR INSERT TO authenticated
  WITH CHECK (
    school_id = (SELECT private.current_school_id())
    AND created_by = (SELECT auth.uid())
    AND (SELECT private.is_school_admin(school_id))
  );

DROP POLICY IF EXISTS schedules_update_admin ON public.schedules;
CREATE POLICY schedules_update_admin ON public.schedules
  FOR UPDATE TO authenticated
  USING ((SELECT private.is_school_admin(school_id)))
  WITH CHECK (school_id = (SELECT private.current_school_id()));

DROP POLICY IF EXISTS schedules_delete_admin ON public.schedules;
CREATE POLICY schedules_delete_admin ON public.schedules
  FOR DELETE TO authenticated
  USING ((SELECT private.is_school_admin(school_id)));

DROP POLICY IF EXISTS reports_read_same_tenant ON public.reports;
CREATE POLICY reports_read_same_tenant ON public.reports
  FOR SELECT TO authenticated
  USING (school_id = (SELECT private.current_school_id()));

DROP POLICY IF EXISTS reports_insert_same_tenant ON public.reports;
CREATE POLICY reports_insert_same_tenant ON public.reports
  FOR INSERT TO authenticated
  WITH CHECK (
    school_id = (SELECT private.current_school_id())
    AND reporter_id = (SELECT auth.uid())
  );

DROP POLICY IF EXISTS reports_update_admin ON public.reports;
CREATE POLICY reports_update_admin ON public.reports
  FOR UPDATE TO authenticated
  USING ((SELECT private.is_school_admin(school_id)))
  WITH CHECK (school_id = (SELECT private.current_school_id()));

DROP POLICY IF EXISTS reports_delete_admin ON public.reports;
CREATE POLICY reports_delete_admin ON public.reports
  FOR DELETE TO authenticated
  USING ((SELECT private.is_school_admin(school_id)));

DROP POLICY IF EXISTS songs_read_same_tenant ON public.songs;
CREATE POLICY songs_read_same_tenant ON public.songs
  FOR SELECT TO authenticated
  USING (school_id = (SELECT private.current_school_id()));

DROP POLICY IF EXISTS songs_insert_admin ON public.songs;
CREATE POLICY songs_insert_admin ON public.songs
  FOR INSERT TO authenticated
  WITH CHECK ((SELECT private.is_school_admin(school_id)));

DROP POLICY IF EXISTS songs_update_admin ON public.songs;
CREATE POLICY songs_update_admin ON public.songs
  FOR UPDATE TO authenticated
  USING ((SELECT private.is_school_admin(school_id)))
  WITH CHECK (school_id = (SELECT private.current_school_id()));

DROP POLICY IF EXISTS songs_delete_admin ON public.songs;
CREATE POLICY songs_delete_admin ON public.songs
  FOR DELETE TO authenticated
  USING ((SELECT private.is_school_admin(school_id)));

DROP POLICY IF EXISTS announcements_read_same_tenant ON public.announcements;
CREATE POLICY announcements_read_same_tenant ON public.announcements
  FOR SELECT TO authenticated
  USING (school_id = (SELECT private.current_school_id()));

DROP POLICY IF EXISTS announcements_insert_admin ON public.announcements;
CREATE POLICY announcements_insert_admin ON public.announcements
  FOR INSERT TO authenticated
  WITH CHECK (
    school_id = (SELECT private.current_school_id())
    AND author_id = (SELECT auth.uid())
    AND (SELECT private.is_school_admin(school_id))
  );

DROP POLICY IF EXISTS announcements_delete_admin ON public.announcements;
CREATE POLICY announcements_delete_admin ON public.announcements
  FOR DELETE TO authenticated
  USING ((SELECT private.is_school_admin(school_id)));

DROP POLICY IF EXISTS club_settings_read_same_tenant ON public.club_settings;
CREATE POLICY club_settings_read_same_tenant ON public.club_settings
  FOR SELECT TO authenticated
  USING (school_id = (SELECT private.current_school_id()));

DROP POLICY IF EXISTS club_settings_insert_admin ON public.club_settings;
CREATE POLICY club_settings_insert_admin ON public.club_settings
  FOR INSERT TO authenticated
  WITH CHECK (
    school_id = (SELECT private.current_school_id())
    AND (SELECT private.is_school_admin(school_id))
  );

DROP POLICY IF EXISTS club_settings_update_admin ON public.club_settings;
CREATE POLICY club_settings_update_admin ON public.club_settings
  FOR UPDATE TO authenticated
  USING ((SELECT private.is_school_admin(school_id)))
  WITH CHECK (school_id = (SELECT private.current_school_id()));

DROP POLICY IF EXISTS equipment_read_same_tenant ON public.equipment;
CREATE POLICY equipment_read_same_tenant ON public.equipment
  FOR SELECT TO authenticated
  USING (school_id = (SELECT private.current_school_id()));

DROP POLICY IF EXISTS equipment_insert_admin ON public.equipment;
CREATE POLICY equipment_insert_admin ON public.equipment
  FOR INSERT TO authenticated
  WITH CHECK ((SELECT private.is_school_admin(school_id)));

DROP POLICY IF EXISTS equipment_update_admin ON public.equipment;
CREATE POLICY equipment_update_admin ON public.equipment
  FOR UPDATE TO authenticated
  USING ((SELECT private.is_school_admin(school_id)))
  WITH CHECK (school_id = (SELECT private.current_school_id()));

DROP POLICY IF EXISTS equipment_delete_admin ON public.equipment;
CREATE POLICY equipment_delete_admin ON public.equipment
  FOR DELETE TO authenticated
  USING ((SELECT private.is_school_admin(school_id)));

-- RLS is necessary but table privileges are also required for Supabase roles.
REVOKE ALL ON TABLE public.schools, public.profiles, public.schedules,
  public.reports, public.songs, public.announcements, public.club_settings,
  public.equipment FROM anon, authenticated;

GRANT SELECT ON TABLE public.schools TO authenticated;
GRANT UPDATE (school_name, club_name, google_account_email, google_drive_folder_url)
  ON public.schools TO authenticated;

GRANT SELECT, DELETE ON TABLE public.profiles TO authenticated;
GRANT INSERT (id, school_id, full_name, part, is_admin)
  ON public.profiles TO authenticated;
GRANT UPDATE (full_name, part, is_admin) ON public.profiles TO authenticated;

GRANT SELECT, DELETE ON TABLE public.schedules TO authenticated;
GRANT INSERT (school_id, title, content, starts_at, ends_at, location)
  ON public.schedules TO authenticated;
GRANT UPDATE (title, content, starts_at, ends_at, location)
  ON public.schedules TO authenticated;

GRANT SELECT, DELETE ON TABLE public.reports TO authenticated;
GRANT INSERT (school_id, kind, report_date, title, reason, arrival_at, photo_url)
  ON public.reports TO authenticated;
GRANT UPDATE (status) ON public.reports TO authenticated;

GRANT SELECT, DELETE ON TABLE public.songs TO authenticated;
GRANT INSERT (school_id, title, sort_reading, composer, arranger, drive_url, youtube_url, audio_file_path)
  ON public.songs TO authenticated;
GRANT UPDATE (title, sort_reading, composer, arranger, drive_url, youtube_url, audio_file_path)
  ON public.songs TO authenticated;

GRANT SELECT, DELETE ON TABLE public.announcements TO authenticated;
GRANT INSERT (school_id, author_id, title, body)
  ON public.announcements TO authenticated;

GRANT SELECT ON TABLE public.club_settings TO authenticated;
GRANT INSERT (school_id, theme_page, theme_ink, theme_font)
  ON public.club_settings TO authenticated;
GRANT UPDATE (theme_page, theme_ink, theme_font)
  ON public.club_settings TO authenticated;

GRANT SELECT ON TABLE public.equipment TO authenticated;
GRANT INSERT (school_id, name, borrower_id, borrowed_at)
  ON public.equipment TO authenticated;
GRANT UPDATE (name, borrower_id, borrowed_at)
  ON public.equipment TO authenticated;
GRANT DELETE ON TABLE public.equipment TO authenticated;

-- The auth.users trigger provisions the initial school/profile atomically.
-- Never expose the service-role key to clients.

-- Store report photos in a private bucket at <school_id>/<unique-file-name>.
INSERT INTO storage.buckets (id, name, public)
VALUES ('report-photos', 'report-photos', false)
ON CONFLICT (id) DO UPDATE SET public = false;

INSERT INTO storage.buckets (id, name, public)
VALUES ('song-audio', 'song-audio', false)
ON CONFLICT (id) DO UPDATE SET public = false;

DROP POLICY IF EXISTS report_photos_read_same_tenant ON storage.objects;
CREATE POLICY report_photos_read_same_tenant ON storage.objects
  FOR SELECT TO authenticated
  USING (
    bucket_id = 'report-photos'
    AND (storage.foldername(name))[1] = (SELECT private.current_school_id())::text
  );

DROP POLICY IF EXISTS report_photos_upload_same_tenant ON storage.objects;
CREATE POLICY report_photos_upload_same_tenant ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'report-photos'
    AND (storage.foldername(name))[1] = (SELECT private.current_school_id())::text
  );

DROP POLICY IF EXISTS report_photos_delete_admin ON storage.objects;
CREATE POLICY report_photos_delete_admin ON storage.objects
  FOR DELETE TO authenticated
  USING (
    bucket_id = 'report-photos'
    AND (storage.foldername(name))[1] = (SELECT private.current_school_id())::text
    AND (SELECT private.is_school_admin((SELECT private.current_school_id())))
  );

DROP POLICY IF EXISTS song_audio_read_same_tenant ON storage.objects;
CREATE POLICY song_audio_read_same_tenant ON storage.objects
  FOR SELECT TO authenticated
  USING (
    bucket_id = 'song-audio'
    AND (storage.foldername(name))[1] = (SELECT private.current_school_id())::text
  );

DROP POLICY IF EXISTS song_audio_upload_admin ON storage.objects;
CREATE POLICY song_audio_upload_admin ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'song-audio'
    AND (storage.foldername(name))[1] = (SELECT private.current_school_id())::text
    AND (SELECT private.is_school_admin((SELECT private.current_school_id())))
  );

DROP POLICY IF EXISTS song_audio_update_admin ON storage.objects;
CREATE POLICY song_audio_update_admin ON storage.objects
  FOR UPDATE TO authenticated
  USING (
    bucket_id = 'song-audio'
    AND (storage.foldername(name))[1] = (SELECT private.current_school_id())::text
    AND (SELECT private.is_school_admin((SELECT private.current_school_id())))
  )
  WITH CHECK (
    bucket_id = 'song-audio'
    AND (storage.foldername(name))[1] = (SELECT private.current_school_id())::text
    AND (SELECT private.is_school_admin((SELECT private.current_school_id())))
  );

DROP POLICY IF EXISTS song_audio_delete_admin ON storage.objects;
CREATE POLICY song_audio_delete_admin ON storage.objects
  FOR DELETE TO authenticated
  USING (
    bucket_id = 'song-audio'
    AND (storage.foldername(name))[1] = (SELECT private.current_school_id())::text
    AND (SELECT private.is_school_admin((SELECT private.current_school_id())))
  );

-- Realtime only works for tables included in the Supabase publication.
DO $publication$
DECLARE
  table_name text;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_publication WHERE pubname = 'supabase_realtime'
  ) THEN
    RAISE EXCEPTION 'Supabase publication supabase_realtime does not exist';
  END IF;

  FOREACH table_name IN ARRAY ARRAY[
    'schools', 'profiles', 'schedules', 'reports', 'songs',
    'announcements', 'club_settings', 'equipment'
  ] LOOP
    IF NOT EXISTS (
      SELECT 1
      FROM pg_catalog.pg_publication_tables
      WHERE pubname = 'supabase_realtime'
        AND schemaname = 'public'
        AND tablename = table_name
    ) THEN
      EXECUTE pg_catalog.format(
        'ALTER PUBLICATION %I ADD TABLE public.%I',
        'supabase_realtime', table_name
      );
    END IF;
  END LOOP;
END;
$publication$;

COMMIT;