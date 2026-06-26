import Foundation

/// Public Supabase project config. The anon key is a publishable key (safe to ship);
/// RLS enforces that a signed-in user can only read/write their own rows.
enum SupabaseConfig {
    static let url = URL(string: "https://hjgkvpzirwkirwzcdrfl.supabase.co")!
    static let anonKey =
        "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImhqZ2t2cHppcndraXJ3emNkcmZsIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODIxOTYzNDEsImV4cCI6MjA5Nzc3MjM0MX0.4QKKXtXSvrjayWd0PSMT92xuo-pt3y6gXcO3V72L2Iw"
}
