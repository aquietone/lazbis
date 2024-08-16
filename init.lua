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

local version = '1.0.0'

local args = { ... }

-- UI States
local openGUI = true
local shouldDrawGUI = true
local terminate = false

-- Character info storage
local gear = {}
local group = {}
local itemChecks = {}
local tradeskills = {}

-- Item list information
local bisConfig = require('bis')
local itemLists = {[1]='anguish',[2]='dsk',[3]='fuku',[4]='hcitems',[5]='jonas',[6]='preanguish',[7]='questitems',[8]='sebilis',[9]='veksar',[10]='vendoritems',}
local selectedItemList = 8
local itemList = bisConfig.sebilis
local selectionChanged = true
local showslots = true
local showmissingonly = false
local orderedSkills = {'Baking', 'Blacksmithing', 'Brewing', 'Fletching', 'Jewelry Making', 'Pottery', 'Tailoring'}

local debug = false

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
            }
            if debug then printf('Add character: Name=%s Class=%s', char.Name, char.Class) end
            group[content.Name] = char
            table.insert(group, char)
            selectionChanged = true
            msg:send({id='hello',Name=mq.TLO.Me(),Class=mq.TLO.Me.Class.Name()})
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
                        local searchString = itemName
                        if not tonumber(itemName) then searchString = '='..searchString end
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
                    if not tonumber(item) then searchString = '='..searchString end
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
        if args[1] == '0' then return end
        local char = group[content.Name]
        tradeskills[char.Name] = tradeskills[char.Name] or {}
        for name,skill in pairs(content.Skills) do
            tradeskills[char.Name][name] = skill
        end
    end
end)

local function changeBroadcastMode(tempBroadcast)
    mq.cmdf('%s /lua stop lazarus_bis', broadcast)

    if not mq.TLO.Plugin('mq2mono')() then
        if tempBroadcast == 1 then
            broadcast = '/dge'
        else
            broadcast = '/dgge'
        end
    else
        if tempBroadcast == 1 then
            broadcast = '/e3bca'
        else
            broadcast = '/e3bcg'
        end
    end
    selectedBroadcast = tempBroadcast
    rebroadcast = true
end

local function getItemColor(slot, count, visibleCount, componentCount)
    if componentCount then
        return { 1, 1, 0 }
    end
    if slot == 'Wrists2' then
        return { count == 2 and 0 or 1, count == 2 and 1 or 0, .1 }
    end
    return { count > 0 and 0 or 1, (count > 0 or visibleCount > 0) and 1 or 0, .1 }
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

