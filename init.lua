--[[
Best In Slot - Project Lazarus Edition
aquietone, dlilah, ...

Tracker lua script for all the good stuff to have on Project Lazarus server.
]]
local mq = require('mq')
local ImGui = require('ImGui')
local ok, actors = pcall(require, 'actors')
if not ok then
    printf('Your version of MacroQuest does not support Lua Actors, exiting.')
    mq.exit()
end
local PackageMan = require('mq/PackageMan')
local sql = PackageMan.Require('lsqlite3')
local dbpath = string.format('%s\\%s', mq.TLO.MacroQuest.Path('resources')(), 'lazbis.db')

local version = '2.0.0'

local args = { ... }

local SCRIPT_NAME = string.match(string.gsub(debug.getinfo(1, 'S').short_src, '\\init.lua', ''), "[^\\]+$")

-- UI States
local openGUI = true
local shouldDrawGUI = true
local terminate = false

-- Character info storage
local gear = {}
local group = {}
local itemChecks = {}
local tradeskills = {}
local ldons = {}

-- Item list information
local bisConfig = require('bis')
local itemLists = {[1]='anguish',[2]='dsk',[3]='fuku',[4]='hcitems',[5]='jonas',[6]='preanguish',[7]='questitems',[8]='sebilis',[9]='veksar',[10]='vendoritems',}
local selectedItemList = 8
local itemList = bisConfig.sebilis
local selectionChanged = true
local showslots = true
local showmissingonly = false
local orderedSkills = {'Baking', 'Blacksmithing', 'Brewing', 'Fletching', 'Jewelry Making', 'Pottery', 'Tailoring'}
local orderedLDONs = {{name='Deepest Guk', num=75}, {name='Miragul\'s', num=75}, {name='Mistmoore', num=75}, {name='Rujarkian', num=75}, {name='Takish', num=75}}

local debug = false

local server = mq.TLO.EverQuest.Server()
local dbfmt = "INSERT INTO Inventory VALUES ('%s','%s','%s','%s','%s','%s',%d,%d,'%s');\n"
local db

-- Default to e3bca if mq2mono is loaded, else use dannet
local broadcast = '/e3bca'
local selectedBroadcast = 1
local rebroadcast = false
if not mq.TLO.Plugin('mq2mono')() then broadcast = '/dge' end

-- Load item list for specific zone if inside raid instance for that zone
if mq.TLO.Zone.ShortName() == 'dreadspire' or mq.TLO.Zone.ShortName() == 'thevoida' then
    selectedItemList = 2
    itemList = bisConfig.dsk
elseif mq.TLO.Zone.ShortName() == 'veksar' then
    selectedItemList = 9
    itemList = bisConfig.veksar
elseif mq.TLO.Zone.ShortName() == 'anguish' then
    selectedItemList = 1
    itemList = bisConfig.anguish
elseif mq.TLO.Zone.ShortName() == 'unrest' then
    selectedItemList = 3
    itemList = bisConfig.fuku
end

local function split(str, char)
    return string.gmatch(str, '[^' .. char .. ']+')
end

local function initTables(db)
    local foundInfo = false
    local foundInventory = false
    local function versioncallback(udata,cols,values,names)
        for i=1,cols do
            if values[i] == 'Info' then
                foundInfo = true
            elseif values[i] == 'Inventory' then
                foundInventory = true
            end
        end
        return 0
    end
    repeat
        local result = db:exec([[SELECT name FROM sqlite_master WHERE type='table';]], versioncallback)
        if result == sql.BUSY then print('\arDatabase was busy!') mq.delay(math.random(10,50)) end
    until result ~= sql.BUSY

    if not foundInventory then
        -- print('Creating Inventory')
        repeat
            local result = db:exec([[
BEGIN TRANSACTION;
CREATE TABLE IF NOT EXISTS Inventory (Character TEXT NOT NULL, Class TEXT NOT NULL, Server TEXT NOT NULL, Slot TEXT NOT NULL, ItemName TEXT NOT NULL, Location TEXT NOT NULL, Count INTEGER NOT NULL, ComponentCount INTEGER NOT NULL, Category TEXT NOT NULL);
COMMIT;]])
            if result ~= 0 then printf('CREATE TABLE Result: %s', result) end
            if result == sql.BUSY then print('\arDatebase was busy!') mq.delay(math.random(10,50)) end
        until result ~= sql.BUSY
    end

    if not foundInfo then
        -- print('Creating Info')
        repeat
            local result = db:exec([[
BEGIN TRANSACTION;
CREATE TABLE IF NOT EXISTS Info (Version TEXT NOT NULL);
COMMIT;]])
if result ~= 0 then printf('CREATE TABLE Result: %s', result) end
            if result == sql.BUSY then print('\arDatebase was busy!') mq.delay(math.random(10,50)) end
        until result ~= sql.BUSY
    end

    repeat
        local result = db:exec([[DELETE FROM Info;]])
        -- print(result)
        if result == sql.BUSY then print('\arDatabase was busy!') mq.delay(math.random(10,50)) end
    until result ~= sql.BUSY

    repeat
        local result = db:exec([[INSERT INTO Info VALUES ('1.0');]])
        -- print(result)
        if result == sql.BUSY then print('\arDatabase was busy!') mq.delay(math.random(10,50)) end
    until result ~= sql.BUSY
