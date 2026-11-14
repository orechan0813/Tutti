-- 備品貸出（個数管理）: 備品の種類と、貸出の記録を分けて管理します。
-- Supabase の SQL Editor に貼り付けて Run してください。何度実行しても安全です。
BEGIN;

CREATE TABLE IF NOT EXISTS public.equipment_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  school_id uuid NOT NULL REFERENCES public.schools(id) ON DELETE CASCADE,
  name text NOT NULL,
  total_count integer NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT equipment_items_name_not_blank CHECK (pg_catalog.length(pg_catalog.btrim(name)) > 0),
  CONSTRAINT equipment_items_name_len CHECK (pg_catalog.length(name) <= 40),
  CONSTRAINT equipment_items_total_range CHECK (total_count BETWEEN 1 AND 9999)
);
CREATE UNIQUE INDEX IF NOT EXISTS equipment_items_school_name_uidx
  ON public.equipment_items (school_id, name);

CREATE TABLE IF NOT EXISTS public.equipment_loans (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  item_id uuid NOT NULL REFERENCES public.equipment_items(id) ON DELETE CASCADE,
  school_id uuid NOT NULL REFERENCES public.schools(id) ON DELETE CASCADE,
  borrower_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  borrower_part text,
  quantity integer NOT NULL,
  borrowed_at timestamptz NOT NULL DEFAULT now(),
  returned_at timestamptz,
  CONSTRAINT equipment_loans_quantity_range CHECK (quantity BETWEEN 1 AND 9999),
  CONSTRAINT equipment_loans_part_len CHECK (borrower_part IS NULL OR pg_catalog.length(borrower_part) <= 40)
);
CREATE INDEX IF NOT EXISTS equipment_loans_item_active_idx
  ON public.equipment_loans (item_id) WHERE returned_at IS NULL;
CREATE INDEX IF NOT EXISTS equipment_loans_school_idx ON public.equipment_loans (school_id);

DROP TRIGGER IF EXISTS equipment_items_set_updated_at ON public.equipment_items;
CREATE TRIGGER equipment_items_set_updated_at
  BEFORE UPDATE ON public.equipment_items
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- 貸出中の数より少ない個数には変更できないようにする
CREATE OR REPLACE FUNCTION private.equipment_items_check_total()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_out integer;
BEGIN
  SELECT COALESCE(pg_catalog.sum(l.quantity), 0) INTO v_out
  FROM public.equipment_loans AS l
  WHERE l.item_id = NEW.id AND l.returned_at IS NULL;
  IF NEW.total_count < v_out THEN
    RAISE EXCEPTION '貸出中の数（%個）より少ない個数にはできません。', v_out;
  END IF;
  RETURN NEW;
END;
$function$;
REVOKE ALL ON FUNCTION private.equipment_items_check_total() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS equipment_items_check_total ON public.equipment_items;
CREATE TRIGGER equipment_items_check_total
  BEFORE UPDATE OF total_count ON public.equipment_items
  FOR EACH ROW EXECUTE FUNCTION private.equipment_items_check_total();

-- ---- 権限（RLS） ----
ALTER TABLE public.equipment_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.equipment_loans ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.equipment_items, public.equipment_loans FROM PUBLIC, anon, authenticated;

DROP POLICY IF EXISTS equipment_items_read ON public.equipment_items;
CREATE POLICY equipment_items_read ON public.equipment_items
  FOR SELECT TO authenticated
  USING ((SELECT private.is_school_member(school_id)));

DROP POLICY IF EXISTS equipment_items_insert_admin ON public.equipment_items;
CREATE POLICY equipment_items_insert_admin ON public.equipment_items
  FOR INSERT TO authenticated
  WITH CHECK ((SELECT private.is_school_admin(school_id)));

DROP POLICY IF EXISTS equipment_items_update_admin ON public.equipment_items;
CREATE POLICY equipment_items_update_admin ON public.equipment_items
  FOR UPDATE TO authenticated
  USING ((SELECT private.is_school_admin(school_id)))
  WITH CHECK ((SELECT private.is_school_admin(school_id)));

