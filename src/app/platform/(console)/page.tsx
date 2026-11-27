import { requirePlatformStaff } from "@/lib/platform";

export default async function PlatformHome() {
  const me = await requirePlatformStaff();
  const groups = Array.from(new Set(me.permissions.map((p) => p.group_name)));

  return (
    <main className="mx-auto max-w-3xl px-4 py-8">
      <p className="text-sm font-semibold uppercase tracking-wide text-[#4A5D70]">KAMI platform console</p>
      <h1 className="mt-1 text-3xl font-bold">Welcome, {me.displayName ?? me.userEmail}</h1>
      <p className="mt-2 text-[#4A5D70]">
        You are signed in as <strong>{me.roleName}</strong> with two-factor on.
        {me.isSuperadmin && " A superadmin has every permission."}
      </p>

      <section className="mt-8 rounded-2xl bg-white p-5 shadow-sm" aria-labelledby="perm-h">
        <h2 id="perm-h" className="text-lg font-semibold">What you can do</h2>
        <div className="mt-4 flex flex-col gap-4">
          {groups.map((g) => (
            <div key={g}>
              <h3 className="text-sm font-semibold text-[#4A5D70]">{g}</h3>
              <ul className="mt-1 flex flex-col gap-1">
                {me.permissions.filter((p) => p.group_name === g).map((p) => (
                  <li key={p.key} className="flex items-center gap-2 text-sm">
                    <span aria-hidden className={p.granted ? "text-[#22C55E]" : "text-[#B8C6D3]"}>{p.granted ? "✓" : "–"}</span>
                    <span className={p.granted ? "" : "text-[#7A8B9B]"}>
                      {p.label}
                      <span className="sr-only">{p.granted ? " (allowed)" : " (not allowed)"}</span>
                    </span>
                  </li>
                ))}
              </ul>
            </div>
          ))}
        </div>
      </section>

      <p className="mt-6 text-sm text-[#4A5D70]">Businesses, plans and the platform log come in the next steps.</p>
      <form action="/auth/signout" method="post" className="mt-6">
        <button type="submit" className="h-11 rounded-xl border border-[#B8C6D3] bg-white px-5 text-sm font-semibold focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[#00A8FF]">
          Sign out
        </button>
      </form>
    </main>
  );
}