end

local function initDB()
    local db = sql.open(dbpath)
    if db then
        db:exec("PRAGMA journal_mode=WAL;")
        initTables(db)
        return db
    end
end
if args[1] ~= '0' then
    db = initDB()
end

local function resolveInvSlot(invslot)
    if invslot == 'Bank' then return ' (Bank)' end
    local numberinvslot = tonumber(invslot)
    if not numberinvslot then return '' end
    if numberinvslot >= 23 then
        return ' (in bag'..invslot - 22 ..')'
    else
        return ' ('..mq.TLO.InvSlot(invslot).Name()..')'
    end
end

local function clearCharacterData(name, category)
    repeat
        local result = db:exec(("BEGIN TRANSACTION; DELETE FROM Inventory WHERE Character = '%s' AND Server = '%s' AND Category = '%s'; COMMIT;"):format(name, server, category))
        if result ~= 0 then print(result) end
        if result == sql.BUSY then print('\arDatabase was busy!') mq.delay(math.random(10,50)) end
    until result ~= sql.BUSY
end

local function buildInsertStmt(name, category)
    local stmt = "BEGIN TRANSACTION;\n"
    local char = group[name]
    for slot,value in pairs(gear[name]) do
        local itemName = value.actualname
        local realSlot = slot ~= 'Wrists2' and slot or 'Wrists'
        if not itemName then
            itemName = itemList[char.Class] and itemList[char.Class][realSlot] or itemList.Template[realSlot]
            if itemName and string.find(itemName, '/') then
                itemName = itemName:match("([^/]+)")
            end
        end
        if itemName then
            stmt = stmt .. dbfmt:format(name,char.Class,server,realSlot:gsub('\'','\'\''),itemName:gsub('\'','\'\''),resolveInvSlot(value.invslot):gsub('\'','\'\''),tonumber(value.count) or 0,tonumber(value.componentcount) or 0,category)
        end
    end
    stmt = stmt .. 'COMMIT;'
    -- print(stmt)
    return stmt
end

local function insertCharacterData(name, category)
    local insertStmt = buildInsertStmt(name, category)
    repeat
        local result = db:exec(insertStmt)
        if result ~= 0 then printf('Insert failed for %s %s with error: %s', name, category, result) end
        if result == sql.BUSY then print('\arDatabase was busy!') mq.delay(math.random(10,50)) end
    until result ~= sql.BUSY
end

local function rowCallback(udata,cols,values,names)
    if group[values[1]] and not group[values[1]].Offline then return 0 end
    -- name,server,slot,item,location,count,compcount,category
    -- printf('%s %s %s %s', values[1], values[2], values[4], values[5])
    if not group[values[1]] then group[values[1]] = {Name=values[1], Class=values[2], Offline=true, Show=false} table.insert(group, group[values[1]])end
    gear[values[1]] = gear[values[1]] or {}
    gear[values[1]][values[4]] = {count=values[7], componentcount=values[8], actualname=values[6] and values[5], location=values[6]}
    return 0
end

local function loadInv(category)
    for _,char in ipairs(group) do
        if char.Offline then gear[char.Name] = {} end
    end
    repeat
        local result = db:exec(string.format("SELECT * FROM Inventory WHERE Category='%s' AND Server = '%s';", category, server), rowCallback)
        if result == sql.BUSY then print('\arDatabase was busy!') mq.delay(math.random(10,50)) end
    until result ~= sql.BUSY
end

local function dumpInv(name, category)
    clearCharacterData(name, category)

    insertCharacterData(name, category)
end

