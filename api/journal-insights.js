// Vercel serverless function: POST /api/journal-insights
// Reads the CALLER'S OWN journal entries (looked up server-side from their
// verified Supabase session — never trusts anything the client submits) and
// asks Claude to find concrete behavioral patterns in the free text
// (notes / feeling_detail / conditions) that the client-side Insights rules
// engine can't see, since that only ever reads structured fields (mood,
// risk, R:R, tags, rules_followed).
// Requires (Vercel project env vars, never exposed to the browser):
//   ANTHROPIC_API_KEY, SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY

const Anthropic = require("@anthropic-ai/sdk");
const { z } = require("zod");
const { zodOutputFormat } = require("@anthropic-ai/sdk/helpers/zod");
const { createClient } = require("@supabase/supabase-js");

const anthropic = new Anthropic();
const supabaseAdmin = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, {
  auth: { autoRefreshToken: false, persistSession: false },
});

const InsightsSchema = z.object({
  insights: z.array(z.object({
    title: z.string(),
    body: z.string(),
    tone: z.enum(["bad", "good", "tip"]),
  })).max(5),
});

// A bare mood tag with no notes tells the model nothing — only entries with
// real free text are worth spending tokens on.
const MIN_TEXT_LENGTH = 15;
const MAX_ENTRIES = 60;

module.exports = async function handler(req, res) {
  if (req.method !== "POST") {
    res.status(405).json({ error: "Method not allowed" });
    return;
  }

  const authHeader = req.headers.authorization || "";
  const token = authHeader.startsWith("Bearer ") ? authHeader.slice(7) : "";
  if (!token) {
    res.status(401).json({ error: "Missing session token" });
    return;
  }

  const { data: userData, error: userErr } = await supabaseAdmin.auth.getUser(token);
  if (userErr || !userData || !userData.user) {
    res.status(401).json({ error: "Invalid or expired session" });
    return;
  }
  const userId = userData.user.id;

  if (!process.env.ANTHROPIC_API_KEY) {
    res.status(500).json({ error: "Server misconfigured: ANTHROPIC_API_KEY is not set" });
    return;
  }

  try {
    const { data: entries, error: entriesErr } = await supabaseAdmin
      .from("journal_entries")
      .select("id, date, mood, feeling_detail, conditions, notes, trade_id")
      .eq("user_id", userId)
      .order("date", { ascending: false })
      .limit(200);
    if (entriesErr) throw entriesErr;

    const textyEntries = (entries || [])
      .filter((en) => ((en.notes || "") + (en.feeling_detail || "") + (en.conditions || "")).trim().length >= MIN_TEXT_LENGTH)
      .slice(0, MAX_ENTRIES);

    if (textyEntries.length < 3) {
      res.status(200).json({ insights: [], reason: "not_enough_text" });
      return;
    }

    const tradeIds = textyEntries.map((en) => en.trade_id).filter(Boolean);
    let tradesById = {};
    if (tradeIds.length) {
      const { data: trades, error: tradesErr } = await supabaseAdmin
        .from("trades")
        .select("id, date, symbol, side, pnl, rules_followed, break_even, risk, rr, entry_type")
        .in("id", tradeIds);
      if (tradesErr) throw tradesErr;
      tradesById = Object.fromEntries((trades || []).map((t) => [t.id, t]));
    }

    const journalText = textyEntries
      .map((en) => {
        const t = en.trade_id ? tradesById[en.trade_id] : null;
        const tradeLine = t
          ? `Linked trade: ${t.date} ${t.symbol || "—"} ${t.side || ""}, P&L ${t.pnl}, followed rules: ${
              t.rules_followed === null || t.rules_followed === undefined ? "not answered" : t.rules_followed
            }, break-even: ${t.break_even}, risk: ${t.risk === null ? "—" : t.risk + "%"}, R:R: ${t.rr === null ? "—" : t.rr}`
          : "No linked trade";
        return [
          `Date: ${en.date}`,
          `Mood: ${en.mood || "—"}`,
          tradeLine,
          en.conditions ? `Market/conditions: ${en.conditions}` : null,
          en.feeling_detail ? `Feeling detail: ${en.feeling_detail}` : null,
          en.notes ? `Notes: ${en.notes}` : null,
        ].filter(Boolean).join("\n");
      })
      .join("\n\n---\n\n");

    const response = await anthropic.messages.parse({
      model: "claude-opus-5",
      max_tokens: 8000,
      system:
        "You are a trading-psychology coach reviewing a trader's own journal entries. " +
        "Find concrete, specific behavioral patterns in the free text — things like moving " +
        "a stop to break-even out of fear, revenge trading after a loss, overconfidence " +
        "after a win streak, acting on a fear threshold smaller than their own stated risk " +
        "tolerance, hesitating on entries that matched their plan, etc. Ground every claim " +
        "only in what the text actually says — never invent details that aren't there. Only " +
        "report something that's either backed by more than one entry, or a single instance " +
        "with a clearly named, quantifiable cost (the trader explicitly says what would have " +
        "happened otherwise). Write each insight the way a sharp, direct trading coach would " +
        "— specific and evidence-based, no hedging filler, no generic advice. If nothing " +
        "notable is in the text, return an empty insights list rather than manufacturing " +
        "something.",
      messages: [
        { role: "user", content: `Here are this trader's journal entries, most recent first:\n\n${journalText}` },
      ],
      output_config: { format: zodOutputFormat(InsightsSchema) },
    });

    if (!response.parsed_output) {
      res.status(200).json({ insights: [], reason: "unparseable" });
      return;
    }

    res.status(200).json({ insights: response.parsed_output.insights });
  } catch (err) {
    console.error("journal-insights error:", err);
    res.status(500).json({ error: "Could not analyze journal entries" });
  }
};
