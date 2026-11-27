import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";

// Decides what a visitor may see in the platform console. The database enforces the same
// rules (staff row, active, two-factor), so this only decides where to send people.
export type PlatformAccess = {
  userEmail: string | null;
  displayName: string | null;
  roleKey: string;
  roleName: string;
  isSuperadmin: boolean;
  permissions: { key: string; label: string; group_name: string; granted: boolean }[];
};

export async function requirePlatformStaff(): Promise<PlatformAccess> {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: aal } = await supabase.auth.mfa.getAuthenticatorAssuranceLevel();
  if (aal?.currentLevel !== "aal2") {
    // No authenticator yet: set one up. Otherwise ask for the 6-digit code.
    redirect(aal?.nextLevel === "aal2" ? "/platform/verify" : "/platform/setup");
  }

  const { data: staff } = await supabase
    .from("platform_staff")
    .select("status, display_name, platform_roles ( id, key, name, is_superadmin )")
    .eq("user_id", user.id)
    .maybeSingle();

  const role = Array.isArray(staff?.platform_roles) ? staff?.platform_roles[0] : staff?.platform_roles;
  if (!staff || staff.status !== "active" || !role) redirect("/platform/no-access");

  const [{ data: all }, { data: grants }] = await Promise.all([
    supabase.from("platform_permissions").select("key, label, group_name, sort_order").order("sort_order"),
    supabase.from("platform_role_permissions").select("permission_key").eq("role_id", role.id),
  ]);
  const granted = new Set((grants ?? []).map((g) => g.permission_key));

  return {
    userEmail: user.email ?? null,
    displayName: staff.display_name,
    roleKey: role.key,
    roleName: role.name,
    isSuperadmin: role.is_superadmin,
    permissions: (all ?? []).map((p) => ({
      key: p.key,
      label: p.label,
      group_name: p.group_name,
      granted: role.is_superadmin || granted.has(p.key),
    })),
  };
}
