-- PingLeader: contact Looking For Group listings one at a time. Pick a mode at
-- the top of the settings (right-click the button, or its cog):
--
-- Join a group: whisper and/or ask to join the leaders of groups that still
-- need one of your ticked roles. One per click.
--
-- Form my group: PingLeader works out which roles your 5-player group still
-- needs (1 tank, 1 healer, 3 DPS, counting your own role and invites not yet
-- answered) and picks solo players of the ticked classes who list one of
-- them. "Invite next" invites one per click; "Auto-invite" invites them as
-- they show up in the results. "Dry run" invites nobody: the plan popup shows
-- who it would invite and why.
--
-- Nothing is ever sent automatically to someone it would not also invite to
-- an open slot: automated whisper spam gets reported and can get the account
-- actioned.
--
--   /ping            contact the next listing
--   /ping join       switch to "Join a group"
--   /ping form       switch to "Form my group"
--   /ping options    open the settings
--   /ping plan       show who it would invite and why
--   /ping list       show who would be contacted, without sending
--   /ping dump       save the raw LFG data (then /reload) for debugging
--   /ping msg <text> change the current mode's message
--   /ping reset      forget who has been contacted
--   /ping wait <min> minutes before the same person can be contacted again

local DEFAULT_MSG = "Hey, Ret Paladin here if you still need a DPS."
local DEFAULT_WAIT = 30      -- minutes
local INVITE_TIMEOUT = 120   -- seconds an unanswered invite holds its slot
local AUTO_GAP = 2           -- seconds between automatic invites
local MAX_ROWS = 15          -- listings shown in the plan popup
local CLASSES = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }
local ROLES = { -- key, label, how many a 5-player group takes
    { "TANK", "Tank", 1 },
    { "HEALER", "Healer", 1 },
    { "DAMAGER", "DPS", 3 },
}
local ROLE_NAME = { TANK = "Tank", HEALER = "Healer", DAMAGER = "DPS" }

local issecret = issecretvalue or function() return false end
local canaccess = canaccesstable or function() return true end
local Send = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage
local Invite = (C_PartyInfo and C_PartyInfo.InviteUnit) or InviteUnit
local RequestInvite = (C_PartyInfo and C_PartyInfo.RequestInviteFromUnit) or Invite

local function Print(text)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99PingLeader|r: " .. text)
end

local function Plain(v)
    if v == nil or issecret(v) then return nil end
    return v
end

local function Readable(t)
    return type(t) == "table" and not issecret(t) and canaccess(t)
end

-- Names compare without case, spaces or hyphens ("Rat Loot" = "rat-loot").
local function Norm(name)
    return type(name) == "string" and (name:lower():gsub("[%s%-]", "")) or nil
end

local function IsMe(name)
    return Norm(name) == Norm(Plain(UnitName("player")))
end

-- Saved settings. db.join and db.form hold each mode's own message and options.
local function DB()
    PingLeaderDB = PingLeaderDB or {}
    local db = PingLeaderDB
    db.wait = db.wait or DEFAULT_WAIT
    db.sent = db.sent or {}
    if not db.join then -- settings were flat before modes existed: move them
        db.join = { msg = db.msg, roles = db.roles }
        db.form = { classes = db.classes }
        db.mode = (db.solo and not db.groups) and "form" or "join"
        db.msg, db.whisper, db.invite, db.roles, db.classes, db.auto, db.dryrun, db.groups, db.solo = nil
    end
    if db.mode ~= "form" then db.mode = "join" end
    local j, f = db.join, db.form
    j.msg = j.msg or DEFAULT_MSG
    if j.whisper == nil then j.whisper = true end
    if j.invite == nil then j.invite = false end
    j.roles = j.roles or { DAMAGER = true }
    f.msg = f.msg or ""
    if f.whisper == nil then f.whisper = false end
    if f.invite == nil then f.invite = true end
    if f.auto == nil then f.auto = false end
    if f.dryrun == nil then f.dryrun = true end
    if not f.classes then
        f.classes = {}
        for _, c in ipairs(CLASSES) do f.classes[c] = true end
    end
    return db
end

-- The current mode's settings, then the whole store.
local function M()
    local db = DB()
    return db[db.mode], db
end

local function AllClasses(classes)
    for _, c in ipairs(CLASSES) do
        if not classes[c] then return false end
    end
    return true
end

local function ClassName(cls)
    return cls and (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[cls] or cls)
end

local function RecentlyContacted(db, name, now)
    local last = db.sent[name]
    return last and now - last < db.wait * 60 and last or nil
end