local function slotRow(slot, tmpGear)
    local realSlot = slot ~= 'Wrists2' and slot or 'Wrists'
    ImGui.TableNextRow()
    ImGui.TableNextColumn()
    ImGui.Text('' .. slot)
    for _, char in ipairs(group) do
        ImGui.TableNextColumn()
        if (tmpGear[char.Name] ~= nil and tmpGear[char.Name][realSlot] ~= nil) then
            local itemName = itemList[char.Class] and itemList[char.Class][realSlot] or itemList.Template[realSlot]
            if (itemName ~= nil) then
                local actualName = tmpGear[char.Name][realSlot].actualname or itemName
                local count, invslot = tmpGear[char.Name][realSlot].count, tmpGear[char.Name][realSlot].invslot
                local countVis = tmpGear[char.Name].Visible and tmpGear[char.Name].Visible[realSlot] and tmpGear[char.Name].Visible[realSlot].count or 0
                local componentcount = tmpGear[char.Name][realSlot].componentcount
                local color = getItemColor(slot, tonumber(count), tonumber(countVis), tonumber(componentcount))
                ImGui.PushStyleColor(ImGuiCol.Text, color[1], color[2], color[3], 1)
                if string.find(actualName, '/') then
					local items = actualName:match("([^/]+)")
                    local resolvedInvSlot = resolveInvSlot(invslot)
                    local lootDropper = color[2] == 0 and bisConfig.LootDroppers[items]
					ImGui.Text('%s%s%s', items, showslots and resolvedInvSlot or '', lootDropper and ' ('..lootDropper..')' or '')
				else
                    local resolvedInvSlot = resolveInvSlot(invslot)
                    local lootDropper = color[2] == 0 and bisConfig.LootDroppers[actualName]
					ImGui.Text('%s%s%s', actualName, showslots and resolvedInvSlot or '', lootDropper and ' ('..lootDropper..')' or '')
				end
                ImGui.PopStyleColor()
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
                ImGui.SetNextWindowSize(150, 195)
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
                local tempBroadcast = ImGui.Combo('Show characters', selectedBroadcast, 'All\0Group\0')
                if tempBroadcast ~= selectedBroadcast then
                    changeBroadcastMode(tempBroadcast)
                end
                ImGui.PopItemWidth()

                if next(itemChecks) ~= nil then
                    ImGui.Separator()
                    if ImGui.Button('X##LinkedItems') then
                        itemChecks = {}
                    end
                    ImGui.SameLine()
                    ImGui.Text('Linked items:')
                    ImGui.BeginTable('linked items', #group + 1)
                    ImGui.TableSetupScrollFreeze(0, 1)
                    ImGui.TableSetupColumn('ItemName', bit32.bor(ImGuiTableColumnFlags.NoSort, ImGuiTableColumnFlags.WidthFixed),
                        160, 0)
                    for i,char in ipairs(group) do
                        ImGui.TableSetupColumn(char.Name, bit32.bor(ImGuiTableColumnFlags.NoSort, ImGuiTableColumnFlags.WidthFixed), -1.0, 0)
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
                    ImGui.EndTable()
                end

                if ImGui.BeginTable('gear', #group + 1, bit32.bor(ImGuiTableFlags.BordersInner, ImGuiTableFlags.RowBg, ImGuiTableFlags.Reorderable, ImGuiTableFlags.NoSavedSettings, ImGuiTableFlags.ScrollX, ImGuiTableFlags.ScrollY)) then
                    ImGui.TableSetupScrollFreeze(0, 1)
                    ImGui.TableSetupColumn('Item', bit32.bor(ImGuiTableColumnFlags.NoSort, ImGuiTableColumnFlags.WidthFixed), -1.0, 0)
                    for i,char in ipairs(group) do
                        ImGui.TableSetupColumn(char.Name, bit32.bor(ImGuiTableColumnFlags.NoSort, ImGuiTableColumnFlags.WidthFixed), -1.0, 0)
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
                                            ImGui.TableNextColumn()
                                            local skill = tradeskills[char.Name] and tradeskills[char.Name][name] or 0
                                            ImGui.TextColored(skill < 300 and 1 or 0, skill == 300 and 1 or 0, 0, 1, '%s', tradeskills[char.Name] and tradeskills[char.Name][name])
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
        mq.cmdf('%s /lua stop lazarus_bis', broadcast)
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
}
group[char.Name] = char
table.insert(group, char)

mq.cmdf('%s /lua stop lazarus_bis', broadcast)
mq.delay(500)
mq.cmdf('%s /lua run lazarus_bis 0%s', broadcast, debug and ' debug' or '')
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
    --print(char)
    --print(message)
    for _, char in ipairs(group) do
        -- TODO: Search a specific item list when items are linked instead of all?
        for _,list in ipairs(itemLists) do
            local classItems = bisConfig[list][char.Class]
            local templateItems = bisConfig[list].Template
            for _,itembucket in ipairs({templateItems,classItems}) do
                for slot,item in pairs(itembucket) do
                    if item then
                        for itemName in split(item, '/') do
                            if string.find(message, itemName) then
                                -- TODO: gear list is based on the current selected item list that the script has results for
                                local hasItem = gear[char.Name][slot] ~= nil and gear[char.Name][slot].count > 0
                                --local color = '\a' .. (hasItem and 'g' or 'r')
                                --print('\t' .. color .. char.Name .. (hasItem and ' has ' or ' needs ') .. itemName)
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
        mq.cmdf('%s /lua run lazarus_bis 0%s', broadcast, debug and ' debug' or '')
        mq.delay(500)
        selectionChanged = true
        rebroadcast = false
    end
    if selectionChanged then selectionChanged = false searchAll() end
    mq.doevents()
end