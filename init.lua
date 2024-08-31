--[[
Best In Slot - Project Lazarus Edition
aquietone, dlilah, ...

Tracker lua script for all the good stuff to have on Project Lazarus server.
]]
local meta          = {version = '2.4.1', name = string.match(string.gsub(debug.getinfo(1, 'S').short_src, '\\init.lua', ''), "[^\\]+$")}
local mq            = require('mq')
local ImGui         = require('ImGui')
local bisConfig     = require('bis')
local PackageMan    = require('mq/PackageMan')
local sql           = PackageMan.Require('lsqlite3')
local dbpath        = string.format('%s\\%s', mq.TLO.MacroQuest.Path('resources')(), 'lazbis.db')
local ok, actors    = pcall(require, 'actors')
if not ok then
    printf('Your version of MacroQuest does not support Lua Actors, exiting.')
    mq.exit()
end

-- UI States
local openGUI       = true
local shouldDrawGUI = true

-- Character info storage
local gear          = {}
local group         = {}
local sortedGroup   = {}
local itemChecks    = {}
local tradeskills   = {}

-- Item list information
local selectedItemList  = bisConfig.ItemLists[bisConfig.ItemLists.DefaultItemList.index]
local itemList          = bisConfig.sebilis
local selectionChanged  = true
local settings          = {ShowSlots=true,ShowMissingOnly=false,AnnounceNeeds=false,AnnounceChannel='Group'}
local orderedSkills     = {'Baking', 'Blacksmithing', 'Brewing', 'Fletching', 'Jewelry Making', 'Pottery', 'Tailoring'}
local recipeQuestIdx    = 1
local ingredientsArray  = {}
local reapplyFilter     = false

local debug         = false

local server        = mq.TLO.EverQuest.Server()
local dbfmt         = "INSERT INTO Inventory VALUES ('%s','%s','%s','%s','%s','%s',%d,%d,'%s');\n"
local db
local actor

-- Default to e3bca if mq2mono is loaded, else use dannet
local broadcast     = '/e3bca'
local selectedBroadcast = 1
local rebroadcast   = false
if not mq.TLO.Plugin('mq2mono')() then broadcast = '/dge' end

local function split(str, char)
    return string.gmatch(str, '[^' .. char .. ']+')
end

local function addCharacter(name, class, offline, show, msg)
    if not group[name] then
        if debug then printf('Add character: Name=%s Class=%s Offline=%s Show=%s, Msg=%s', name, class, offline, show, msg) end
        local char = {Name=name, Class=class, Offline=offline, Show=show}
        group[name] = char
        table.insert(group, char)
        table.insert(sortedGroup, char.Name)
        table.sort(sortedGroup, function(a,b) return a < b end)
        if msg then
            selectionChanged = true
            msg:send({id='hello',Name=mq.TLO.Me(),Class=mq.TLO.Me.Class.Name()})
        end
    elseif msg and group[name].Offline then
        if debug then printf('Add character: Name=%s Class=%s Offline=%s Show=%s, Msg=%s', name, class, offline, show, msg) end
        group[name].Offline = false
        if selectedBroadcast == 1 or (selectedBroadcast == 3 and mq.TLO.Group.Member(name)()) then
            group[name].Show = true
        end
    end
end

local function simpleExec(stmt)
    repeat
        local result = db:exec(stmt)
        if result ~= 0 then printf('Result: %s', result) end
        if result == sql.BUSY then print('\arDatebase was busy!') mq.delay(math.random(10,50)) end
    until result ~= sql.BUSY
end

local function initTables()
    local foundInventory = false
    local foundSettings = false
    local function versioncallback(udata,cols,values,names)
        for i=1,cols do
            if values[i] == 'Inventory' then
                foundInventory = true
            elseif values[i] == 'Settings' then
                foundSettings = true
            end
        end
        return 0
    end
    repeat
        local result = db:exec([[SELECT name FROM sqlite_master WHERE type='table';]], versioncallback)
        if result == sql.BUSY then print('\arDatabase was busy!') mq.delay(math.random(10,50)) end
    until result ~= sql.BUSY

    if not foundInventory then
        simpleExec([[CREATE TABLE IF NOT EXISTS Inventory (Character TEXT NOT NULL, Class TEXT NOT NULL, Server TEXT NOT NULL, Slot TEXT NOT NULL, ItemName TEXT NOT NULL, Location TEXT NOT NULL, Count INTEGER NOT NULL, ComponentCount INTEGER NOT NULL, Category TEXT NOT NULL)]])
    end
    simpleExec([[DROP TABLE IF EXISTS Info]])
    if not foundSettings then
        simpleExec([[CREATE TABLE IF NOT EXISTS Settings (Key TEXT UNIQUE NOT NULL, Value TEXT NOT NULL)]])
    end
    -- check version and handle any migrations, none atm
    simpleExec(("INSERT INTO Settings VALUES ('Version', '%s') ON CONFLICT(Key) DO UPDATE SET Value = '%s'"):format(meta.version, meta.version))
