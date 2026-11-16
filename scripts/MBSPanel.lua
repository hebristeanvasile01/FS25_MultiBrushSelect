Logging.info('[MultiBrushSelect] MBSPanel.lua loaded')
-- Shift+O / the last button of the category bar: multi-select GUI (textures, foliage, trees; everything the construction menu knows,
-- base game + DLC + mods + every tree type/stage/variation). Click items to toggle them, hold LMB on the
-- terrain to paint / scatter everything selected, mixed.

MBSPanel = {
    active = false,
    selected = {},      -- key -> entry
    selectedCount = 0,
    data = nil,         -- { texture = {...}, foliage = {...}, tree = {...} }
    kind = "texture",
    filter = {},        -- kind -> group title or nil (= all)
    scroll = {},        -- kind -> first visible row (0-based)
    radius = 5,
    density = 100,      -- percent
    lmb = false,
    rmb = false,
    search = "",
    lastX = nil, lastZ = nil,
    mouseX = 0, mouseY = 0,
    o = false,
    hidden = false,
    overlays = {},
    hits = {},          -- clickable rects rebuilt each draw
}
local P = MBSPanel
P.modDir = g_currentModDirectory

local R_MIN, R_MAX = 1, 25
local KINDS = { "texture", "foliage", "tree" }
local KIND_LABEL = { texture = "Textures", foliage = "Foliage", tree = "Trees" }
local SPACING = 1.3

local function isShift()
    return (Input.KEY_lshift ~= nil and Input.isKeyPressed(Input.KEY_lshift)) or (Input.KEY_rshift ~= nil and Input.isKeyPressed(Input.KEY_rshift))
end

local function isCtrl()
    return (Input.KEY_lctrl ~= nil and Input.isKeyPressed(Input.KEY_lctrl)) or (Input.KEY_rctrl ~= nil and Input.isKeyPressed(Input.KEY_rctrl))
end

local function getScreen()
    if g_gui == nil or g_gui.currentGuiName ~= "ConstructionScreen" then return nil end
    return g_gui.screenControllers ~= nil and g_gui.screenControllers[ConstructionScreen] or nil
end

----------------------------------------------------------------------------
-- data: everything that exists
----------------------------------------------------------------------------
local function tr(text)
    if text == nil then return nil end
    return g_i18n:convertText(text)
end