if args[1] == 'dumpinv' then
    group[mq.TLO.Me.CleanName()] = {Name=mq.TLO.Me.CleanName(),Class=mq.TLO.Me.Class.Name(),Offline=false}
    table.insert(group, group[mq.TLO.Me.CleanName()])
    for _,list in ipairs(itemLists) do
        local classItems = bisConfig[list][mq.TLO.Me.Class.Name()]
        local templateItems = bisConfig[list].Template
        itemList = bisConfig[list]
        local results = {}
        for _,itembucket in ipairs({templateItems,classItems}) do
            for slot,item in pairs(itembucket) do
                local currentResult = 0
                local componentResult = 0
                local currentSlot = nil
                local actualName = nil
                if string.find(item, '/') then
                    for itemName in split(item, '/') do
                        local searchString = itemName
                        local findItem = mq.TLO.FindItem(searchString)
                        local findItemBank = mq.TLO.FindItemBank(searchString)
                        local count = mq.TLO.FindItemCount(searchString)() + mq.TLO.FindItemBankCount(searchString)()
                        if slot == 'PSAugSprings' and itemName == '39071' and currentResult < 3 then
                            currentResult = 0
                        end
                        if count > 0 and not actualName then
                            actualName = findItem() or findItemBank()
                            currentSlot = findItem.ItemSlot() or (findItemBank() and 'Bank') or ''
                        end
                        currentResult = currentResult + count
                    end
                else
                    local searchString = item
                    currentResult = currentResult + mq.TLO.FindItemCount(searchString)() + mq.TLO.FindItemBankCount(searchString)()
                    currentSlot = mq.TLO.FindItem(searchString).ItemSlot() or (mq.TLO.FindItemBank(searchString)() and 'Bank') or ''
                end
                if currentResult == 0 and bisConfig[list].Visible and bisConfig[list].Visible[slot] then
                    local compItem = bisConfig[list].Visible[slot]
                    componentResult = mq.TLO.FindItemCount(compItem)() or mq.TLO.FindItemBankCount(compItem)()
                    currentSlot = mq.TLO.FindItem(compItem).ItemSlot() or (mq.TLO.FindItemBank(compItem)() and 'Bank') or ''
                end
                results[slot] = {count=currentResult, invslot=currentSlot, componentcount=componentResult>0 and componentResult or nil, actualname=actualName}
            end
        end
        gear[mq.TLO.Me.CleanName()] = results
        dumpInv(mq.TLO.Me.CleanName(), list)
    end
    return
end

