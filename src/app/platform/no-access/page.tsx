export default function NoAccess() {
  return (
    <main className="mx-auto flex min-h-dvh max-w-sm flex-col items-center justify-center gap-4 px-4 text-center">
      <h1 className="text-2xl font-bold">No access</h1>
      <p className="text-[#4A5D70]">This account is not part of the KAMI platform team.</p>
      <form action="/auth/signout" method="post">
        <button type="submit" className="h-11 rounded-xl border border-[#B8C6D3] bg-white px-5 text-sm font-semibold">Sign out</button>
      </form>
    </main>
  );
}
