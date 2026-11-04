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

  const action = body.action;
  const targetUserId = typeof body.targetUserId === "string" ? body.targetUserId : "";
  if (!targetUserId) return jsonResponse({ error: "targetUserId is required" }, 400);

  const serviceClient = createClient(supabaseUrl, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const { data: actor, error: actorError } = await serviceClient
    .from("school_memberships")
    .select("school_id, is_admin")
    .eq("user_id", authData.user.id)
    .maybeSingle();
  if (actorError) {
    console.error("Could not load the acting profile.", actorError);
    return jsonResponse({ error: "Could not verify administrator" }, 500);
  }
  if (!actor?.is_admin) return jsonResponse({ error: "Administrator permission required" }, 403);

  const { data: target, error: targetError } = await serviceClient
    .from("school_memberships")
    .select("user_id, school_id, is_admin")
    .eq("user_id", targetUserId)
    .eq("school_id", actor.school_id)
    .maybeSingle();
  if (targetError) {
    console.error("Could not load the target profile.", targetError);
    return jsonResponse({ error: "Could not load member" }, 500);
  }
  if (!target) return jsonResponse({ error: "Member not found in your organization" }, 404);

  if (action === "update") {
    const updates: Record<string, unknown> = {};
    if (typeof body.fullName === "string") {
      const fullName = body.fullName.trim();
      if (!fullName) return jsonResponse({ error: "Name is required" }, 400);
      updates.full_name = fullName;
    }
    if (typeof body.part === "string") updates.part = body.part.trim() || null;
    if (Object.hasOwn(body, "grade")) {
      const grade = body.grade === null || body.grade === "" ? null : Number(body.grade);
      if (grade !== null && (!Number.isInteger(grade) || grade < 1 || grade > 3)) {
        return jsonResponse({ error: "Grade must be between 1 and 3" }, 400);
      }
      updates.grade = grade;
      updates.grade_as_of = grade === null ? null : new Intl.DateTimeFormat("sv-SE", {
        timeZone: "Asia/Tokyo",
        year: "numeric",
        month: "2-digit",
        day: "2-digit",
      }).format(new Date());
    }
    if (typeof body.isAdmin === "boolean") {
      if (target.is_admin && !body.isAdmin) {
        const { count, error: countError } = await serviceClient
          .from("school_memberships")
          .select("user_id", { count: "exact", head: true })
          .eq("school_id", actor.school_id)
          .eq("is_admin", true);
        if (countError) {
          console.error("Could not count organization admins.", countError);
          return jsonResponse({ error: "Could not verify organization administrators" }, 500);
        }
        if ((count || 0) <= 1) return jsonResponse({ error: "The last administrator cannot be demoted" }, 400);
      }
      updates.is_admin = body.isAdmin;
    }
    if (!Object.keys(updates).length) return jsonResponse({ error: "No profile changes provided" }, 400);

    const { error } = await serviceClient
      .from("school_memberships")
      .update(updates)
      .eq("user_id", target.user_id)
      .eq("school_id", actor.school_id);
    if (error) {
      console.error("Could not update the member profile.", error);
      return jsonResponse({ error: "Could not update member" }, 500);
    }
    return jsonResponse({ ok: true });
  }

  if (action === "delete") {
    if (target.user_id === authData.user.id) {
      return jsonResponse({ error: "You cannot delete your own account here" }, 400);
    }
    if (target.is_admin) {
      const { count, error: countError } = await serviceClient
        .from("school_memberships")
        .select("user_id", { count: "exact", head: true })
        .eq("school_id", actor.school_id)
        .eq("is_admin", true);
      if (countError) {
        console.error("Could not count organization admins.", countError);
        return jsonResponse({ error: "Could not verify organization administrators" }, 500);
      }
      if ((count || 0) <= 1) return jsonResponse({ error: "The last administrator cannot be deleted" }, 400);
    }

    const { error: membershipDeleteError } = await serviceClient
      .from("school_memberships")
      .delete()
      .eq("user_id", target.user_id)
      .eq("school_id", actor.school_id);
    if (membershipDeleteError) {
      console.error("Could not remove the organization membership.", membershipDeleteError);
      return jsonResponse({ error: "Could not remove member from organization" }, 500);
    }

    const { count, error: membershipCountError } = await serviceClient
      .from("school_memberships")
      .select("school_id", { count: "exact", head: true })
      .eq("user_id", target.user_id);
    if (membershipCountError) {
      console.error("Could not count remaining memberships.", membershipCountError);
      return jsonResponse({ error: "Membership removed, but account status could not be verified" }, 500);
    }
    if ((count || 0) > 0) return jsonResponse({ ok: true, accountDeleted: false });

    const { error } = await serviceClient.auth.admin.deleteUser(target.user_id);
    if (error) {
      console.error("Could not delete the Auth user.", error);
      return jsonResponse({ error: "Could not delete member account" }, 500);
    }
    return jsonResponse({ ok: true, accountDeleted: true });
  }

  return jsonResponse({ error: "Unsupported action" }, 400);
});