-- Actor message handler
local actor = actors.register(function(msg)
    local content = msg()
    if debug then printf('<<< MSG RCVD: id=%s', content.id) end
    if content.id == 'hello' then
        if debug then printf('=== MSG: id=%s Name=%s Class=%s', content.id, content.Name, content.Class) end
        if args[1] == '0' then return end
        if not group[content.Name] then
            local char = {
                Name = content.Name,
                Class = content.Class,
                Offline = false,
                Show = true,
            }
            if debug then printf('Add character: Name=%s Class=%s', char.Name, char.Class) end
            group[content.Name] = char
            table.insert(group, char)
            selectionChanged = true
            msg:send({id='hello',Name=mq.TLO.Me(),Class=mq.TLO.Me.Class.Name()})
        elseif group[content.Name].Offline then
            group[content.Name].Offline = false
        end
    elseif content.id == 'search' then
        if debug then printf('=== MSG: id=%s list=%s', content.id, content.list) end
        -- {id='search', list='dsk'}
        local classItems = bisConfig[content.list][mq.TLO.Me.Class.Name()]
        local templateItems = bisConfig[content.list].Template
        local results = {}
        for _,itembucket in ipairs({templateItems,classItems}) do
            for slot,item in pairs(itembucket) do
                local currentResult = 0
                local componentResult = 0
                local currentSlot = nil
                local actualName = nil
                if string.find(item, '/') then
                    for itemName in split(item, '/') do
                        -- if not actualName then actualName = itemName end
                        local searchString = itemName
                        -- if not tonumber(itemName) then searchString = '='..searchString end
                        local findItem = mq.TLO.FindItem(searchString)
                        local findItemBank = mq.TLO.FindItemBank(searchString)
                        local count = mq.TLO.FindItemCount(searchString)() + mq.TLO.FindItemBankCount(searchString)()
                        if slot == 'PSAugSprings' and itemName == '39071' and currentResult < 3 then
                            currentResult = 0
                        end
                        if count > 0 and not actualName then
                        -- if count > 0 and actualName == itemName then
                            actualName = findItem() or findItemBank()
                            currentSlot = findItem.ItemSlot() or (findItemBank() and 'Bank') or ''
                        end
                        currentResult = currentResult + count
                    end
                else
                    local searchString = item
                    -- if not tonumber(item) then searchString = '='..searchString end
                    currentResult = currentResult + mq.TLO.FindItemCount(searchString)() + mq.TLO.FindItemBankCount(searchString)()
                    currentSlot = mq.TLO.FindItem(searchString).ItemSlot() or (mq.TLO.FindItemBank(searchString)() and 'Bank') or ''
                end
                if currentResult == 0 and bisConfig[content.list].Visible and bisConfig[content.list].Visible[slot] then
                    local compItem = bisConfig[content.list].Visible[slot]
                    componentResult = mq.TLO.FindItemCount(compItem)() or mq.TLO.FindItemBankCount(compItem)()
                    currentSlot = mq.TLO.FindItem(compItem).ItemSlot() or (mq.TLO.FindItemBank(compItem)() and 'Bank') or ''
                end
                results[slot] = {count=currentResult, invslot=currentSlot, componentcount=componentResult>0 and componentResult or nil, actualname=actualName}
            end
        end
        if debug then printf('>>> SEND MSG: id=%s Name=%s list=%s class=%s', content.id, mq.TLO.Me.CleanName(), content.list, mq.TLO.Me.Class.Name()) end
        msg:send({id='result', Name=mq.TLO.Me.CleanName(), list=content.list, class=mq.TLO.Me.Class.Name(), results=results})
    elseif content.id == 'result' then
        if debug then printf('=== MSG: id=%s Name=%s list=%s class=%s', content.id, content.Name, content.list, content.class) end
        if args[1] == '0' then return end
        -- {id='result', Name='name', list='dsk', class='Warrior', results={slot1=1, slot2=0}}
        local results = content.results
        if results == nil then return end
        local char = group[content.Name]
        gear[char.Name] = {}--gear[char.Name] or {}
        for slot,res in pairs(results) do
            if (bisConfig[content.list][content.class] and bisConfig[content.list][content.class][slot]) or bisConfig[content.list].Template[slot] then
                gear[char.Name][slot] = res
            end
        end
        if bisConfig[content.list].Visible ~= nil and bisConfig[content.list].Visible.Slots ~= nil then
            gear[char.Name].Visible = gear[char.Name].Visible or {}
            for slot in split(bisConfig[content.list].Visible.Slots, ',') do
                gear[char.Name].Visible[slot] = gear[char.Name][slot]
            end
        end
        dumpInv(char.Name, content.list)
    elseif content.id == 'tsquery' then
        if debug then printf('=== MSG: id=%s', content.id) end
        local skills = {
            Blacksmithing = mq.TLO.Me.Skill('blacksmithing')(),
            Baking = mq.TLO.Me.Skill('baking')(),
            Brewing = mq.TLO.Me.Skill('brewing')(),
            Tailoring = mq.TLO.Me.Skill('tailoring')(),
            Pottery = mq.TLO.Me.Skill('pottery')(),
            ['Jewelry Making'] = mq.TLO.Me.Skill('jewelry making')(),
            Fletching = mq.TLO.Me.Skill('fletching')(),
        }
        -- local ldon = {}
        -- for i=1,5 do
        --     print(mq.TLO.Window('AdventureStatsWnd/AdvStats_ThemeList').List(i..',1')())
        --     ldon[mq.TLO.Window('AdventureStatsWnd/AdvStats_ThemeList').List(i..',1')()] = mq.TLO.Window('AdventureStatsWnd/AdvStats_ThemeList').List(i..',3')()
        -- end
        if debug then printf('>>> SEND MSG: id=%s Name=%s Skills=%s', content.id, mq.TLO.Me.CleanName(), skills) end
        msg:send({id='tsresult', Skills=skills, Name=mq.TLO.Me.CleanName()})
    elseif content.id == 'tsresult' then
        if debug then printf('=== MSG: id=%s Name=%s Skills=%s', content.id, content.Name, content.Skills) end
        if args[1] == '0' then return end
        local char = group[content.Name]
        tradeskills[char.Name] = tradeskills[char.Name] or {}
        for name,skill in pairs(content.Skills) do
            tradeskills[char.Name][name] = skill
        end
        -- ldons[char.Name] = ldons[char.Name] or {}
        -- for name,count in pairs(content.ldon) do
        --     ldons[char.Name][name] = tonumber(count) or 0
        -- end
    end
end)