end

local function settingsRowCallback(udata,cols,values,names)
    local value = values[2]
    if value == 'true' then value = true
    elseif value == 'false' then value = false
    elseif tonumber(value) then value = tonumber(value) end
    settings[values[1]] = value
    return 0
end

local function initSettings()
    repeat
        local result = db:exec("SELECT * FROM Settings WHERE Key != 'Version'", settingsRowCallback)
        if result == sql.BUSY then print('\arDatabase was busy!') mq.delay(math.random(10,50)) end
    until result ~= sql.BUSY
end

local function initDB()
    db = sql.open(dbpath)
    if db then
        db:exec("PRAGMA journal_mode=WAL;")
        initTables()
        initSettings()
    end
end

local function exec(stmt, name, category, action)
    for i=1,10 do
        local wrappedStmt = ('BEGIN TRANSACTION;%s;COMMIT;'):format(stmt)
        if debug then printf('Exec: %s', wrappedStmt) end
        local result = db:exec(wrappedStmt)
        if result == sql.BUSY then
            print('\arDatabase was Busy!') mq.delay(math.random(100,1000))
        elseif result ~= sql.OK then
            printf('\ar%s failed for name: %s, category: %s, result: %s\n%s', action, name, category, result, wrappedStmt)
        elseif result == sql.OK then
            if debug then printf('Successfully %s for name: %s, category: %s', action, name, category) end
            break
        end
    end
end

local function clearAllDataForCharacter(name)
    local deleteStmt = ("DELETE FROM Inventory WHERE Character = '%s' AND Server = '%s'"):format(name, server)
    exec(deleteStmt, name, nil, 'deleted')
end

local function clearCategoryDataForCharacter(name, category)
    local deleteStmt = ("DELETE FROM Inventory WHERE Character = '%s' AND Server = '%s' AND Category = '%s'"):format(name, server, category)
    exec(deleteStmt, name, category, 'deleted')
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

local function buildInsertStmt(name, category)
    local stmt = "\n"
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
    return stmt
end

local function insertCharacterDataForCategory(name, category)
    local insertStmt = buildInsertStmt(name, category)
    exec(insertStmt, name, category, 'inserted')
end

local function rowCallback(udata,cols,values,names)
    if group[values[1]] and not group[values[1]].Offline then return 0 end
    addCharacter(values[1], values[2], true, false)
    gear[values[1]] = gear[values[1]] or {}
    gear[values[1]][values[4]] = {count=tonumber(values[7]), componentcount=tonumber(values[8]), actualname=values[6] and values[5], location=values[6]}
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
    reapplyFilter = true
end

local foundItem = nil
local function singleRowCallback(udata,cols,values,names)
    foundItem = {Character=values[1], Count=tonumber(values[7]), ItemName=values[6] and values[5], ComponentCount=tonumber(values[8])}
end
local function loadSingleRow(category, charName, itemName)
    for _,char in ipairs(group) do
        if char.Offline then gear[char.Name] = {} end
    end
    repeat
        local result = db:exec(string.format("SELECT * FROM Inventory WHERE Category='%s' AND Server = '%s' AND Character = '%s' AND ItemName = '%s';", category, server, charName, itemName:gsub('\'','\'\'')), singleRowCallback)
        if result == sql.BUSY then print('\arDatabase was busy!') mq.delay(math.random(10,50)) end
    until result ~= sql.BUSY
end

local function dumpInv(name, category)
    clearCategoryDataForCharacter(name, category)

    insertCharacterDataForCategory(name, category)
end

local function searchItemsInList(list)
    local classItems = bisConfig[list][mq.TLO.Me.Class.Name()]
    local templateItems = bisConfig[list].Template
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
                componentResult = mq.TLO.FindItemCount(compItem)() + mq.TLO.FindItemBankCount(compItem)()
                currentSlot = mq.TLO.FindItem(compItem).ItemSlot() or (mq.TLO.FindItemBank(compItem)() and 'Bank') or ''
            end
            results[slot] = {count=currentResult, invslot=currentSlot, componentcount=componentResult>0 and componentResult or nil, actualname=actualName}
        end
    end
    return results
