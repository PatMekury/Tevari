import { initializeApp } from "firebase-admin/app";
import { getAuth } from "firebase-admin/auth";
import { defineSecret } from "firebase-functions/params";
import { defineString } from "firebase-functions/params";
import { onRequest } from "firebase-functions/v2/https";
import { GoogleAuth } from "google-auth-library";

initializeApp();

const glooClientID = defineSecret("GLOO_CLIENT_ID");
const glooClientSecret = defineSecret("GLOO_CLIENT_SECRET");
const youVersionAppKey = defineSecret("YVP_APP_KEY");
const storyVoiceURL = defineString("STORY_VOICE_URL", {
  default: "https://tevari-story-voice-zpoclnpreq-uc.a.run.app"
});

const allowedTraditions = new Set(["general", "evangelical", "catholic", "mainline"]);
const maxHistoryItems = 12;
const maxHistoryItemCharacters = 1_200;
const maxFaithLensQuestionCharacters = 700;
const maxFaithLensImageBytes = 3 * 1024 * 1024;
const maxStoryPromptCharacters = 320;
const maxStoryNarrationCharacters = 1_200;
const usfmPassagePattern = /^[A-Z0-9]{3,5}\.\d+(?:\.\d+)?(?:-\d+(?:\.\d+)?)?$/;
// Tevari's licensed YouVersion source. Keeping one translation avoids mixing
// Bible text across live prayer updates.
const tevariBibleID = 111; // New International Version 2011 (NIV11)

function sendError(response, status, code, message) {
  response.status(status).json({ error: { code, message } });
}

async function requireFirebaseUser(request, response) {
  const authorization = request.get("authorization") || "";
  const match = authorization.match(/^Bearer (.+)$/i);
  if (!match) {
    sendError(response, 401, "unauthenticated", "Sign in to Tevari before making this request.");
    return null;
  }

  try {
    return await getAuth().verifyIdToken(match[1]);
  } catch {
    sendError(response, 401, "unauthenticated", "Your Tevari session has expired. Please sign in again.");
    return null;
  }
}

function validatedPrayerHistory(value) {
  if (!Array.isArray(value) || value.length === 0 || value.length > maxHistoryItems) {
    return null;
  }

  const history = [];
  for (const item of value) {
    if (!item || item.role !== "user" || typeof item.content !== "string") return null;
    const content = item.content.trim();
    if (!content || content.length > maxHistoryItemCharacters) return null;
    history.push({ role: "user", content });
  }
  return history;
}

async function glooAccessToken() {
  const clientID = glooClientID.value();
  const clientSecret = glooClientSecret.value();
  const basicCredential = Buffer.from(`${clientID}:${clientSecret}`).toString("base64");
  const tokenResponse = await fetch("https://platform.ai.gloo.com/oauth2/token", {
    method: "POST",
    headers: {
      "Content-Type": "application/x-www-form-urlencoded",
      Authorization: `Basic ${basicCredential}`
    },
    body: new URLSearchParams({ grant_type: "client_credentials", scope: "api/access" })
  });

  if (!tokenResponse.ok) {
    throw new Error(`Gloo OAuth failed with ${tokenResponse.status}`);
  }
  const payload = await tokenResponse.json();
  if (typeof payload.access_token !== "string" || !payload.access_token) {
    throw new Error("Gloo OAuth response did not include an access token.");
  }
  return payload.access_token;
}

async function licensedScripture(passageID) {
  const headers = { "X-YVP-App-Key": youVersionAppKey.value(), Accept: "application/json" };
  const passageResponse = await fetch(
    `https://api.youversion.com/v1/bibles/${tevariBibleID}/passages/${encodeURIComponent(passageID)}?format=text&include_headings=false&include_notes=false`,
    { headers }
  );
  if (!passageResponse.ok) throw new Error(`YouVersion NIV11 passage failed with ${passageResponse.status}`);
  const passage = await passageResponse.json();
  if (typeof passage?.content !== "string" || typeof passage?.reference !== "string") {
    throw new Error("YouVersion returned an unusable passage.");
  }
  return {
    id: String(passage.id || passageID),
    reference: passage.reference,
    content: passage.content,
    bible: {
      id: tevariBibleID,
      title: "New International Version 2011",
      abbreviation: "NIV11",
      copyright: null,
      publisherURL: null,
      deepLink: null
    }
  };
}

function fallbackPassageID(history) {
  const prayer = history.map((item) => item.content).join(" ").toLowerCase();
  if (/health|heal|healing|sick|illness|body|pain/.test(prayer)) return "JAS.5.15";
  if (/anxious|anxiety|worry|worried|fear|afraid/.test(prayer)) return "PHP.4.6-7";
  if (/grief|grieve|mourning|loss|lost|sad/.test(prayer)) return "PSA.34.18";
  if (/angry|anger|rage|resent/.test(prayer)) return "PSA.4.4";
  if (/family|child|children|marriage|husband|wife/.test(prayer)) return "JOS.24.15";
  if (/thank|gratitude|grateful|praise/.test(prayer)) return "PSA.100.4";
  return "PSA.23.1";
}

function fallbackPrayerPrompt(history) {
  const context = history.map((item) => item.content).join(" ").toLowerCase();
  if (/lust|tempt|sexual|porn/.test(context)) return "God, give me strength to turn from temptation and choose what brings life and integrity.";
  if (/health|heal|healing|sick|illness|body|pain/.test(context)) return "God, bring your healing presence and steady hope into this need.";
  if (/anxious|anxiety|worry|worried|fear|afraid/.test(context)) return "God, meet me in this fear and give me your peace for the next faithful step.";
  if (/grief|grieve|mourning|loss|lost|sad/.test(context)) return "God, stay close in this sorrow and hold what feels too heavy to carry alone.";
  if (/work|job|overwhelm|burnout|burden/.test(context)) return "God, give me wisdom for this work and grace to carry only what is mine to carry.";
  return "God, receive what is on my heart and lead me in your peace today.";
}