local function changeBroadcastMode(tempBroadcast)
    mq.cmdf('%s /lua stop %s', broadcast, SCRIPT_NAME)

    if not mq.TLO.Plugin('mq2mono')() then
        if tempBroadcast == 3 then
            broadcast = '/dgge'
        else
            broadcast = '/dge'
        end
    else
        if tempBroadcast == 3 then
            broadcast = '/e3bcg'
        else
            broadcast = '/e3bca'
        end
    end
    if tempBroadcast == 1 or tempBroadcast == 3 then
        -- remove offline toons
        for _,char in ipairs(group) do
            if char.Offline then char.Show = false end
        end
    elseif tempBroadcast == 2 then
        -- add offline toons
        for _,char in ipairs(group) do
            if char.Offline then char.Show = true end
        end
    end
    selectedBroadcast = tempBroadcast
    rebroadcast = true
end

local function getItemColor(slot, count, visibleCount, componentCount)
    if componentCount and componentCount > 0 then
        return { 1, 1, 0 }
    end
    if slot == 'Wrists2' then
        return { count == 2 and 0 or 1, count == 2 and 1 or 0, .1 }
    end
    return { count > 0 and 0 or 1, (count > 0 or visibleCount > 0) and 1 or 0, .1 }
end

local function slotRow(slot, tmpGear)
    local realSlot = slot ~= 'Wrists2' and slot or 'Wrists'
    ImGui.TableNextRow()
    ImGui.TableNextColumn()
    ImGui.Text('' .. slot)
    for _, char in ipairs(group) do
        if char.Show then
            ImGui.TableNextColumn()
            if (tmpGear[char.Name] ~= nil and tmpGear[char.Name][realSlot] ~= nil) then
                local itemName = itemList[char.Class] and itemList[char.Class][realSlot] or itemList.Template[realSlot]
                if (itemName ~= nil) then
                    if string.find(itemName, '/') then
                        itemName = itemName:match("([^/]+)")
                    end
                    local actualName = tmpGear[char.Name][realSlot].actualname
                    if not actualName or string.find(actualName, '/') then
                        actualName = itemName
                    end
                    local count, invslot = tmpGear[char.Name][realSlot].count, tmpGear[char.Name][realSlot].invslot
                    local countVis = tmpGear[char.Name].Visible and tmpGear[char.Name].Visible[realSlot] and tmpGear[char.Name].Visible[realSlot].count or 0
                    local componentcount = tmpGear[char.Name][realSlot].componentcount
                    local color = getItemColor(slot, tonumber(count), tonumber(countVis), tonumber(componentcount))
                    ImGui.PushStyleColor(ImGuiCol.Text, color[1], color[2], color[3], 1)
                    if itemName == actualName then
                        local resolvedInvSlot = tmpGear[char.Name][realSlot].location or resolveInvSlot(invslot)
                        local lootDropper = color[2] == 0 and bisConfig.LootDroppers[actualName]
                        ImGui.Text('%s%s%s', itemName, showslots and resolvedInvSlot or '', lootDropper and ' ('..lootDropper..')' or '')
                        ImGui.PopStyleColor()
                    else
                        local lootDropper = color[2] == 0 and bisConfig.LootDroppers[actualName]
                        ImGui.Text('%s%s', itemName, lootDropper and ' ('..lootDropper..')' or '')
                        ImGui.PopStyleColor()
                        if ImGui.IsItemHovered() then
                            local resolvedInvSlot = tmpGear[char.Name][realSlot].location or resolveInvSlot(invslot)
                            ImGui.BeginTooltip()
                            ImGui.Text('Found ') ImGui.SameLine() ImGui.TextColored(0,1,0,1,'%s', actualName) ImGui.SameLine() ImGui.Text('in slot %s', resolvedInvSlot)
                            ImGui.EndTooltip()
                        end
                    end
                end
            end
        end
    end
end

local filter = ''
local filteredGear = {}
local filteredSlots = {}
local useFilter = false

local function filterGear(slots)
    filteredGear = {}
    filteredSlots = {}
    local lowerFilter = filter:lower()
    if slots then
        for _,category in ipairs(slots) do
            local catSlots = category.Slots
            for _,slot in ipairs(catSlots) do
                for _, char in ipairs(group) do
                    if (gear[char.Name] ~= nil and gear[char.Name][slot] ~= nil) then
                        local itemName = itemList[char.Class] and itemList[char.Class][slot] or itemList.Template[slot]
                        if (itemName ~= nil) and itemName:lower():find(lowerFilter) and (not showmissingonly or gear[char.Name][slot].count == 0) then
                            filteredGear[char.Name] = filteredGear[char.Name] or {Name=char.Name, Class=char.Class}
                            filteredGear[char.Name][slot] = gear[char.Name][slot]
                            if not filteredSlots[category.Name] then
                                table.insert(filteredSlots, {Name=category.Name, Slots={slot}})
                                filteredSlots[category.Name] = category.Name
                            else
                                for _,cat in ipairs(filteredSlots) do
                                    if cat.Name == category.Name then
                                        local addSlot = true
                                        for _,s in ipairs(cat.Slots) do
                                            if s == slot then
                                                addSlot = false
                                                break
                                            end
                                        end
                                        if addSlot then table.insert(cat.Slots, slot) end
                                        break
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end

