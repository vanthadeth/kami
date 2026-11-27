import { NextResponse, type NextRequest } from "next/server";
import { createClient } from "@/lib/supabase/server";

// Google sends the person back here with a one-time code; swap it for a session.
export async function GET(request: NextRequest) {
  const { searchParams, origin } = request.nextUrl;
  const code = searchParams.get("code");

  if (code) {
    const supabase = await createClient();
    const { error } = await supabase.auth.exchangeCodeForSession(code);
    if (!error) {
      const proto = request.headers.get("x-forwarded-proto") ?? "https";
      const host = request.headers.get("x-forwarded-host");
      const base = host ? `${proto}://${host}` : origin;
      return NextResponse.redirect(`${base}/`);
    }
  }
  return NextResponse.redirect(`${origin}/login?error=1`);
}
