-- rex-auto-title: name each Rex tab after what it is doing.
--
--   rex do auto_title.lua --all                 watch every session and rename tabs
--   rex do auto_title.lua --all mode=once       rename once and exit
--   rex do auto_title.lua --all mode=dry_run    print what each tab would be named
--
-- A tab is named "<directory> - <branch> - <conversation>": the folder its
-- focused pane is in, the git branch when it is not the default one, and the
-- name of the Codex, Claude Code, or pi conversation running there. A tab you
-- rename yourself is left alone; clear its name to hand it back.

local M = {}
M.VERSION = "0.1.0"

local TERMINAL = "com.superlogical.terminal"
M.MAX_WIDTH = 50   -- columns a whole name may take
M.DIR_MAX = 20     -- columns the directory keeps when a name is too long
M.BRANCH_MAX = 12  -- columns a branch keeps before it is shortened
local CONVENTIONAL_TRUNKS = { main = true, master = true, trunk = true }
local UUID = "%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x"

local args = (rex and rex.args) or {}
local HOME = os.getenv("HOME") or ""
M.HOME = HOME

local function list(t) return type(t) == "table" and t or {} end

local function basename(path)
  return tostring(path or ""):match("([^/]+)/*$") or ""
end

local function trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

local function lines(text)
  local out = {}
  for line in (text or ""):gmatch("[^\n]+") do out[#out + 1] = line end
  return out
end

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  return data
end

local function stdout_of(argv)
  local r = rex.exec(argv)
  return r and r.stdout or ""
end

local function decode(text)
  local ok, value = pcall(rex.json.decode, text)
  if ok then return value end
end

local function log(message)
  if args.quiet ~= true then print(os.date("%Y-%m-%d %H:%M:%S") .. " " .. message) end
end

local function cp_width(cp)
  if (cp >= 0x1100 and cp <= 0x115F) or (cp >= 0x2E80 and cp <= 0xA4CF)
    or (cp >= 0xAC00 and cp <= 0xD7A3) or (cp >= 0xF900 and cp <= 0xFAFF)
    or (cp >= 0xFE30 and cp <= 0xFE4F) or (cp >= 0xFF00 and cp <= 0xFF60)
    or (cp >= 0xFFE0 and cp <= 0xFFE6) or (cp >= 0x1F300 and cp <= 0x1FAFF)
    or (cp >= 0x20000 and cp <= 0x3FFFD) then
    return 2
  end
  if cp == 0x200D then return 0 end
  return 1
end

local function chars(s)
  local out = {}
  for ch in tostring(s or ""):gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    local b1, b2, b3, b4 = ch:byte(1, 4)
    local cp
    if b1 < 0x80 then cp = b1
    elseif b1 < 0xE0 then cp = (b1 % 0x20) * 0x40 + (b2 or 0) % 0x40
    elseif b1 < 0xF0 then cp = ((b1 % 0x10) * 0x40 + (b2 or 0) % 0x40) * 0x40 + (b3 or 0) % 0x40
    else cp = (((b1 % 0x08) * 0x40 + (b2 or 0) % 0x40) * 0x40 + (b3 or 0) % 0x40) * 0x40 + (b4 or 0) % 0x40 end
    out[#out + 1] = { ch, cp_width(cp) }
  end
  return out
end

function M.width(s)
  local w = 0
  for _, c in ipairs(chars(s)) do w = w + c[2] end
  return w
end

local function cut(s, max)
  if M.width(s) <= max then return s end
  if max <= 0 then return "" end
  local out, w = {}, 0
  for _, c in ipairs(chars(s)) do
    if w + c[2] > max - 1 then break end
    out[#out + 1] = c[1]
    w = w + c[2]
  end
  return (trim(table.concat(out)):gsub("[%s%-_/.]+$", "")) .. "…"
end

local function sanitize(s)
  s = tostring(s or "")
  s = s:gsub("\27%][^\7\27]*\7", ""):gsub("\27%][^\27]*\27\\", "")
  s = s:gsub("\27%[[%d;?]*[%a@~\96]", ""):gsub("\27.", "")
  -- Zero-width, direction marks and overrides, isolates, and the BOM. The
  -- zero-width joiner stays: emoji are built from it.
  s = s:gsub("\226\128[\139\140\142\143\170-\174]", ""):gsub("\226\129[\166-\169]", "")
  s = s:gsub("\239\187\191", "")
  s = s:gsub("[%z\1-\31\127]", " ")
  s = s:gsub("\194\160", " "):gsub("\227\128\128", " ")
  s = s:gsub("%s+", " ")
  return trim(s)
end

local function is_location(word)
  return word:match("^/.") or word:match("^~/") or word:match("^%a[%w+.-]*://") ~= nil
end

-- Absolute paths and URLs are dropped: they eat the width and the folder is
-- already in the name.
function M.topic(s)
  s = tostring(s or "")
  -- Claude Code wraps a slash command in markup; its name and arguments say
  -- what was run.
  local command = s:match("<command%-name>%s*/?([^<%s]+)%s*</command%-name>")
  if command then
    local cargs = s:match("<command%-args>(.-)</command%-args>")
    cargs = cargs and trim((cargs:match("^%s*([^\n]*)")))
    return sanitize(command .. ((cargs and cargs ~= "") and (" " .. cargs) or ""))
  end
  s = s:gsub("<([%a][%w%-]*)[^>]*>.-</%1>", " ")
  local first = ""
  for line in s:gmatch("[^\r\n]+") do
    if trim(line) ~= "" then first = line break end
  end
  first = sanitize(first)
  local words, path = {}, nil
  for word in first:gmatch("%S+") do
    if is_location(word) then
      path = path or word
    else
      words[#words + 1] = word
    end
  end
  local out = table.concat(words, " ")
  out = out:gsub("^[%s%-:,;]+", ""):gsub("[%s%-:,;]+$", "")
  if out == "" and path then
    out = basename((path:gsub("[%?#].*$", "")))
  end
  -- " - " separates the parts of a name, so a topic keeps at most one in a row.
  local before
  repeat
    before = out
    out = out:gsub(" %- %- ", " - ")
  until out == before
  return out
end

-- The topic tells tabs apart best, so the directory is shortened first, then
-- the branch dropped, and only then the topic cut.
local function compose(dir, branch, topic)
  local max = M.MAX_WIDTH
  local function join(d, b, t)
    local parts = {}
    for _, p in ipairs({ d or "", b or "", t or "" }) do
      if p ~= "" then parts[#parts + 1] = p end
    end
    return table.concat(parts, " - ")
  end
  local name = join(dir, branch, topic)
  if M.width(name) <= max then return name end
  local short_dir = dir and cut(dir, M.DIR_MAX)
  name = join(short_dir, branch, topic)
  if M.width(name) <= max then return name end
  if topic and topic ~= "" then
    name = join(short_dir, nil, topic)
    if M.width(name) <= max then return name end
  end
  return cut(name, max)
end

local function resolve(base, path)
  if path:sub(1, 1) == "/" then return path end
  return base .. "/" .. path
end

local function git(dir)
  dir = tostring(dir or ""):gsub("/+$", "")
  while dir ~= "" do
    local gitdir
    local head = read_file(dir .. "/.git/HEAD")
    if head then
      gitdir = dir .. "/.git"
    else
      local link = read_file(dir .. "/.git")
      local target = link and link:match("^gitdir:%s*(.-)%s*$")
      if target then
        gitdir = resolve(dir, target)
        head = read_file(gitdir .. "/HEAD")
      end
    end
    if gitdir and head then
      local common = trim(read_file(gitdir .. "/commondir") or "")
      common = common ~= "" and resolve(gitdir, common) or gitdir
      local info = { root = dir, common = common }
      local ref = head:match("^ref:%s*refs/heads/(.-)%s*$")
      if ref then
        info.branch = ref
      else
        local hash = head:match("^(%x+)")
        if hash then info.detached = hash:sub(1, 7) end
      end
      local origin = read_file(common .. "/refs/remotes/origin/HEAD")
      info.default = origin and origin:match("refs/remotes/origin/(.-)%s*$") or nil
      return info
    end
    dir = dir:match("^(.*)/[^/]*$") or ""
  end
end

local SEPS = "[%-_./ ]"

local function cut_at_separator(value, max)
  if M.width(value) <= max then return value end
  local head, w = {}, 0
  for _, c in ipairs(chars(value)) do
    if w + c[2] > max then break end
    head[#head + 1] = c[1]
    w = w + c[2]
  end
  local s = table.concat(head)
  local next_char = value:sub(#s + 1, #s + 1)
  if not next_char:match(SEPS) then
    local at = s:match("^.*()" .. SEPS)
    if at and at > 1 then s = s:sub(1, at - 1) end
  end
  return (s:gsub("^" .. SEPS .. "+", ""):gsub(SEPS .. "+$", ""))
end

-- A long branch keeps what identifies it: an issue key such as MC-13675, or
-- the part after the last slash, cut at a word.
local function shorten_branch(branch)
  local max = M.BRANCH_MAX
  branch = tostring(branch or ""):gsub("^" .. SEPS .. "+", ""):gsub(SEPS .. "+$", "")
  if branch == "" then return "" end
  if M.width(branch) <= max then return branch end
  local from = 1
  while true do
    local s, e, letters, digits = branch:find("(%a+)%-(%d+)", from)
    if not s then break end
    local before = s > 1 and branch:sub(s - 1, s - 1) or ""
    local after = branch:sub(e + 1, e + 1)
    -- Two to six letters and two to six digits, standing as a word.
    if #letters >= 2 and #letters <= 6 and #digits >= 2 and #digits <= 6
      and not before:match("%a") and not after:match("%w") then
      return (letters .. "-" .. digits):upper()
    end
    from = e + 1
  end
  local last = branch:match("/([^/]+)$")
  if last then return cut_at_separator(last, max) end
  local short = cut_at_separator(branch, max)
  local first = branch:match("^([^%-_./ ]+)" .. SEPS)
  if first and short == first then
    return cut_at_separator((branch:sub(#first + 1):gsub("^" .. SEPS .. "+", "")), max)
  end
  return short
end

-- The default branch, a conventional trunk, and a branch named like the
-- directory add nothing to a name.
local function branch_label(info, dir_name)
  if not info then return nil end
  if info.detached then return info.detached end
  local branch = info.branch
  if not branch or branch == "" then return nil end
  if info.default and branch == info.default then return nil end
  if not info.default and CONVENTIONAL_TRUNKS[branch] then return nil end
  if dir_name and branch == dir_name then return nil end
  local short = shorten_branch(branch)
  if short == "" then return nil end
  return short
end

local function parse_etime(text)
  text = text or ""
  local days, rest = text:match("^(%d+)%-(.+)$")
  if not days then days, rest = "0", text end
  local seconds = 0
  for n in rest:gmatch("%d+") do seconds = seconds * 60 + tonumber(n) end
  return tonumber(days) * 86400 + seconds
end

function M.parse_ps(text)
  local out = {}
  for _, line in ipairs(lines(text)) do
    local pid, etime, command = line:match("^%s*(%d+)%s+(%S+)%s*(.*)$")
    if pid then out[tonumber(pid)] = { age = parse_etime(etime), args = command } end
  end
  return out
end

local function split_words(text)
  local out = {}
  for word in (text or ""):gmatch("%S+") do out[#out + 1] = word end
  return out
end

-- Claude Code and pi can run under node, so the command line is read too.
local function agent_of(name, argv)
  argv = list(argv)
  local exe = basename(argv[1])
  name = basename(name)
  for _, app in ipairs({ "codex", "claude", "pi" }) do
    if name == app or exe == app then return app end
  end
  if name == "node" or exe:match("^node") then
    for i = 2, math.min(#argv, 3) do
      local a = argv[i] or ""
      if basename(a) == "claude" or a:find("claude-code", 1, true) then return "claude" end
      if basename(a) == "codex" or a:find("/@openai/codex/", 1, true) then return "codex" end
      if basename(a) == "pi" or a:find("pi-coding-agent", 1, true) then return "pi" end
    end
  end
end

local function chain_of(proc)
  local out, seen, candidates = {}, {}, {}
  if type(proc) ~= "table" then return out end
  if proc.foreground then candidates[#candidates + 1] = proc.foreground end
  for _, p in ipairs(list(proc.ancestors)) do candidates[#candidates + 1] = p end
  for _, p in ipairs(candidates) do
    if p.pid and not seen[p.pid] and p.name ~= "login" then
      seen[p.pid] = true
      out[#out + 1] = p
    end
  end
  return out
end

-- A conversation named on the command line: "codex resume <id>",
-- "claude --resume <id>", "pi --session <id|path>".
local function argv_session(app, argv)
  argv = list(argv)
  for i = 1, #argv do
    local a, b = argv[i], argv[i + 1]
    if app == "codex" and a == "resume" and b and b:match("^" .. UUID .. "$") then return b end
    if app == "claude" then
      if (a == "--resume" or a == "-r" or a == "--session-id") and b and b:match("^" .. UUID .. "$") then
        return b
      end
      local id = a:match("^%-%-resume=(" .. UUID .. ")$") or a:match("^%-%-session%-id=(" .. UUID .. ")$")
      if id then return id end
    end
    if app == "pi" then
      if (a == "--session" or a == "--session-id") and b and not b:match("^%-") then return b end
      local v = a:match("^%-%-session=(.+)$") or a:match("^%-%-session%-id=(.+)$")
      if v then return v end
    end
  end
end

-- Session files only grow, so each one is followed: a poll reads the lines
-- written since the last, and a file that shrank is read again from the start.
local followed = {}

local function follow(path, absorb)
  local f = io.open(path, "rb")
  if not f then followed[path] = nil return nil end
  local size = f:seek("end")
  local st = followed[path]
  if not st or size < st.offset then
    st = { offset = 0, rest = "", state = {} }
    followed[path] = st
  end
  if size > st.offset then
    f:seek("set", st.offset)
    local data = st.rest .. (f:read(size - st.offset) or "")
    st.offset = size
    local last = 1
    for line, after in data:gmatch("([^\n]*)\n()") do
      absorb(st.state, line)
      last = after
    end
    st.rest = data:sub(last)
  end
  f:close()
  return st.state
end
M.follow = follow

local function content_text(content)
  if type(content) == "string" then return content end
  local out = {}
  for _, part in ipairs(list(content)) do
    if type(part) == "table" and type(part.text) == "string"
      and (part.type == nil or part.type == "text" or part.type == "input_text") then
      out[#out + 1] = part.text
    end
  end
  return table.concat(out, "\n")
end

-- A name the user gave (/rename, custom-title) beats one Claude generated (ai-title).
local function claude_absorb(st, line)
  if line:find('"custom-title"', 1, true) then
    local e = decode(line)
    if e and e.type == "custom-title" and e.customTitle and e.customTitle ~= "" then st.custom = e.customTitle end
  elseif line:find('"ai-title"', 1, true) then
    local e = decode(line)
    if e and e.type == "ai-title" and e.aiTitle and e.aiTitle ~= "" then st.ai = e.aiTitle end
  elseif not st.opening and line:find('"human"', 1, true) then
    local e = decode(line)
    if e and e.type == "user" and type(e.origin) == "table" and e.origin.kind == "human" then
      local text = M.topic(content_text(e.message and e.message.content))
      if text ~= "" then st.opening = text end
    end
  end
end

-- /name can be run again, and an empty name clears it, so the last one wins.
local function pi_absorb(st, line)
  if line:find('"session_info"', 1, true) then
    local e = decode(line)
    if e and e.type == "session_info" then st.name = trim(e.name) end
  elseif not st.opening and line:find('"user"', 1, true) then
    local e = decode(line)
    if e and e.type == "message" and type(e.message) == "table" and e.message.role == "user" then
      local text = M.topic(content_text(e.message.content))
      if text ~= "" then st.opening = text end
    end
  end
end

-- Codex 0.149 moved the prompt from user_message to a UserMessage item.
function M.codex_absorb(st, line)
  if st.opening then return end
  if line:find('"user_message"', 1, true) or line:find('"UserMessage"', 1, true) then
    local e = decode(line)
    local p = e and e.type == "event_msg" and e.payload
    if type(p) == "table" then
      local text
      if p.type == "user_message" then text = p.message
      elseif p.type == "item_completed" and type(p.item) == "table" and p.item.type == "UserMessage" then
        text = content_text(p.item.content)
      end
      text = text and M.topic(text)
      if text and text ~= "" then st.opening = text end
    end
  end
end

function M.claude_topic(path)
  local st = follow(path, claude_absorb)
  if not st then return nil end
  return st.custom or st.ai or st.opening
end

function M.pi_topic(path)
  local st = follow(path, pi_absorb)
  if not st then return nil end
  if st.name and st.name ~= "" then return st.name end
  return st.opening
end

local function claude_slug(cwd) return (tostring(cwd or ""):gsub("[^%w]", "-")) end
local function pi_slug(cwd)
  local path = tostring(cwd or ""):gsub("^[/\\]", ""):gsub("[/\\:]", "-")
  return "--" .. path .. "--"
end

local function list_dir(dir, suffix)
  local out = {}
  local r = rex.exec({ "ls", "-1", dir })
  if not (r and r.ok) then return out end
  for _, name in ipairs(lines(r.stdout)) do
    if not suffix or name:sub(-#suffix) == suffix then out[#out + 1] = dir .. "/" .. name end
  end
  return out
end

local OS

local function mtimes(paths)
  local out = {}
  if #paths == 0 then return out end
  local argv = { "stat", "-f", "%m %N" }
  if OS ~= "Darwin" then argv = { "stat", "-c", "%Y %n" } end
  for _, p in ipairs(paths) do argv[#argv + 1] = p end
  for _, line in ipairs(lines(stdout_of(argv))) do
    local t, path = line:match("^(%d+) (.+)$")
    if t then out[path] = tonumber(t) end
  end
  return out
end

local function file_candidates(dir)
  local out = {}
  for path, t in pairs(mtimes(list_dir(dir, ".jsonl"))) do out[#out + 1] = { key = path, t = t } end
  return out
end

local function codex_homes()
  local homes, seen = {}, {}
  for _, h in ipairs({ os.getenv("CODEX_HOME") or "", HOME .. "/.codex", HOME .. "/.codex-internal" }) do
    if h ~= "" and not seen[h] then
      seen[h] = true
      homes[#homes + 1] = h
    end
  end
  return homes
end

local function sql_quote(s) return "'" .. tostring(s):gsub("'", "''") .. "'" end

local function codex_query(where, limit)
  local rows = {}
  for _, home in ipairs(codex_homes()) do
    for _, db in ipairs(list_dir(home, ".sqlite")) do
      if basename(db):match("^state_%d+%.sqlite$") then
        local r = rex.exec({ "sqlite3", "-readonly", "-json", db,
          "select id, name, title, first_user_message, cwd, rollout_path, updated_at_ms " ..
          "from threads where " .. where .. " order by updated_at_ms desc limit " .. (limit or 1) },
          { timeout = 5 })
        for _, row in ipairs(list(r and r.ok and decode(r.stdout))) do rows[#rows + 1] = row end
      end
    end
  end
  table.sort(rows, function(a, b) return (a.updated_at_ms or 0) > (b.updated_at_ms or 0) end)
  return rows
end

-- Older Codex keeps /rename names only in session_index.jsonl.
local function codex_index_name(id)
  for _, home in ipairs(codex_homes()) do
    local st = follow(home .. "/session_index.jsonl", function(names, line)
      local e = decode(line)
      if e and e.id then names[e.id] = trim(e.thread_name) end
    end)
    if st and st[id] and st[id] ~= "" then return st[id] end
  end
end

local function codex_topic(id)
  local row = codex_query("id = " .. sql_quote(id))[1]
  local name = (row and trim(row.name)) or ""
  if name == "" then name = codex_index_name(id) or "" end
  if name ~= "" then return name end
  if not row then return nil end
  if trim(row.first_user_message) ~= "" then return row.first_user_message end
  if row.rollout_path and row.rollout_path ~= "" then
    local st = follow(row.rollout_path, M.codex_absorb)
    if st and st.opening then return st.opening end
  end
  if trim(row.title) ~= "" then return row.title end
end

-- Keys are Codex thread IDs and Claude or pi file paths.
local function candidates(app, cwd, since)
  local out = {}
  if app == "claude" then
    out = file_candidates(HOME .. "/.claude/projects/" .. claude_slug(cwd))
  elseif app == "pi" then
    out = file_candidates(HOME .. "/.pi/agent/sessions/" .. pi_slug(cwd))
  elseif app == "codex" then
    -- Subagents record their parent in source; the user's own threads don't.
    for _, row in ipairs(codex_query("cwd = " .. sql_quote(cwd) ..
        " and archived = 0 and source not like '{%' and updated_at_ms >= " ..
        string.format("%d", since * 1000), 20)) do
      out[#out + 1] = { key = row.id, t = math.floor((row.updated_at_ms or 0) / 1000) }
    end
  end
  local kept = {}
  for _, c in ipairs(out) do
    if c.t >= since then kept[#kept + 1] = c end
  end
  table.sort(kept, function(a, b)
    if a.t ~= b.t then return a.t > b.t end
    return a.key > b.key
  end)
  return kept
end

local function named_conversation(pane)
  if not pane.id then return nil end
  if pane.app == "codex" then return pane.id end
  if pane.app == "claude" then
    return HOME .. "/.claude/projects/" .. claude_slug(pane.cwd) .. "/" .. pane.id .. ".jsonl"
  end
  if pane.app == "pi" then
    if pane.id:find("/", 1, true) then return pane.id end
    for _, path in ipairs(list_dir(HOME .. "/.pi/agent/sessions/" .. pi_slug(pane.cwd), ".jsonl")) do
      local file_id = path:match("_([^_/]+)%.jsonl$")
      if file_id and file_id:sub(1, #pane.id) == pane.id then return path end
    end
  end
end

local function conversation_topic(app, key)
  if app == "codex" then return codex_topic(key) end
  if app == "claude" then return M.claude_topic(key) end
  if app == "pi" then return M.pi_topic(key) end
end

function M.default_label(window_id)
  return "Window " .. tostring(window_id or ""):sub(-8)
end

function M.describe(proc, ps)
  local chain = chain_of(proc)
  if #chain == 0 then return nil end
  for _, p in ipairs(chain) do
    local info = ps[p.pid] or {}
    local argv = split_words(info.args)
    if #argv == 0 and p.argv0 then argv = { p.argv0 } end
    -- pi runs as node; only argv0 says it is pi.
    local app = agent_of(p.name, argv) or agent_of(p.argv0, argv)
    if app then
      if not p.cwd then return nil end
      return { app = app, pid = p.pid, cwd = p.cwd, age = info.age or 0, id = argv_session(app, argv) }
    end
  end
  local cwd = chain[1].cwd or chain[#chain].cwd
  return cwd and { cwd = cwd } or nil
end

-- Home and the root say nothing about the work.
local function dir_label(cwd)
  if not cwd or cwd == "" then return nil end
  cwd = cwd:gsub("/+$", "")
  if cwd == "" or cwd == HOME then return nil end
  return basename(cwd)
end

function M.name_for(pane, topic)
  if not pane then return "" end
  local dir = dir_label(pane.cwd)
  if not dir and not topic then return "" end
  local branch = dir and branch_label(git(pane.cwd), dir) or nil
  return compose(dir, branch, topic)
end

-- What to do with a tab's label. current is its label now, default the one
-- Rex gives an unnamed tab, owned the label this tool last set on it, and
-- desired the name it should carry ("" for Rex's default).
--
--   manual  the label is someone else's: leave it, and forget it was ours
--   keep    the label is already right
--   set     rename the tab to desired
--   reset   clear the label so Rex shows its default
function M.decide(current, default, owned, desired)
  local ours = current == default or (owned ~= nil and current == owned)
  if not ours and current ~= desired then return "manual" end
  if desired == "" then
    if current == default then return "keep" end
    return "reset"
  end
  if current == desired then return "keep" end
  return "set"
end

local STATE_DIR = args.state_dir or (HOME .. "/Library/Application Support/rex-auto-title")
local STATE_FILE = STATE_DIR .. "/state.json"

local state

-- owned survives restarts so a label this tool set isn't taken for the user's.
local function load_state()
  if state then return state end
  local text = read_file(STATE_FILE)
  local st = text and decode(text)
  st = type(st) == "table" and st or {}
  state = { owned = type(st.owned) == "table" and st.owned or {},
            bound = type(st.bound) == "table" and st.bound or {},
            retired = type(st.retired) == "table" and st.retired or {} }
  return state
end

local function save_state()
  rex.exec({ "mkdir", "-p", STATE_DIR })
  local snapshot = { version = M.VERSION, owned = state.owned, bound = state.bound, retired = state.retired }
  local text = rex.json.encode(snapshot, { indent = true }) .. "\n"
  if text ~= state.saved then
    -- Write then rename, so a crash never leaves half a file that reads as no state.
    local f = io.open(STATE_FILE .. ".tmp", "wb")
    if not f then return end
    f:write(text)
    f:close()
    os.rename(STATE_FILE .. ".tmp", STATE_FILE)
    state.saved = text
  end
end

local function collect()
  local listing = rex.call("session.list") or {}
  local tabs, pids = {}, {}
  for _, s in ipairs(list(listing.sessions)) do
    rex.session.attach{ session_id = s.session_id }
    local view = rex.session.view{ session_id = s.session_id }
    for _, w in ipairs(list(view and view.windows)) do
      local focused = w.focused_block_id
      local is_terminal = false
      for _, layer in ipairs(list(w.layers)) do
        for _, b in ipairs(list(layer.blocks)) do
          if b.block_id == focused and b.creator_name == TERMINAL then is_terminal = true end
        end
      end
      local tab = { session_id = s.session_id, session = s.label, window_id = w.window_id,
                    label = w.label, block_id = focused }
      if is_terminal then
        tab.proc = rex.block.call(TERMINAL, "process", { session_id = s.session_id, block_id = focused })
        for _, p in ipairs(chain_of(tab.proc)) do pids[#pids + 1] = p.pid end
      end
      tabs[#tabs + 1] = tab
    end
  end
  local ps = {}
  if #pids > 0 then
    ps = M.parse_ps(stdout_of({ "ps", "-o", "pid=,etime=,args=", "-p", table.concat(pids, ",") }))
  end
  return tabs, ps
end

-- How an agent tab came by its conversation (pane.via):
--   named      its command line names one (codex resume ID, claude --resume, pi --session)
--   kept       the one bound earlier to this tab's process
--   started    the only unbound chat of its agent in the folder: the newest
--              free conversation written since it started
--   switched   the only chat of its agent in the folder, moved to a newer
--              free conversation: /new or /clear
--   ambiguous  several unbound chats of one agent in one folder; no guess
--   waiting    nothing written yet
-- A conversation whose tab closed or whose process changed is retired, so a
-- later chat in that folder doesn't take its name.
M.SOURCES = { candidates = candidates, named = named_conversation, topic = conversation_topic }
M.MAX_RETIRED = 200
-- ps reports age in whole seconds and file times are whole seconds too.
local SLACK = 5

function M.plan(tabs, ps, now, state, sources)
  sources = sources or M.SOURCES
  state.bound = state.bound or {}
  state.retired = state.retired or {}
  local retired = {}
  for _, key in ipairs(state.retired) do retired[key] = true end
  local function retire(key)
    if not retired[key] then
      retired[key] = true
      table.insert(state.retired, key)
      while #state.retired > M.MAX_RETIRED do retired[table.remove(state.retired, 1)] = nil end
    end
  end
  local function release(block_id)
    retire(state.bound[block_id].key)
    state.bound[block_id] = nil
  end

  -- A tab whose process couldn't be read this pass keeps its binding: the
  -- lookup fails now and then, and retiring on a miss loses the conversation.
  local groups, open = {}, {}
  for _, tab in ipairs(tabs) do
    open[tab.block_id] = true
    tab.pane = tab.proc and M.describe(tab.proc, ps) or nil
    local p = tab.pane
    local b = state.bound[tab.block_id]
    if b and p and not (b.pid == p.pid and b.app == p.app) then release(tab.block_id) b = nil end
    if p and p.app then
      p.start = now - p.age
      if b then p.key, p.via = b.key, "kept" end
      local named = sources.named(p)
      if named then p.key, p.via = named, "named" end
      local gk = p.app .. "\0" .. tostring(p.cwd)
      groups[gk] = groups[gk] or { app = p.app, cwd = p.cwd, panes = {} }
      table.insert(groups[gk].panes, { block_id = tab.block_id, pane = p })
    end
  end
  for block_id in pairs(state.bound) do
    if not open[block_id] then release(block_id) end
  end

  for _, g in pairs(groups) do
    local claimed, unbound, oldest = {}, {}, now
    for _, e in ipairs(g.panes) do
      if e.pane.key then claimed[e.pane.key] = true else unbound[#unbound + 1] = e.pane end
      oldest = math.min(oldest, e.pane.start)
    end
    local all, free = sources.candidates(g.app, g.cwd, oldest - SLACK), {}
    for _, c in ipairs(all) do
      if not claimed[c.key] and not retired[c.key] then free[#free + 1] = c end
    end
    if #unbound == 1 then
      local p = unbound[1]
      p.via = "waiting"
      for _, c in ipairs(free) do
        if c.t >= p.start - SLACK then p.key, p.via = c.key, "started" break end
      end
    elseif #unbound > 1 then
      for _, p in ipairs(unbound) do p.via = "ambiguous" end
    elseif #g.panes == 1 and g.panes[1].pane.via == "kept" and free[1] then
      local p, held = g.panes[1].pane, nil
      for _, c in ipairs(all) do
        if c.key == p.key then held = c.t end
      end
      if not held or free[1].t > held then
        retire(p.key)
        p.key, p.via = free[1].key, "switched"
      end
    end
    for _, e in ipairs(g.panes) do
      local p = e.pane
      if p.key then state.bound[e.block_id] = { pid = p.pid, app = p.app, key = p.key } end
    end
  end

  for _, tab in ipairs(tabs) do
    local p = tab.pane
    if p then
      local topic = p.key and M.topic(sources.topic(p.app, p.key) or "")
      tab.desired = M.name_for(p, topic ~= "" and topic or nil)
    end
  end
  return tabs
end

function M.pass(apply)
  local st = load_state()
  local owned = st.owned
  local tabs, ps = collect()
  M.plan(tabs, ps, os.time(), st)
  local live = {}
  for _, tab in ipairs(tabs) do
    live[tab.window_id] = true
    if tab.desired then
      local default = M.default_label(tab.window_id)
      local action = M.decide(tab.label, default, owned[tab.window_id], tab.desired)
      tab.action = action
      if action == "manual" then
        owned[tab.window_id] = nil
      elseif apply and (action == "set" or action == "reset") then
        local label = action == "set" and tab.desired or ""
        local ok, err = rex.session.set_window_label{ session_id = tab.session_id,
                                                      window_id = tab.window_id, label = label }
        if ok then
          owned[tab.window_id] = action == "set" and tab.desired or nil
          log(string.format("%s %s: %s -> %s", tostring(tab.session), tab.window_id:sub(-8), tab.label,
                            action == "set" and tab.desired or default))
        else
          log("couldn't rename " .. tab.window_id .. ": " .. tostring(err))
        end
      elseif action == "keep" and tab.desired ~= "" then
        owned[tab.window_id] = tab.desired
      end
    end
  end
  for id in pairs(owned) do
    if not live[id] then owned[id] = nil end
  end
  if apply then save_state() end
  return tabs
end

local function dry_run()
  for _, tab in ipairs(M.pass(false)) do
    local p = tab.pane or {}
    print(table.concat({ tostring(tab.session), tab.window_id, tostring(p.app or "-"), tostring(p.via or "-"),
      tostring(tab.label), tostring(tab.desired), tostring(tab.action) }, "\t"))
  end
end

local function watch()
  local interval = tonumber(args.interval) or 3
  local pending = false
  local function soon()
    if pending then return end
    pending = true
    rex.after(0.5, function()
      pending = false
      M.pass(true)
    end)
  end
  log("rex-auto-title " .. M.VERSION .. " watching; checking tabs every " .. interval .. " seconds")
  M.pass(true)
  rex.every(interval, function() M.pass(true) end)
  for _, event in ipairs({ "terminal.process_changed", "terminal.pwd_changed", "terminal.title_changed",
                           "window_created", "active_window_changed" }) do
    rex.on(event, soon)
  end
end

if REX_AUTO_TITLE_LIB then return M end

OS = stdout_of({ "uname", "-s" }):gsub("%s+$", "")
local mode = args.mode or "watch"
if mode == "watch" then return watch() end
if mode == "once" then M.pass(true) return end
if mode == "dry_run" then return dry_run() end
if mode == "version" then print("rex-auto-title " .. M.VERSION) return end
error("unknown mode " .. tostring(mode) .. "; use watch, once, dry_run, or version", 0)

