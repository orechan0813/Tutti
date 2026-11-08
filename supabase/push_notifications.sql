BEGIN;

CREATE TABLE IF NOT EXISTS public.push_subscriptions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  endpoint text NOT NULL,
  p256dh text NOT NULL,
  auth_key text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT push_subscriptions_endpoint_key UNIQUE (endpoint),
  CONSTRAINT push_subscriptions_sizes CHECK (
    pg_catalog.length(endpoint) <= 2048 AND pg_catalog.length(p256dh) <= 200 AND pg_catalog.length(auth_key) <= 100
  ),
  CONSTRAINT push_subscriptions_endpoint_allowed CHECK (
    endpoint ~ '^https://(fcm\.googleapis\.com|android\.googleapis\.com|[a-z0-9-]+\.push\.services\.mozilla\.com|[a-z0-9-]+\.push\.apple\.com|[a-z0-9.-]+\.notify\.windows\.com)/[^[:space:]]+$'
  )
);
CREATE INDEX IF NOT EXISTS push_subscriptions_user_idx ON public.push_subscriptions (user_id);
ALTER TABLE public.push_subscriptions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.push_subscriptions FROM PUBLIC, anon, authenticated;

CREATE TABLE IF NOT EXISTS public.announcement_pushes (
  announcement_id uuid PRIMARY KEY REFERENCES public.announcements(id) ON DELETE CASCADE,
  sent_at timestamptz NOT NULL DEFAULT now(),
  attempted integer NOT NULL DEFAULT 0,
  delivered integer NOT NULL DEFAULT 0
);
ALTER TABLE public.announcement_pushes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.announcement_pushes FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.register_push_subscription(p_endpoint text, p_p256dh text, p_auth_key text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_user_id uuid := (SELECT auth.uid());
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'ログインが必要です。';
  END IF;
  IF p_endpoint IS NULL OR p_p256dh IS NULL OR p_auth_key IS NULL
     OR pg_catalog.length(p_endpoint) > 2048
     OR pg_catalog.length(p_p256dh) > 200
     OR pg_catalog.length(p_auth_key) > 100 THEN
    RAISE EXCEPTION '通知の登録情報が正しくありません。';
  END IF;
  IF p_endpoint !~ '^https://(fcm\.googleapis\.com|android\.googleapis\.com|[a-z0-9-]+\.push\.services\.mozilla\.com|[a-z0-9-]+\.push\.apple\.com|[a-z0-9.-]+\.notify\.windows\.com)/[^[:space:]]+$' THEN
    RAISE EXCEPTION 'この端末の通知方式には対応していません。';
  END IF;
  IF (SELECT pg_catalog.count(*) FROM public.push_subscriptions AS s
      WHERE s.user_id = v_user_id AND s.endpoint <> p_endpoint) >= 10 THEN
    RAISE EXCEPTION '通知を登録できる端末数の上限に達しています。';
  END IF;

  INSERT INTO public.push_subscriptions (user_id, endpoint, p256dh, auth_key)
  VALUES (v_user_id, p_endpoint, p_p256dh, p_auth_key)
  ON CONFLICT (endpoint) DO UPDATE
    SET user_id = EXCLUDED.user_id,
        p256dh = EXCLUDED.p256dh,
        auth_key = EXCLUDED.auth_key,
        updated_at = pg_catalog.now();
END;
$function$;

CREATE OR REPLACE FUNCTION public.unregister_push_subscription(p_endpoint text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
BEGIN
  IF (SELECT auth.uid()) IS NULL THEN
    RAISE EXCEPTION 'ログインが必要です。';
  END IF;
  DELETE FROM public.push_subscriptions
  WHERE endpoint = p_endpoint
    AND user_id = (SELECT auth.uid());
END;
$function$;

REVOKE ALL ON FUNCTION public.register_push_subscription(text, text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.unregister_push_subscription(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.register_push_subscription(text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.unregister_push_subscription(text) TO authenticated;

COMMIT;
