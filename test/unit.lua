-- Unit tests for auto_title.lua, by behavior: the two state machines (what
-- happens to a label, how a tab finds its conversation), then the name a tab
-- gets, what each agent's conversation is called, and which agent a tab runs.
--
--   rex do test/unit.lua            (from the repository root)

REX_AUTO_TITLE_LIB = true
local here = (debug.getinfo(1, "S").source:match("^@(.*)/test/[^/]*$")) or "."
local M = dofile(here .. "/auto_title.lua")

local passed, failed = 0, 0
local function show(v) return type(v) == "table" and rex.json.encode(v) or tostring(v) end
local function check(name, got, want)
  if show(got) == show(want) then
    passed = passed + 1
  else
    failed = failed + 1
    print("FAIL " .. name .. "\n  got:  " .. show(got) .. "\n  want: " .. show(want))
  end
end

local T = os.tmpname()
os.remove(T)
local function write(path, text)
  rex.exec({ "mkdir", "-p", (path:match("^(.*)/[^/]*$")) })
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end
local function append(path, text)
  local f = assert(io.open(path, "ab"))
  f:write(text)
  f:close()
end
local function json(v) return rex.json.encode(v) .. "\n" end

---------------------------------------------------------------------------
-- State machine 1: what happens to a tab's label.
-- current label x who set it x what it should be -> set | keep | reset | manual

local D, OURS = "Window 1234abcd", "proj - fix login"
check("Rex's default label is Window + the window ID's last 8",
  M.default_label("window:01a1-cd47-75c8-af82-1234abcd"), D)
for _, c in ipairs({
  -- name                                        current  owned  desired         want
  { "unnamed tab gets a name",                    D,      nil,   "proj",         "set" },
  { "unnamed tab with nothing to say stays",      D,      nil,   "",             "keep" },
  { "our label, still right",                     OURS,   OURS,  OURS,           "keep" },
  { "our label follows the work",                 OURS,   OURS,  "proj - next",  "set" },
  { "our label, nothing left to say: reset",      OURS,   OURS,  "",             "reset" },
  { "user's label is left alone",                 "mine", OURS,  "proj",         "manual" },
  { "user's label on a tab we never named",       "mine", nil,   "proj",         "manual" },
  { "user's label with nothing to say",           "mine", nil,   "",             "manual" },
  { "a label equal to what we'd set is fine",     "proj", nil,   "proj",         "keep" },
  { "cleared by the user: handed back",           D,      "old", "proj",         "set" },
}) do
  check("label: " .. c[1], M.decide(c[2], D, c[3], c[4]), c[5])
end

---------------------------------------------------------------------------
-- State machine 2: how an agent tab comes by its conversation (pane.via).
-- A fake world of conversations stands in for the agents' files.

local world = {}
local function convo(app, cwd, key, t, topic)
  local k = app .. "\0" .. cwd
  world[k] = world[k] or {}
  table.insert(world[k], { key = key, t = t, topic = topic })
