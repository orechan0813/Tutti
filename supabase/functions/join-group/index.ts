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

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (request.method !== "POST") return jsonResponse({ error: "Method not allowed" }, 405);

  const authorization = request.headers.get("Authorization");
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!authorization || !supabaseUrl || !anonKey || !serviceRoleKey) {
    return jsonResponse({ error: "Unauthorized or server is not configured" }, 401);
  }

  const authClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authorization } },
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const { data: authData, error: authError } = await authClient.auth.getUser();
  if (authError || !authData.user) return jsonResponse({ error: "Unauthorized" }, 401);

  let body: Record<string, unknown>;
  try {
    body = await request.json();
  } catch {
    return jsonResponse({ error: "Invalid request body" }, 400);
  }
  const inviteCode = typeof body.inviteCode === "string" ? body.inviteCode.trim().toUpperCase() : "";
  if (!/^[0-9A-F]{12}$/.test(inviteCode)) {
    return jsonResponse({ error: "招待コードは12桁の英数字で入力してください。" }, 400);
  }

  const serviceClient = createClient(supabaseUrl, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const [{ data: profile, error: profileError }, { data: school, error: schoolError }] = await Promise.all([
    serviceClient.from("profiles")
      .select("full_name, part, grade, grade_as_of")
      .eq("id", authData.user.id)
      .maybeSingle(),
    serviceClient.from("schools")
      .select("id, school_name, club_name")
      .eq("invite_code", inviteCode)
      .maybeSingle(),
  ]);
  if (profileError || schoolError) {
    console.error("Could not load the profile or invitation target.", profileError || schoolError);
    return jsonResponse({ error: "参加先を確認できませんでした。" }, 500);
  }
  if (!profile) return jsonResponse({ error: "部員プロフィールがありません。" }, 403);
  if (!school) return jsonResponse({ error: "招待コードが見つかりません。" }, 404);

  const { error: membershipError } = await serviceClient
    .from("school_memberships")
    .upsert({
      user_id: authData.user.id,
      school_id: school.id,
      full_name: profile.full_name,
      part: profile.part,
      grade: profile.grade,
      grade_as_of: profile.grade_as_of,
      is_admin: false,
    }, { onConflict: "user_id,school_id", ignoreDuplicates: true });
  if (membershipError) {
    console.error("Could not create the organization membership.", membershipError);
    return jsonResponse({ error: "団体への参加登録に失敗しました。" }, 500);
  }

  return jsonResponse({
    ok: true,
    school: { id: school.id, school_name: school.school_name, club_name: school.club_name },
  });
});