function prayerPromptFromCompletion(rawContent, generated, history) {
  const structuredPrompt = typeof generated?.prompt === "string" ? generated.prompt.trim() : "";
  if (isDirectPrayer(structuredPrompt)) return structuredPrompt;
  // Do not ever render model formatting or JSON as a prayer. Some providers
  // occasionally return a partial code fence or malformed JSON despite the
  // schema instruction; only plain prose can be safely shown to the user.
  const cleaned = typeof rawContent === "string"
    ? rawContent.replace(/```(?:json)?/gi, "").replace(/```/g, "").trim()
    : "";
  const embedded = cleaned.match(/["']prompt["']\s*:\s*["']([^"']+)["']/i)?.[1]?.trim() || "";
  if (isDirectPrayer(embedded)) return embedded;
  if (isDirectPrayer(cleaned)) return cleaned;
  return fallbackPrayerPrompt(history);
}

function isDirectPrayer(value) {
  if (typeof value !== "string") return false;
  const text = value.trim();
  const words = text.split(/\s+/).filter(Boolean);
  return words.length >= 4 && words.length <= 42
    && /^(?:dear\s+)?(?:god|lord|father|jesus|holy\s+spirit)\b/i.test(text)
    && !/[`{}[\]]/.test(text);
}

function fallbackFaithLensPassageID(question) {
  const context = question.toLowerCase();
  if (/bird|creation|sky|tree|flower|nature|beauty/.test(context)) return "MAT.6.26";
  if (/rejection|heartbroken|heartbreak|sad|loss|grief/.test(context)) return "PSA.34.18";
  if (/fear|anxious|anxiety|worry|worried/.test(context)) return "PHP.4.6-7";
  if (/decision|choose|direction|discern/.test(context)) return "JAS.1.5";
  return "PSA.23.1";
}

function faithLensReflectionText(value) {
  if (typeof value !== "string") return "";
  const cleaned = value
    .replace(/```(?:json)?/gi, "")
    .replace(/```/g, "")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 420);
  // Never let a partial provider payload become customer-facing reflection.
  if (!cleaned || /[{}\[\]`]/.test(cleaned) || /^json\b/i.test(cleaned)) return "";
  return cleaned;
}

function fallbackFaithLensReflection(question) {
  const context = question.toLowerCase();
  if (/prayer|pray/.test(context)) {
    return "God, help me receive this moment with attention, gratitude, and trust. Give me grace for the next faithful step.";
  }
  if (/scripture|bible|verse/.test(context)) {
    return "Pause with what is before you. Let this ordinary moment become an invitation to notice God’s care and receive Scripture slowly.";
  }
  return "Take a quiet moment with what you are seeing. Scripture can help you meet it with attention, humility, and hope.";
}

function fallbackParallelPassageID(prompt) {
  const context = prompt.toLowerCase();
  if (/fear|afraid|anxious|anxiety|worry|worried|overwhelm/.test(context)) return "PHP.4.6-7";
  if (/grief|loss|lonely|alone|sad|heartbreak/.test(context)) return "PSA.34.18";
  if (/decision|choose|direction|uncertain|next step/.test(context)) return "JAS.1.5";
  if (/thank|grateful|gratitude|joy/.test(context)) return "PSA.100.4";
  return "PSA.23.1";
}

function directParallelPassageIDs(prompt) {
  const context = prompt.toLowerCase();
  if (/(sick|ill|illness|pain).{0,50}(long|years|long time)|(?:long|years|long time).{0,50}(sick|ill|illness|pain)/.test(context)) return ["JHN.5.1-9", "MRK.5.25-34", "LUK.5.12-15"];
  if (/grief|loss|mourning|bereave/.test(context)) return ["JHN.11.32-36", "PSA.34.18"];
  if (/afraid|fear|anxious|anxiety|storm/.test(context)) return ["MRK.4.35-41", "PSA.56.3-4"];
  if (/overwhelm|overwhelmed|work|job|workload|burnout|too much|burden/.test(context)) return ["EXO.18.17-23", "LUK.10.38-42"];
  if (/judged|judgment|condemn|ashamed|shame/.test(context)) return ["JHN.8.1-11", "ROM.8.1"];
  return [];
}

function validatedFaithLensRequest(value) {
  const question = typeof value?.question === "string" ? value.question.trim() : "";
  const imageBase64 = typeof value?.imageBase64 === "string" ? value.imageBase64 : "";
  if (!question || question.length > maxFaithLensQuestionCharacters || !imageBase64) return null;
  const image = Buffer.from(imageBase64, "base64");
  if (!image.length || image.length > maxFaithLensImageBytes) return null;
  return { question, imageBase64 };
}

function validatedStoryPrompt(value) {
  const prompt = typeof value?.prompt === "string" ? value.prompt.trim() : "";
  return prompt && prompt.length <= maxStoryPromptCharacters ? prompt : null;
}

function validatedStoryPassageID(value) {
  const passageID = typeof value === "string" ? value.trim().toUpperCase() : "";
  const bookCode = passageID.split(".")[0];
  return usfmPassagePattern.test(passageID) && storyBookCodeSet.has(bookCode) ? passageID : null;
}

const storyBookCodes = {
  "1 SAMUEL": "1SA", "2 SAMUEL": "2SA", "1 KINGS": "1KI", "2 KINGS": "2KI", "1 CHRONICLES": "1CH", "2 CHRONICLES": "2CH",
  "1 CORINTHIANS": "1CO", "2 CORINTHIANS": "2CO", "1 THESSALONIANS": "1TH", "2 THESSALONIANS": "2TH", "1 TIMOTHY": "1TI", "2 TIMOTHY": "2TI",
  "1 PETER": "1PE", "2 PETER": "2PE", "1 JOHN": "1JN", "2 JOHN": "2JN", "3 JOHN": "3JN",
  GENESIS: "GEN", EXODUS: "EXO", LEVITICUS: "LEV", NUMBERS: "NUM", DEUTERONOMY: "DEU", JOSHUA: "JOS", JUDGES: "JDG", RUTH: "RUT",
  EZRA: "EZR", NEHEMIAH: "NEH", ESTHER: "EST", JOB: "JOB", PSALM: "PSA", PSALMS: "PSA", PROVERBS: "PRO", ECCLESIASTES: "ECC", "SONG OF SONGS": "SNG", "SONG OF SOLOMON": "SNG",
  ISAIAH: "ISA", JEREMIAH: "JER", LAMENTATIONS: "LAM", EZEKIEL: "EZK", DANIEL: "DAN", HOSEA: "HOS", JOEL: "JOL", AMOS: "AMO", OBADIAH: "OBA", JONAH: "JON", MICAH: "MIC", NAHUM: "NAM", HABAKKUK: "HAB", ZEPHANIAH: "ZEP", HAGGAI: "HAG", ZECHARIAH: "ZEC", MALACHI: "MAL",
  MATTHEW: "MAT", MARK: "MRK", LUKE: "LUK", JOHN: "JHN", ACTS: "ACT", ROMANS: "ROM", GALATIANS: "GAL", EPHESIANS: "EPH", PHILIPPIANS: "PHP", COLOSSIANS: "COL", TITUS: "TIT", PHILEMON: "PHM", HEBREWS: "HEB", JAMES: "JAS", JUDE: "JUD", REVELATION: "REV"
};
const storyBookCodeSet = new Set(Object.values(storyBookCodes));

function passageIDFromText(value) {
  if (typeof value !== "string") return null;
  // Models often return a normal Bible reference (for example, "Mark 5:25–34")
  // rather than the YouVersion USFM code. Resolve that before looking for an
  // already-coded reference; otherwise "MARK.5.25" is mistaken for a code.
  for (const [bookName, bookCode] of Object.entries(storyBookCodes)) {
    const namePattern = bookName.replace(/ /g, "\\s+");
    const reference = new RegExp(`\\b${namePattern}\\s+(\\d+)(?:\\s*[:.]\\s*(\\d+))?(?:\\s*[-–—]\\s*(?:(\\d+)\\s*[:.]\\s*)?(\\d+))?`, "i").exec(value);
    if (!reference) continue;
    const [, chapter, verse, endChapter, endVerse] = reference;
    const start = verse ? `${bookCode}.${chapter}.${verse}` : `${bookCode}.${chapter}`;
    const end = endVerse ? `-${endChapter ? `${endChapter}.` : ""}${endVerse}` : "";
    return validatedStoryPassageID(`${start}${end}`);
  }
  const normalized = value.toUpperCase()
    .replace(/[–—]/g, "-")
    .replace(/:/g, ".")
    .replace(/\b([A-Z0-9]{3,5})\s+(\d+)/g, "$1.$2");
  const match = normalized.match(/[A-Z0-9]{3,5}\.\d+(?:\.\d+)?(?:-\d+(?:\.\d+)?)?/);
  if (match) return validatedStoryPassageID(match[0]);
  return null;
}

// Gloo may return an array, prose around a reference, or several ordinary
// references in one reply. Preserve every valid candidate instead of taking
// only the first one and letting a single bad reference sink the whole shelf.
function passageIDsFromText(value) {
  if (typeof value !== "string") return [];
  const candidates = [];
  const referencePattern = /\b(?:1\s+|2\s+|3\s+)?(?:Samuel|Kings|Chronicles|Corinthians|Thessalonians|Timothy|Peter|John|Genesis|Exodus|Leviticus|Numbers|Deuteronomy|Joshua|Judges|Ruth|Ezra|Nehemiah|Esther|Job|Psalms?|Proverbs|Ecclesiastes|Isaiah|Jeremiah|Lamentations|Ezekiel|Daniel|Hosea|Joel|Amos|Obadiah|Jonah|Micah|Nahum|Habakkuk|Zephaniah|Haggai|Zechariah|Malachi|Matthew|Mark|Luke|Acts|Romans|Galatians|Ephesians|Philippians|Colossians|Titus|Philemon|Hebrews|James|Jude|Revelation)\s+\d+(?:\s*:\s*\d+)?(?:\s*[-–—]\s*(?:\d+\s*:\s*)?\d+)?/gi;
  for (const match of value.match(referencePattern) || []) {
    const parsed = passageIDFromText(match);
    if (parsed) candidates.push(parsed);
  }
  const normalized = value.toUpperCase().replace(/[–—]/g, "-").replace(/:/g, ".");
  const usfmPattern = /[A-Z0-9]{3,5}\.\d+(?:\.\d+)?(?:-\d+(?:\.\d+)?)?/g;
  for (const match of normalized.match(usfmPattern) || []) {
    const parsed = validatedStoryPassageID(match);
    if (parsed) candidates.push(parsed);
  }
  const first = passageIDFromText(value);
  if (first) candidates.push(first);
  return [...new Set(candidates)];
}

function completionText(value) {
  if (typeof value === "string") return value.trim();
  if (Array.isArray(value)) {
    return value.map((part) => {
      if (typeof part === "string") return part;
      if (typeof part?.text === "string") return part.text;
      if (typeof part?.content === "string") return part.content;
      return "";
    }).join("\n").trim();
  }
  return "";
}

function structuredCompletion(raw) {
  if (!raw) return null;
  const cleaned = raw.replace(/^```(?:json)?\s*|\s*```$/g, "").trim();
  try { return JSON.parse(cleaned); } catch { /* Try JSON surrounded by prose. */ }
  const start = cleaned.indexOf("{");
  const end = cleaned.lastIndexOf("}");
  if (start >= 0 && end > start) {
    try { return JSON.parse(cleaned.slice(start, end + 1)); } catch { return null; }
  }
  return null;
}

function faithLensDetailsFromRaw(raw) {
  const structured = structuredCompletion(raw);
  if (structured) return structured;
  if (typeof raw !== "string") return null;
  // Vision routes occasionally obey the content request but miss JSON mode.
  // Recover a small labelled response rather than discarding the useful
  // reflection and falling through to an unrelated generic passage.
  const field = (names) => {
    const match = new RegExp(`(?:^|\\n)\\s*(?:${names.join("|")})\\s*[:—-]\\s*(.+?)(?=\\n\\s*(?:reflection|response|prayer|passage(?:id)?|scripture)\\s*[:—-]|$)`, "is").exec(raw);
    return match?.[1]?.replace(/\\s+/g, " ").trim() || "";
  };
  const response = field(["reflection", "response"]);
  const prayer = field(["prayer"]);
  const passageID = field(["passage(?:id)?", "scripture", "reference"]);
  if (response || prayer || passageID) return { response, prayer, passageID };

  const plain = faithLensReflectionText(raw);
  return plain ? { response: plain, prayer: "", passageID: passageIDFromText(raw) || "" } : null;
}

function fallbackStoryPassageID(prompt) {
  const context = prompt.toLowerCase();
  if (/samson.{0,50}delilah|delilah.{0,50}samson/.test(context)) return "JDG.16.4-21";
  if (/cain|abel|able/.test(context)) return "GEN.4.7";
  if (/issue of blood|woman.{0,40}(?:blood|bleed|hemorrhag)|(?:blood|bleed|hemorrhag).{0,40}woman/.test(context)) return "MRK.5.25-34";
  if (/jezebel/.test(context)) return "1KI.16.31";
  if (/david|goliath/.test(context)) return "1SA.17.45";
  if (/moses|exodus|red sea/.test(context)) return "EXO.14.13";
  if (/joseph|dream|brother/.test(context)) return "GEN.50.20";
  if (/ruth|naomi/.test(context)) return "RUT.1.16";
  if (/daniel|lion/.test(context)) return "DAN.6.22";
  if (/esther|queen/.test(context)) return "EST.4.14";
  if (/jonah|whale|fish/.test(context)) return "JON.2.2";
  if (/mary|nativity|birth of jesus/.test(context)) return "LUK.2.11";
  if (/healing|heal|sick/.test(context)) return "MRK.2.5";
  if (/creation|created|beginning/.test(context)) return "GEN.1.1";
  if (/fear|afraid|courage|brave/.test(context)) return "EST.4.14";
  if (/lost|forgive|forgiveness|return/.test(context)) return "LUK.15.20";
  if (/storm|anxious|anxiety|peace/.test(context)) return "MRK.4.39";
  if (/hope|waiting|promise/.test(context)) return "GEN.12.2";
  return null;
}

function specificStoryPassageID(prompt) {
  const context = prompt.toLowerCase();
  if (/samson.{0,50}delilah|delilah.{0,50}samson/.test(context)) return "JDG.16.4-21";
  if (/cain|abel|able/.test(context)) return "GEN.4.7";
  if (/issue of blood|woman.{0,40}(?:blood|bleed|hemorrhag)|(?:blood|bleed|hemorrhag).{0,40}woman/.test(context)) return "MRK.5.25-34";
  if (/jezebel/.test(context)) return "1KI.16.31";
  return null;
}

async function resolveStoryPassageID(accessToken, prompt, narration) {
  const repairResponse = await fetch("https://platform.ai.gloo.com/ai/v2/chat/completions", {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${accessToken}` },
    body: JSON.stringify({
      auto_routing: true,
      temperature: 0,
      max_tokens: 80,
      messages: [{
        role: "system",
        content: "Identify the one canonical Bible passage that grounds this requested scene. Reply with exactly one USFM passage ID and nothing else, for example MRK.5.25-34. Use real codes (MRK, not MARK; 1KI, not 1 KINGS). Do not use a generic Jesus passage when a named event or person is supplied."
      }, {
        role: "user",
        content: `Requested story: ${prompt}\n\nGenerated scene: ${narration}`
      }]
    })
  });
  if (!repairResponse.ok) return null;
  const repair = await repairResponse.json();
  const raw = completionText(repair?.choices?.[0]?.message?.content);
  const structured = structuredCompletion(raw);
  const value = structured?.passageID || structured?.passageId || structured?.passage_id
    || structured?.passage || structured?.reference || structured?.scriptureReference
    || structured?.scripture_reference || raw;
  return validatedStoryPassageID(value) || passageIDFromText(value);
}

async function resolveParallelPassageIDs(accessToken, prompt) {
  const repairResponse = await fetch("https://platform.ai.gloo.com/ai/v2/chat/completions", {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${accessToken}` },
    body: JSON.stringify({
      auto_routing: true,
      temperature: 0,
      max_tokens: 180,
      messages: [{
        role: "system",
        content: "You repair Bible retrieval requests for Tevari Parallel. Given a person's present moment, identify one to three concrete, genuinely analogous biblical accounts. Reply with strict JSON only: {\"passageIDs\":[\"USFM verse/range\"]}. Use real passage IDs such as EXO.18.17-23 or LUK.10.38-42. Never give thematic verses, advice, or prose."
      }, {
        role: "user",
        content: prompt
      }]
    })
  });
  if (!repairResponse.ok) return [];
  const repair = await repairResponse.json();
  const raw = completionText(repair?.choices?.[0]?.message?.content);
  const structured = structuredCompletion(raw) || {};
  const values = Array.isArray(structured.passageIDs) ? structured.passageIDs
    : Array.isArray(structured.passages) ? structured.passages
      : [structured.passageID, structured.passageId, structured.passage, raw];
  return [...new Set(values.flatMap((value) => [
    validatedStoryPassageID(value),
    ...passageIDsFromText(value)
  ]).filter(Boolean))];
}

async function repairStoryDetails(accessToken, prompt, continuationPassageID) {
  const repairResponse = await fetch("https://platform.ai.gloo.com/ai/v2/chat/completions", {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${accessToken}` },
    body: JSON.stringify({
      auto_routing: true,
      temperature: 0.2,
      max_tokens: 420,
      messages: [{
        role: "system",
        content: "Return strict JSON only with title, guide, narration, and passageID. Tell one accurate, concise Bible-story scene for the request. title: 8 words maximum. guide: 35 words maximum. narration: 40-60 words of plain spoken prose with a complete ending. passageID: one real USFM verse/range. Never output markdown, code fences, JSON labels, explanations, or any text outside the JSON. If the requested event is not narrated in the Bible, say so plainly in the guide and use the closest directly relevant canonical passage; do not invent the event."
      }, {
        role: "user",
        content: continuationPassageID ? `${prompt}\n\nContinue from this Scripture anchor: ${continuationPassageID}.` : prompt
      }]
    })
  });
  if (!repairResponse.ok) return null;
  const repair = await repairResponse.json();
  return structuredCompletion(completionText(repair?.choices?.[0]?.message?.content));
}

async function repairFaithLensDetails(accessToken, input, tradition) {
  const repairResponse = await fetch("https://platform.ai.gloo.com/ai/v2/chat/completions", {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${accessToken}` },
    body: JSON.stringify({
      auto_routing: true,
      ...(tradition === "general" ? {} : { tradition }),
      temperature: 0.2,
      max_tokens: 220,
      messages: [{
        role: "system",
        content: "Return strict JSON only with response, prayer, and passageID. response is a grounded Christian reflection of 40 words maximum. prayer is optional and 35 words maximum. passageID is one real USFM verse/range. Never output Markdown, code fences, a JSON label, or any text outside the JSON. Do not claim private knowledge of God's will or infer sensitive facts from an image."
      }, {
        role: "user",
        content: [{ type: "text", text: input.question }, { type: "image_url", image_url: { url: `data:image/jpeg;base64,${input.imageBase64}` } }]
      }]
    })
  });
  if (!repairResponse.ok) return null;
  const repair = await repairResponse.json();
  return faithLensDetailsFromRaw(completionText(repair?.choices?.[0]?.message?.content));
}