local function AddUnderline(color)
    local min = ImGui.GetItemRectMinVec()
    local max = ImGui.GetItemRectMaxVec()
    min.y = max.y
    ImGui.GetWindowDrawList():AddLine(min, max, color, 20)
end

local function DrawTextLink(label, url)
    ImGui.PushStyleColor(ImGuiCol.Text, ImGui.GetStyleColor(ImGuiCol.ButtonHovered))
    ImGui.Text(label)
    ImGui.PopStyleColor()

    if ImGui.IsItemHovered() then
        if ImGui.IsMouseClicked(ImGuiMouseButton.Left) then
            os.execute(('start "" "%s"'):format(url))
        end
        -- AddUnderline(ImGui.GetStyleColor(ImGuiCol.ButtonHovered))
        ImGui.BeginTooltip()
        ImGui.Text('%s', url)
        ImGui.EndTooltip()
    -- else
    --     AddUnderline(ImGui.GetStyleColor(ImGuiCol.Button))
    end
end

local function bisGUI()
    ImGui.SetNextWindowSize(ImVec2(800,500), ImGuiCond.FirstUseEver)
    openGUI, shouldDrawGUI = ImGui.Begin('BIS Check ('.. version ..')###BIS Check', openGUI, ImGuiWindowFlags.HorizontalScrollbar)
    if shouldDrawGUI then
        if ImGui.BeginTabBar('bistabs') then
            if ImGui.BeginTabItem('Gear') then
                local origSelectedItemList = selectedItemList
                ImGui.PushItemWidth(150)
                ImGui.SetNextWindowSize(150, 213)
                selectedItemList = ImGui.Combo('Item List', selectedItemList, 'Anguish\0Dreadspire\0FUKU\0HC Items\0Hand Aug\0Pre-Anguish\0Quest Items\0Sebilis\0Veksar\0Vendor Items\0')
                ImGui.PopItemWidth()
                itemList = bisConfig[itemLists[selectedItemList]]
                local slots = itemList.Main.Slots
                if selectedItemList ~= origSelectedItemList then
                    selectionChanged = true
                    filter = ''
                    showmissingonly = false
                end
                ImGui.SameLine()
                if ImGui.Button('Refresh') then selectionChanged = true end
                ImGui.SameLine()
                ImGui.PushItemWidth(300)
                local tmpFilter = ImGui.InputTextWithHint('##filter', 'Search...', filter)
                ImGui.PopItemWidth()
                ImGui.SameLine()
                showslots = ImGui.Checkbox('Show Slots', showslots)
                ImGui.SameLine()
                local tmpshowmissingonly = ImGui.Checkbox('Show Missing Only', showmissingonly)
                if tmpshowmissingonly ~= showmissingonly or tmpFilter ~= filter then
                    filter = tmpFilter
                    showmissingonly = tmpshowmissingonly
                    filterGear(slots)
                end
                if filter ~= '' or showmissingonly then useFilter = true else useFilter = false end

                ImGui.SameLine()
                ImGui.PushItemWidth(90)
                local tempBroadcast = ImGui.Combo('Show characters', selectedBroadcast, 'All Online\0All Offline\0Group\0Custom\0')
                if tempBroadcast ~= selectedBroadcast then
                    changeBroadcastMode(tempBroadcast)
                end
                ImGui.PopItemWidth()
                ImGui.SameLine()
                ImGui.PushItemWidth(150)
                if ImGui.BeginCombo('##Characters', 'Characters') then
                    for i,char in ipairs(group) do
                        local tmpShow = ImGui.Checkbox(char.Name, char.Show or false)
                        if tmpShow ~= char.Show then char.Show = tmpShow selectedBroadcast = 4 end
                    end
                    ImGui.EndCombo()
                end
                ImGui.PopItemWidth()

                local numColumns = 1
                for _,char in ipairs(group) do if char.Show then numColumns = numColumns + 1 end end
                if next(itemChecks) ~= nil then
                    ImGui.Separator()
                    if ImGui.Button('X##LinkedItems') then
                        itemChecks = {}
                    end
                    ImGui.SameLine()
                    ImGui.Text('Linked items:')
                    ImGui.BeginTable('linked items', numColumns)
                    ImGui.TableSetupScrollFreeze(0, 1)
                    ImGui.TableSetupColumn('ItemName', bit32.bor(ImGuiTableColumnFlags.NoSort, ImGuiTableColumnFlags.WidthFixed),
                        160, 0)
                    for i,char in ipairs(group) do
                        if char.Show then
                            ImGui.TableSetupColumn(char.Name, bit32.bor(ImGuiTableColumnFlags.NoSort, ImGuiTableColumnFlags.WidthFixed), -1.0, 0)
                        end
                    end
                    ImGui.TableHeadersRow()

                    for itemName, _ in pairs(itemChecks) do
                        ImGui.TableNextRow()
                        ImGui.TableSetColumnIndex(0)
                        if ImGui.Button('X##' .. itemName) then
                            itemChecks[itemName] = nil
                        end
                        ImGui.SameLine()
                        ImGui.Text(itemName)
                        if itemChecks[itemName] then
                            for _,char in ipairs(group) do
                                if char.Show then
                                    ImGui.TableNextColumn()
                                    if itemChecks[itemName][char.Name] ~= nil then
                                        local hasItem = itemChecks[itemName][char.Name]
                                        ImGui.PushStyleColor(ImGuiCol.Text, hasItem and 0 or 1, hasItem and 1 or 0, 0.1, 1)
                                        ImGui.Text(hasItem and 'HAVE' or 'NEED')
                                        ImGui.PopStyleColor()
                                    end
                                end
                            end
                        end
                    end
                    ImGui.EndTable()
                end

                if ImGui.BeginTable('gear', numColumns, bit32.bor(ImGuiTableFlags.BordersInner, ImGuiTableFlags.RowBg, ImGuiTableFlags.Reorderable, ImGuiTableFlags.NoSavedSettings, ImGuiTableFlags.ScrollX, ImGuiTableFlags.ScrollY)) then
                    ImGui.TableSetupScrollFreeze(0, 1)
                    ImGui.TableSetupColumn('Item', bit32.bor(ImGuiTableColumnFlags.NoSort, ImGuiTableColumnFlags.WidthFixed), -1.0, 0)
                    for i,char in ipairs(group) do
                        if char.Show then
                            ImGui.TableSetupColumn(char.Name, bit32.bor(ImGuiTableColumnFlags.NoSort, ImGuiTableColumnFlags.WidthFixed), -1.0, 0)
                        end
                    end
                    ImGui.TableHeadersRow()

                    local tmpSlots = slots
                    local tmpGear = gear
                    if useFilter then tmpSlots = filteredSlots tmpGear = filteredGear end
                    if tmpSlots then
                        for _,category in ipairs(tmpSlots) do
                            local catName = category.Name
                            ImGui.TableNextRow()
                            ImGui.TableNextColumn()
                            if ImGui.TreeNodeEx(catName, bit32.bor(ImGuiTreeNodeFlags.SpanFullWidth, ImGuiTreeNodeFlags.DefaultOpen)) then
                                local catSlots = category.Slots
                                for _,slot in ipairs(catSlots) do
                                    slotRow(slot, tmpGear)
                                    if slot == 'Wrists' then
                                        slotRow('Wrists2', tmpGear)
                                    end
                                end
                                ImGui.TreePop()
                            end
                            if catName == 'Gear' and itemLists[selectedItemList] == 'questitems' then
                                ImGui.TableNextRow()
                                ImGui.TableNextColumn()
                                if ImGui.TreeNodeEx('Tradeskills', bit32.bor(ImGuiTreeNodeFlags.SpanFullWidth, ImGuiTreeNodeFlags.DefaultOpen)) then
                                    for _,name in ipairs(orderedSkills) do
                                        ImGui.TableNextRow()
                                        ImGui.TableNextColumn()
                                        ImGui.Text(name)
                                        for _,char in ipairs(group) do
                                            if not char.Offline or char.Show then
                                                ImGui.TableNextColumn()
                                                local skill = tradeskills[char.Name] and tradeskills[char.Name][name] or 0
                                                ImGui.TextColored(skill < 300 and 1 or 0, skill == 300 and 1 or 0, 0, 1, '%s', tradeskills[char.Name] and tradeskills[char.Name][name])
                                            end
                                        end
                                    end
                                    ImGui.TreePop()
                                end
                                -- if ImGui.TreeNodeEx('LDON', bit32.bor(ImGuiTreeNodeFlags.SpanFullWidth, ImGuiTreeNodeFlags.DefaultOpen)) then
                                --     for _,ldon in ipairs(orderedLDONs) do
                                --         ImGui.TableNextRow()
                                --         ImGui.TableNextColumn()
                                --         ImGui.Text(ldon.name)
                                --         for _,char in ipairs(group) do
                                --             ImGui.TableNextColumn()
                                --             local count = ldons[char.Name] and ldons[char.Name][ldon.name] or 0
                                --             ImGui.TextColored(count < ldon.num and 1 or 0, count == ldon.num and 1 or 0, 0, 1, '%s', ldons[char.Name] and ldons[char.Name][ldon.name])
                                --         end
                                --     end
                                --     ImGui.TreePop()
                                -- end
                            end
                        end
                    end

                    ImGui.EndTable()
                end

                ImGui.EndTabItem()
            end
            if ImGui.BeginTabItem('Priority') then
                ImGui.Text(bisConfig.Info.VisiblePriority)
                ImGui.EndTabItem()
            end
            if ImGui.BeginTabItem('Anguish Focus Effects') then
                ImGui.Text(bisConfig.Info.AnguishFocusEffects)
                ImGui.EndTabItem()
            end
            if ImGui.BeginTabItem('Links') then
                for _,link in ipairs(bisConfig.Links) do
                    DrawTextLink(link.label, link.url)
                end
            end
            ImGui.EndTabBar()
        end
    end
    ImGui.End()
    if not openGUI then
        mq.cmdf('%s /lua stop %s', broadcast, SCRIPT_NAME)
        mq.exit()
    end