local function ResultIDs()
    local ids
    if C_LFGList.GetSearchResults then
        local _, list = C_LFGList.GetSearchResults()
        ids = list
    end
    if (not ids or #ids == 0) and LFGBrowseFrame and type(LFGBrowseFrame.results) == "table" then
        ids = LFGBrowseFrame.results
    end
    return ids or {}
end

-- Class file name (e.g. "PRIEST") of the listing's leader, or nil if hidden.
local function LeaderClass(id, members)
    local first
    for i = 1, members do
        local cls, lead
        if C_LFGList.GetSearchResultPlayerInfo then
            local p = C_LFGList.GetSearchResultPlayerInfo(id, i)
            if Readable(p) then cls, lead = Plain(p.classFilename), Plain(p.isLeader) end
        elseif C_LFGList.GetSearchResultMemberInfo then
            local _, c, _, _, l = C_LFGList.GetSearchResultMemberInfo(id, i)
            cls, lead = Plain(c), Plain(l)
        end
        if lead then return cls end
        first = first or cls
    end
    return first -- the leader is listed first
end

-- Join a group ----------------------------------------------------------------

-- True if the group has room for any ticked role, or no role is ticked.
local function WantsRole(id, roles)
    local counts = C_LFGList.GetSearchResultMemberCounts and C_LFGList.GetSearchResultMemberCounts(id)
    if not Readable(counts) then return true end
    local any = false
    for _, r in ipairs(ROLES) do
        local key, cap = r[1], r[3]
        if roles[key] then
            any = true
            local left, have = Plain(counts[key .. "_REMAINING"]), Plain(counts[key])
            if type(left) == "number" then
                if left > 0 then return true end
            elseif type(have) ~= "number" or have < cap then
                return true
            end
        end
    end
    return not any
end

-- Leader name and size of a group listing that has room for a ticked role.
local function GroupCandidate(id, roles)
    local ok, leader, members = pcall(function()
        local info = C_LFGList.GetSearchResultInfo(id)
        if not Readable(info) or Plain(info.isDelisted) then return end
        local leader, members = Plain(info.leaderName), Plain(info.numMembers)
        if type(leader) ~= "string" or leader == "" or IsMe(leader) then return end
        if type(members) ~= "number" or members < 2 or members >= 5 then return end -- full groups
        if not WantsRole(id, roles) then return end
        return leader, members
    end)
    if ok then return leader, members end
end

-- Form my group ---------------------------------------------------------------

local invited = {} -- invites not answered yet: Norm(name) -> { t = time, role = key }
local roleOf = {}  -- Norm(name) -> role we invited them for; their assigned role is often NONE

-- Your role: the group's assigned one, else the first role ticked in your listing.
local function MyRole()
    local r = Plain(UnitGroupRolesAssigned("player"))
    if ROLE_NAME[r] then return r end
    local ok, roles = pcall(function()
        if C_LFGListRoles and C_LFGListRoles.GetRoles then return C_LFGListRoles.GetRoles() end
    end)
    if ok and Readable(roles) then
        if Plain(roles.tank) then return "TANK" end
        if Plain(roles.healer) then return "HEALER" end
        if Plain(roles.dps) then return "DAMAGER" end
    end
end

-- Everyone in your party but you: Norm(name) -> role key, or false if unknown.
local function Members()
    local out = {}
    for i = 1, 4 do
        local unit = "party" .. i
        local name = UnitExists(unit) and Norm(Plain(UnitName(unit)))
        if name then
            local r = Plain(UnitGroupRolesAssigned(unit))
            out[name] = ROLE_NAME[r] and r or roleOf[name] or false
        end
    end
    return out
end

-- Open slots per role in your 5-player group. Invites not yet answered hold
-- their slot; members with no known role are counted as DPS.
local function Needs(members)
    local now = time()
    local have, unknown, size, out = { TANK = 0, HEALER = 0, DAMAGER = 0 }, 0, 1, 0
    local function add(role)
        if role and have[role] then have[role] = have[role] + 1 else unknown = unknown + 1 end
    end
    local me = MyRole()
    add(me)
    for _, role in pairs(members) do
        add(role)
        size = size + 1
    end
    for key, inv in pairs(invited) do
        if members[key] ~= nil or now - inv.t > INVITE_TIMEOUT then
            invited[key] = nil -- joined, or never answered
        else
            add(inv.role)
            out = out + 1
        end
    end
    local need = {}
    for _, r in ipairs(ROLES) do need[r[1]] = math.max(0, r[3] - have[r[1]]) end
    for _, key in ipairs({ "DAMAGER", "HEALER", "TANK" }) do
        local take = math.min(unknown, need[key])
        need[key], unknown = need[key] - take, unknown - take
    end
    return need, me, size, out
end

local function NeedText(need)
    local parts = {}
    for _, r in ipairs(ROLES) do
        if need[r[1]] > 0 then parts[#parts + 1] = need[r[1]] .. " " .. r[2] end
    end
    return #parts > 0 and table.concat(parts, ", ") or "nothing, the group is full"
end

local function GroupStatus(plan)
    return ("You: %s. In group: %d/5, invites out: %d. Still need: %s."):format(
        ROLE_NAME[plan.me] or "role unknown (pick one in your listing)", plan.size, plan.out, NeedText(plan.need))
end

-- Name, class, level and offered roles of a solo listing, or nil.
local function Solo(id)
    local ok, row = pcall(function()
        local info = C_LFGList.GetSearchResultInfo(id)
        if not Readable(info) or Plain(info.isDelisted) or Plain(info.numMembers) ~= 1 then return end
        local name = Plain(info.leaderName)
        if type(name) ~= "string" or name == "" or IsMe(name) then return end
        local row = { name = name, members = 1, roles = {} }
        local p = C_LFGList.GetSearchResultPlayerInfo and C_LFGList.GetSearchResultPlayerInfo(id, 1)
        if Readable(p) then
            row.class, row.level = Plain(p.classFilename), Plain(p.level)
            local lr = p.lfgRoles -- Classic-style listings: every role the player ticked
            if Readable(lr) then
                row.roles.TANK = Plain(lr.tank) or nil
                row.roles.HEALER = Plain(lr.healer) or nil
                row.roles.DAMAGER = Plain(lr.dps) or nil
            end
            local r = Plain(p.assignedRole)
            if not next(row.roles) and ROLE_NAME[r] then row.roles[r] = true end
        end
        if not next(row.roles) then
            local c = C_LFGList.GetSearchResultMemberCounts and C_LFGList.GetSearchResultMemberCounts(id)
            if Readable(c) then
                for key in pairs(ROLE_NAME) do
                    local n = Plain(c[key])
                    if type(n) == "number" and n > 0 then row.roles[key] = true end
                end
            end
        end
        row.class = row.class or LeaderClass(id, 1)
        return row
    end)
    return ok and row or nil
end

-- Every solo listing in the results, with what PingLeader would do and why.
-- plan.picks are the ones it would invite, in order, each with the role it fills.
local function FormPlan()
    local db, now = DB(), time()
    local classes = db.form.classes
    local members = Members()
    local need, me, size, out = Needs(members)
    local left, picks, skips, seen = {}, {}, {}, {}
    for k, v in pairs(need) do left[k] = v end
    for _, id in ipairs(ResultIDs()) do
        local row = Solo(id)
        local key = row and Norm(row.name)
        if row and not seen[key] then
            seen[key] = true
            local offers = {}
            for _, r in ipairs(ROLES) do
                if row.roles[r[1]] then offers[#offers + 1] = r[2] end
            end
            offers = #offers > 0 and table.concat(offers, "/") or nil
            local last = RecentlyContacted(db, row.name, now)
            if members[key] ~= nil then
                row.why = "already in your group"
            elseif invited[key] then
                row.why = ("invited %ds ago, waiting for an answer"):format(now - invited[key].t)
            elseif last then
                row.why = ("contacted %d min ago"):format(math.floor((now - last) / 60))
            elseif not AllClasses(classes) and not classes[row.class or ""] then
                row.why = (ClassName(row.class) or "unknown class") .. " is not ticked"
            elseif not offers then
                row.why = "the game doesn't show their roles"
            else
                for _, r in ipairs(ROLES) do
                    if row.roles[r[1]] and left[r[1]] > 0 then
                        row.role = r[1]
                        break
                    end
                end
                if row.role then
                    left[row.role] = left[row.role] - 1
                    row.why = ("lists %s; you need %d %s"):format(offers, need[row.role], ROLE_NAME[row.role])
                else
                    row.why = ("lists %s; no open slot for that"):format(offers)
                end
            end
            if row.role then picks[#picks + 1] = row else skips[#skips + 1] = row end
        end
    end
    local rows = {}
    for _, r in ipairs(picks) do rows[#rows + 1] = r end
    for _, r in ipairs(skips) do rows[#rows + 1] = r end
    return { rows = rows, picks = picks, need = need, me = me, size = size, out = out }
end

-- Everyone the next click would contact, in order: { name, members, role },
-- plus the forming plan in "Form my group" mode.
local function Pending()
    local db, now = DB(), time()
    if db.mode == "form" then
        local plan = FormPlan()
        return plan.picks, plan
    end
    local list, seen = {}, {}
    for _, id in ipairs(ResultIDs()) do
        local leader, members = GroupCandidate(id, db.join.roles)
        if leader and not seen[leader] and not RecentlyContacted(db, leader, now) then
            seen[leader] = true
            list[#list + 1] = { name = leader, members = members }
        end
    end
    return list
end

local function Contact(e)
    local m, db = M()
    local done, key = {}, Norm(e.name)
    if m.whisper and m.msg ~= "" then
        Send(m.msg, "WHISPER", nil, e.name)
        done[#done + 1] = "whispered " .. e.name
    end
    if m.invite then
        if db.mode == "join" then
            RequestInvite(e.name)
            done[#done + 1] = "asked to join " .. e.name .. "'s group"
        else
            Invite(e.name)
            invited[key] = { t = time(), role = e.role }
            roleOf[key] = e.role
            done[#done + 1] = "invited " .. e.name .. (e.role and (" as " .. ROLE_NAME[e.role]) or "")
        end
    end
    db.sent[e.name] = time()
    Print(table.concat(done, ", "))
end

-- Plan popup ------------------------------------------------------------------

local popup

local function Colored(name, cls)
    local c = cls and RAID_CLASS_COLORS and RAID_CLASS_COLORS[cls]
    return c and c.colorStr and ("|c%s%s|r"):format(c.colorStr, name) or name
end

local function Backdrop(frame)
    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 14,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    frame:SetBackdropColor(0.06, 0.06, 0.07, 0.95)
    frame:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)
end

local function CreatePopup()
    if popup then return end
    popup = CreateFrame("Frame", "PingLeaderPlan", UIParent, "BackdropTemplate")
    popup:SetSize(460, 100)
    popup:SetPoint("TOP", 0, -120)
    popup:SetFrameStrata("DIALOG")
    Backdrop(popup)
    popup:SetMovable(true)
    popup:SetClampedToScreen(true)
    popup:EnableMouse(true)
    popup:RegisterForDrag("LeftButton")
    popup:SetScript("OnDragStart", popup.StartMoving)
    popup:SetScript("OnDragStop", popup.StopMovingOrSizing)
    popup:Hide()

    local title = popup:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", 0, -12)
    title:SetText("PingLeader: who it would invite, and why")
    local close = CreateFrame("Button", nil, popup, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -2, -2)
    close:SetScript("OnClick", function() popup:Hide() end)

    popup.head = popup:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    popup.head:SetPoint("TOPLEFT", 14, -34)
    popup.head:SetWidth(432)
    popup.head:SetJustifyH("LEFT")
    popup.rows = {}
    for i = 1, MAX_ROWS do
        local t = popup:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        t:SetPoint("TOPLEFT", 14, -66 - (i - 1) * 15)
        t:SetWidth(432)
        t:SetJustifyH("LEFT")
        t:SetWordWrap(false)
        popup.rows[i] = t
    end
end

local function UpdatePopup(plan)
    if not (popup and popup:IsShown()) then return end
    local f = DB().form
    local lines = {}
    if not plan then
        popup.head:SetText("You're in \"Join a group\" mode. Pick \"Form my group\" in the settings (the cog) to see who it would invite.")
    else
        local mode
        if IsInGroup() and not UnitIsGroupLeader("player") then
            mode = "|cffff6060You're not the group leader, so you can't invite.|r"
        elseif not f.invite then
            mode = "Group invite is off: nobody will be invited."
        elseif not f.auto then
            mode = "Auto-invite is off: click Invite next to invite the first one."
        elseif f.dryrun then
            mode = "|cffffd200Dry run: nobody is invited.|r Untick Dry run to invite for real."
        else
            mode = "|cff33ff33Auto-invite is on.|r"
        end
        popup.head:SetText(GroupStatus(plan) .. "\n" .. mode)
        for _, row in ipairs(plan.rows) do
            local tag = row.role and "|cff33ff33INVITE|r" or "|cff888888skip|r"
            lines[#lines + 1] = ("%s  %s%s - %s"):format(tag, Colored(row.name, row.class),
                row.level and (" " .. row.level) or "", row.why)
        end
        if #lines == 0 then lines[1] = "No solo players in the results. Hit refresh in the LFG window." end
        if #lines > MAX_ROWS then
            local more = #lines - MAX_ROWS + 1
            for i = MAX_ROWS + 1, #lines do lines[i] = nil end
            lines[MAX_ROWS] = ("... and %d more"):format(more)
        end
    end
    for i, t in ipairs(popup.rows) do
        t:SetText(lines[i] or "")
        t:SetShown(lines[i] ~= nil)
    end
    popup:SetHeight(76 + #lines * 15)
end

-- Refresh and auto-invite -----------------------------------------------------

local button, panel, Refresh
local autoWait = false

local function AutoInvite(plan)
    local f = DB().form
    if autoWait or not (f.auto and f.invite) or f.dryrun then return end
    if IsInGroup() and not UnitIsGroupLeader("player") then return end
    local e = plan.picks[1]
    if not e then return end
    autoWait = true
    Contact(e)
    C_Timer.After(AUTO_GAP, function()
        autoWait = false
        Refresh()
    end)
end

-- Button label for the current mode and actions, e.g. "Invite next".
local function Verb()
    local m, db = M()
    local act = db.mode == "form" and "Invite" or "Ask"
    if m.whisper and m.invite then return "Ping + " .. act:lower() end
    if m.invite then return act .. " next" end
    return "Ping next"
end

Refresh = function()
    local m = M()
    local list, plan = Pending()
    if button then
        button:SetText(("%s (%d)"):format(Verb(), #list))
        button:SetEnabled(#list > 0 and (m.whisper or m.invite))
    end
    if panel and plan then panel.status:SetText(GroupStatus(plan)) end
    UpdatePopup(plan)
    if plan then AutoInvite(plan) end
end

local function ShowPlan(show)
    CreatePopup()
    if show == nil then show = not popup:IsShown() end
    popup:SetShown(show)
    Refresh()
end

local function PingNext()
    local m = M()
    if not (m.whisper or m.invite) then
        Print("nothing to do: tick an Action in the settings (the cog).")
        return
    end
    if m.whisper and not m.invite and m.msg == "" then
        Print("the message is empty. Right-click the button to write one.")
        return
    end
    local e = Pending()[1]
    if not e then
        Print("nobody left to contact. Hit refresh in the LFG window, or widen who gets it.")
        return
    end
    Contact(e)
    Refresh()
end

-- Settings panel ------------------------------------------------------------

local checks, edits, tabs = {}, {}, {}
local MODES = {
    join = { tab = "Join a group", height = 270,
        desc = "Whisper or ask to join leaders of groups that still need your role. One per click." },
    form = { tab = "Form my group", height = 405,
        desc = "Invite solo players of the classes you tick into the roles your group still needs." },
}

local function Check(parent, label, get, set, color)
    local c = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    c:SetSize(22, 22)
    local t = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    t:SetPoint("LEFT", c, "RIGHT", 1, 0)
    t:SetText(label)
    if color then t:SetTextColor(color.r, color.g, color.b) end
    c:SetHitRectInsets(0, -(t:GetStringWidth() + 4), 0, 0) -- the label toggles it too
    c.get = get
    c:SetScript("OnClick", function(self)
        set(self:GetChecked() and true or false)
        Refresh()
    end)
    checks[#checks + 1] = c
    return c
end

local function Tip(frame, title, ...)
    local lines = { ... }
    frame:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(title)
        for _, l in ipairs(lines) do GameTooltip:AddLine(l, 1, 1, 1, true) end
        GameTooltip:Show()
    end)
    frame:SetScript("OnLeave", GameTooltip_Hide)
end

local function Label(parent, text, x, y)
    local t = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    t:SetPoint("TOPLEFT", x, y)
    t:SetText(text)
    return t
end

local function SmallButton(parent, text, width, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width, 20)
    b:SetText(text)
    b:SetScript("OnClick", onClick)
    return b
end

-- Multi-line message box at y, saving into settings table s.msg.
local function MessageBox(parent, label, y, s)
    Label(parent, label, 14, y)
    local box = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    box:SetPoint("TOPLEFT", 12, y - 14)
    box:SetPoint("TOPRIGHT", -12, y - 14)
    box:SetHeight(60)
    box:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    box:SetBackdropColor(0, 0, 0, 0.6)
    box:SetBackdropBorderColor(0.35, 0.35, 0.35, 1)
    local edit = CreateFrame("EditBox", nil, box)
    edit:SetPoint("TOPLEFT", 5, -5)
    edit:SetPoint("BOTTOMRIGHT", -5, 5)
    edit:SetMultiLine(true)
    edit:SetAutoFocus(false)
    edit:SetMaxLetters(255) -- whisper limit
    edit:SetFontObject(GameFontHighlightSmall)
    edit:SetScript("OnTextChanged", function(self, user)
        if user then s.msg = strtrim((self:GetText():gsub("[\r\n]+", " "))) end
    end)
    edit:SetScript("OnEnterPressed", edit.ClearFocus)
    edit:SetScript("OnEscapePressed", edit.ClearFocus)
    edit:SetScript("OnEditFocusLost", function(self) self:SetText(s.msg) end)
    edit.s = s
    box:EnableMouse(true)
    box:SetScript("OnMouseDown", function() edit:SetFocus() end)
    edits[#edits + 1] = edit
end

-- Show the current mode's options and mark its tab.
local function ApplyMode()
    local mode = DB().mode
    for key, tab in pairs(tabs) do
        local on = key == mode
        if on then tab:LockHighlight() else tab:UnlockHighlight() end
        local fs = tab:GetFontString()
        if fs then
            if on then fs:SetTextColor(1, 0.82, 0) else fs:SetTextColor(0.6, 0.6, 0.6) end
        end
        panel[key]:SetShown(on)
    end
    panel.desc:SetText(MODES[mode].desc)
    panel:SetHeight(MODES[mode].height)
end

local function SetMode(mode)
    DB().mode = mode
    if panel then ApplyMode() end
    Refresh()
end

local function SyncPanel()
    for _, c in ipairs(checks) do c:SetChecked(c.get()) end
    for _, e in ipairs(edits) do
        if not e:HasFocus() then e:SetText(e.s.msg) end
    end
    ApplyMode()
end

local function JoinOptions(parent, j)
    MessageBox(parent, "Message", 0, j)
    Label(parent, "Action", 14, -84)
    Check(parent, "Send whisper", function() return j.whisper end, function(v) j.whisper = v end)
        :SetPoint("TOPLEFT", 10, -98)
    local ask = Check(parent, "Ask to join", function() return j.invite end, function(v) j.invite = v end)
    ask:SetPoint("TOPLEFT", 130, -98)
    Tip(ask, "Ask to join", "Sends the group leader a request to join their group.")
    Label(parent, "Groups that still need", 14, -128)
    for i, r in ipairs(ROLES) do
        local key = r[1]
        Check(parent, r[2], function() return j.roles[key] end, function(v) j.roles[key] = v or nil end)
            :SetPoint("TOPLEFT", 10 + (i - 1) * 70, -142)
    end
end

local function FormOptions(parent, f)
    MessageBox(parent, "Message (sent only if Send whisper is ticked)", 0, f)
    Label(parent, "Action", 14, -84)
    Check(parent, "Send whisper", function() return f.whisper end, function(v) f.whisper = v end)
        :SetPoint("TOPLEFT", 10, -98)
    Check(parent, "Group invite", function() return f.invite end, function(v) f.invite = v end)
        :SetPoint("TOPLEFT", 130, -98)
    local auto = Check(parent, "Auto-invite", function() return f.auto end, function(v)
        f.auto = v
        if v then ShowPlan(true) end
    end)
    auto:SetPoint("TOPLEFT", 10, -120)
    Tip(auto, "Auto-invite", "Invites solo players for your open roles as they appear in the results, one every "
        .. AUTO_GAP .. " seconds. Needs Group invite ticked.")
    local dry = Check(parent, "Dry run (popup only)", function() return f.dryrun end, function(v)
        f.dryrun = v
        if v then ShowPlan(true) end
    end)
    dry:SetPoint("TOPLEFT", 130, -120)
    Tip(dry, "Dry run", "Auto-invite invites nobody. The plan popup shows who it would invite and why.")

    Label(parent, "Your group", 14, -150)
    panel.status = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    panel.status:SetPoint("TOPLEFT", 14, -164)
    panel.status:SetWidth(222)
    panel.status:SetJustifyH("LEFT")

    Label(parent, "Classes to invite", 14, -194)
    for i, cls in ipairs(CLASSES) do
        local color = RAID_CLASS_COLORS and RAID_CLASS_COLORS[cls]
        Check(parent, ClassName(cls), function() return f.classes[cls] end,
            function(v) f.classes[cls] = v or nil end, color)
            :SetPoint("TOPLEFT", 10 + ((i - 1) % 3) * 78, -208 - math.floor((i - 1) / 3) * 22)
    end
    local function SetAll(v)
        for _, cls in ipairs(CLASSES) do f.classes[cls] = v or nil end
        SyncPanel()
        Refresh()
    end
    local all = SmallButton(parent, "All", 54, function() SetAll(true) end)
    all:SetPoint("BOTTOMLEFT", 14, 12)
    local none = SmallButton(parent, "None", 54, function() SetAll(false) end)
    none:SetPoint("LEFT", all, "RIGHT", 6, 0)
    SmallButton(parent, "Show plan", 96, function() ShowPlan() end):SetPoint("BOTTOMRIGHT", -14, 12)
end

local function CreatePanel()
    if panel or not LFGBrowseFrame then return end
    local db = DB()
    panel = CreateFrame("Frame", "PingLeaderPanel", LFGBrowseFrame, "BackdropTemplate")
    panel:SetSize(250, MODES.join.height)
    panel:SetPoint("TOPLEFT", _G.LFGParentFrame or LFGBrowseFrame, "TOPRIGHT", 4, 0)
    Backdrop(panel)
    panel:EnableMouse(true)
    panel:Hide()

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", 0, -12)
    title:SetText("PingLeader")
    local close = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -2, -2)
    close:SetScript("OnClick", function() panel:Hide() end)

    -- mode switch: the first thing you see
    for i, key in ipairs({ "join", "form" }) do
        local tab = SmallButton(panel, MODES[key].tab, 108, function() SetMode(key) end)
        tab:SetHeight(24)
        tab:SetPoint("TOPLEFT", 14 + (i - 1) * 114, -32)
        tabs[key] = tab
    end
    panel.desc = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    panel.desc:SetPoint("TOPLEFT", 14, -62)
    panel.desc:SetWidth(222)
    panel.desc:SetJustifyH("LEFT")
    panel.desc:SetTextColor(0.7, 0.7, 0.7)

    for key, build in pairs({ join = JoinOptions, form = FormOptions }) do
        local content = CreateFrame("Frame", nil, panel)
        content:SetPoint("TOPLEFT", 0, -92)
        content:SetPoint("BOTTOMRIGHT")
        content:Hide()
        panel[key] = content
        build(content, db[key])
    end

    panel:SetScript("OnShow", function()
        SyncPanel()
        Refresh()
    end)
end

local function TogglePanel()
    CreatePanel()
    if not panel or not LFGBrowseFrame:IsVisible() then
        Print("open the Looking For Group window first.")
    else
        panel:SetShown(not panel:IsShown())
    end
end

-- Button ----------------------------------------------------------------------

local function CreateButton()
    if button or not LFGBrowseFrame then return end
    button = CreateFrame("Button", "PingLeaderButton", LFGBrowseFrame, "UIPanelButtonTemplate")
    button:SetSize(130, 22)
    local anchor = _G.LFGBrowseFrameSendMessageButton
    if anchor then
        button:SetPoint("LEFT", anchor, "RIGHT", 10, 0) -- in the gap before Group Invite
    else
        button:SetPoint("BOTTOMLEFT", LFGBrowseFrame, "BOTTOMLEFT", 20, 50)
    end
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:SetScript("OnClick", function(_, mouse)
        if mouse == "RightButton" then TogglePanel() else PingNext() end
    end)
    button:SetScript("OnShow", Refresh)
    button:SetScript("OnEnter", function(self)
        local m, db = M()
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("PingLeader: " .. MODES[db.mode].tab)
        GameTooltip:AddLine("Click: " .. Verb():lower(), 1, 1, 1)
        GameTooltip:AddLine("Right-click: settings and mode", 1, 1, 1)
        if m.whisper and m.msg ~= "" then GameTooltip:AddLine(m.msg, 1, 0.82, 0, true) end
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", GameTooltip_Hide)

    -- cog beside it, so the settings are findable without knowing to right-click
    local cog = CreateFrame("Button", nil, button)
    cog:SetSize(18, 18)
    cog:SetPoint("LEFT", button, "RIGHT", 4, 0)
    local icon = cog:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints()
    if not (icon.SetAtlas and pcall(icon.SetAtlas, icon, "OptionsIcon-Brown", false) and icon:GetAtlas()) then
        icon:SetTexture("Interface\\Buttons\\UI-OptionsButton")
    end
    icon:SetAlpha(0.8)
    cog:SetScript("OnClick", TogglePanel)
    cog:SetScript("OnEnter", function(self)
        icon:SetAlpha(1)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("PingLeader settings and mode")
        GameTooltip:Show()
    end)
    cog:SetScript("OnLeave", function()
        icon:SetAlpha(0.8)
        GameTooltip:Hide()
    end)
    Refresh()
end

-- Debug dump ------------------------------------------------------------------

local function Copy(v, depth)
    if issecret(v) then return "<secret>" end
    if type(v) == "table" then
        if not canaccess(v) then return "<no access>" end
        if depth > 4 then return "<deep>" end
        local t = {}
        for k, x in pairs(v) do
            if type(k) == "string" or type(k) == "number" then t[k] = Copy(x, depth + 1) end
        end
        return t
    end
    if type(v) == "function" or type(v) == "userdata" then return nil end
    return v
end

local function Try(fn, ...)
    if type(fn) ~= "function" then return "<no such function>" end
    local r = { pcall(fn, ...) }
    if not r[1] then return "error: " .. tostring(r[2]) end
    table.remove(r, 1)
    return Copy(#r > 1 and r or r[1], 1)
end

-- Raw LFG data into PingLeaderDB.dump, so the real field names can be checked.
local function Dump()
    local L = C_LFGList
    local d = {
        when = date("%Y-%m-%d %H:%M:%S"),
        myName = Try(UnitName, "player"),
        myAssignedRole = Try(UnitGroupRolesAssigned, "player"),
        myListingRoles = Try(C_LFGListRoles and C_LFGListRoles.GetRoles),
        activeEntry = Try(L.GetActiveEntryInfo),
        party = {},
        results = {},
    }
    for i = 1, 4 do
        local unit = "party" .. i
        if UnitExists(unit) then
            d.party[unit] = { name = Try(UnitName, unit), role = Try(UnitGroupRolesAssigned, unit) }
        end
    end
    for _, id in ipairs(ResultIDs()) do
        local r = { id = id, info = Try(L.GetSearchResultInfo, id), counts = Try(L.GetSearchResultMemberCounts, id),
            players = {}, memberInfo = {} }
        local n = type(r.info) == "table" and tonumber(r.info.numMembers) or 1
        for i = 1, math.min(n, 5) do
            r.players[i] = Try(L.GetSearchResultPlayerInfo, id, i)
            r.memberInfo[i] = Try(L.GetSearchResultMemberInfo, id, i)
        end
        r.leaderInfo = Try(L.GetSearchResultLeaderInfo, id)
        d.results[#d.results + 1] = r
    end
    DB().dump = d
    Print(("saved %d listings. Type /reload so the game writes them to disk."):format(#d.results))
end

-- Events ----------------------------------------------------------------------

-- Lua pattern for a Blizzard "%s ..." message; the name is the capture.
local function Pattern(fmt)
    if type(fmt) ~= "string" then return nil end
    local p = fmt:gsub("([%%%^%$%(%)%.%[%]%*%+%-%?])", "%%%1"):gsub("%%%%s", "(.+)")
    return "^" .. p .. "$"
end
-- System messages that end an invite without the player joining.
local INVITE_ENDED = {}
for _, fmt in ipairs({ ERR_DECLINE_GROUP_S, ERR_ALREADY_IN_GROUP_S, ERR_BAD_PLAYER_NAME_S }) do
    INVITE_ENDED[#INVITE_ENDED + 1] = Pattern(fmt)
end

local events = CreateFrame("Frame")
for _, event in ipairs({ "PLAYER_LOGIN", "ADDON_LOADED", "LFG_LIST_SEARCH_RESULTS_RECEIVED",
    "LFG_LIST_SEARCH_RESULT_UPDATED", "LFG_LIST_ACTIVE_ENTRY_UPDATE", "GROUP_ROSTER_UPDATE",
    "PLAYER_ROLES_ASSIGNED", "CHAT_MSG_SYSTEM", "ADDON_ACTION_BLOCKED", "ADDON_ACTION_FORBIDDEN" }) do
    pcall(events.RegisterEvent, events, event) -- skip events this client doesn't have
end
events:SetScript("OnEvent", function(_, event, arg1, arg2)
    if event == "PLAYER_LOGIN" or event == "ADDON_LOADED" then
        CreateButton()
        if event == "PLAYER_LOGIN" then
            -- unanswered invites time out, so the plan changes with no event
            C_Timer.NewTicker(5, function()
                if (popup and popup:IsShown()) or (DB().form.auto and next(invited)) then Refresh() end
            end)
        end
    elseif event == "CHAT_MSG_SYSTEM" then
        if type(arg1) ~= "string" or issecret(arg1) then return end
        for _, pat in ipairs(INVITE_ENDED) do
            local name = arg1:match(pat)
            if name then
                name = name:match("%[(.-)%]") or name -- strip a player link
                if invited[Norm(name)] then
                    invited[Norm(name)] = nil
                    Refresh()
                end
                return
            end
        end
    elseif event == "ADDON_ACTION_BLOCKED" or event == "ADDON_ACTION_FORBIDDEN" then
        if arg1 == "PingLeader" then
            DB().form.auto = false
            if panel and panel:IsShown() then SyncPanel() end
            Print(("the game blocked %s, so Auto-invite is off. Click Invite next instead."):format(tostring(arg2)))
        end
    else
        Refresh()
    end
end)

SLASH_PINGLEADER1 = "/ping"
SLASH_PINGLEADER2 = "/pingleader"
SlashCmdList.PINGLEADER = function(input)
    local cmd, rest = (input or ""):match("^%s*(%S*)%s*(.-)%s*$")
    cmd = cmd:lower()
    local m, db = M()
    if cmd == "" then
        PingNext()
    elseif cmd == "join" or cmd == "form" then
        SetMode(cmd)
        if panel and panel:IsShown() then SyncPanel() end
        Print("mode: " .. MODES[cmd].tab)
    elseif cmd == "options" or cmd == "config" then
        TogglePanel()
    elseif cmd == "plan" then
        ShowPlan()
    elseif cmd == "dump" then
        Dump()
    elseif cmd == "list" then
        local names = {}
        for _, e in ipairs((Pending())) do names[#names + 1] = e.name end
        Print(#names == 0 and "nobody to contact." or ("next: " .. table.concat(names, ", ")))
    elseif cmd == "msg" and rest ~= "" then
        m.msg = rest
        if panel and panel:IsShown() then SyncPanel() end
        Print(MODES[db.mode].tab .. " message set to: " .. rest)
    elseif cmd == "reset" then
        wipe(db.sent)
        wipe(invited)
        Print("forgot everyone you have contacted.")
        Refresh()
    elseif cmd == "wait" and tonumber(rest) then
        db.wait = tonumber(rest)
        Print(("same person can be contacted again after %d min."):format(db.wait))
        Refresh()
    else
        Print("/ping, /ping join, /ping form, /ping options, /ping plan, /ping list, /ping dump, "
            .. "/ping msg <text>, /ping reset, /ping wait <minutes>")
    end
end