end

-- Actor message handler
local function actorCallback(msg)
    local content = msg()
    if debug then printf('<<< MSG RCVD: id=%s', content.id) end
    if content.id == 'hello' then
        if debug then printf('=== MSG: id=%s Name=%s Class=%s', content.id, content.Name, content.Class) end
        if not openGUI then return end
        addCharacter(content.Name, content.Class, false, true, msg)
    elseif content.id == 'search' then
        if debug then printf('=== MSG: id=%s list=%s', content.id, content.list) end
        -- {id='search', list='dsk'}
        local results = searchItemsInList(content.list)
        if debug then printf('>>> SEND MSG: id=%s Name=%s list=%s class=%s', content.id, mq.TLO.Me.CleanName(), content.list, mq.TLO.Me.Class.Name()) end
        msg:send({id='result', Name=mq.TLO.Me.CleanName(), list=content.list, class=mq.TLO.Me.Class.Name(), results=results})
    elseif content.id == 'result' then
        if debug then printf('=== MSG: id=%s Name=%s list=%s class=%s', content.id, content.Name, content.list, content.class) end
        if not openGUI then return end
        -- {id='result', Name='name', list='dsk', class='Warrior', results={slot1=1, slot2=0}}
        local results = content.results
        if results == nil then return end
        local char = group[content.Name]
        gear[char.Name] = {}
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
        reapplyFilter = true
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
        if debug then printf('>>> SEND MSG: id=%s Name=%s Skills=%s', content.id, mq.TLO.Me.CleanName(), skills) end
        msg:send({id='tsresult', Skills=skills, Name=mq.TLO.Me.CleanName()})
    elseif content.id == 'tsresult' then
        if debug then printf('=== MSG: id=%s Name=%s Skills=%s', content.id, content.Name, content.Skills) end
        if not openGUI then return end
        local char = group[content.Name]
        tradeskills[char.Name] = tradeskills[char.Name] or {}
        for name,skill in pairs(content.Skills) do
            tradeskills[char.Name][name] = skill
        end
    end
end

local function changeBroadcastMode(tempBroadcast)
    local origBroadcast = broadcast

    local bChanged = false
    if not mq.TLO.Plugin('mq2mono')() then
        if tempBroadcast == 3 and broadcast ~= '/dgge' then
            broadcast = '/dgge'
            bChanged = true
        elseif broadcast ~= '/dge' then
            broadcast = '/dge'
            bChanged = true
        end
    else
        if tempBroadcast == 3 and broadcast ~= '/e3bcg' then
            broadcast = '/e3bcg'
            bChanged = true
        elseif broadcast ~= '/e3bca' then
            broadcast = '/e3bca'
            bChanged = true
        end
    end
    if tempBroadcast == 1 or tempBroadcast == 3 then
        -- remove offline toons
        for _,char in ipairs(group) do
            if char.Offline or (tempBroadcast == 3 and not mq.TLO.Group.Member(char.Name)()) then
                char.Show = false
            elseif tempBroadcast == 1 or (tempBroadcast == 3 and mq.TLO.Group.Member(char.Name)()) then
                char.Show = true
            end
        end
    elseif tempBroadcast == 2 then
        -- add offline toons
        for _,char in ipairs(group) do
            char.Show = true
        end
    end
    if bChanged then
        rebroadcast = true
        mq.cmdf('%s /lua stop %s', origBroadcast, meta.name)
    end
    selectedBroadcast = tempBroadcast
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
                        ImGui.Text('%s%s%s', itemName, settings.ShowSlots and resolvedInvSlot or '', lootDropper and ' ('..lootDropper..')' or '')
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
                        if (itemName ~= nil) and itemName:lower():find(lowerFilter) and (not settings.ShowMissingOnly or gear[char.Name][slot].count == 0) then
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

local ingredientFilter = ''
local filteredIngredients = {}
local useIngredientFilter = false
local function filterIngredients()
    filteredIngredients = {}
    for _,ingredient in pairs(ingredientsArray) do
        if ingredient.Name:lower():find(ingredientFilter:lower()) then
            table.insert(filteredIngredients, ingredient)
        end
    end
end

local function DrawTextLink(label, url)
    ImGui.PushStyleColor(ImGuiCol.Text, ImGui.GetStyleColor(ImGuiCol.ButtonHovered))
    ImGui.Text(label)
    ImGui.PopStyleColor()

    if ImGui.IsItemHovered() then
        if ImGui.IsMouseClicked(ImGuiMouseButton.Left) then
            os.execute(('start "" "%s"'):format(url))
        end
        ImGui.BeginTooltip()
        ImGui.Text('%s', url)
        ImGui.EndTooltip()
    end