DROP POLICY IF EXISTS equipment_items_delete_admin ON public.equipment_items;
CREATE POLICY equipment_items_delete_admin ON public.equipment_items
  FOR DELETE TO authenticated
  USING ((SELECT private.is_school_admin(school_id)));

DROP POLICY IF EXISTS equipment_loans_read ON public.equipment_loans;
CREATE POLICY equipment_loans_read ON public.equipment_loans
  FOR SELECT TO authenticated
  USING ((SELECT private.is_school_member(school_id)));

GRANT SELECT ON TABLE public.equipment_items TO authenticated;
GRANT INSERT (school_id, name, total_count) ON public.equipment_items TO authenticated;
GRANT UPDATE (name, total_count) ON public.equipment_items TO authenticated;
GRANT DELETE ON TABLE public.equipment_items TO authenticated;
-- 貸出の記録は、下の関数経由でのみ増減できます（直接の書き込みは不可）
GRANT SELECT ON TABLE public.equipment_loans TO authenticated;

-- ---- 借りる ----
CREATE OR REPLACE FUNCTION public.borrow_equipment_item(p_item_id uuid, p_quantity integer, p_part text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_user_id uuid := (SELECT auth.uid());
  v_school_id uuid;
  v_total integer;
  v_out integer;
  v_part text := pg_catalog.btrim(p_part);
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'ログインが必要です。';
  END IF;
  IF p_quantity IS NULL OR p_quantity < 1 THEN
    RAISE EXCEPTION '個数は1以上を入力してください。';
  END IF;
  IF v_part IS NULL OR v_part = '' OR pg_catalog.length(v_part) > 40 THEN
    RAISE EXCEPTION 'パートを40文字以内で入力してください。';
  END IF;

  -- 同時に借りられても数が合うよう、備品の行をロックする
  SELECT i.school_id, i.total_count INTO v_school_id, v_total
  FROM public.equipment_items AS i
  WHERE i.id = p_item_id
  FOR UPDATE;
  IF v_school_id IS NULL OR NOT (SELECT private.is_school_member(v_school_id)) THEN
    RAISE EXCEPTION '備品が見つかりません。';
  END IF;

  SELECT COALESCE(pg_catalog.sum(l.quantity), 0) INTO v_out
  FROM public.equipment_loans AS l
  WHERE l.item_id = p_item_id AND l.returned_at IS NULL;
  IF p_quantity > v_total - v_out THEN
    RAISE EXCEPTION '空きが足りません（残り%個）。', v_total - v_out;
  END IF;

  INSERT INTO public.equipment_loans (item_id, school_id, borrower_id, borrower_part, quantity)
  VALUES (p_item_id, v_school_id, v_user_id, v_part, p_quantity);
END;
$function$;

-- ---- 返す（借りた本人か管理者） ----
CREATE OR REPLACE FUNCTION public.return_equipment_loan(p_loan_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_user_id uuid := (SELECT auth.uid());
  v_school_id uuid;
  v_borrower uuid;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'ログインが必要です。';
  END IF;
  SELECT l.school_id, l.borrower_id INTO v_school_id, v_borrower
  FROM public.equipment_loans AS l
  WHERE l.id = p_loan_id AND l.returned_at IS NULL;
  IF v_school_id IS NULL THEN
    RAISE EXCEPTION '貸出の記録が見つかりません。';
  END IF;
  IF v_borrower <> v_user_id AND NOT (SELECT private.is_school_admin(v_school_id)) THEN
    RAISE EXCEPTION '返却できるのは借りた本人か管理者のみです。';
  END IF;
  UPDATE public.equipment_loans SET returned_at = pg_catalog.now() WHERE id = p_loan_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.borrow_equipment_item(uuid, integer, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.return_equipment_loan(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.borrow_equipment_item(uuid, integer, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.return_equipment_loan(uuid) TO authenticated;

-- ---- リアルタイム更新（他の人の貸出が自動で反映される） ----
DO $publication$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['equipment_items', 'equipment_loans'] LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_catalog.pg_publication_tables
      WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = t
    ) THEN
      EXECUTE pg_catalog.format('ALTER PUBLICATION %I ADD TABLE public.%I', 'supabase_realtime', t);
    END IF;
  END LOOP;
END;
$publication$;

COMMIT;