async function resolveFaithLensPassageID(accessToken, input, tradition) {
  const response = await fetch("https://platform.ai.gloo.com/ai/v2/chat/completions", {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${accessToken}` },
    body: JSON.stringify({
      auto_routing: true,
      ...(tradition === "general" ? {} : { tradition }),
      temperature: 0,
      max_tokens: 32,
      messages: [{
        role: "system",
        content: "Look at the submitted image and select one specific, concrete Bible passage that fits what is visibly present and the user's question. Reply with exactly one real USFM passage ID, for example MAT.6.26 or MRK.4.35-41. Do not reply with a reflection, JSON, headings, Markdown, or Psalm 23 unless the image/question specifically calls for shepherding or provision."
      }, {
        role: "user",
        content: [{ type: "text", text: input.question }, { type: "image_url", image_url: { url: `data:image/jpeg;base64,${input.imageBase64}` } }]
      }]
    })
  });
  if (!response.ok) return null;
  const payload = await response.json();
  const raw = completionText(payload?.choices?.[0]?.message?.content);
  return validatedStoryPassageID(raw) || passageIDFromText(raw);
}

function storyText(value, maximumLength) {
  return typeof value === "string" ? value.trim().slice(0, maximumLength) : "";
}

function storyNarrationText(value) {
  const cleaned = storyText(value, 1_200)
    .replace(/```[\s\S]*?```/g, " ")
    .replace(/^\s*(?:#{1,6}|[-*•])\s+/gm, "")
    .replace(/\[([^\]]+)\]\([^)]*\)/g, "$1")
    .replace(/[*_`#>|]/g, "")
    .replace(/\s+/g, " ")
    .trim();
  if (!cleaned) return "";

  // Keep complete spoken sentences. A word slice can make a faithful scene
  // sound like disconnected facts or leave Kokoro reading unfinished markup.
  const sentences = cleaned.match(/[^.!?]+[.!?]+/g) || [];
  const complete = [];
  let words = 0;
  for (const sentence of sentences) {
    const count = sentence.trim().split(/\s+/).length;
    if (words + count > 60) break;
    complete.push(sentence.trim());
    words += count;
  }
  if (complete.length) return complete.join(" ");
  return cleaned.split(/\s+/).slice(0, 60).join(" ").replace(/[,:;\-]+$/, "") + ".";
}

function storyGuideText(value) {
  const guide = storyText(value, 220).replace(/\s+/g, " ").trim();
  if (guide) return guide;
  return "";
}

function guideFromNarration(narration) {
  const sentences = narration.match(/[^.!?]+[.!?]+/g) || [];
  return storyGuideText(sentences.slice(0, 2).join(" ")) || storyGuideText(narration);
}

function fallbackStoryDetails(prompt) {
  if (/samson.{0,50}delilah|delilah.{0,50}samson/.test(prompt.toLowerCase())) {
    return {
      title: "Samson and Delilah",
      guide: "Samson's strength is bound up with a sacred calling. Delilah presses him to reveal its source, and betrayal leaves him exposed before his enemies.",
      narration: "Samson loves Delilah, but the rulers around her want the secret of his strength. Again and again she asks, and eventually Samson tells her of the vow marked by his uncut hair. While he sleeps, his hair is cut. Samson rises expecting strength, but he has been betrayed and captured."
    };
  }
  if (/cain|abel|able/.test(prompt.toLowerCase())) {
    return {
      title: "Cain and Abel",
      guide: "Two brothers bring offerings before God. Their story invites honest reflection on worship, envy, responsibility, and the care we owe one another.",
      narration: "Cain and Abel come before God with their offerings. Cain grows angry when Abel's offering is received differently. God warns Cain that sin is close, yet he is still responsible for his next step."
    };
  }
  return null;
}

/**
 * Generates a single, short prompt only after the user has explicitly started
 * prayer and approved the transcript history sent by the iPhone.
 */
export const prayerContinue = onRequest(
  {
    region: "us-central1",
    cors: false,
    secrets: [glooClientID, glooClientSecret, youVersionAppKey]
  },
  async (request, response) => {
    if (request.method !== "POST") return sendError(response, 405, "method_not_allowed", "Use POST.");
    const user = await requireFirebaseUser(request, response);
    if (!user) return;

    const history = validatedPrayerHistory(request.body?.history);
    const tradition = request.body?.tradition || "general";
    if (!history || !allowedTraditions.has(tradition)) {
      return sendError(response, 400, "invalid_request", "Prayer history or tradition is invalid.");
    }

    let stage = "Gloo authorization";
    try {
      const accessToken = await glooAccessToken();
      stage = "Gloo prayer prompt";
      const completionResponse = await fetch("https://platform.ai.gloo.com/ai/v2/chat/completions", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${accessToken}`
        },
        body: JSON.stringify({
          auto_routing: true,
          // Gloo accepts only named tradition values. "general" is Tevari's
          // internal no-preference state, so it must be omitted rather than
          // passed through as an invalid provider value.
          ...(tradition === "general" ? {} : { tradition }),
          temperature: 0.35,
          max_tokens: 80,
          messages: [
            {
              role: "system",
              content: "You support a person who is actively praying. The user's transcript is private prayer context: identify its specific concern, need, or person (for example health, grief, work, family, or gratitude) and make the next gentle phrase clearly relevant to that context. Return valid JSON only, exactly with keys prompt and passageID. prompt is one gentle prayer-continuation phrase or structural prompt, no more than 30 words. passageID is one relevant USFM verse or short range such as JAS.5.15 or PSA.23.1-3. Do not quote Scripture. Do not take over the prayer, claim divine authority, diagnose, or invent facts."
            },
            ...history
          ]
        })
      });

      const completion = await completionResponse.json();
      if (!completionResponse.ok) {
        console.error("Gloo completion failed", { status: completionResponse.status, code: completion?.error?.code, traceID: completion?.error?.trace_id });
        return sendError(response, 502, "prayer_service_unavailable", "Tevari could not prepare a prayer prompt right now.");
      }

      const rawContent = completionText(completion?.choices?.[0]?.message?.content);
      const generated = structuredCompletion(rawContent);
      // Some routed models return a valid prayer line but ignore JSON-only
      // instructions. Preserve that helpful response and select a licensed
      // Scripture reference from the approved transcript instead of failing.
      const prompt = prayerPromptFromCompletion(rawContent, generated, history);
      const generatedPassageID = generated?.passageID?.trim()?.toUpperCase();
      const passageID = typeof generatedPassageID === "string" && usfmPassagePattern.test(generatedPassageID)
        ? generatedPassageID
        : fallbackPassageID(history);
      if (typeof prompt !== "string" || !prompt) {
        return sendError(response, 502, "invalid_prayer_response", "Tevari received an unusable prayer prompt.");
      }
      stage = "YouVersion Scripture";
      const scripture = await licensedScripture(passageID);
      response.status(200).json({ prompt, scripture, model: completion.model || null });
    } catch (error) {
      // Never log the prayer transcript. The stage and status message are enough
      // to diagnose provider configuration without retaining private content.
      console.error("Prayer request failed", {
        stage,
        message: error instanceof Error ? error.message : "unknown"
      });
      if (stage === "YouVersion Scripture") {
        sendError(response, 502, "scripture_service_unavailable", "Tevari could not retrieve a licensed Bible passage right now.");
      } else {
        sendError(response, 502, "prayer_service_unavailable", "Tevari could not prepare a prayer prompt right now.");
      }
    }
  }
);

/**
 * Faith Lens analyzes one user-triggered glasses frame plus their spoken
 * question. The frame is processed for this response only; it is neither
 * logged nor persisted by this function.
 */
export const faithLens = onRequest(
  {
    region: "us-central1",
    cors: false,
    secrets: [glooClientID, glooClientSecret, youVersionAppKey]
  },
  async (request, response) => {
    if (request.method !== "POST") return sendError(response, 405, "method_not_allowed", "Use POST.");
    const user = await requireFirebaseUser(request, response);
    if (!user) return;
    const input = validatedFaithLensRequest(request.body);
    const tradition = request.body?.tradition || "general";
    if (!input || !allowedTraditions.has(tradition)) {
      return sendError(response, 400, "invalid_request", "Faith Lens needs one question and one captured image.");
    }

    let stage = "Gloo authorization";
    try {
      const accessToken = await glooAccessToken();
      stage = "Gloo Faith Lens response";
      const completionResponse = await fetch("https://platform.ai.gloo.com/ai/v2/chat/completions", {
        method: "POST",
        headers: { "Content-Type": "application/json", Authorization: `Bearer ${accessToken}` },
        body: JSON.stringify({
          auto_routing: true,
          ...(tradition === "general" ? {} : { tradition }),
          temperature: 0.3,
          max_tokens: 170,
          messages: [{
            role: "system",
            content: "You are Tevari Faith Lens. Respond to a user's real-world image and question with a gentle, grounded Christian reflection. Never claim to know God's private will, diagnose, infer sensitive personal facts, or present generated words as Scripture. Return strict JSON only: response (40 words max), prayer (optional 35 words max), and passageID (one USFM verse/range). Do not quote Scripture. If the image is unclear, say so gently and answer the user's stated question."
          }, {
            role: "user",
            content: [{ type: "text", text: input.question }, { type: "image_url", image_url: { url: `data:image/jpeg;base64,${input.imageBase64}` } }]
          }]
        })
      });
      const completion = await completionResponse.json();
      if (!completionResponse.ok) {
        console.error("Faith Lens completion failed", { status: completionResponse.status, code: completion?.error?.code, traceID: completion?.error?.trace_id });
        return sendError(response, 502, "faith_lens_unavailable", "Tevari could not reflect on this moment right now.");
      }
      const raw = completionText(completion?.choices?.[0]?.message?.content);
      const primary = faithLensDetailsFromRaw(raw);
      const repaired = (!primary?.response || !primary?.passageID)
        ? await repairFaithLensDetails(accessToken, input, tradition)
        : null;
      const generated = {
        response: primary?.response || repaired?.response || "",
        prayer: primary?.prayer || repaired?.prayer || "",
        passageID: primary?.passageID || repaired?.passageID || ""
      };
      // Raw vision-model content is not displayable product content. It can
      // contain partial JSON, Markdown, or provider framing, so accept only a
      // validated structured reflection.
      const modelReflection = faithLensReflectionText(generated?.response);
      const isScriptureOnlyRequest = /^what scripture speaks to this moment\?$/i.test(input.question);
      // Find Scripture should lead with the licensed passage, not an invented
      // filler reflection. Other Faith Lens requests retain a gentle fallback
      // when the routed model has no usable prose.
      const reflection = modelReflection || (isScriptureOnlyRequest ? "" : fallbackFaithLensReflection(input.question));
      const prayer = faithLensReflectionText(generated?.prayer) || null;
      const candidate = generated.passageID?.trim()?.toUpperCase();
      const parsedPassageID = typeof candidate === "string" && usfmPassagePattern.test(candidate)
        ? candidate
        : passageIDFromText(generated.passageID || raw);
      const resolvedPassageID = parsedPassageID || await resolveFaithLensPassageID(accessToken, input, tradition);
      const passageID = resolvedPassageID || fallbackFaithLensPassageID(input.question);
      stage = "YouVersion Scripture";
      const scripture = await licensedScripture(passageID);
      response.status(200).json({ response: reflection, prayer: prayer || null, scripture, model: completion.model || null });
    } catch (error) {
      console.error("Faith Lens request failed", { stage, message: error instanceof Error ? error.message : "unknown" });
      const message = stage === "YouVersion Scripture"
        ? "Tevari could not retrieve a licensed Bible passage right now."
        : "Tevari could not reflect on this moment right now.";
      sendError(response, 502, "faith_lens_unavailable", message);
    }
  }
);

/**
 * Creates one concise Story scene. Gloo writes only the clearly-labelled
 * narration/guide; exact Scripture always comes from YouVersion afterwards.
 */
export const parallel = onRequest(
  { region: "us-central1", cors: false, secrets: [glooClientID, glooClientSecret, youVersionAppKey] },
  async (request, response) => {
    if (request.method !== "POST") return sendError(response, 405, "method_not_allowed", "Use POST.");
    const user = await requireFirebaseUser(request, response);
    if (!user) return;
    const prompt = validatedStoryPrompt(request.body);
    const tradition = request.body?.tradition || "general";
    const imageBase64 = typeof request.body?.imageBase64 === "string" ? request.body.imageBase64 : null;
    if (!prompt || !allowedTraditions.has(tradition)) return sendError(response, 400, "invalid_request", "Parallel needs a short moment and a valid tradition.");
    if (imageBase64 && (!Buffer.from(imageBase64, "base64").length || Buffer.from(imageBase64, "base64").length > maxFaithLensImageBytes)) {
      return sendError(response, 400, "invalid_request", "Parallel image is invalid.");
    }
    let stage = "Gloo authorization";
    try {
      const accessToken = await glooAccessToken();
      stage = "Gloo Parallel";
      const userContent = imageBase64
        ? [{ type: "text", text: prompt }, { type: "image_url", image_url: { url: `data:image/jpeg;base64,${imageBase64}` } }]
        : prompt;
      const completionResponse = await fetch("https://platform.ai.gloo.com/ai/v2/chat/completions", {
        method: "POST",
        headers: { "Content-Type": "application/json", Authorization: `Bearer ${accessToken}` },
        body: JSON.stringify({
          auto_routing: true,
          ...(tradition === "general" ? {} : { tradition }),
          temperature: 0.3,
          max_tokens: 260,
          messages: [{
            role: "system",
            content: "You are Tevari Parallel, a Scripture retrieval engine. Find one to three concrete biblical accounts genuinely analogous to the person's present moment. Return strict JSON only: {\"passageIDs\":[\"USFM verse/range\"]}. Do not write an explanation, reflection, advice, prayer, narration, title, or any other prose. Select actual analogous situations, not broad thematic verses. Use real USFM codes such as JHN.5.1-9."
          }, { role: "user", content: userContent }]
        })
      });
      const completion = await completionResponse.json();
      if (!completionResponse.ok) return sendError(response, 502, "parallel_unavailable", "Tevari could not create a Parallel right now.");
      const raw = completionText(completion?.choices?.[0]?.message?.content);
      const generated = structuredCompletion(raw) || {};
      const suggested = Array.isArray(generated.passageIDs) ? generated.passageIDs
        : Array.isArray(generated.passages) ? generated.passages
          : [generated.passageID, generated.passageId, generated.passage, raw];
      const glooPassageIDs = suggested.flatMap((value) => [
        validatedStoryPassageID(value),
        ...passageIDsFromText(value)
      ]).filter(Boolean);
      // This independent, retrieval-only pass makes the feature work for an
      // open-ended moment even if the first model reply has malformed JSON.
      const repairedPassageIDs = await resolveParallelPassageIDs(accessToken, prompt);
      const passageIDs = [...new Set([
        ...directParallelPassageIDs(prompt),
        ...glooPassageIDs,
        ...repairedPassageIDs
      ])].slice(0, 6);
      if (!passageIDs.length) return sendError(response, 502, "parallel_unavailable", "Tevari could not find a specific parallel in Scripture for this moment.");
      stage = "YouVersion Scripture";
      // A model can occasionally name a real-looking but invalid range. Keep
      // the valid, licensed results instead of failing the entire experience.
      const passageResults = await Promise.allSettled(passageIDs.map((id) => licensedScripture(id)));
      const passages = passageResults
        .filter((result) => result.status === "fulfilled")
        .map((result) => result.value)
        .slice(0, 3);
      if (!passages.length) return sendError(response, 502, "parallel_unavailable", "Tevari could not retrieve a licensed Bible passage for this Parallel.");
      response.status(200).json({ moment: "", scene: "", narration: "", scripture: passages[0], supporting: passages.slice(1), model: completion.model || null });
    } catch (error) {
      console.error("Parallel failed", { stage, message: error instanceof Error ? error.message : "unknown" });
      sendError(response, 502, "parallel_unavailable", stage === "YouVersion Scripture" ? "Tevari could not retrieve the licensed Bible passage for this Parallel." : "Tevari could not create a Parallel right now.");
    }
  }
);

export const storyScene = onRequest(
  {
    region: "us-central1",
    cors: false,
    secrets: [glooClientID, glooClientSecret, youVersionAppKey]
  },
  async (request, response) => {
    if (request.method !== "POST") return sendError(response, 405, "method_not_allowed", "Use POST.");
    const user = await requireFirebaseUser(request, response);
    if (!user) return;
    const prompt = validatedStoryPrompt(request.body);
    const continuationPassageID = validatedStoryPassageID(request.body?.continuationPassageID);
    const tradition = request.body?.tradition || "general";
    if (!prompt || !allowedTraditions.has(tradition)) {
      return sendError(response, 400, "invalid_request", "Story needs a short prompt and a valid tradition.");
    }

    let stage = "Gloo authorization";
    try {
      const accessToken = await glooAccessToken();
      stage = "Gloo Story scene";
      const completionResponse = await fetch("https://platform.ai.gloo.com/ai/v2/chat/completions", {
        method: "POST",
        headers: { "Content-Type": "application/json", Authorization: `Bearer ${accessToken}` },
        body: JSON.stringify({
          auto_routing: true,
          ...(tradition === "general" ? {} : { tradition }),
          temperature: 0.35,
          max_tokens: 240,
          messages: [{
            role: "system",
            content: "You are Tevari Story. Create exactly one short, vivid Bible-story scene in response to the user's prompt. Identify the named person, event, or theme and select a passage that specifically matches it; never default to David or Goliath unless the user asks for them. If a continuation passage is supplied, continue that exact biblical thread with an adjacent canonical passage. Return strict JSON only with title (8 words max), guide (35 words max), narration (40-60 words), and passageID (one USFM verse/range). Narration must be plain spoken prose: no headings, hashtags, Markdown, bullets, labels, citations, verse numbers, or symbols. It must be a complete coherent scene with setup, action, and a natural ending—never a list of facts or a sentence cut off mid-thought. Narration is a clearly non-Scripture guide: do not quote Bible text, invent canonical events, claim divine authority, or present interpretation as fact. Keep the scene faithful to the selected passage and suitable for spoken narration."
          }, {
            role: "user",
            content: continuationPassageID
              ? `${prompt}\n\nContinue from this Scripture anchor: ${continuationPassageID}.`
              : prompt
          }]
        })
      });
      const completion = await completionResponse.json();
      if (!completionResponse.ok) {
        console.error("Gloo Story completion failed", { status: completionResponse.status, code: completion?.error?.code, traceID: completion?.error?.trace_id });
        return sendError(response, 502, "story_unavailable", "Tevari could not prepare a Bible story right now.");
      }
      const raw = completionText(completion?.choices?.[0]?.message?.content);
      const generated = structuredCompletion(raw) || await repairStoryDetails(accessToken, prompt, continuationPassageID);
      const fallback = fallbackStoryDetails(prompt);
      // Raw model text is never a safe story scene: a partial JSON reply can
      // otherwise show code fragments as narration. Use only validated fields
      // from one of the two structured retrieval passes.
      const narration = storyNarrationText(generated?.narration) || fallback?.narration || "";
      const title = storyText(generated?.title || generated?.storyTitle || generated?.story_title, 80)
        || fallback?.title || "";
      const guide = storyGuideText(generated?.guide || generated?.summary || generated?.description || generated?.sceneDescription || generated?.scene_description)
        || fallback?.guide || guideFromNarration(narration)
        || "";
      const generatedPassage = generated?.passageID
        || generated?.passageId
        || generated?.passage_id
        || generated?.passage
        || generated?.scripture
        || generated?.scriptureReference
        || generated?.scripture_reference;
      const candidate = validatedStoryPassageID(generatedPassage)
        || passageIDFromText(generatedPassage)
        || passageIDFromText(raw);
      // The narration model is intentionally creative; resolve the Scripture
      // separately so a good scene is never paired with a generic fallback.
      const resolvedPassageID = await resolveStoryPassageID(accessToken, prompt, narration);
      const passageID = specificStoryPassageID(prompt) || resolvedPassageID || candidate || continuationPassageID || fallbackStoryPassageID(prompt);
      if (!passageID) {
        console.warn("Unmatched Story response", { hasNarration: Boolean(narration), rawLength: raw.length });
        return sendError(response, 502, "unmatched_story", "Tevari could not match that request to a Bible story. Try naming a person, event, or passage.");
      }
      if (!title || !guide || !narration) {
        return sendError(response, 502, "invalid_story_response", "Tevari could not match that request to a Bible story. Try naming a person, event, or passage.");
      }
      stage = "YouVersion Scripture";
      const scripture = await licensedScripture(passageID);
      response.status(200).json({ title, guide, narration, scripture, model: completion.model || null });
    } catch (error) {
      console.error("Story scene failed", { stage, message: error instanceof Error ? error.message : "unknown" });
      const message = stage === "YouVersion Scripture"
        ? "Tevari could not retrieve the licensed Bible passage for this story."
        : "Tevari could not prepare a Bible story right now.";
      sendError(response, 502, "story_unavailable", message);
    }
  }
);

/** Proxies private Kokoro narration. Cloud Run is never callable from the app. */
export const storyNarration = onRequest(
  {
    region: "us-central1",
    cors: false,
    timeoutSeconds: 180,
    secrets: []
  },
  async (request, response) => {
    if (request.method !== "POST") return sendError(response, 405, "method_not_allowed", "Use POST.");
    const user = await requireFirebaseUser(request, response);
    if (!user) return;
    const narration = storyText(request.body?.narration, maxStoryNarrationCharacters);
    if (!narration) return sendError(response, 400, "invalid_request", "Narration text is invalid.");

    try {
      const baseURL = storyVoiceURL.value().replace(/\/$/, "");
      const client = await new GoogleAuth().getIdTokenClient(baseURL);
      const identityHeaders = await client.getRequestHeaders(baseURL);
      const voiceResponse = await fetch(`${baseURL}/v1/narrations`, {
        method: "POST",
        headers: { ...identityHeaders, "Content-Type": "application/json" },
        body: JSON.stringify({ text: narration, voice: "af_bella", speed: 0.96 })
      });
      if (!voiceResponse.ok) throw new Error(`Narrator returned ${voiceResponse.status}.`);
      const audio = Buffer.from(await voiceResponse.arrayBuffer());
      if (audio.length < 44 || audio.subarray(0, 4).toString() !== "RIFF" || audio.subarray(8, 12).toString() !== "WAVE") {
        throw new Error("Narrator returned invalid WAV audio.");
      }
      response.set({ "Cache-Control": "private, no-store" });
      response.status(200).json({ audioBase64: audio.toString("base64") });
    } catch (error) {
      console.error("Story narration failed", { message: error instanceof Error ? error.message : "unknown" });
      sendError(response, 502, "story_voice_unavailable", "Tevari could not prepare the story narration right now.");
    }
  }
);

/** Returns licensed Bible text and publisher attribution from YouVersion. */
export const scripturePassage = onRequest(
  {
    region: "us-central1",
    cors: false,
    secrets: [youVersionAppKey]
  },
  async (request, response) => {
    if (request.method !== "POST") return sendError(response, 405, "method_not_allowed", "Use POST.");
    const user = await requireFirebaseUser(request, response);
    if (!user) return;

    const bibleID = request.body?.bibleID;
    const passageID = request.body?.passageID;
    if (!Number.isInteger(bibleID) || bibleID <= 0 || typeof passageID !== "string" || !usfmPassagePattern.test(passageID)) {
      return sendError(response, 400, "invalid_request", "Bible ID or passage ID is invalid.");
    }

    try {
      const headers = { "X-YVP-App-Key": youVersionAppKey.value(), Accept: "application/json" };
      const [passageResponse, bibleResponse] = await Promise.all([
        fetch(`https://api.youversion.com/v1/bibles/${bibleID}/passages/${encodeURIComponent(passageID)}`, { headers }),
        fetch(`https://api.youversion.com/v1/bibles/${bibleID}`, { headers })
      ]);

      if (!passageResponse.ok || !bibleResponse.ok) {
        console.error("YouVersion request failed", { passageStatus: passageResponse.status, bibleStatus: bibleResponse.status });
        return sendError(response, 502, "scripture_service_unavailable", "Tevari could not retrieve this passage right now.");
      }

      const [passage, bible] = await Promise.all([passageResponse.json(), bibleResponse.json()]);
      response.status(200).json({
        passage: { id: passage.id, reference: passage.reference, content: passage.content },
        bible: {
          id: bible.id,
          title: bible.title,
          abbreviation: bible.abbreviation,
          copyright: bible.copyright,
          info: bible.info,
          publisherURL: bible.publisher_url,
          deepLink: bible.youversion_deep_link
        }
      });
    } catch (error) {
      console.error("Scripture request failed", { message: error instanceof Error ? error.message : "unknown" });
      sendError(response, 502, "scripture_service_unavailable", "Tevari could not retrieve this passage right now.");
    }
  }
);