end

local ColumnID_Name = 1
local ColumnID_Location = 2
local current_sort_specs = nil
local function CompareWithSortSpecs(a, b)
    for n = 1, current_sort_specs.SpecsCount, 1 do
        local sort_spec = current_sort_specs:Specs(n)
        local delta = 0

        local sortA = a
        local sortB = b
        if sort_spec.ColumnUserID == ColumnID_Name then
            sortA = a.Name
            sortB = b.Name
        elseif sort_spec.ColumnUserID == ColumnID_Location then
            sortA = a.Location
            sortB = b.Location
        end
        if sortA < sortB then
            delta = -1
        elseif sortB < sortA then
            delta = 1
        else
            delta = 0
        end

        if delta ~= 0 then
            if sort_spec.SortDirection == ImGuiSortDirection.Ascending then
                return delta < 0
            end
            return delta > 0
        end
    end

    -- Always return a way to differentiate items.
    return a.Name < b.Name
end

local function updateSetting(name, value)
    settings[name] = value
    simpleExec(("INSERT INTO Settings VALUES ('%s', '%s') ON CONFLICT(Key) DO UPDATE SET Value = '%s'"):format(name, value, value))
end

local function getAnnounceChannel()
    if settings.AnnounceChannel == 'Raid' then
        if mq.TLO.Raid.Members() > 0 then return '/rs ' else return '/g ' end
    elseif settings.AnnounceChannel == 'Group' then
        return '/g '
    elseif settings.AnnounceChannel == 'Guild' then
        return '/gu '
    elseif settings.AnnounceChannel == 'Say' then
        return '/say '
    end
end

local function VerticalSeparator()
    ImGui.PushStyleColor(ImGuiCol.Button, 0, 0.2, 0.4, 1)
    ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0, 0.2, 0.4, 1)
    ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0, 0.2, 0.4, 1)
    ImGui.Button('##separator', 3, 0)
    ImGui.PopStyleColor(3)
end

