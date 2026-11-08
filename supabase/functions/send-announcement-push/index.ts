import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, x-client-info, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MAX_ANNOUNCEMENT_AGE_MS = 10 * 60 * 1000;

// 正規のプッシュサービス以外には送信しない(SQL側の制約と同じ一覧)
const ALLOWED_PUSH_HOSTS = [
  /^fcm\.googleapis\.com$/,
  /^android\.googleapis\.com$/,
  /^[a-z0-9-]+\.push\.services\.mozilla\.com$/,
  /^[a-z0-9-]+\.push\.apple\.com$/,
  /^[a-z0-9.-]+\.notify\.windows\.com$/,
];

function isAllowedEndpoint(endpoint: string) {
  try {
    const url = new URL(endpoint);
    if (url.protocol !== "https:" || url.username || url.password || url.port) return false;
    return ALLOWED_PUSH_HOSTS.some((pattern) => pattern.test(url.hostname));
  } catch {
    return false;
  }
}

function clip(value: string, max: number) {
  const characters = Array.from(value.trim());
  return characters.length > max ? `${characters.slice(0, max - 1).join("")}…` : characters.join("");
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (request.method !== "POST") return jsonResponse({ error: "Method not allowed" }, 405);

  const authorization = request.headers.get("Authorization");
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const vapidPublicKey = Deno.env.get("VAPID_PUBLIC_KEY");
  const vapidPrivateKey = Deno.env.get("VAPID_PRIVATE_KEY");
  const vapidSubject = Deno.env.get("VAPID_SUBJECT");

  if (!authorization) return jsonResponse({ error: "Unauthorized" }, 401);
  if (!supabaseUrl || !anonKey || !serviceRoleKey || !vapidPublicKey || !vapidPrivateKey || !vapidSubject) {
    console.error("Push notification secrets are not configured.");
    return jsonResponse({ error: "Push service is not configured" }, 503);
  }

  const authClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authorization } },
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const { data: authData, error: authError } = await authClient.auth.getUser();
  const user = authData?.user;
  if (authError || !user) return jsonResponse({ error: "Unauthorized" }, 401);

  let body: Record<string, unknown>;
  try {
    body = await request.json();
  } catch {
    return jsonResponse({ error: "Invalid request body" }, 400);
  }
  const announcementId = typeof body.announcementId === "string" ? body.announcementId : "";
  if (!UUID_PATTERN.test(announcementId)) return jsonResponse({ error: "announcementId is required" }, 400);

  const serviceClient = createClient(supabaseUrl, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  // 送信先の団体は、クライアントの入力ではなくDB上の投稿から決める
  const { data: announcement, error: announcementError } = await serviceClient
    .from("announcements")
    .select("id, school_id, title, body, created_at")
    .eq("id", announcementId)
    .maybeSingle();
  if (announcementError) {
    console.error("Could not load the announcement.", announcementError);
    return jsonResponse({ error: "Could not load the announcement" }, 500);
  }
  if (!announcement) return jsonResponse({ error: "Announcement not found" }, 404);

  // その団体の管理者だけが通知を送れる
  const { data: membership, error: membershipError } = await serviceClient
    .from("school_memberships")
    .select("is_admin")
    .eq("user_id", user.id)
    .eq("school_id", announcement.school_id)
    .maybeSingle();
  if (membershipError) {
    console.error("Could not verify the administrator.", membershipError);
    return jsonResponse({ error: "Could not verify administrator" }, 500);
  }
  if (!membership?.is_admin) return jsonResponse({ error: "Administrator permission required" }, 403);

  if (Date.now() - Date.parse(announcement.created_at) > MAX_ANNOUNCEMENT_AGE_MS) {
    return jsonResponse({ error: "This announcement is too old to send notifications for" }, 400);
  }

  const { data: school, error: schoolError } = await serviceClient
    .from("schools")
    .select("school_name, club_name")
    .eq("id", announcement.school_id)
    .maybeSingle();
  if (schoolError || !school) {
    console.error("Could not load the organization.", schoolError);
    return jsonResponse({ error: "Could not load the organization" }, 500);
  }

  try {
    webpush.setVapidDetails(vapidSubject, vapidPublicKey, vapidPrivateKey);
  } catch (error) {
    console.error("Invalid VAPID configuration.", error);
    return jsonResponse({ error: "Push service is not configured" }, 503);
  }

  // 同じ投稿への二重送信を防ぐ(先に記録を取れた1回だけが送信する)
  const { error: reserveError } = await serviceClient
    .from("announcement_pushes")
    .insert({ announcement_id: announcement.id });
  if (reserveError) {
    if (reserveError.code === "23505") return jsonResponse({ ok: true, alreadySent: true });
    console.error("Could not reserve the notification.", reserveError);
    return jsonResponse({ error: "Could not queue the notification" }, 500);
  }

  // 宛先: この団体の部員だけ
  const userIds = new Set<string>();
  for (let from = 0; ; from += 1000) {
    const { data: rows, error } = await serviceClient
      .from("school_memberships")
      .select("user_id")
      .eq("school_id", announcement.school_id)
      .range(from, from + 999);
    if (error) {
      console.error("Could not load the recipients.", error);
      await serviceClient.from("announcement_pushes").delete().eq("announcement_id", announcement.id);
      return jsonResponse({ error: "Could not load recipients" }, 500);
    }
    for (const row of rows || []) userIds.add(row.user_id);
    if (!rows || rows.length < 1000) break;
  }

  const subscriptions: { id: string; endpoint: string; p256dh: string; auth_key: string }[] = [];
  const idList = [...userIds];
  for (let i = 0; i < idList.length; i += 50) {
    const { data: rows, error } = await serviceClient
      .from("push_subscriptions")
      .select("id, endpoint, p256dh, auth_key")
      .in("user_id", idList.slice(i, i + 50));
    if (error) {
      console.error("Could not load the subscriptions.", error);
      await serviceClient.from("announcement_pushes").delete().eq("announcement_id", announcement.id);
      return jsonResponse({ error: "Could not load subscriptions" }, 500);
    }
    subscriptions.push(...(rows || []));
  }

  const payload = JSON.stringify({
    title: clip(`【${school.club_name}】${announcement.title}`, 60),
    body: clip(announcement.body || `${school.school_name} ${school.club_name}`, 100),
    tag: `announcement-${announcement.id}`,
  });

  const staleIds: string[] = [];
  let delivered = 0;
  let failed = 0;
  for (let i = 0; i < subscriptions.length; i += 20) {
    await Promise.all(subscriptions.slice(i, i + 20).map(async (subscription) => {
      if (!isAllowedEndpoint(subscription.endpoint)) {
        staleIds.push(subscription.id);
        return;
      }
      try {
        await webpush.sendNotification(
          { endpoint: subscription.endpoint, keys: { p256dh: subscription.p256dh, auth: subscription.auth_key } },
          payload,
          { TTL: 60 * 60 * 24, urgency: "normal", timeout: 10000 },
        );
        delivered++;
      } catch (error) {
        const status = (error as { statusCode?: number }).statusCode;
        if (status === 404 || status === 410) staleIds.push(subscription.id);
        else {
          failed++;
          console.error("Push delivery failed.", status);
        }
      }
    }));
  }

  if (staleIds.length) {
    const { error } = await serviceClient.from("push_subscriptions").delete().in("id", staleIds);
    if (error) console.error("Could not remove expired subscriptions.", error);
  }
  await serviceClient
    .from("announcement_pushes")
    .update({ attempted: subscriptions.length, delivered })
    .eq("announcement_id", announcement.id);

  return jsonResponse({ ok: true, delivered, failed, removed: staleIds.length });
});