end
local sources = {
  candidates = function(app, cwd, since)
    local out = {}
    for _, c in ipairs(world[app .. "\0" .. cwd] or {}) do
      if c.t >= since then out[#out + 1] = { key = c.key, t = c.t } end
    end
    table.sort(out, function(a, b) return a.t > b.t end)
    return out
  end,
  named = function(p) return p.id end,
  topic = function(_, key)
    for _, cs in pairs(world) do
      for _, c in ipairs(cs) do if c.key == key then return c.topic end end
    end
  end,
}
-- tab(BLOCK, PID, PROGRAM, CWD, [COMMAND LINE], [STARTED AT])
local function tab(block, pid, name, cwd, cmdline, started)
  return { window_id = "window:" .. block, block_id = "block:" .. block, started = started or 900,
           cmdline = cmdline or name, proc = { foreground = { pid = pid, name = name, cwd = cwd } } }
end
local function plan(now, st, ...)
  local tabs, ps = { ... }, {}
  for _, t in ipairs(tabs) do
    if t.proc then ps[t.proc.foreground.pid] = { age = now - t.started, args = t.cmdline } end
  end
  return M.plan(tabs, ps, now, st, sources)
end
local function seen(tabs)
  local out = {}
  for _, t in ipairs(tabs) do out[#out + 1] = { t.pane and t.pane.via or "-", tostring(t.desired) } end
  return out
end

local st = {}
convo("codex", "/w/a", "old", 100, "older thread")
convo("codex", "/w/a", "a1", 950, "login fix")
check("started: alone in its folder, takes the newest conversation since it started",
  seen(plan(1000, st, tab("A", 11, "codex", "/w/a"))), { { "started", "a - login fix" } })
check("kept: the next pass keeps it",
  seen(plan(1001, st, tab("A", 11, "codex", "/w/a"))), { { "kept", "a - login fix" } })
convo("codex", "/w/a", "a2", 990, "signup page")
check("a second chat in the folder takes the new conversation; the first keeps its own",
  seen(plan(1000, st, tab("A", 11, "codex", "/w/a"), tab("B", 12, "codex", "/w/a", nil, 985))),
  { { "kept", "a - login fix" }, { "started", "a - signup page" } })

-- A session file is written when the agent starts, before anyone has typed, so
-- taking it then would name the tab after an empty conversation.
st = {}
convo("pi", "/w/y", "y1", 1000, nil)
check("waiting: a session nobody has spoken in yet is not taken",
  seen(plan(1000, st, tab("Y", 98, "pi", "/w/y"))), { { "waiting", "y" } })
world["pi\0/w/y"][1].topic = "spoken at last"
check("started: and is taken once someone speaks",
  seen(plan(1002, st, tab("Y", 98, "pi", "/w/y"))), { { "started", "y - spoken at last" } })

st = {}
convo("pi", "/w/x", "x1", 950, "old topic")
plan(1000, st, tab("X", 97, "pi", "/w/x"))
convo("pi", "/w/x", "x2", 1010, nil)
check("waiting: /new to a session nobody has spoken in yet keeps the old name",
  seen(plan(1020, st, tab("X", 97, "pi", "/w/x"))), { { "kept", "x - old topic" } })
world["pi\0/w/x"][2].topic = "new topic"
check("switched: and switches once the new session has something to say",
  seen(plan(1022, st, tab("X", 97, "pi", "/w/x"))), { { "switched", "x - new topic" } })
world["pi\0/w/x"][1].t = 1030
check("switched: the old session written again doesn't take the tab back",
  seen(plan(1030, st, tab("X", 97, "pi", "/w/x"))), { { "kept", "x - new topic" } })

convo("claude", "/w/b", "b1", 990, "one")
convo("claude", "/w/b", "b2", 991, "two")
check("ambiguous: two new chats of one agent in one folder are not guessed at",
  seen(plan(1000, {}, tab("C", 21, "claude", "/w/b"), tab("D", 22, "claude", "/w/b"))),
  { { "ambiguous", "b" }, { "ambiguous", "b" } })
local ID = "2fb47a2c-4ac5-4863-aa77-8ec316e4b15d"
convo("claude", "/w/b", ID, 10, "resumed one")
check("named: a conversation on the command line wins, and the other chat then stands alone",
  seen(plan(1000, {}, tab("E", 31, "claude", "/w/b", "claude --resume " .. ID), tab("F", 32, "claude", "/w/b"))),
  { { "named", "b - resumed one" }, { "started", "b - two" } })

st = {}
convo("codex", "/w/d", "d1", 950, "closed one")
plan(1000, st, tab("H", 51, "codex", "/w/d"))
check("waiting: a closed tab's conversation is retired, not handed to the next chat",
  seen(plan(1100, st, tab("I", 52, "codex", "/w/d", nil, 940))), { { "waiting", "d" } })
check("waiting: a conversation from before the chat started is not taken",
  seen(plan(1000, {}, tab("Z", 99, "claude", "/w/z"))), { { "waiting", "z" } })

st = {}
convo("codex", "/w/h", "h1", 950, "survives a miss")
plan(1000, st, tab("N", 91, "codex", "/w/h"))
local miss = tab("N", 91, "codex", "/w/h")
miss.proc = nil
check("unknown: a tab whose process can't be read this pass is left alone",
  seen(plan(1003, st, miss)), { { "-", "nil" } })
check("unknown: and keeps its conversation for the next pass",
  seen(plan(1006, st, tab("N", 91, "codex", "/w/h"))), { { "kept", "h - survives a miss" } })
local nocwd = tab("N", 91, "codex", "/w/h")
nocwd.proc.foreground.cwd = nil
check("unknown: a process without a folder is left alone too",
  seen(plan(1009, st, nocwd)), { { "-", "nil" } })

st = {}
convo("claude", "/w/e", "e1", 950, "e topic")
plan(1000, st, tab("J", 61, "claude", "/w/e"))
check("another program in the tab: back to its folder",
  seen(plan(1100, st, tab("J", 62, "zsh", "/w/e"))), { { "-", "e" } })
check("another program in the tab: a chat started there later doesn't take the old conversation",
  seen(plan(1200, st, tab("J", 63, "claude", "/w/e"))), { { "waiting", "e" } })

check("a shell is named after its folder; a tab without a terminal is left alone",
  seen(plan(1000, {}, tab("K", 71, "zsh", "/w/f"), { window_id = "window:L", block_id = "block:L" })),
  { { "-", "f" }, { "-", "nil" } })


---------------------------------------------------------------------------
-- The name a tab gets: "<dir> - <branch> - <topic>"

local function repo(dir, head, default)
  write(dir .. "/.git/HEAD", head .. "\n")
  if default then write(dir .. "/.git/refs/remotes/origin/HEAD", "ref: refs/remotes/origin/" .. default .. "\n") end
  return dir
end
local function name(cwd, topic) return M.name_for({ cwd = cwd }, topic) end
local function on(branch, default) return repo(T .. "/b/repo", "ref: refs/heads/" .. branch, default) end

check("folder, branch, and topic", name(on("feat/login", "main"), "fix"), "repo - feat/login - fix")
check("a subfolder of a repo shows the subfolder and the repo's branch",
  name((function() local r = on("feat/login", "main"); rex.exec({ "mkdir", "-p", r .. "/src" }); return r .. "/src" end)()),
  "src - feat/login")
check("the default branch is left out", name(on("develop", "develop")), "repo")
check("without a default, main is left out", name(repo(T .. "/nodef/repo", "ref: refs/heads/main")), "repo")
check("main is shown when the default is another branch", name(on("main", "develop")), "repo - main")
check("a branch named like the folder is left out", name(repo(T .. "/same/feat-x", "ref: refs/heads/feat-x", "main")), "feat-x")
check("detached HEAD shows a short hash",
  name(repo(T .. "/det/repo", "0123456789abcdef0123456789abcdef01234567")), "repo - 0123456")
write(T .. "/wt/.git", "gitdir: " .. T .. "/b/repo/.git/worktrees/wt\n")
write(T .. "/b/repo/.git/worktrees/wt/HEAD", "ref: refs/heads/main\n")
write(T .. "/b/repo/.git/worktrees/wt/commondir", "../..\n")
on("x", "main")
check("a worktree reads its own branch and the repo's default", name(T .. "/wt"), "wt")
for _, c in ipairs({
  { "a long branch keeps its issue key",            "bugfix-asa-cpanel-uapi-mc-13675", "MC-13675" },
  { "an issue key after a slash",                   "feature/MC-13200-oauth-scopes",  "MC-13200" },
  { "utf-8 is not an issue key",                    "fix-utf-8-decoding-everywhere",  "fix-utf-8" },
  { "a long branch keeps the part after a slash",   "feature/oauth-scopes-and-more",  "oauth-scopes" },
  { "a long branch is cut at a word",               "fix-login-page-styles",          "fix-login" },
  { "a lone first word reads as a namespace",       "improve-login-performance",      "login" },
}) do
  check("branch: " .. c[1], name(on(c[2], "main")), "repo - " .. c[3])
end
check("home folder with nothing to say: Rex's default", name(M.HOME), "")
check("home folder with a topic: just the topic", name(M.HOME, "fix"), "fix")
check("the root folder says nothing", name("/"), "")
check("no terminal: Rex's default", M.name_for(nil, nil), "")

local long = repo(T .. "/a-really-long-directory-name-for-this", "ref: refs/heads/MC-1234", "main")
check("too long: the folder is shortened first",
  name(long, "fix login"), "a-really-long-direc… - MC-1234 - fix login")
check("too long: then the branch is dropped",
  name(long, "fix the login page now"), "a-really-long-direc… - fix the login page now")
check("too long: the topic is cut last", name(T .. "/b", string.rep("x", 60)), "b - " .. string.rep("x", 45) .. "…")
check("too long: CJK counts as two columns", name(T .. "/b", string.rep("中", 40)), "b - " .. string.rep("中", 22) .. "…")
check("too long: emoji count as two columns", name(T .. "/b", string.rep("🚀", 40)), "b - " .. string.rep("🚀", 22) .. "…")

---------------------------------------------------------------------------
-- What a conversation is about: cleaning its text for a tab

for _, c in ipairs({
  { "its first line",                       "fix login\nmore detail",                      "fix login" },
  { "blank lines skipped",                  "\n\n  fix it  \n",                             "fix it" },
  { "absolute paths dropped",               "/tmp/handoff.md 明确一下要做的测评",           "明确一下要做的测评" },
  { "URLs dropped",                         "https://github.com/x/y 评估下怎么启动",        "评估下怎么启动" },
  { "home paths dropped",                   "read ~/notes/a.md now",                        "read now" },
  { "relative paths kept",                  "fix src/auth.ts",                              "fix src/auth.ts" },
  { "a lone path becomes its file",         "/tmp/cvm-bench-swebench-handoff.md",           "cvm-bench-swebench-handoff.md" },
  { "a lone URL becomes its last part",     "https://github.com/kvcache-ai/AgentENV",       "AgentENV" },
  { "repeated separators folded",           "a - - - b",                                    "a - b" },
  { "dangling separators trimmed",          "- fix -",                                      "fix" },
  { "markup blocks dropped",                "<system-reminder>ignore</system-reminder>real question", "real question" },
  { "a slash command and its arguments",    "<command-name>/review</command-name><command-args>spec.md\nmore</command-args>", "review spec.md" },
  { "a slash command alone",                "<command-name>/clear</command-name><command-args></command-args>", "clear" },
  { "terminal escapes stripped",            "\27[31mred\27[0m \27]0;title\7ok",             "red ok" },
  { "controls and odd spaces folded",       "a\tb c\194\160d",                              "a b c d" },
  { "invisible marks removed",              "a\226\128\139b\226\128\174c\239\187\191",      "abc" },
}) do
  check("topic: " .. c[1], M.topic(c[2]), c[3])
end

---------------------------------------------------------------------------
-- What each agent's conversation is called, read from its own files

local claude = T .. "/claude.jsonl"
write(claude, json({ type = "user", origin = { kind = "task-notification" }, message = { content = "not this" } })
  .. json({ type = "user", origin = { kind = "human" }, message = { content = {
       { type = "text", text = "<system-reminder>x</system-reminder>探究推理强度\nmore" } } } }))
check("claude: the first prompt a person typed", M.claude_topic(claude), "探究推理强度")
append(claude, json({ type = "ai-title", aiTitle = "推理强度评测" }))
check("claude: its generated title beats the prompt", M.claude_topic(claude), "推理强度评测")
append(claude, json({ type = "custom-title", customTitle = "my name" }) .. json({ type = "ai-title", aiTitle = "later ai" }))
check("claude: /rename beats a generated title, even a later one", M.claude_topic(claude), "my name")
append(claude, '{"type":"user","origin":{"kind":"human"},"message":{"content":"half')
check("claude: a half-written line is waited for", M.claude_topic(claude), "my name")
write(claude, json({ type = "ai-title", aiTitle = "rewritten" }))
check("claude: a file that was rewritten is read again", M.claude_topic(claude), "rewritten")
check("claude: no file, no topic", M.claude_topic(T .. "/none.jsonl"), nil)

local pi = T .. "/pi.jsonl"
write(pi, json({ type = "session", cwd = "/w" })
  .. json({ type = "message", message = { role = "user", content = { { type = "text", text = "全局 skill 可以禁用吗" } } } })
  .. json({ type = "message", message = { role = "user", content = "second" } }))
check("pi: the first prompt", M.pi_topic(pi), "全局 skill 可以禁用吗")
append(pi, json({ type = "session_info", name = "清理 skill" }))
check("pi: /name beats the prompt", M.pi_topic(pi), "清理 skill")
append(pi, json({ type = "session_info", name = "" }))
check("pi: an empty /name clears it", M.pi_topic(pi), "全局 skill 可以禁用吗")

local rollout = T .. "/rollout.jsonl"
write(rollout, json({ type = "event_msg", payload = { type = "item_completed", item = { type = "UserMessage",
  content = { { type = "text", text = "看看评测顺序" } } } } }))
check("codex: the first prompt from a rollout", M.follow(rollout, M.codex_absorb).opening, "看看评测顺序")
local rollout_old = T .. "/rollout-old.jsonl"
write(rollout_old, json({ type = "event_msg", payload = { type = "user_message", message = "old style prompt" } }))
check("codex: the first prompt from an older rollout", M.follow(rollout_old, M.codex_absorb).opening, "old style prompt")

---------------------------------------------------------------------------
-- Which agent a tab runs, and the conversation its command line names

local function agent(name, cmdline, argv0)
  local d = M.describe({ foreground = { pid = 1, name = name, argv0 = argv0, cwd = "/w" } },
    { [1] = cmdline and { age = 9, args = cmdline } or nil })
  return d and { d.app, d.id }
end
for _, c in ipairs({
  { "codex by name",                     "codex",  "codex --yolo",                                  nil,  { "codex" } },
  { "claude by name",                    "claude", "claude",                                        nil,  { "claude" } },
  { "pi, running as node with argv0 pi", "node",   nil,                                             "pi", { "pi" } },
  { "claude under node",                 "node",   "node /usr/lib/node_modules/@anthropic-ai/claude-code/cli.js", nil, { "claude" } },
  { "codex under node",                  "node",   "node /opt/lib/node_modules/@openai/codex/bin/codex.js", nil, { "codex" } },
  { "pi under node by path",             "node",   "node /x/pi-coding-agent/dist/cli.js",           nil,  { "pi" } },
  { "another node program",              "node",   "node server.js",                                nil,  {} },
  { "a shell",                           "zsh",    "-zsh",                                          nil,  {} },
  { "codex resume ID",                   "codex",  "codex resume " .. ID,                           nil,  { "codex", ID } },
  { "codex resume picker has no ID",     "codex",  "codex --yolo resume",                           nil,  { "codex" } },
  { "claude --resume ID",                "claude", "claude --resume " .. ID,                        nil,  { "claude", ID } },
  { "claude --session-id=ID",            "claude", "claude --session-id=" .. ID,                    nil,  { "claude", ID } },
  { "pi --session ID",                   "pi",     "pi --session 01a1e244",                         nil,  { "pi", "01a1e244" } },
  { "pi --session=PATH",                 "pi",     "pi --session=/a/b.jsonl",                       nil,  { "pi", "/a/b.jsonl" } },
}) do
  check("agent: " .. c[1], agent(c[2], c[3], c[4]), c[5])
end
check("agent: a login shell is skipped for the program under it",
  M.describe({ foreground = { pid = 3, name = "claude", cwd = "/w" },
               ancestors = { { pid = 1, name = "login" } } }, { [3] = { age = 9, args = "claude" } }).app, "claude")
check("agent: age comes from ps elapsed time",
  M.describe({ foreground = { pid = 3, name = "codex", cwd = "/w" } },
             M.parse_ps(" 3 1-02:03:04 codex\n")).age, 93784)
check("agent: no process, nothing to describe", M.describe({}, {}), nil)

rex.exec({ "rm", "-rf", T })
print(string.format("%d passed, %d failed", passed, failed))
if failed > 0 then rex.stop(1) end