local classes = {Bard='BRD',Beastlord='BST',Berserker='BER',Cleric='CLR',Druid='DRU',Enchanter='ENC',Magician='MAG',Monk='MNK',Necromancer='NEC',Paladin='PAL',Ranger='RNG',Rogue='ROG',['Shadow Knight']='SHD',Shaman='SHM',Warrior='WAR',Wizard='WIZ'}
local function bisGUI()
    ImGui.SetNextWindowSize(ImVec2(800,500), ImGuiCond.FirstUseEver)
    openGUI, shouldDrawGUI = ImGui.Begin('BIS Check ('.. meta.version ..')###BIS Check', openGUI, ImGuiWindowFlags.HorizontalScrollbar)
    if shouldDrawGUI then
        ImGui.PushStyleVar(ImGuiStyleVar.ScrollbarSize, 17)
        if ImGui.BeginTabBar('bistabs') then
            if ImGui.BeginTabItem('Gear') then
                local origSelectedItemList = selectedItemList
                ImGui.PushItemWidth(150)
                ImGui.SetNextWindowSize(150, 213)
                if ImGui.BeginCombo('Item List', selectedItemList.name) then
                    for i,list in ipairs(bisConfig.ItemLists) do
                        if ImGui.Selectable(list.name, selectedItemList.id == list.id) then selectedItemList = list end
                    end
                    ImGui.EndCombo()
                end
                ImGui.PopItemWidth()
                itemList = bisConfig[selectedItemList.id]
                local slots = itemList.Main.Slots
                if selectedItemList.id ~= origSelectedItemList.id then
                    selectionChanged = true
                    filter = ''
                    settings.ShowMissingOnly = false
                end
                ImGui.SameLine()
                if ImGui.Button('Refresh') then selectionChanged = true end
                ImGui.SameLine()
                ImGui.PushItemWidth(300)
                local tmpFilter = ImGui.InputTextWithHint('##filter', 'Search...', filter)
                ImGui.PopItemWidth()
                ImGui.SameLine()
                ImGui.Text('Show:')
                ImGui.SameLine()
                local tmpShowSlots = ImGui.Checkbox('Slots', settings.ShowSlots)
                if tmpShowSlots ~= settings.ShowSlots then updateSetting('ShowSlots', tmpShowSlots) end
                ImGui.SameLine()
                local tmpShowMissingOnly = ImGui.Checkbox('Missing Only', settings.ShowMissingOnly)
                if tmpShowMissingOnly ~= settings.ShowMissingOnly or tmpFilter ~= filter or reapplyFilter then
                    filter = tmpFilter
                    if tmpShowMissingOnly ~= settings.ShowMissingOnly then updateSetting('ShowMissingOnly', tmpShowMissingOnly) end
                    filterGear(slots)
                    reapplyFilter = false
                end
                if filter ~= '' or settings.ShowMissingOnly then useFilter = true else useFilter = false end
                ImGui.SameLine()
                VerticalSeparator()
                ImGui.SameLine()
                ImGui.Text('Announce:')
                ImGui.SameLine()
                local tmpAnnounceNeeds = ImGui.Checkbox('##AnnounceNeeds', settings.AnnounceNeeds)
                if tmpAnnounceNeeds ~= settings.AnnounceNeeds then updateSetting('AnnounceNeeds', tmpAnnounceNeeds) end
                ImGui.SameLine()
                ImGui.PushItemWidth(90)
                if ImGui.BeginCombo('##Channel', settings.AnnounceChannel) then
                    for i,name in ipairs({'Group','Raid','Guild','Say'}) do
                        local selected = ImGui.Selectable(name, settings.AnnounceChannel == name)
                        if selected and name ~= settings.AnnounceChannel then
                            updateSetting('AnnounceChannel', name)
                        end
                    end
                    ImGui.EndCombo()
                end
                ImGui.PopItemWidth()
                ImGui.SameLine()
                VerticalSeparator()
                ImGui.SameLine()
                ImGui.PushItemWidth(150)
                if ImGui.BeginCombo('##Characters', 'Characters') then
                    local _,pressed = ImGui.Checkbox('All Online', selectedBroadcast == 1)
                    if pressed then changeBroadcastMode(1) end
                    _,pressed = ImGui.Checkbox('All Offline', selectedBroadcast == 2)
                    if pressed then changeBroadcastMode(2) end
                    _,pressed = ImGui.Checkbox('Group', selectedBroadcast == 3)
                    if pressed then changeBroadcastMode(3) end
                    for i,name in ipairs(sortedGroup) do
                        local char = group[name]
                        _,pressed = ImGui.Checkbox(char.Name, char.Show or false)
                        if pressed then
                            char.Show = not char.Show
                            changeBroadcastMode(4)
                        end
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
                    ImGui.BeginTable('linked items', numColumns, bit32.bor(ImGuiTableFlags.NoSavedSettings, ImGuiTableFlags.ScrollX, ImGuiTableFlags.ScrollY), -1.0, 115)
                    ImGui.TableSetupScrollFreeze(0, 1)
                    ImGui.TableSetupColumn('ItemName', bit32.bor(ImGuiTableColumnFlags.NoSort, ImGuiTableColumnFlags.WidthFixed), 250, 0)
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
                        if ImGui.Button('Announce##'..itemName) then
                            local message = getAnnounceChannel()
                            local doSend = false
                            message = message .. itemName .. ' - '
                            for _,name in ipairs(sortedGroup) do
                                local char = group[name]
                                if itemChecks[itemName][char.Name] == false then
                                    -- message = message .. string.format('%s(%s)', char.Name, classes[char.Class]) .. ', '
                                    message = message .. char.Name .. ', '
                                    doSend = true
                                end
                            end
                            if doSend then mq.cmd(message) end
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
                            if catName == 'Gear' and selectedItemList.id == 'questitems' then
                                ImGui.TableNextRow()
                                ImGui.TableNextColumn()
                                if ImGui.TreeNodeEx('Tradeskills', bit32.bor(ImGuiTreeNodeFlags.SpanFullWidth, ImGuiTreeNodeFlags.DefaultOpen)) then
                                    for _,name in ipairs(orderedSkills) do
                                        ImGui.TableNextRow()
                                        ImGui.TableNextColumn()
                                        ImGui.Text(name)
                                        for _,char in ipairs(group) do
                                            if char.Show then
                                                ImGui.TableNextColumn()
                                                local skill = tradeskills[char.Name] and tradeskills[char.Name][name] or 0
                                                ImGui.TextColored(skill < 300 and 1 or 0, skill == 300 and 1 or 0, 0, 1, '%s', tradeskills[char.Name] and tradeskills[char.Name][name])
                                            end
                                        end
                                    end
                                    ImGui.TreePop()
                                end
                            end
                        end
                    end
                    ImGui.EndTable()
                end
                ImGui.EndTabItem()
            end
            if bisConfig.StatFoodRecipes and ImGui.BeginTabItem('Stat Food') then
                if ImGui.BeginTabBar('##statfoodtabs') then
                    if ImGui.BeginTabItem('Recipes') then
                        for _,recipe in ipairs(bisConfig.StatFoodRecipes) do
                            ImGui.PushStyleColor(ImGuiCol.Text, 0,1,1,1)
                            local expanded = ImGui.TreeNode(recipe.Name)
                            ImGui.PopStyleColor()
                            if expanded then
                                ImGui.Indent(30)
                                for _,ingredient in ipairs(recipe.Ingredients) do
                                    ImGui.Text('%s%s', ingredient, bisConfig.StatFoodIngredients[ingredient] and ' - '..bisConfig.StatFoodIngredients[ingredient].Location or '')
                                    ImGui.SameLine()
                                    ImGui.TextColored(1,1,0,1,'(%s)', mq.TLO.FindItemCount('='..ingredient))
                                end
                                ImGui.Unindent(30)
                                ImGui.TreePop()
                            end
                        end
                        ImGui.EndTabItem()
                    end
                    if ImGui.BeginTabItem('Quests') then
                        ImGui.PushItemWidth(300)
                        if ImGui.BeginCombo('Quest', bisConfig.StatFoodQuests[recipeQuestIdx].Name) then
                            for i,quest in ipairs(bisConfig.StatFoodQuests) do
                                if ImGui.Selectable(quest.Name, recipeQuestIdx == i) then
                                    recipeQuestIdx = i
                                end
                            end
                            ImGui.EndCombo()
                        end
                        ImGui.PopItemWidth()

                        for _,questStep in ipairs(bisConfig.StatFoodQuests[recipeQuestIdx].Recipes) do
                            ImGui.TextColored(0,1,1,1,questStep.Name)
                            ImGui.Indent(25)
                            for _,step in ipairs(questStep.Steps) do
                                ImGui.Text('\xee\x97\x8c %s', step)
                            end
                            ImGui.Unindent(25)
                        end
                        ImGui.EndTabItem()
                    end
                    if ImGui.BeginTabItem('Ingredients') then
                        ImGui.SameLine()
                        ImGui.PushItemWidth(300)
                        local tmpIngredientFilter = ImGui.InputTextWithHint('##ingredientfilter', 'Search...', ingredientFilter)
                        ImGui.PopItemWidth()
                        if tmpIngredientFilter ~= ingredientFilter then
                            ingredientFilter = tmpIngredientFilter
                            filterIngredients()
                        end
                        if ingredientFilter ~= '' then useIngredientFilter = true else useIngredientFilter = false end
                        local tmpIngredients = ingredientsArray
                        if useIngredientFilter then tmpIngredients = filteredIngredients end

                        if ImGui.BeginTable('Ingredients', 3, bit32.bor(ImGuiTableFlags.BordersInner, ImGuiTableFlags.RowBg, ImGuiTableFlags.Reorderable, ImGuiTableFlags.NoSavedSettings, ImGuiTableFlags.ScrollX, ImGuiTableFlags.ScrollY, ImGuiTableFlags.Sortable)) then
                            ImGui.TableSetupScrollFreeze(0, 1)
                            ImGui.TableSetupColumn('Ingredient', bit32.bor(ImGuiTableColumnFlags.DefaultSort, ImGuiTableColumnFlags.WidthFixed), -1.0, ColumnID_Name)
                            ImGui.TableSetupColumn('Location', bit32.bor(ImGuiTableColumnFlags.WidthFixed), -1.0, ColumnID_Location)
                            ImGui.TableSetupColumn('Count', bit32.bor(ImGuiTableColumnFlags.NoSort, ImGuiTableColumnFlags.WidthFixed), -1.0, 0)
                            ImGui.TableHeadersRow()

                            local sort_specs = ImGui.TableGetSortSpecs()
                            if sort_specs then
                                if sort_specs.SpecsDirty then
                                    current_sort_specs = sort_specs
                                    table.sort(tmpIngredients, CompareWithSortSpecs)
                                    current_sort_specs = nil
                                    sort_specs.SpecsDirty = false
                                end
                            end

                            for _,ingredient in ipairs(tmpIngredients) do
                                ImGui.TableNextRow()
                                ImGui.TableNextColumn()
                                ImGui.Text(ingredient.Name)
                                ImGui.TableNextColumn()
                                ImGui.Text(ingredient.Location)
                                ImGui.TableNextColumn()
                                ImGui.Text('%s', mq.TLO.FindItemCount('='..ingredient.Name)())
                            end
                            ImGui.EndTable()
                        end
                        ImGui.EndTabItem()
                    end
                    ImGui.EndTabBar()
                end
                ImGui.EndTabItem()
            end
            for _,infoTab in ipairs(bisConfig.Info) do
                if ImGui.BeginTabItem(infoTab.Name) then
                    ImGui.Text(infoTab.Text)
                    ImGui.EndTabItem()
                end
            end
            if ImGui.BeginTabItem('Links') then
                for _,link in ipairs(bisConfig.Links) do
                    DrawTextLink(link.label, link.url)
                end
            end
            ImGui.EndTabBar()
        end
        ImGui.PopStyleVar()
    end
    ImGui.End()
    if not openGUI then
        mq.cmdf('%s /lua stop %s', broadcast, meta.name)
        mq.exit()
    end