function P:buildData()
    local data = { texture = {}, foliage = {}, tree = {} }
    local seen = {}

    -- ground textures (every layer of the loaded map)
    do
        local names = {}
        for typeName in pairs(g_groundTypeManager.groundTypeMappings) do table.insert(names, typeName) end
        table.sort(names)
        local knownLayers = {}
        for _, typeName in ipairs(names) do
            local layer = g_groundTypeManager:getTerrainLayerByType(typeName)
            if layer ~= nil and not knownLayers[layer] then
                knownLayers[layer] = true
                table.insert(data.texture, { kind = "texture", key = "texture:" .. tostring(layer), layer = layer,
                    name = tr(g_groundTypeManager:getTerrainTitleByType(typeName)) or typeName, group = "Textures" })
            end
        end
    end

    -- foliage + trees from the store (base game, DLC and mods)
    do
        for _, storeItem in ipairs(g_storeManager:getItems()) do
            local b = storeItem.brush
            if b ~= nil then
                local class = g_constructionBrushTypeManager:getClassObjectByTypeName(b.type)
                local params = b.parameters
                local group = (b.tab ~= nil and tr(b.tab.title)) or "-"
                if class == ConstructionBrushFoliage and params ~= nil and params[1] ~= nil then
                    local paint = g_currentMission.foliageSystem:getFoliagePaintByName(params[1])
                    local state = tonumber(params[2])
                    if paint ~= nil and state ~= nil then
                        local key = "foliage:" .. tostring(paint.id) .. ":" .. tostring(state)
                        if not seen[key] then
                            seen[key] = true
                            table.insert(data.foliage, { kind = "foliage", key = key, foliagePaint = paint, foliageState = state,
                                name = storeItem.name or params[1], group = group, image = storeItem.imageFilename })
                        end
                    end
                elseif class == ConstructionBrushTree and params ~= nil and params[1] ~= nil then
                    if self.treeIconSlice == nil and b.tab ~= nil and b.tab.iconSliceId ~= nil then self.treeIconSlice = b.tab.iconSliceId end
                    local stage, variation = tonumber(params[2]), tonumber(params[3])
                    local key = "tree:" .. tostring(params[1]) .. ":" .. tostring(stage) .. ":" .. tostring(variation)
                    if stage ~= nil and not seen[key] then
                        seen[key] = true
                        table.insert(data.tree, { kind = "tree", key = key, treeType = params[1], treeStage = stage, variationIndex = variation,
                            storeItem = storeItem, name = storeItem.name or params[1], group = group, image = storeItem.imageFilename })
                    end
                end
            end
        end
    end

    -- every tree type / stage / variation the game knows (also what the store does not list)
    do
        for _, desc in pairs(g_treePlantManager.treeTypes) do
            if desc.stages ~= nil then
                for stage, variations in ipairs(desc.stages) do
                    for variation = 1, #variations do
                        local key = "tree:" .. tostring(desc.name) .. ":" .. stage .. ":" .. variation
                        local keyAlt = "tree:" .. tostring(desc.name) .. ":" .. stage .. ":" .. "nil"
                        if not seen[key] and not seen[keyAlt] then
                            seen[key] = true
                            table.insert(data.tree, { kind = "tree", key = key, treeType = desc.name, treeStage = stage, variationIndex = variation,
                                name = string.format("%s  s%d v%d", tostring(desc.title or desc.name), stage, variation), group = "All tree types" })
                        end
                    end
                end
            end
        end
    end

    local treeImg = {}
    for _, e in ipairs(data.tree) do
        if e.image ~= nil and treeImg[string.lower(tostring(e.treeType))] == nil then treeImg[string.lower(tostring(e.treeType))] = e.image end
    end
    for _, e in ipairs(data.tree) do
        if e.image == nil then e.image = treeImg[string.lower(tostring(e.treeType))] end
    end

    local function byName(a, b) return tostring(a.name) < tostring(b.name) end
    table.sort(data.tree, function(a, b)
        if a.group ~= b.group then return a.group < b.group end
        return byName(a, b)
    end)
    self.data = data
    Logging.info('[MultiBrushSelect] panel data: %d textures, %d foliage, %d trees', #data.texture, #data.foliage, #data.tree)
    do
        local tn, fn = {}, {}
        for _, d in pairs(g_treePlantManager.treeTypes) do table.insert(tn, tostring(d.name)) end
        table.sort(tn)
        for _, e in ipairs(data.foliage) do table.insert(fn, tostring(e.name)) end
        Logging.info('[MultiBrushSelect] tree types: %s', table.concat(tn, ", "))
        Logging.info('[MultiBrushSelect] foliage: %s', table.concat(fn, ", "))
    end
end

function P:groups(kind)
    self.groupCache = self.groupCache or {}
    if self.groupCache[kind] ~= nil and self.groupCacheData == self.data then return self.groupCache[kind] end
    if self.groupCacheData ~= self.data then self.groupCache = {} self.groupCacheData = self.data end
    local list, seen = {}, {}
    if self.data[kind] == nil then return list end
    for _, e in ipairs(self.data[kind]) do
        if not seen[e.group] then seen[e.group] = true table.insert(list, e.group) end
    end
    self.groupCache[kind] = list
    return list
end

function P:visibleEntries()
    local out = {}
    if self.data[self.kind] == nil then return out end
    local ckey = tostring(self.kind) .. "|" .. tostring(self.filter[self.kind]) .. "|" .. tostring(self.search)
    if self.visCache ~= nil and self.visKey == ckey and self.visData == self.data then return self.visCache end
    local f = self.filter[self.kind]
    local q = string.lower(self.search or "")
    for _, e in ipairs(self.data[self.kind]) do
        if f == nil or e.group == f then
            if q == "" or string.find(string.lower(tostring(e.name)), q, 1, true) or string.find(string.lower(tostring(e.treeType or e.group or "")), q, 1, true) then
                table.insert(out, e)
            end
        end
    end
    self.visCache, self.visKey, self.visData = out, ckey, self.data
    return out
end

function P:selectedOf(kind)
    if self.selCache == nil then self.selCache = {} end
    local c = self.selCache[kind]
    if c ~= nil then return c end
    local out = {}
    for _, e in pairs(self.selected) do
        if e.kind == kind then table.insert(out, e) end
    end
    self.selCache[kind] = out
    return out
end

function P:toggle(entry)
    self.selCache = nil
    if self.selected[entry.key] ~= nil then
        self.selected[entry.key] = nil
        self.selectedCount = self.selectedCount - 1
    else
        self.selected[entry.key] = entry
        self.selectedCount = self.selectedCount + 1
    end
end

function P:clear()
    self.selCache = nil
    self.selected = {}
    self.selectedCount = 0
end

----------------------------------------------------------------------------
-- presets (saved to modSettings/FS25_MultiBrushSelect/presets.xml)
----------------------------------------------------------------------------
local function presetDir()
    return getUserProfileAppPath() .. "modSettings/FS25_MultiBrushSelect/"
end

function P:loadPresets()
    self.presets = {}
    local path = presetDir() .. "presets.xml"
    if not fileExists(path) then return end
    local xml = loadXMLFile("mbsPresets", path)
    if xml == nil or xml == 0 then return end
    local i = 0
    while true do
        local base = string.format("presets.preset(%d)", i)
        if not hasXMLProperty(xml, base) then break end
        local p = {
            name = getXMLString(xml, base .. "#name") or ("Preset " .. (i + 1)),
            radius = getXMLInt(xml, base .. "#radius") or 5,
            density = getXMLInt(xml, base .. "#density") or 100,
            keys = {},
        }
        local j = 0
        while true do
            local kb = string.format("%s.item(%d)", base, j)
            if not hasXMLProperty(xml, kb) then break end
            local k = getXMLString(xml, kb .. "#key")
            if k ~= nil then table.insert(p.keys, k) end
            j = j + 1
        end
        table.insert(self.presets, p)
        i = i + 1
    end
    delete(xml)
end

function P:savePresets()
    createFolder(getUserProfileAppPath() .. "modSettings/")
    createFolder(presetDir())
    local xml = createXMLFile("mbsPresets", presetDir() .. "presets.xml", "presets")
    if xml == nil or xml == 0 then return end
    for i, p in ipairs(self.presets) do
        local base = string.format("presets.preset(%d)", i - 1)
        setXMLString(xml, base .. "#name", p.name)
        setXMLInt(xml, base .. "#radius", p.radius)
        setXMLInt(xml, base .. "#density", p.density)
        for j, k in ipairs(p.keys) do
            setXMLString(xml, string.format("%s.item(%d)#key", base, j - 1), k)
        end
    end
    saveXMLFile(xml)
    delete(xml)
end

function P:entryByKey(key)
    if self.byKey == nil then
        self.byKey = {}
        for _, kind in ipairs(KINDS) do
            for _, e in ipairs(self.data[kind]) do self.byKey[e.key] = e end
        end
    end
    return self.byKey[key]
end

function P:onPresetName(text, clickedOk)
    if clickedOk == false then return end
    text = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" or self.selectedCount == 0 then return end
    if self.presets == nil then self:loadPresets() end
    local keys = {}
    for k in pairs(self.selected) do table.insert(keys, k) end
    table.sort(keys)
    local preset = { name = text, radius = self.radius, density = self.density, keys = keys }
    for i, p in ipairs(self.presets) do
        if string.lower(p.name) == string.lower(text) then self.presets[i] = preset preset = nil break end
    end
    if preset ~= nil then table.insert(self.presets, preset) end
    self:savePresets()
end

function P:openSavePreset()
    if self.selectedCount == 0 then return end
    local cb = function(text, clickedOk) MBSPanel:onPresetName(text, clickedOk) end
    TextInputDialog.show(cb, nil, "", "Preset name", "Preset name", 30, "Save")
end

function P:loadPreset(p)
    self:clear()
    self.selCache = nil
    for _, k in ipairs(p.keys) do
        local e = self:entryByKey(k)
        if e ~= nil then self.selected[k] = e self.selectedCount = self.selectedCount + 1 end
    end
    self.radius = math.max(R_MIN, math.min(R_MAX, p.radius or self.radius))
    self.density = math.max(10, math.min(300, p.density or self.density))
end

function P:deletePreset(i)
    table.remove(self.presets, i)
    self:savePresets()
end

----------------------------------------------------------------------------
-- painting
----------------------------------------------------------------------------
local function sendEvent(event)
    g_client:getServerConnection():sendEvent(event)
end

local function canUse(x, y, z)
    if not g_currentMission.accessHandler:canFarmAccessLand(g_localPlayer.farmId, x, z, true) then return false end
    if PlacementUtil.isInsidePlacementPlaces(g_currentMission.storeSpawnPlaces, x, y, z) then return false end
    if PlacementUtil.isInsidePlacementPlaces(g_currentMission.loadSpawnPlaces, x, y, z) then return false end
    if PlacementUtil.isInsideRestrictedZone(g_currentMission.restrictedZones, x, y, z) then return false end
    return true
end

local function randomInCircle(x, z, r)
    local a = math.random() * 2 * math.pi
    local d = math.sqrt(math.random()) * r
    return x + math.cos(a) * d, z + math.sin(a) * d
end

function P:applyAt(x, y, z)
    if not canUse(x, y, z) then return end
    local r = self.radius
    local dens = self.density / 100
    local shape = Landscaping.BRUSH_SHAPE.CIRCLE

    -- textures: random small patches so the textures are mixed
    local tex = self:selectedOf("texture")
    if #tex > 0 then
        local sr = math.max(0.5, math.min(1.5, r / 2))
        local n = math.min(14, math.max(1, math.ceil((r * r) / (sr * sr) * 0.5 * dens)))
        if #tex == 1 then n = 1 sr = r end
        for _ = 1, n do
            local px, pz = x, z
            if #tex > 1 then px, pz = randomInCircle(x, z, math.max(0, r - sr)) end
            local py = getTerrainHeightAtWorldPos(g_terrainNode, px, 0, pz)
            local pick = tex[math.random(1, #tex)]
            sendEvent(LandscapingSculptEvent.new(false, Landscaping.OPERATION.PAINT, px, py, pz, nil, nil, nil, nil, nil, nil, sr, 1, shape, 1, pick.layer))
        end
    end

    -- foliage: random patches, each picks one of the selected types
    local fol = self:selectedOf("foliage")
    if #fol > 0 then
        local sr = math.max(0.5, math.min(1.5, r / 2))
        local n = math.min(30, math.max(#fol, math.ceil((r * r) / (sr * sr) * 0.7 * dens)))
        for i = 1, n do
            local px, pz = randomInCircle(x, z, math.max(0, r - sr))
            local py = getTerrainHeightAtWorldPos(g_terrainNode, px, 0, pz)
            local pick = fol[(i <= #fol) and i or math.random(1, #fol)]
            sendEvent(LandscapingSculptEvent.new(false, Landscaping.OPERATION.FOLIAGE, px, py, pz, nil, nil, nil, nil, nil, nil, sr, 1, shape, 0, nil, pick.foliagePaint.id, pick.foliageState))
        end
    end

    -- trees: sparse, never touching (crown-radius aware, remembered across the whole stroke)
    local trees = self:selectedOf("tree")
    if #trees > 0 and g_treePlantManager ~= nil then
        local tx, tz = self.lastTreeX, self.lastTreeZ
        local gate = math.max(4, r)
        if tx ~= nil and (x - tx) * (x - tx) + (z - tz) * (z - tz) < gate * gate then return end
        self.lastTreeX, self.lastTreeZ = x, z
        self.treeMem = self.treeMem or {}
        local money = g_currentMission:getMoney()
        local spent = 0
        local farmId = g_localPlayer.farmId
        local area = math.pi * r * r
        local avgCr = 0
        for _, t in ipairs(trees) do
            local d = g_treePlantManager:getTreeTypeDescFromName(t.treeType)
            local n = (d ~= nil and d.stages ~= nil) and #d.stages or 1
            avgCr = avgCr + MBSPanel.crownRadius((t.treeStage or 1) / math.max(1, n))
        end
        avgCr = avgCr / #trees
        local expected = dens * area / ((2 * avgCr + 1.5) ^ 2) * 0.6
        local want = math.floor(expected)
        if math.random() < expected - want then want = want + 1 end
        local planted = 0
        for _ = 1, want * 12 do
            if planted >= want then break end
            local px, pz = randomInCircle(x, z, r)
            local pick = trees[math.random(1, #trees)]
            local desc = g_treePlantManager:getTreeTypeDescFromName(pick.treeType)
            if desc ~= nil and desc.stages ~= nil and #desc.stages > 0 then
                local stage = math.min(pick.treeStage or 1, #desc.stages)
                local variations = desc.stages[stage]
                local cr = MBSPanel.crownRadius(stage / #desc.stages)
                local free = true
                for _, m in ipairs(self.treeMem) do
                    local dx, dz = m[1] - px, m[2] - pz
                    local need = m[3] + cr + 1.0
                    if dx * dx + dz * dz < need * need then free = false break end
                end
                local py = getTerrainHeightAtWorldPos(g_terrainNode, px, 0, pz)
                if free and variations ~= nil and #variations > 0 and canUse(px, py, pz) then
                    local variation = math.min(pick.variationIndex or math.random(1, #variations), #variations)
                    local price = 0
                    if pick.storeItem ~= nil then
                        price = MathUtil.lerp(0, g_currentMission.economyManager:getBuyPrice(pick.storeItem), stage / #desc.stages)
                    end
                    if not g_treePlantManager:canPlantTree() or spent + price > money then break end
                    local ry = math.random() * 2 * math.pi
                    if g_server ~= nil then
                        local id = g_treePlantManager:plantTree(desc.index, px, py, pz, 0, ry, 0, stage, variation, false)
                        if id ~= nil then
                            self.curStroke = self.curStroke or {}
                            table.insert(self.curStroke, id)
                        end
                        g_currentMission:addMoney(-price, farmId, MoneyType.SHOP_PROPERTY_BUY, true)
                    else
                        sendEvent(TreePlantEvent.new(desc.index, px, py, pz, 0, ry, 0, stage, variation, nil, false, price, farmId))
                    end
                    spent = spent + price
                    planted = planted + 1
                    table.insert(self.treeMem, { px, pz, cr })
                    if #self.treeMem > 500 then table.remove(self.treeMem, 1) end
                end
            end
        end
    end
end

-- approximate crown radius (m) from growth fraction 0..1
function MBSPanel.crownRadius(frac)
    return 0.5 + 4.5 * math.max(0, math.min(1, frac))
end

local function removeTreeNode(node)
    if node == nil or not entityExists(node) then return false end
    local n = getNumOfChildren(node)
    for i = n - 1, 0, -1 do
        delete(getChildAt(node, i))
    end
    return true
end

function P:cleanupTrees(x, z)
    g_treePlantManager:cleanupDeletedTrees()
    if x ~= nil then
        local range = 12
        g_densityMapHeightManager:setCollisionMapAreaDirty(x - range, z - range, x + range, z + range, true)
        g_currentMission.aiSystem:setAreaDirty(x - range, x + range, z - range, z + range)
    end
end

-- removes planted trees inside the circle (only the selected tree types if any are selected)
function P:eraseTrees(x, z)
    if g_server == nil then
        if not self.warnedClientErase then
            self.warnedClientErase = true
            Logging.info('[MultiBrushSelect] tree erase works for the host / singleplayer only')
        end
        return
    end
    local td = g_treePlantManager ~= nil and g_treePlantManager.treesData or nil
    if td == nil then return end
    local types, any = {}, false
    for _, e in ipairs(self:selectedOf("tree")) do
        local d = g_treePlantManager:getTreeTypeDescFromName(e.treeType)
        if d ~= nil then types[d.index] = true any = true end
    end
    local r2 = self.radius * self.radius
    local victims = {}
    for _, list in ipairs({ td.growingTrees, td.splitTrees }) do
        for _, tree in ipairs(list) do
            local dx, dz = tree.x - x, tree.z - z
            if dx * dx + dz * dz <= r2 and (not any or types[tree.treeType]) then
                table.insert(victims, tree.node)
            end
        end
    end
    for _, node in ipairs(victims) do removeTreeNode(node) end
    if #victims > 0 then self:cleanupTrees(x, z) end
end

-- undo: removes the trees planted by the last paint stroke (host / singleplayer)
function P:undoTrees()
    local stroke = table.remove(self.strokes or {})
    if stroke == nil then return end
    local x, z
    for _, node in ipairs(stroke) do
        if entityExists(node) then
            local nx, _ny, nz = getWorldTranslation(node)
            x, z = nx, nz
            removeTreeNode(node)
        end
    end
    self:cleanupTrees(x, z)
end

-- right mouse: removes foliage (grass, weeds, flowers) inside the brush circle
function P:eraseAt(x, y, z)
    if not canUse(x, y, z) then return end
    local noBrush = TerrainDeformation ~= nil and TerrainDeformation.NO_TERRAIN_BRUSH or nil
    sendEvent(LandscapingSculptEvent.new(false, Landscaping.OPERATION.PAINT, x, y, z, nil, nil, nil, nil, nil, nil, self.radius, 1, Landscaping.BRUSH_SHAPE.CIRCLE, 0, noBrush))
    self:eraseTrees(x, z)
end

----------------------------------------------------------------------------
-- layout / drawing
----------------------------------------------------------------------------
local TEXT = 0.0122
local ROW_H = 0.029

local PANEL_H = 0.64
local function panelRect(screen)
    -- same width as the native construction menu, so it stays inside the game's frame
    local bx, bw = 0.065, 0.2
    local mb = screen ~= nil and screen.menuBox or nil
    if mb ~= nil and mb.absPosition ~= nil and mb.absSize ~= nil then bx, bw = mb.absPosition[1], mb.absSize[1] end
    return bx + 0.003, 0.97 - PANEL_H, bw - 0.006, PANEL_H
end

local fitCache = {}
local fitCount = 0
local function fit(text, size, maxW)
    text = tostring(text)
    local ck = text .. "|" .. size .. "|" .. maxW
    local hit = fitCache[ck]
    if hit ~= nil then return hit end
    local res = (function()
    if getTextWidth(size, text) <= maxW then return text end
    while #text > 1 and getTextWidth(size, text .. "..") > maxW do text = text:sub(1, #text - 1) end
    return text .. ".."
    end)()
    fitCount = fitCount + 1
    if fitCount > 4000 then fitCache = {} fitCount = 0 end
    fitCache[ck] = res
    return res
end

local function txt(x, y, size, text, r, g, b, bold, align)
    setTextBold(bold == true)
    setTextColor(r or 1, g or 1, b or 1, 1)
    setTextAlignment(align or RenderText.ALIGN_LEFT)
    renderText(x, y, size, text)
    setTextBold(false)
    setTextAlignment(RenderText.ALIGN_LEFT)
end

function P:addHit(x, y, w, h, fn)
    table.insert(self.hits, { x = x, y = y, w = w, h = h, fn = fn })
end

local GR, GG, GB = 0.2, 0.38, 0.001       -- FS25 green (engine shows it as ~#A0C312)
local TAB_BG = { 0.0042, 0.0036, 0.0062 }    -- native category background (engine shows it as ~#10131B)
local function frame(x, y, w, h, t, r, g, b, a)
    drawFilledRect(x, y, w, t, r, g, b, a)
    drawFilledRect(x, y + h - t, w, t, r, g, b, a)
    drawFilledRect(x, y, t, h, r, g, b, a)
    drawFilledRect(x + w - t, y, t, h, r, g, b, a)
end

local function button(self, x, y, w, h, label, active, fn)
    local hover = self.mouseX >= x and self.mouseX <= x + w and self.mouseY >= y and self.mouseY <= y + h
    if active then
        drawFilledRect(x, y, w, h, GR, GG, GB, 1)
        frame(x, y, w, h, 0.0012, 0, 0, 0, 1)
        txt(x + w / 2, y + h / 2 - TEXT * 0.4, TEXT, label, 0.06, 0.08, 0.02, true, RenderText.ALIGN_CENTER)
    else
        drawFilledRect(x, y, w, h, hover and 0.05 or 0.028, hover and 0.058 or 0.034, hover and 0.085 or 0.05, 1)
        frame(x, y, w, h, 0.0012, 0, 0, 0, 1)
        txt(x + w / 2, y + h / 2 - TEXT * 0.4, TEXT, label, GR, GG, GB, true, RenderText.ALIGN_CENTER)
    end
    self:addHit(x, y, w, h, fn)
end

function P:onSearchText(text, clickedOk)
    if clickedOk == false then return end
    self.search = tostring(text or "")
    self.scroll[self.kind] = 0
end

function P:openSearch()
    local cb = function(text, clickedOk) MBSPanel:onSearchText(text, clickedOk) end
    TextInputDialog.show(cb, nil, self.search or "", "Search", "Search", 40, "OK")
end

function P:getOverlay(path)
    if path == nil then return nil end
    local o = self.overlays[path]
    if o == nil then
        local id = createImageOverlay(path)
        o = (id ~= nil and id ~= 0) and id or false
        self.overlays[path] = o
    end
    return o or nil
end

local function hashColor(str)
    local h = 7
    for i = 1, #str do h = (h * 31 + str:byte(i)) % 997 end
    local r = 0.25 + ((h * 13) % 60) / 100
    local g = 0.25 + ((h * 29) % 60) / 100
    local b = 0.25 + ((h * 47) % 60) / 100
    return r, g, b
end

function P:drawIcon(e, x, y, w, h)
    local ov = self:getOverlay(e.image)
    if ov ~= nil then
        renderOverlay(ov, x, y, w, h)
        return
    end
    if e.kind == "texture" and e.layer ~= nil and TerrainLayerElement ~= nil then
        if self.layerEl == nil then
            self.layerEl = TerrainLayerElement.new()
        end
        local el = self.layerEl
        el:setTerrainLayer(g_terrainNode, e.layer)
        el:setSize(w, h)
        el:setAbsolutePosition(x, y)
        el.absSize = { w, h }
        el:draw()
        return
    end
    if e.kind == "tree" then
        -- no game icon for this tree type: native tree glyph tinted per type + short type label
        local hr, hg, hb = hashColor(tostring(e.treeType))
        drawFilledRect(x, y, w, h, 0.07, 0.1, 0.14, 1)
        if self.treeIconSlice ~= nil then
            if self.treeGlyph == nil then
                local ok, ov = pcall(function() return g_overlayManager:createOverlay(self.treeIconSlice, 0, 0, 0, 0) end)
                self.treeGlyph = (ok and ov) or false
            end
            if self.treeGlyph then
                local g = self.treeGlyph
                g:setPosition(x + w * 0.1, y + h * 0.22)
                g:setDimension(w * 0.8, h * 0.74)
                g:setColor(0.55 + hr * 0.45, 0.8 + hg * 0.2, 0.55 + hb * 0.45, 1)
                g:draw()
                txt(x + w / 2, y + h * 0.02, TEXT * 0.6, string.upper(string.sub(tostring(e.treeType), 1, 3)), 0.8, 0.9, 1, true, RenderText.ALIGN_CENTER)
                return
            end
        end
        local cr, cg, cb = 0.12 + hr * 0.35, 0.3 + hg * 0.4, 0.12 + hb * 0.3
        drawFilledRect(x + w * 0.45, y + h * 0.18, w * 0.1, h * 0.28, 0.42, 0.3, 0.18, 1)
        drawFilledRect(x + w * 0.18, y + h * 0.42, w * 0.64, h * 0.22, cr, cg, cb, 1)
        drawFilledRect(x + w * 0.26, y + h * 0.58, w * 0.48, h * 0.2, cr * 1.15, cg * 1.15, cb * 1.15, 1)
        drawFilledRect(x + w * 0.36, y + h * 0.74, w * 0.28, h * 0.18, cr * 1.3, cg * 1.3, cb * 1.3, 1)
        txt(x + w / 2, y + h * 0.02, TEXT * 0.6, string.upper(string.sub(tostring(e.treeType), 1, 3)), 0.8, 0.9, 1, true, RenderText.ALIGN_CENTER)
        return
    end
    local r, g, b = hashColor(tostring(e.name))
    drawFilledRect(x, y, w, h, r, g, b, 1)
    txt(x + w / 2, y + h / 2 - TEXT * 0.4, TEXT, string.upper(string.sub(tostring(e.name), 1, 1)), 1, 1, 1, true, RenderText.ALIGN_CENTER)
end

function P:drawPanel(screen)
    self.hits = {}
    local px, py, pw, ph = panelRect(screen)
    local aspect = g_screenWidth / g_screenHeight
    -- FS25 look: grey body, black border, green text
    drawFilledRect(px, py, pw, ph, 0.02, 0.025, 0.04, 0.98)
    frame(px, py, pw, ph, 0.0025, 0, 0, 0, 1)
    local pad = 0.008
    local x0, w = px + pad, pw - 2 * pad
    local y = py + ph - 0.026

    txt(x0, y, TEXT * 1.3, "MULTI BRUSH", GR, GG, GB, true)
    txt(px + pw - pad, y, TEXT * 0.95, "FS MODDING", 0.85, 0.87, 0.92, true, RenderText.ALIGN_RIGHT)
    drawFilledRect(x0, y - 0.011, w, 0.0016, 0, 0, 0, 1)
    y = y - 0.04

    -- kind tabs
    local TABS = { "texture", "foliage", "tree", "preset" }
    local tw = w / #TABS
    for i, kind in ipairs(TABS) do
        local count = kind ~= "preset" and #self:selectedOf(kind) or 0
        local label = (kind == "preset" and "Presets" or KIND_LABEL[kind]) .. (count > 0 and (" (" .. count .. ")") or "")
        button(self, x0 + (i - 1) * tw, y, tw - 0.002, 0.027, fit(label, TEXT, tw - 0.01), self.kind == kind, function() self.kind = kind if kind == "preset" and self.presets == nil then self:loadPresets() end end)
    end
    y = y - 0.032

    local footer = 0.125
    local listBottom = py + footer + 0.004
    local sbW = 0.007
    self.sb = nil

    local function scrollbar(listTop, rowsVisible, totalRows, scroll, maxScroll, key)
        local trackH = listTop - listBottom
        drawFilledRect(px + pw - pad - sbW + 0.0005, listBottom, sbW, trackH, 0.008, 0.01, 0.018, 1)
        frame(px + pw - pad - sbW + 0.0005, listBottom, sbW, trackH, 0.0008, 0, 0, 0, 1)
        if maxScroll > 0 then
            local barH = math.max(0.03, trackH * rowsVisible / math.max(1, totalRows))
            local barY = listTop - barH - (trackH - barH) * (scroll / maxScroll)
            drawFilledRect(px + pw - pad - sbW + 0.0005, barY, sbW, barH, GR, GG, GB, 1)
            frame(px + pw - pad - sbW + 0.0005, barY, sbW, barH, 0.0008, 0, 0, 0, 1)
            self.sb = { x = px + pw - pad - sbW - 0.003, y = listBottom, w = sbW + 0.008, h = trackH, max = maxScroll, key = key }
        end
    end

    if self.kind == "preset" then
        if self.presets == nil then self:loadPresets() end
        self.listRect = { x = px, y = listBottom, w = pw, h = y - listBottom, rows = 1, max = 0 }
        local can = self.selectedCount > 0
        button(self, x0, y, w, 0.027, can and ("Save current selection as preset (" .. self.selectedCount .. ")") or "Select items first, then save as preset", can, function() self:openSavePreset() end)
        y = y - 0.034
        local rowsVisible = math.max(1, math.floor((y - listBottom) / ROW_H))
        local maxScroll = math.max(0, #self.presets - rowsVisible)
        local scroll = math.max(0, math.min(self.scroll.preset or 0, maxScroll))
        self.scroll.preset = scroll
        scrollbar(y, rowsVisible, #self.presets, scroll, maxScroll, "preset")
        for i = 1, rowsVisible do
            local p = self.presets[scroll + i]
            if p == nil then break end
            local ry = y - i * ROW_H
            local rw = w - sbW - 0.034
            drawFilledRect(x0, ry, rw, ROW_H - 0.002, 0.035, 0.04, 0.06, 1)
            frame(x0, ry, rw, ROW_H - 0.002, 0.0012, 0, 0, 0, 1)
            txt(x0 + 0.006, ry + ROW_H * 0.52, TEXT, fit(p.name, TEXT, rw - 0.012), GR, GG, GB, true)
            txt(x0 + 0.006, ry + ROW_H * 0.12, TEXT * 0.75, fit(string.format("%d items | radius %d m | density %d%%", #p.keys, p.radius, p.density), TEXT * 0.75, rw - 0.012), 0.82, 0.84, 0.9)
            local idx = scroll + i
            self:addHit(x0, ry, rw, ROW_H - 0.002, function() self:loadPreset(p) end)
            button(self, x0 + rw + 0.003, ry, 0.026, ROW_H - 0.002, "x", false, function() self:deletePreset(idx) end)
        end
        if #self.presets == 0 then
            txt(x0 + 0.01, y - 0.04, TEXT, "No presets yet.", 0.82, 0.84, 0.9)
        end
    else
        -- search box
        local hasQuery = (self.search or "") ~= ""
        local fieldW = hasQuery and (w - 0.03) or w
        drawFilledRect(x0, y, fieldW, 0.026, 0.008, 0.01, 0.018, 1)
        frame(x0, y, fieldW, 0.026, 0.0012, 0, 0, 0, 1)
        if hasQuery then
            txt(x0 + 0.006, y + 0.0075, TEXT, fit(self.search, TEXT, fieldW - 0.012), GR, GG, GB, true)
        else
            txt(x0 + 0.006, y + 0.0075, TEXT, "Search... (click to type)", 0.6, 0.62, 0.68)
        end
        self:addHit(x0, y, fieldW, 0.026, function() self:openSearch() end)
        if hasQuery then
            button(self, x0 + w - 0.027, y, 0.027, 0.026, "x", false, function() self.search = "" self.scroll[self.kind] = 0 end)
        end
        y = y - 0.031

        -- group chips
        local groups = self:groups(self.kind)
        if #groups > 1 then
            local perRow = 3
            local cw = w / perRow
            local list = { false }
            for _, g in ipairs(groups) do table.insert(list, g) end
            local rows = math.ceil(#list / perRow)
            for i, g in ipairs(list) do
                local col = (i - 1) % perRow
                local row = math.floor((i - 1) / perRow)
                local cx, cy = x0 + col * cw, y - row * 0.026
                local label = g == false and "All" or fit(g, TEXT * 0.9, cw - 0.012)
                local active = (g == false and self.filter[self.kind] == nil) or (g ~= false and self.filter[self.kind] == g)
                button(self, cx, cy, cw - 0.002, 0.023, label, active, function()
                    self.filter[self.kind] = (g ~= false) and g or nil
                    self.scroll[self.kind] = 0
                end)
            end
            y = y - rows * 0.026 - 0.004
        end

        -- 2-column grid
        local listTop = y
        local entries = self:visibleEntries()
        local cols, gap = 2, 0.004
        local gridW = w - sbW - 0.005
        local tileW = (gridW - gap) / cols
        local rowsVisible = math.max(1, math.floor((listTop - listBottom) / ROW_H))
        local totalRows = math.ceil(#entries / cols)
        local maxScroll = math.max(0, totalRows - rowsVisible)
        local scroll = math.max(0, math.min(self.scroll[self.kind] or 0, maxScroll))
        self.scroll[self.kind] = scroll
        self.listRect = { x = px, y = listBottom, w = pw, h = listTop - listBottom, rows = rowsVisible, max = maxScroll }
        scrollbar(listTop, rowsVisible, totalRows, scroll, maxScroll, self.kind)

        local iconH = ROW_H * 0.86
        local iconW = iconH / aspect
        for r = 1, rowsVisible do
            for c = 1, cols do
                local e = entries[(scroll + r - 1) * cols + c]
                if e == nil then break end
                local tx = x0 + (c - 1) * (tileW + gap)
                local ry = listTop - r * ROW_H
                local sel = self.selected[e.key] ~= nil
                local hv = self.mouseX >= tx and self.mouseX <= tx + tileW and self.mouseY >= ry and self.mouseY <= ry + ROW_H
                if sel then
                    drawFilledRect(tx, ry, tileW, ROW_H - 0.002, GR, GG, GB, 1)
                else
                    drawFilledRect(tx, ry, tileW, ROW_H - 0.002, hv and 0.055 or 0.035, hv and 0.062 or 0.04, hv and 0.09 or 0.06, 1)
                end
                frame(tx, ry, tileW, ROW_H - 0.002, 0.0012, 0, 0, 0, 1)
                self:drawIcon(e, tx + 0.002, ry + 0.002, iconW, iconH)
                local nx = tx + iconW + 0.006
                local maxW = tx + tileW - 0.003 - nx
                if sel then
                    txt(nx, ry + ROW_H * 0.52, TEXT * 0.92, fit(e.name, TEXT * 0.92, maxW), 0.06, 0.08, 0.02, true)
                else
                    txt(nx, ry + ROW_H * 0.52, TEXT * 0.92, fit(e.name, TEXT * 0.92, maxW), GR, GG, GB, true)
                end
                local sub = e.kind == "tree" and (tostring(e.treeType) .. " stage " .. tostring(e.treeStage)) or e.group
                if sub ~= nil then
                    txt(nx, ry + ROW_H * 0.12, TEXT * 0.7, fit(sub, TEXT * 0.7, maxW), sel and 0.15 or 0.82, sel and 0.18 or 0.84, sel and 0.05 or 0.9)
                end
                self:addHit(tx, ry, tileW, ROW_H - 0.002, function() self:toggle(e) end)
            end
        end
        if #entries == 0 then
            txt(x0 + 0.01, listTop - 0.05, TEXT, "(nothing in this category)", 0.82, 0.84, 0.9)
        end
    end

    -- footer
    local fy = py + footer - 0.022
    drawFilledRect(px + 0.0025, py + 0.0025, pw - 0.005, footer - 0.0025, 0.012, 0.016, 0.026, 1)
    drawFilledRect(px + 0.0025, py + footer, pw - 0.005, 0.0016, 0, 0, 0, 1)
    txt(x0, fy, TEXT * 0.95, string.format("Selected: %d textures, %d foliage, %d trees",
        #self:selectedOf("texture"), #self:selectedOf("foliage"), #self:selectedOf("tree")), GR, GG, GB, true)
    local bw = w / 3
    button(self, x0, fy - 0.03, bw - 0.002, 0.025, "Clear", false, function() self:clear() end)
    button(self, x0 + bw, fy - 0.03, bw - 0.002, 0.025, "Undo trees", false, function() self:undoTrees() end)
    button(self, x0 + bw * 2, fy - 0.03, bw - 0.002, 0.025, "Save preset", self.selectedCount > 0, function() self:openSavePreset() end)

    local function stepper(yy, label, valueText, onMinus, onPlus)
        txt(x0, yy + 0.007, TEXT, label, 0.85, 0.87, 0.92)
        local bx = x0 + w * 0.45
        button(self, bx, yy, 0.022, 0.025, "-", false, onMinus)
        txt(bx + 0.022 + (w * 0.55 - 0.044) / 2, yy + 0.007, TEXT, valueText, GR, GG, GB, true, RenderText.ALIGN_CENTER)
        button(self, x0 + w - 0.022, yy, 0.022, 0.025, "+", false, onPlus)
    end
    stepper(fy - 0.062, "Radius", string.format("%d m", self.radius),
        function() self.radius = math.max(R_MIN, self.radius - 1) end,
        function() self.radius = math.min(R_MAX, self.radius + 1) end)
    stepper(fy - 0.092, "Density", string.format("%d%%", self.density),
        function() self.density = math.max(10, self.density - 10) end,
        function() self.density = math.min(300, self.density + 10) end)
end

----------------------------------------------------------------------------
-- own category button in the construction screen's left bar, after the last native category
----------------------------------------------------------------------------
local TAB_H = 0.119           -- height of one native category button
local TAB_LAST_BOTTOM = 0.1753 -- bottom edge of the last native category (our tab sits flush below it)

local function barWidth(screen)
    local mb = screen ~= nil and screen.menuBox or nil
    if mb ~= nil and mb.absPosition ~= nil and mb.absPosition[1] > 0 then return mb.absPosition[1] end
    return 0.065
end

local function tabRect(screen)
    return 0, TAB_LAST_BOTTOM - TAB_H, barWidth(screen), TAB_H
end

function P:setActive(on)
    if getScreen() == nil then return end
    if on and self.data == nil then self:buildData() end
    self.active = on
    if on then self.activatedAt = g_time end
    if not on then self.lmb = false self.rmb = false end
end

-- while our panel is open the native highlighted category must look unselected: repaint it dark with its own icon
function P:drawNativeCover(screen)
    local ok, err = pcall(function()
        local cats = g_storeManager:getConstructionCategories()
        local n = #cats
        local cur = screen.currentCategory
        if type(cur) == "table" then cur = cur.index end
        if type(cur) ~= "number" or cats[cur] == nil then return end
        local x, _, w, h = tabRect(screen)
        local y = TAB_LAST_BOTTOM + (n - cur) * TAB_H
        if y < 0 or y + h > 1 then return end
        drawFilledRect(x, y, w, h, TAB_BG[1], TAB_BG[2], TAB_BG[3], 1)
        drawFilledRect(x, y + h - 0.0013, w, 0.0013, 1, 1, 1, 0.8)
        drawFilledRect(x, y, w, 0.0013, 1, 1, 1, 0.8)
        local cat = cats[cur]
        if not self.catLogged then
            self.catLogged = true
            Logging.info('[MultiBrushSelect] categories=%d current=%s slice=%s file=%s', n, tostring(cur), tostring(cat.iconSliceId), tostring(cat.iconFilename))
        end
        local aspect = g_screenWidth / g_screenHeight
        local ih = h * 0.46
        local iw = ih / aspect
        local ix, iy = x + (w - iw) / 2, y + (h - ih) / 2
        self.catIcons = self.catIcons or {}
        local key = tostring(cat.iconSliceId or cat.iconFilename)
        local ic = self.catIcons[key]
        if ic == nil then
            ic = false
            if cat.iconSliceId ~= nil then
                local ok2, ov = pcall(function() return g_overlayManager:createOverlay(cat.iconSliceId, 0, 0, 0, 0) end)
                if ok2 and ov then ic = { slice = ov } end
            end
            if not ic and cat.iconFilename ~= nil then
                local id = createImageOverlay(cat.iconFilename)
                if id ~= nil and id ~= 0 then ic = { image = id, uvs = cat.iconUVs } end
            end
            self.catIcons[key] = ic
        end
        if ic and ic.slice then
            ic.slice:setPosition(ix, iy)
            ic.slice:setDimension(iw, ih)
            ic.slice:setColor(1, 1, 1, 1)
            ic.slice:draw()
        elseif ic and ic.image then
            if type(ic.uvs) == "table" and #ic.uvs >= 8 then setOverlayUVs(ic.image, unpack(ic.uvs)) end
            setOverlayColor(ic.image, 1, 1, 1, 1)
            renderOverlay(ic.image, ix, iy, iw, ih)
        end
    end)
    if not ok and not self.coverErr then
        self.coverErr = true
        Logging.info('[MultiBrushSelect] native cover failed: %s', tostring(err))
    end
end

function P:drawTab(screen)
    if self.active then self:drawNativeCover(screen) end
    local x, y, w, h = tabRect(screen)
    if self.active then
        drawFilledRect(x, y, w, h, GR, GG, GB, 1)
    else
        local hover = self.mouseX >= x and self.mouseX <= x + w and self.mouseY >= y and self.mouseY <= y + h
        drawFilledRect(x, y, w, h, hover and 0.007 or TAB_BG[1], hover and 0.006 or TAB_BG[2], hover and 0.01 or TAB_BG[3], 1)
    end
    drawFilledRect(x, y + h - 0.0013, w, 0.0013, 1, 1, 1, 0.8)
    drawFilledRect(x, y, w, 0.0013, 1, 1, 1, 0.8)
    local aspect = g_screenWidth / g_screenHeight
    local ih = h * 0.5
    local iw = ih / aspect
    local c = self.active and 0.02 or 1
    if self.tabIcon == nil then
        local id = self.modDir ~= nil and createImageOverlay(self.modDir .. "tab_icon.dds") or nil
        self.tabIcon = (id ~= nil and id ~= 0) and id or false
    end
    if self.tabIcon then
        setOverlayColor(self.tabIcon, c, c, c, 1)
        renderOverlay(self.tabIcon, x + (w - iw) / 2, y + (h - ih) / 2, iw, ih)
    end
end

-- a native category / brush was chosen: leave our panel
function P:onNativeSelect()
    if self.active and g_time - (self.activatedAt or 0) > 400 and g_time - (self.openAt or 0) > 1500 then
        self:setActive(false)
    end
end

function P:drawMarker(screen)
    if screen == nil or screen.cursor == nil or self.listRect == nil then return end
    local x, y, z = screen.cursor:getHitTerrainPosition()
    if x == nil or self:overPanel(self.mouseX, self.mouseY) then return end
    local n, r = 24, self.radius
    -- terrain heights only recomputed when the cursor moved noticeably (cheaper per frame)
    local m = self.marker
    if m == nil or m.r ~= r or math.abs(m.x - x) > 0.3 or math.abs(m.z - z) > 0.3 then
        m = { x = x, z = z, r = r, pts = {} }
        for i = 0, n do
            local a = i / n * 2 * math.pi
            local cx, cz = x + math.cos(a) * r, z + math.sin(a) * r
            m.pts[i + 1] = { cx, getTerrainHeightAtWorldPos(g_terrainNode, cx, 0, cz) + 0.15, cz }
        end
        self.marker = m
    end
    local cr, cg, cb = self.rmb and 1 or GR, self.rmb and 0.2 or GG, self.rmb and 0.0 or GB
    for i = 2, #m.pts do
        local p, q = m.pts[i - 1], m.pts[i]
        drawDebugLine(p[1], p[2], p[3], cr, cg, cb, q[1], q[2], q[3], cr, cg, cb, false)
    end
end

function P:overPanel(mx, my)
    local lr = self.panelBounds
    if lr == nil then return false end
    return mx >= lr.x and mx <= lr.x + lr.w and my >= lr.y and my <= lr.y + lr.h
end

----------------------------------------------------------------------------
-- screen hooks
----------------------------------------------------------------------------
function P:setDefaultMenuVisible(screen, visible)
    for _, name in ipairs({ "menuBox" }) do
        local el = screen[name]
        if el ~= nil and el.setVisible ~= nil then el:setVisible(visible) end
    end
end

function P:scrollTo(posY)
    local sb = self.sb
    if sb == nil then return end
    local frac = math.max(0, math.min(1, (sb.y + sb.h - posY) / sb.h))
    self.scroll[sb.key] = math.floor(frac * sb.max + 0.5)
end

function P:handleMouse(posX, posY, isDown, isUp, button)
    self.mouseX, self.mouseY = posX, posY
    local scr0 = getScreen()
    if scr0 ~= nil and isDown and button == (Input.MOUSE_BUTTON_LEFT or 1) then
        local tx, ty, tw, th = tabRect(scr0)
        if posX >= tx and posX <= tx + tw and posY >= ty and posY <= ty + th then
            self:setActive(not self.active)
            return
        elseif self.active and posX < tw and not self:overPanel(posX, posY) then
            self:setActive(false) -- clicked a native category: leave our panel, the native menu shows again
        end
    end
    if self.sbDrag then
        if isUp then self.sbDrag = false else self:scrollTo(posY) return end
    end
    if not self.active or getScreen() == nil then return end
    local left = Input.MOUSE_BUTTON_LEFT or 1
    if isDown and button == left then
        if self:overPanel(posX, posY) then
            local sb = self.sb
            if sb ~= nil and posX >= sb.x and posX <= sb.x + sb.w and posY >= sb.y and posY <= sb.y + sb.h then
                self.sbDrag = true
                self:scrollTo(posY)
                return
            end
            for _, h in ipairs(self.hits) do
                if posX >= h.x and posX <= h.x + h.w and posY >= h.y and posY <= h.y + h.h then
                    h.fn()
                    break
                end
            end
        else
            self.lmb = true
            self.lastX = nil
            self.lastTreeX = nil
            self.treeMem = {}
        end
    elseif isDown and button == (Input.MOUSE_BUTTON_RIGHT or 3) and not self:overPanel(posX, posY) then
        self.rmb = true
        self.lastEraseX = nil
    elseif isUp and button == (Input.MOUSE_BUTTON_RIGHT or 3) then
        self.rmb = false
        self.lastEraseX = nil
    elseif isUp and button == left then
        self.lmb = false
        self.lastX = nil
        if self.curStroke ~= nil and #self.curStroke > 0 then
            self.strokes = self.strokes or {}
            table.insert(self.strokes, self.curStroke)
            if #self.strokes > 40 then table.remove(self.strokes, 1) end
        end
        self.curStroke = nil
    elseif isDown and self:overPanel(posX, posY) then
        local up, down = Input.MOUSE_BUTTON_WHEEL_UP, Input.MOUSE_BUTTON_WHEEL_DOWN
        local step = nil
        if up ~= nil and button == up then step = -2 elseif down ~= nil and button == down then step = 2 end
        if step ~= nil then
            self.scroll[self.kind] = math.max(0, (self.scroll[self.kind] or 0) + step)
        end
    end
end

function P:trigger(src)
    if self.lastTrigger ~= nil and g_time - self.lastTrigger < 400 then return end
    self.lastTrigger = g_time
    local screen = getScreen()
    Logging.info('[MultiBrushSelect] toggle (%s) screen=%s gui=%s', src, tostring(screen ~= nil), tostring(g_gui ~= nil and g_gui.currentGuiName))
    if screen ~= nil then
        self:setActive(not self.active)
    elseif g_currentMission ~= nil and not g_gui:getIsGuiVisible() and g_localPlayer ~= nil then
        if self.data == nil then
            self:buildData()
        end
        self.active = true
        self.activatedAt = g_time
        self.openAt = g_time
        g_gui:showGui("ConstructionScreen")
    end
end

function P:onToggleAction()
    self:trigger("action")
end

function P:onUndoAction()
    if self.active and getScreen() ~= nil then self:undoTrees() end
end

function P:keyEvent(unicode, sym, modifier, isDown)
    if isDown and Input.KEY_o ~= nil and sym == Input.KEY_o and isShift() then
        self:trigger("keyEvent")
    end
end

function P:update(dt)
    if g_dedicatedServer ~= nil or g_gui == nil then return end
    local screen = getScreen()

    -- Shift+O (polled as a fallback; the F1 action event does the same, trigger() debounces)
    local oDown = Input.KEY_o ~= nil and Input.isKeyPressed(Input.KEY_o)
    if oDown and not self.o and isShift() then
        self:trigger("poll")
    end
    self.o = oDown
    screen = getScreen()

    if screen == nil then
        if self.hidden then
            local sc = g_gui.screenControllers ~= nil and g_gui.screenControllers[ConstructionScreen] or nil
            if sc ~= nil then self:setDefaultMenuVisible(sc, true) end
        end
        self.hidden = false
        self.lmb = false
        if not g_gui:getIsGuiVisible() and g_time - (self.openAt or 0) > 1500 then self.active = false end
        return
    end

    if self.active then
        if self.data == nil then self:buildData() end
        if not self.hidden then
            self:setDefaultMenuVisible(screen, false)
            self.hidden = true
        end
        if self.lmb and screen.cursor ~= nil then
            local x, y, z = screen.cursor:getHitTerrainPosition()
            if x ~= nil then
                local step = math.max(0.5, self.radius * 0.5)
                local moved = self.lastX == nil
                if not moved then
                    local dx, dz = x - self.lastX, z - self.lastZ
                    moved = dx * dx + dz * dz >= step * step
                end
                if moved then
                    self.lastX, self.lastZ = x, z
                    self:applyAt(x, y, z)
                end
            end
        end
        if self.rmb and screen.cursor ~= nil then
            local x, y, z = screen.cursor:getHitTerrainPosition()
            if x ~= nil then
                local step = math.max(0.5, self.radius * 0.4)
                local moved = self.lastEraseX == nil
                if not moved then
                    local dx, dz = x - self.lastEraseX, z - self.lastEraseZ
                    moved = dx * dx + dz * dz >= step * step
                end
                if moved then
                    self.lastEraseX, self.lastEraseZ = x, z
                    self:eraseAt(x, y, z)
                end
            end
        end
    elseif self.hidden then
        self:setDefaultMenuVisible(screen, true)
        self.hidden = false
        self.lmb = false
        self.rmb = false
    end
end

function P:drawOverlay()
    if g_dedicatedServer ~= nil then return end
    local screen = getScreen()
    if screen == nil then return end
    self:drawTab(screen)
    if not self.active or self.data == nil then return end
    local px, py, pw, ph = panelRect(screen)
    self.panelBounds = { x = px, y = py, w = pw, h = ph }
    self:drawPanel(screen)
    self:drawMarker(screen)
end

if ConstructionScreen ~= nil then
    ConstructionScreen.mouseEvent = Utils.appendedFunction(ConstructionScreen.mouseEvent, function(self, posX, posY, isDown, isUp, button)
        MBSPanel:handleMouse(posX, posY, isDown, isUp, button)
    end)

    for _, fname in ipairs({ "setCurrentCategory", "setBrush" }) do
        if ConstructionScreen[fname] ~= nil then
            ConstructionScreen[fname] = Utils.appendedFunction(ConstructionScreen[fname], function()
                MBSPanel:onNativeSelect()
            end)
        end
    end

    ConstructionScreen.draw = Utils.appendedFunction(ConstructionScreen.draw, function(self)
        MBSPanel:drawOverlay()
    end)
end

-- F1 help: register our actions together with the brush actions of the construction screen
if ConstructionScreen ~= nil and ConstructionScreen.registerBrushActionEvents ~= nil then
    ConstructionScreen.registerBrushActionEvents = Utils.appendedFunction(ConstructionScreen.registerBrushActionEvents, function(self)
        if self.brush == nil or self.brushEvents == nil then return end
        local list = {
            { InputAction.MBS_TOGGLE, MBSPanel.onToggleAction, "input_MBS_TOGGLE" },
            { InputAction.MBS_UNDO, MBSPanel.onUndoAction, "input_MBS_UNDO" },
        }
        for _, a in ipairs(list) do
            if a[1] ~= nil then
                local _, id = g_inputBinding:registerActionEvent(a[1], MBSPanel, a[2], false, true, false, true)
                if id ~= nil then
                    g_inputBinding:setActionEventText(id, g_i18n:getText(a[3]))
                    g_inputBinding:setActionEventTextPriority(id, GS_PRIO_HIGH)
                    g_inputBinding:setActionEventTextVisibility(id, true)
                    table.insert(self.brushEvents, id)
                end
            end
        end
    end)
end

addModEventListener(MBSPanel)
