import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

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

function escapeHtml(value: string) {
  return value.replace(/[&<>"']/g, (character) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    '"': "&quot;",
    "'": "&#39;",
  })[character]!);
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (request.method !== "POST") return jsonResponse({ error: "Method not allowed" }, 405);

  const authorization = request.headers.get("Authorization");
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const resendApiKey = Deno.env.get("RESEND_API_KEY");
  const fromEmail = Deno.env.get("TUTTI_FROM_EMAIL");
  const appUrl = Deno.env.get("TUTTI_APP_URL");

  if (!authorization) return jsonResponse({ error: "Unauthorized" }, 401);
  if (!supabaseUrl || !anonKey || !serviceRoleKey || !resendApiKey || !fromEmail || !appUrl) {
    console.error("Organization welcome email secrets are not configured.");
    return jsonResponse({ error: "Email service is not configured" }, 503);
  }

  const authClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authorization } },
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const { data: authData, error: authError } = await authClient.auth.getUser();
  const user = authData.user;
  if (authError || !user?.email) return jsonResponse({ error: "Unauthorized" }, 401);

  const serviceClient = createClient(supabaseUrl, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const { data: profile, error: profileError } = await serviceClient
    .from("profiles")
    .select("school_id, is_admin")
    .eq("id", user.id)
    .maybeSingle();
  if (profileError) {
    console.error("Could not load the requesting profile.", profileError);
    return jsonResponse({ error: "Could not verify organization membership" }, 500);
  }
  if (!profile?.is_admin) return jsonResponse({ error: "Organization admin required" }, 403);

  const { data: school, error: schoolError } = await serviceClient
    .from("schools")
    .select("id, school_name, club_name, invite_code, welcome_email_sent_at")
    .eq("id", profile.school_id)
    .eq("created_by", user.id)
    .maybeSingle();
  if (schoolError) {
    console.error("Could not load the created organization.", schoolError);
    return jsonResponse({ error: "Could not verify the created organization" }, 500);
  }
  if (!school) return jsonResponse({ error: "Only the organization creator can request this email" }, 403);
  if (school.welcome_email_sent_at) return jsonResponse({ ok: true, alreadySent: true });

  const sentAt = new Date().toISOString();
  const { data: reservation, error: reservationError } = await serviceClient
    .from("schools")
    .update({ welcome_email_sent_at: sentAt })
    .eq("id", school.id)
    .is("welcome_email_sent_at", null)
    .select("id")
    .maybeSingle();
  if (reservationError) {
    console.error("Could not reserve the welcome email.", reservationError);
    return jsonResponse({ error: "Could not queue the welcome email" }, 500);
  }
  if (!reservation) return jsonResponse({ ok: true, alreadySent: true });

  const safeSchool = escapeHtml(school.school_name);
  const safeClub = escapeHtml(school.club_name);
  const safeCode = escapeHtml(school.invite_code);
  const safeAppUrl = escapeHtml(appUrl);
  const html = `<h1>Tuttiへようこそ</h1><p>${safeSchool} ${safeClub}の管理者アカウントが作成されました。</p><p>登録メールアドレス: ${escapeHtml(user.email)}</p><p>部員招待コード: <strong>${safeCode}</strong></p><p>このコードを部員へ共有してください。参加にはコードが必要です。</p><p><a href="${safeAppUrl}">Tuttiを開く</a></p>`;
  const text = [
    "Tuttiへようこそ",
    `${school.school_name} ${school.club_name}の管理者アカウントが作成されました。`,
    `登録メールアドレス: ${user.email}`,
    `部員招待コード: ${school.invite_code}`,
    "このコードを部員へ共有してください。参加にはコードが必要です。",
    `Tuttiを開く: ${appUrl}`,
  ].join("\n\n");

  const mailResponse = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${resendApiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      from: fromEmail,
      to: [user.email],
      subject: `${school.school_name} ${school.club_name}の登録情報`,
      html,
      text,
    }),
  });

  if (!mailResponse.ok) {
    const { error: releaseError } = await serviceClient
      .from("schools")
      .update({ welcome_email_sent_at: null })
      .eq("id", school.id)
      .eq("welcome_email_sent_at", sentAt);
    if (releaseError) console.error("Could not release the welcome email reservation.", releaseError);
    console.error("Email provider rejected the welcome email.", mailResponse.status);
    return jsonResponse({ error: "Welcome email could not be sent" }, 502);
  }

  return jsonResponse({ ok: true });
});