end

local function searchAll()
    for _, char in ipairs(group) do
        actor:send({character=char.Name}, {id='search', list=selectedItemList.id})
    end
    for _, char in ipairs(group) do
        actor:send({character=char.Name}, {id='tsquery'})
    end
end

local recentlyAnnounced = {}
local function sayCallback(line, char, message)
    if itemList == nil or group == nil or gear == nil then
        print('g ' .. #group .. ' gear ' .. #gear)
        return
    end
    if string.find(message, 'Burns') then
        return
    end
    local currentZone = mq.TLO.Zone.ShortName()
    local currentZoneList = bisConfig.ZoneMap[currentZone] and bisConfig.ItemLists[bisConfig.ZoneMap[currentZone].index]
    local scanLists = currentZoneList and {currentZoneList} or bisConfig.ItemLists

    local messages = {}
    for _,list in ipairs(scanLists) do
        for _, name in ipairs(sortedGroup) do
            local char = group[name]
            if char.Show then
                local classItems = bisConfig[list.id][char.Class]
                local templateItems = bisConfig[list.id].Template
                local visibleItems = bisConfig[list.id].Visible
                for _,itembucket in ipairs({classItems,templateItems,visibleItems}) do
                    for slot,item in pairs(itembucket) do
                        if item then
                            for itemName in split(item, '/') do
                                if string.find(message, itemName) then
                                    local hasItem = gear[char.Name][slot] ~= nil and (gear[char.Name][slot].count > 0 or (gear[char.Name][slot].componentcount or 0) > 0)
                                    if not hasItem and list.id ~= selectedItemList.id then
                                        loadSingleRow(list.id, char.Name, itemName)
                                        if foundItem and (foundItem.Count > 0 or (foundItem.ComponentCount or 0) > 0) then hasItem = true end
                                        foundItem = nil
                                    end
                                    itemChecks[itemName] = itemChecks[itemName] or {}
                                    itemChecks[itemName][char.Name] = hasItem
                                    if not hasItem then
                                        messages[itemName] = messages[itemName] or itemName .. ' - '
                                        -- messages[itemName] = messages[itemName] .. string.format('%s(%s)', char.Name, classes[char.Class]) .. ', '
                                        messages[itemName] = messages[itemName] .. char.Name .. ', '
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    if settings.AnnounceNeeds then
        for itemName,msg in pairs(messages) do
            if not recentlyAnnounced[itemName] or mq.gettime() - recentlyAnnounced[itemName] > 30000 then
                local prefix = getAnnounceChannel()
                mq.cmdf('%s%s', prefix, msg)
                recentlyAnnounced[itemName] = mq.gettime()
            end
        end
    end
end

local function lootedCallback(line, who, item)
    if who == 'You' then who = mq.TLO.Me.CleanName() end
    if not group[who] then return end
    local char = group[who]
    local currentZone = mq.TLO.Zone.ShortName()
    local listToScan = bisConfig.ZoneMap[currentZone] and bisConfig.ItemLists[bisConfig.ZoneMap[currentZone].index]
    if not listToScan then return end

    local classItems = bisConfig[listToScan.id][char.Class]
    local templateItems = bisConfig[listToScan.id].Template
    local visibleItems = bisConfig[listToScan.id].Visible
    for _,itembucket in ipairs({classItems,templateItems,visibleItems}) do
        for slot,itemLine in pairs(itembucket) do
            for itemName in split(itemLine, '/') do
                if itemName == item then
                    if listToScan.id == selectedItemList.id then
                        gear[char.Name][slot] = gear[char.Name][slot] or {count=0, componentcount=0, actualname=item}
                        if visibleItems[slot] == item then
                            gear[char.Name][slot].componentcount = (gear[char.Name][slot].componentcount or 0) + 1
                        else
                            gear[char.Name][slot].count = (gear[char.Name][slot].count or 0) + 1
                        end
                    end
                    local stmt = dbfmt:format(char.Name,char.Class,server,slot:gsub('\'','\'\''),item:gsub('\'','\'\''),'',gear[char.Name][slot].count or 0,gear[char.Name][slot].componentcount or 0,listToScan.id)
                    exec(stmt, char.Name, listToScan.id, 'inserted')
                end
            end
        end
    end
end

local function writeAllItemLists()
    addCharacter(mq.TLO.Me.CleanName(), mq.TLO.Me.Class.Name(), false, true)
    local insertStmt = ''
    for _,list in ipairs(bisConfig.ItemLists) do
        itemList = bisConfig[list.id]
        gear[mq.TLO.Me.CleanName()] = searchItemsInList(list.id)
        insertStmt = insertStmt .. buildInsertStmt(mq.TLO.Me.CleanName(), list.id)
    end
    clearAllDataForCharacter(mq.TLO.Me.CleanName())
    exec(insertStmt, mq.TLO.Me.CleanName(), nil, 'inserted')
end

local function init(args)
    printf('\ag%s\ax started with \ay%d\ax arguments:', meta.name, #args)
    for i, arg in ipairs(args) do
        printf('args[%d]: %s', i, arg)
    end
    if args[1] == 'debug' or args[2] == 'debug' then debug = true end
    if args[1] ~= '0' then initDB() end
    if args[1] == 'dumpinv' then
        writeAllItemLists()
        openGUI = false
        return
    end
    if args[1] == '0' then openGUI = false end
    actor = actors.register(actorCallback)
    if args[1] == '0' then
        mq.delay(100)
        actor:send({id='hello',Name=mq.TLO.Me(),Class=mq.TLO.Me.Class.Name()})
        while true do
            mq.delay(1000)
        end
    end

    local zone = mq.TLO.Zone.ShortName()
    -- Load item list for specific zone if inside raid instance for that zone
    if bisConfig.ZoneMap[zone] then
        selectedItemList = bisConfig.ItemLists[bisConfig.ZoneMap[zone].index]
        itemList = bisConfig[selectedItemList.id]
    end

    for name,ingredient in pairs(bisConfig.StatFoodIngredients) do
        table.insert(ingredientsArray, {Name=name, Location=ingredient.Location})
    end
    table.sort(ingredientsArray, function(a,b) return a.Name < b.Name end)

    addCharacter(mq.TLO.Me.CleanName(), mq.TLO.Me.Class.Name(), false, true)

    mq.cmdf('%s /lua stop %s', broadcast, meta.name)
    mq.delay(500)
    mq.cmdf('%s /lua run %s 0%s', broadcast, meta.name, debug and ' debug' or '')
    mq.delay(500)

    mq.event('meSayItems', 'You say, #2#', sayCallback)
    mq.event('sayItems', '#1# says, #2#', sayCallback)
    mq.event('rsayItems', '#1# tells the raid, #2#', sayCallback)
    mq.event('rMeSayItems', 'You tell your raid, #2#', sayCallback)
    mq.event('gsayItems', '#1# tells the group, #2#', sayCallback)
    mq.event('gMeSayItems', 'You tell your party, #2#', sayCallback)
    mq.event('otherLootedItem', '#*#--#1# has looted a #2#.--#*#', lootedCallback)
    mq.event('youLootedItem', '#*#--#1# have looted a #2#.--#*#', lootedCallback)

    mq.imgui.init('BISCheck', bisGUI)
end

init({...})
while openGUI do
    mq.delay(1000)
    if rebroadcast then
        gear = {}
        itemChecks = {}
        tradeskills = {}
        for _,c in ipairs(group) do if c.Name ~= mq.TLO.Me.CleanName() then c.Offline = true printf('set %s offline', c.Name) end end

        mq.delay(500)
        mq.cmdf('%s /lua run %s 0%s', broadcast, meta.name, debug and ' debug' or '')
        mq.delay(500)
        selectionChanged = true
        rebroadcast = false
    end
    if selectionChanged then selectionChanged = false searchAll() loadInv(selectedItemList.id) end
    for itemName,lastAnnounced in pairs(recentlyAnnounced) do
        if mq.gettime() - lastAnnounced > 30000 then
            recentlyAnnounced[itemName] = nil
        end
    end
    mq.doevents()
end