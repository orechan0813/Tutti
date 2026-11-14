-- 練習予定の「全体の活動枠」と「細かいタイムテーブル」を分けて登録できるようにする。
-- Supabase の SQL Editor に貼り付けて Run してください。何度実行しても安全です。
-- ※ アプリ（index.html）を GitHub に反映する「前」に実行してください。
BEGIN;

-- 1) 活動枠：開始時刻を決めない予定にも対応（終了時刻は既存の ends_at 列を使う）
ALTER TABLE public.schedules
  ADD COLUMN IF NOT EXISTS starts_time_set boolean NOT NULL DEFAULT true;

-- 2) タイムテーブル（活動枠の中の細かいメニュー）
CREATE TABLE IF NOT EXISTS public.schedule_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  schedule_id uuid NOT NULL REFERENCES public.schedules(id) ON DELETE CASCADE,
  school_id uuid NOT NULL REFERENCES public.schools(id) ON DELETE CASCADE,
  title text NOT NULL,
  start_time time,
  end_time time,
  sort_order integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT schedule_items_title_ok CHECK (pg_catalog.length(pg_catalog.btrim(title)) BETWEEN 1 AND 60),
  CONSTRAINT schedule_items_order_ok CHECK (start_time IS NULL OR end_time IS NULL OR end_time > start_time)
);
CREATE INDEX IF NOT EXISTS schedule_items_schedule_idx ON public.schedule_items (schedule_id, sort_order);
CREATE INDEX IF NOT EXISTS schedule_items_school_idx ON public.schedule_items (school_id);

ALTER TABLE public.schedule_items ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.schedule_items FROM PUBLIC, anon, authenticated;

DROP POLICY IF EXISTS schedule_items_read ON public.schedule_items;
CREATE POLICY schedule_items_read ON public.schedule_items
  FOR SELECT TO authenticated
  USING ((SELECT private.is_school_member(school_id)));

-- 閲覧だけ。登録・変更は下の関数（管理者のみ）を通します。
GRANT SELECT ON TABLE public.schedule_items TO authenticated;

-- 3) 予定の保存（新規・編集どちらも）。活動枠とタイムテーブルを一度にまとめて保存します。
--    p_id が空なら新規、入っていれば編集。p_items は [{"title":"…","start":"16:00","end":"16:30"}, …]
CREATE OR REPLACE FUNCTION public.save_schedule(
  p_id uuid,
  p_school_id uuid,
  p_title text,
  p_location text,
  p_content text,
  p_date date,
  p_start time,
  p_end time,
  p_items jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_user_id uuid := (SELECT auth.uid());
  v_id uuid;
  v_starts timestamptz;
  v_ends timestamptz;
  v_title text := pg_catalog.btrim(p_title);
  v_location text := pg_catalog.btrim(p_location);
  v_content text := COALESCE(pg_catalog.btrim(p_content), '');
  v_item jsonb;
  v_item_title text;
  v_item_start time;
  v_item_end time;
  v_index integer := 0;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'ログインが必要です。';
  END IF;
  IF p_school_id IS NULL OR NOT (SELECT private.is_school_admin(p_school_id)) THEN
    RAISE EXCEPTION '予定を登録できるのは管理者のみです。';
  END IF;
  IF v_title IS NULL OR v_title = '' THEN
    RAISE EXCEPTION '練習内容を入力してください。';
  END IF;
  IF v_location IS NULL OR v_location = '' THEN
    RAISE EXCEPTION '場所を入力してください。';
  END IF;
  IF p_date IS NULL THEN
    RAISE EXCEPTION '日付を入力してください。';
  END IF;
  IF p_start IS NOT NULL AND p_end IS NOT NULL AND p_end <= p_start THEN
    RAISE EXCEPTION '終了時刻は開始時刻より後にしてください。';
  END IF;
  IF p_items IS NOT NULL AND pg_catalog.jsonb_typeof(p_items) <> 'array' THEN
    RAISE EXCEPTION 'タイムテーブルの形式が正しくありません。';
  END IF;
  IF p_items IS NOT NULL AND pg_catalog.jsonb_array_length(p_items) > 50 THEN
    RAISE EXCEPTION 'タイムテーブルは50件までです。';
  END IF;

  -- 時刻はすべて日本時間として保存する。開始が未指定の日は 0:00 に置き、starts_time_set を false にする。
  v_starts := ((p_date + COALESCE(p_start, time '00:00')) AT TIME ZONE 'Asia/Tokyo');
  v_ends := CASE WHEN p_end IS NULL THEN NULL ELSE ((p_date + p_end) AT TIME ZONE 'Asia/Tokyo') END;
  IF v_ends IS NOT NULL AND v_ends <= v_starts THEN
    RAISE EXCEPTION '終了時刻は開始時刻より後にしてください。';
  END IF;

  IF p_id IS NULL THEN
    INSERT INTO public.schedules (school_id, title, content, starts_at, ends_at, location, starts_time_set, created_by)
    VALUES (p_school_id, v_title, v_content, v_starts, v_ends, v_location, p_start IS NOT NULL, v_user_id)
    RETURNING id INTO v_id;
  ELSE
    UPDATE public.schedules
    SET title = v_title,
        content = v_content,
        starts_at = v_starts,
        ends_at = v_ends,
        location = v_location,
        starts_time_set = (p_start IS NOT NULL)
    WHERE id = p_id AND school_id = p_school_id
    RETURNING id INTO v_id;
    IF v_id IS NULL THEN
      RAISE EXCEPTION '予定が見つかりません。すでに削除された可能性があります。';
    END IF;
    DELETE FROM public.schedule_items WHERE schedule_id = v_id;
  END IF;

  FOR v_item IN
    SELECT e.value
    FROM pg_catalog.jsonb_array_elements(COALESCE(p_items, '[]'::jsonb)) WITH ORDINALITY AS e(value, ord)
    ORDER BY e.ord
  LOOP
    v_item_title := pg_catalog.btrim(v_item ->> 'title');
    IF v_item_title IS NULL OR v_item_title = '' THEN
      RAISE EXCEPTION 'メニュー名を入力してください。';
    END IF;
    IF pg_catalog.length(v_item_title) > 60 THEN
      RAISE EXCEPTION 'メニュー名は60文字以内にしてください。';
    END IF;
    v_item_start := NULLIF(v_item ->> 'start', '')::time;
    v_item_end := NULLIF(v_item ->> 'end', '')::time;
    IF v_item_start IS NOT NULL AND v_item_end IS NOT NULL AND v_item_end <= v_item_start THEN
      RAISE EXCEPTION '「%」の終了時刻は開始時刻より後にしてください。', v_item_title;
    END IF;
    INSERT INTO public.schedule_items (schedule_id, school_id, title, start_time, end_time, sort_order)
    VALUES (v_id, p_school_id, v_item_title, v_item_start, v_item_end, v_index);
    v_index := v_index + 1;
  END LOOP;

  RETURN v_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.save_schedule(uuid, uuid, text, text, text, date, time, time, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.save_schedule(uuid, uuid, text, text, text, date, time, time, jsonb) TO authenticated;

-- 4) リアルタイム更新（タイムテーブルの変更が他の人の画面にも反映される）
DO $publication$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'schedule_items'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.schedule_items;
  END IF;
END;
$publication$;

COMMIT;