end

printf('Script called with %d arguments:', #args)
for i, arg in ipairs(args) do
    printf('args[%d]: %s', i, arg)
end

if args[1] == 'debug' or args[2] == 'debug' then debug = true end
if args[1] == '0' then
    mq.delay(100)
    actor:send({id='hello',Name=mq.TLO.Me(),Class=mq.TLO.Me.Class.Name()})
    while true do
        mq.delay(1000)
    end
end

local char = {
    ['Name'] = mq.TLO.Me(),
    ['Class'] = mq.TLO.Me.Class.Name(),
    ['Offline'] = false,
    ['Show'] = true,
}
group[char.Name] = char
table.insert(group, char)

mq.cmdf('%s /lua stop %s', broadcast, SCRIPT_NAME)
mq.delay(500)
mq.cmdf('%s /lua run %s 0%s', broadcast, SCRIPT_NAME, debug and ' debug' or '')
mq.delay(500)

local function searchAll()
    for _, char in ipairs(group) do
        actor:send({character=char.Name}, {id='search', list=itemLists[selectedItemList]})
    end
    for _, char in ipairs(group) do
        actor:send({character=char.Name}, {id='tsquery'})
    end
end

local function sayCallback(line, char, message)
    if itemList == nil or group == nil or gear == nil then
        print('g ' .. #group .. ' gear ' .. #gear)
        return
    end
    if string.find(message, 'Burns') then
        return
    end
    for _, char in ipairs(group) do
        for _,list in ipairs(itemLists) do
            local classItems = bisConfig[list][char.Class]
            local templateItems = bisConfig[list].Template
            for _,itembucket in ipairs({templateItems,classItems}) do
                for slot,item in pairs(itembucket) do
                    if item then
                        for itemName in split(item, '/') do
                            if string.find(message, itemName) then
                                local hasItem = gear[char.Name][slot] ~= nil and gear[char.Name][slot].count > 0
                                itemChecks[itemName] = itemChecks[itemName] or {}
                                itemChecks[itemName][char.Name] = hasItem
                            end
                        end
                    end
                end
            end
        end
    end
end

mq.event('meSayItems', 'You say, #2#', sayCallback)
mq.event('sayItems', '#1# says, #2#', sayCallback)
mq.event('rsayItems', '#1# tells the raid, #2#', sayCallback)
mq.event('rMeSayItems', 'You tell your raid, #2#', sayCallback)
mq.event('gsayItems', '#1# tells the group, #2#', sayCallback)
mq.event('gMeSayItems', 'You tell your party, #2#', sayCallback)

mq.imgui.init('BISCheck', bisGUI)

while not terminate do
    mq.delay(1000)
    if rebroadcast then
        gear = {}
        group = {}
        itemChecks = {}
        tradeskills = {}

        group[char.Name] = char
        table.insert(group, char)

        mq.delay(500)
        mq.cmdf('%s /lua run %s 0%s', broadcast, SCRIPT_NAME, debug and ' debug' or '')
        mq.delay(500)
        selectionChanged = true
        rebroadcast = false
    end
    if selectionChanged then selectionChanged = false searchAll() loadInv(itemLists[selectedItemList]) end
    mq.doevents()
end