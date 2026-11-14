-- 組織アカウント（団体を作成した管理者アカウント）を特定し、そのアカウントだけの機能を使えるようにする。
-- Supabase の SQL Editor に貼り付けて Run してください。何度実行しても安全です。
--
-- 判定の基準:
--   schools.created_by（団体を作成したアカウント）かつ、その団体の管理者であること。
--   「氏名に管理者と付く」ことは基準にしません（誰でも名乗れて、なりすませるため）。
BEGIN;

-- 1) 作成者が空の団体を補完する（学年未設定の管理者のうち、最初に入った人）
UPDATE public.schools AS s
SET created_by = (
  SELECT m.user_id
  FROM public.school_memberships AS m
  WHERE m.school_id = s.id AND m.is_admin AND m.grade IS NULL
  ORDER BY m.created_at
  LIMIT 1
)
WHERE s.created_by IS NULL;

CREATE INDEX IF NOT EXISTS schools_created_by_idx ON public.schools (created_by);

-- 2) 「この団体の組織アカウントか」を判定する関数
CREATE OR REPLACE FUNCTION private.is_school_owner(target_school_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT EXISTS (
    SELECT 1
    FROM public.schools AS s
    JOIN public.school_memberships AS m
      ON m.school_id = s.id AND m.user_id = s.created_by
    WHERE s.id = target_school_id
      AND s.created_by = (SELECT auth.uid())
      AND m.is_admin
  )
$function$;

REVOKE ALL ON FUNCTION private.is_school_owner(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.is_school_owner(uuid) TO authenticated;

-- アプリから呼ぶための入口
CREATE OR REPLACE FUNCTION public.is_school_owner(p_school_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT (SELECT private.is_school_owner(p_school_id))
$function$;

REVOKE ALL ON FUNCTION public.is_school_owner(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_school_owner(uuid) TO authenticated;

-- 3) プラン（今後のサブスク用）。見られるのは組織アカウントだけ。
--    書き換えは、将来の決済連携（サーバー側）からだけ行う想定で、アプリからは書けません。
CREATE TABLE IF NOT EXISTS public.school_plans (
  school_id uuid PRIMARY KEY REFERENCES public.schools(id) ON DELETE CASCADE,
  plan text NOT NULL DEFAULT 'free',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO public.school_plans (school_id)
SELECT s.id FROM public.schools AS s
ON CONFLICT (school_id) DO NOTHING;

-- 新しい団体ができたら、無料プランの行を自動で作る
CREATE OR REPLACE FUNCTION private.create_school_plan()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
BEGIN
  INSERT INTO public.school_plans (school_id) VALUES (NEW.id)
  ON CONFLICT (school_id) DO NOTHING;
  RETURN NEW;
END;
$function$;
REVOKE ALL ON FUNCTION private.create_school_plan() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS schools_create_plan ON public.schools;
CREATE TRIGGER schools_create_plan
  AFTER INSERT ON public.schools
  FOR EACH ROW EXECUTE FUNCTION private.create_school_plan();

DROP TRIGGER IF EXISTS school_plans_set_updated_at ON public.school_plans;
CREATE TRIGGER school_plans_set_updated_at
  BEFORE UPDATE ON public.school_plans
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

ALTER TABLE public.school_plans ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.school_plans FROM PUBLIC, anon, authenticated;

DROP POLICY IF EXISTS school_plans_read_owner ON public.school_plans;
CREATE POLICY school_plans_read_owner ON public.school_plans
  FOR SELECT TO authenticated
  USING ((SELECT private.is_school_owner(school_id)));

GRANT SELECT ON TABLE public.school_plans TO authenticated;

COMMIT;
