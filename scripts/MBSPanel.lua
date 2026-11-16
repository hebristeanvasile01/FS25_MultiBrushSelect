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
    weights = {},       -- key -> share (percent), every kind sums to 100
    selVersion = 0,
    rules = nil,        -- tree / terrain rules (see defaultRules)
    zone = nil,         -- drawn area that is filled live with the current selection
    cursorX = nil, cursorY = nil, cursorZ = nil,
}
local P = MBSPanel
P.modDir = g_currentModDirectory

local R_MIN, R_MAX = 1, 25
local KINDS = { "texture", "foliage", "tree" }
local KIND_LABEL = { texture = "Textures", foliage = "Foliage", tree = "Trees" }
local SPACING = 1.3
local AGE_LABEL = { "As selected", "Random", "Young", "Old" }
local ALT_OFF_MIN, ALT_OFF_MAX = -100, 1500
local function defaultRules()
    return { gap = 1.0, age = 1, slope = 90, altMin = ALT_OFF_MIN, altMax = ALT_OFF_MAX, field = false, road = false, building = false }
end
P.rules = defaultRules()

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
    self.selVersion = self.selVersion + 1
    if self.selected[entry.key] ~= nil then
        self.selected[entry.key] = nil
        self.weights[entry.key] = nil
        self.selectedCount = self.selectedCount - 1
    else
        self.selected[entry.key] = entry
        self.weights[entry.key] = nil
        self.selectedCount = self.selectedCount + 1
    end
    self:normalize(entry.kind)
    self:zoneTouch()
end

function P:clear()
    self.selCache = nil
    self.selVersion = self.selVersion + 1
    self.selected = {}
    self.weights = {}
    self.selectedCount = 0
    self:zoneTouch()
end

----------------------------------------------------------------------------
-- mix: share (percent) of every selected item inside its kind
----------------------------------------------------------------------------
function P:normalize(kind)
    local list = self:selectedOf(kind)
    local n = #list
    if n == 0 then return end
    local sum = 0
    for _, e in ipairs(list) do
        local w = self.weights[e.key]
        if w == nil or w <= 0 then w = 100 / n end
        self.weights[e.key] = w
        sum = sum + w
    end
    for _, e in ipairs(list) do self.weights[e.key] = self.weights[e.key] * 100 / sum end
end

function P:share(e)
    return self.weights[e.key] or (100 / math.max(1, #self:selectedOf(e.kind)))
end

function P:setShare(e, value)
    local list = self:selectedOf(e.kind)
    local n = #list
    if n <= 1 then return end
    value = math.max(1, math.min(99, value))
    local cur = self:share(e)
    local others = 100 - cur
    for _, o in ipairs(list) do
        if o.key ~= e.key then
            local w = self:share(o)
            if others > 0.001 then
                self.weights[o.key] = w * (100 - value) / others
            else
                self.weights[o.key] = (100 - value) / (n - 1)
            end
        end
    end
    self.weights[e.key] = value
    self:zoneTouch()
end

function P:pickWeighted(list)
    local n = #list
    if n == 1 then return list[1] end
    local total = 0
    for _, e in ipairs(list) do total = total + (self.weights[e.key] or (100 / n)) end
    local r = math.random() * total
    for _, e in ipairs(list) do
        r = r - (self.weights[e.key] or (100 / n))
        if r <= 0 then return e end
    end
    return list[n]
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
            w = {},
            rules = defaultRules(),
        }
        local r = p.rules
        r.gap = getXMLFloat(xml, base .. "#gap") or r.gap
        r.age = getXMLInt(xml, base .. "#age") or r.age
        r.slope = getXMLInt(xml, base .. "#slope") or r.slope
        r.altMin = getXMLInt(xml, base .. "#altMin") or r.altMin
        r.altMax = getXMLInt(xml, base .. "#altMax") or r.altMax
        r.field = getXMLBool(xml, base .. "#field") or false
        r.road = getXMLBool(xml, base .. "#road") or false
        r.building = getXMLBool(xml, base .. "#building") or false
        local j = 0
        while true do
            local kb = string.format("%s.item(%d)", base, j)
            if not hasXMLProperty(xml, kb) then break end
            local k = getXMLString(xml, kb .. "#key")
            if k ~= nil then
                table.insert(p.keys, k)
                local wv = getXMLFloat(xml, kb .. "#w")
                if wv ~= nil then p.w[k] = wv end
            end
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
        local r = p.rules or defaultRules()
        setXMLFloat(xml, base .. "#gap", r.gap)
        setXMLInt(xml, base .. "#age", r.age)
        setXMLInt(xml, base .. "#slope", r.slope)
        setXMLInt(xml, base .. "#altMin", r.altMin)
        setXMLInt(xml, base .. "#altMax", r.altMax)
        setXMLBool(xml, base .. "#field", r.field == true)
        setXMLBool(xml, base .. "#road", r.road == true)
        setXMLBool(xml, base .. "#building", r.building == true)
        for j, k in ipairs(p.keys) do
            local ib = string.format("%s.item(%d)", base, j - 1)
            setXMLString(xml, ib .. "#key", k)
            if p.w ~= nil and p.w[k] ~= nil then setXMLFloat(xml, ib .. "#w", p.w[k]) end
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
    local w, rules = {}, {}
    for _, k in ipairs(keys) do w[k] = self.weights[k] end
    for k, v in pairs(self.rules) do rules[k] = v end
    local preset = { name = text, radius = self.radius, density = self.density, keys = keys, w = w, rules = rules }
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
        if e ~= nil then
            self.selected[k] = e
            self.selectedCount = self.selectedCount + 1
            if p.w ~= nil and p.w[k] ~= nil then self.weights[k] = p.w[k] end
        end
    end
    for _, kind in ipairs(KINDS) do self:normalize(kind) end
    local rules = defaultRules()
    if p.rules ~= nil then for k, v in pairs(p.rules) do rules[k] = v end end
    self.rules = rules
    self.radius = math.max(R_MIN, math.min(R_MAX, p.radius or self.radius))
    self.density = math.max(10, math.min(300, p.density or self.density))
    self:zoneTouch()
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

----------------------------------------------------------------------------
-- terrain rules: slope, altitude, fields, roads / buildings
----------------------------------------------------------------------------
local function slopeDeg(x, z)
    local h1 = getTerrainHeightAtWorldPos(g_terrainNode, x + 1, 0, z)
    local h2 = getTerrainHeightAtWorldPos(g_terrainNode, x - 1, 0, z)
    local h3 = getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z + 1)
    local h4 = getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z - 1)
    local gx, gz = (h1 - h2) / 2, (h3 - h4) / 2
    return math.deg(math.atan(math.sqrt(gx * gx + gz * gz)))
end
P.slopeDeg = slopeDeg

local rayHit = nil
function P:rayCb(hitObjectId)
    rayHit = hitObjectId
    return false
end

local maskCache = nil
local function blockMasks()
    if maskCache == nil then
        local function flag(name)
            if CollisionFlag ~= nil and type(CollisionFlag[name]) == "number" then return CollisionFlag[name] end
            return nil
        end
        local stat, road, build = flag("STATIC_OBJECT") or 0, flag("ROAD") or 0, flag("BUILDING") or 0
        maskCache = { road = road + stat, building = build + stat }
        Logging.info('[MultiBrushSelect] avoid masks: road=%d building=%d (STATIC_OBJECT=%s ROAD=%s BUILDING=%s)',
            maskCache.road, maskCache.building, tostring(flag("STATIC_OBJECT")), tostring(flag("ROAD")), tostring(flag("BUILDING")))
    end
    return maskCache
end

local function blockedBy(x, y, z, mask)
    if mask == nil or mask == 0 or raycastClosest == nil then return false end
    rayHit = nil
    local ok = pcall(raycastClosest, x, y + 30, z, 0, -1, 0, 60, "rayCb", MBSPanel, mask)
    return ok and rayHit ~= nil
end

local function inField(x, z)
    local fm = g_fieldManager
    if fm == nil or fm.getFieldAtWorldPosition == nil then return false end
    local ok, field = pcall(fm.getFieldAtWorldPosition, fm, x, z)
    return ok and field ~= nil
end

function P:rulesActive()
    local r = self.rules
    return r.slope < 90 or r.altMin > ALT_OFF_MIN or r.altMax < ALT_OFF_MAX or r.field or r.road or r.building
end

function P:placeOk(px, py, pz)
    local r = self.rules
    if r.altMin > ALT_OFF_MIN and py < r.altMin then return false end
    if r.altMax < ALT_OFF_MAX and py > r.altMax then return false end
    if r.slope < 90 and slopeDeg(px, pz) > r.slope then return false end
    if r.field and inField(px, pz) then return false end
    if r.road and blockedBy(px, py, pz, blockMasks().road) then return false end
    if r.building and blockedBy(px, py, pz, blockMasks().building) then return false end
    return true
end

-- growth stage for a tree pick, following the "Tree age" rule
function P:treeStage(pick, desc)
    local n = #desc.stages
    local mode = self.rules.age
    local s = math.min(pick.treeStage or 1, n)
    if mode == 2 then
        s = math.random(1, n)
    elseif mode == 3 then
        s = math.random(1, math.max(1, math.ceil(n / 3)))
    elseif mode == 4 then
        s = math.random(math.max(1, n - math.ceil(n / 3) + 1), n)
    end
    return s
end

function P:avgCrown(trees)
    local mode = self.rules.age
    if mode == 2 then return MBSPanel.crownRadius(0.5) end
    if mode == 3 then return MBSPanel.crownRadius(0.17) end
    if mode == 4 then return MBSPanel.crownRadius(0.83) end
    local sum = 0
    for _, t in ipairs(trees) do
        local d = g_treePlantManager:getTreeTypeDescFromName(t.treeType)
        local n = (d ~= nil and d.stages ~= nil) and #d.stages or 1
        sum = sum + MBSPanel.crownRadius((t.treeStage or 1) / math.max(1, n))
    end
    return sum / math.max(1, #trees)
end

-- plants one tree if the spot is free and allowed. Returns { cr, price, node } or nil; second value true = stop (no money / limit)
function P:plantTreeAt(pick, px, pz, mem, budget)
    local desc = g_treePlantManager:getTreeTypeDescFromName(pick.treeType)
    if desc == nil or desc.stages == nil or #desc.stages == 0 then return nil end
    local stage = self:treeStage(pick, desc)
    local variations = desc.stages[stage]
    if variations == nil or #variations == 0 then return nil end
    local cr = MBSPanel.crownRadius(stage / #desc.stages)
    local gap = self.rules.gap
    for _, m in ipairs(mem) do
        local dx, dz = m[1] - px, m[2] - pz
        local need = m[3] + cr + gap
        if dx * dx + dz * dz < need * need then return nil end
    end
    local py = getTerrainHeightAtWorldPos(g_terrainNode, px, 0, pz)
    if not canUse(px, py, pz) or not self:placeOk(px, py, pz) then return nil end
    local variation = self.rules.age == 1 and pick.variationIndex or math.random(1, #variations)
    variation = math.min(variation, #variations)
    local price = 0
    if pick.storeItem ~= nil then
        price = MathUtil.lerp(0, g_currentMission.economyManager:getBuyPrice(pick.storeItem), stage / #desc.stages)
    end
    if not g_treePlantManager:canPlantTree() or price > budget.left then return nil, true end
    budget.left = budget.left - price
    local farmId = g_localPlayer.farmId
    local ry = math.random() * 2 * math.pi
    local node = nil
    if g_server ~= nil then
        node = g_treePlantManager:plantTree(desc.index, px, py, pz, 0, ry, 0, stage, variation, false)
        g_currentMission:addMoney(-price, farmId, MoneyType.SHOP_PROPERTY_BUY, true)
    else
        sendEvent(TreePlantEvent.new(desc.index, px, py, pz, 0, ry, 0, stage, variation, nil, false, price, farmId))
    end
    table.insert(mem, { px, pz, cr })
    return { cr = cr, price = price, node = node }
end

function P:applyAt(x, y, z)
    if not canUse(x, y, z) then return end
    local r = self.radius
    local dens = self.density / 100
    local shape = Landscaping.BRUSH_SHAPE.CIRCLE
    local ruled = self:rulesActive()

    -- textures: random small patches so the textures are mixed (weighted by the Mix shares)
    local tex = self:selectedOf("texture")
    if #tex > 0 then
        local sr = math.max(0.5, math.min(1.5, r / 2))
        local n = math.min(14, math.max(1, math.ceil((r * r) / (sr * sr) * 0.5 * dens)))
        if #tex == 1 then n = 1 sr = r end
        for _ = 1, n do
            local px, pz = x, z
            if #tex > 1 then px, pz = randomInCircle(x, z, math.max(0, r - sr)) end
            local py = getTerrainHeightAtWorldPos(g_terrainNode, px, 0, pz)
            if not ruled or self:placeOk(px, py, pz) then
                local pick = self:pickWeighted(tex)
                sendEvent(LandscapingSculptEvent.new(false, Landscaping.OPERATION.PAINT, px, py, pz, nil, nil, nil, nil, nil, nil, sr, 1, shape, 1, pick.layer))
            end
        end
    end

    -- foliage: random patches, each picks one of the selected types (weighted)
    local fol = self:selectedOf("foliage")
    if #fol > 0 then
        local sr = math.max(0.5, math.min(1.5, r / 2))
        local n = math.min(30, math.max(#fol, math.ceil((r * r) / (sr * sr) * 0.7 * dens)))
        for _ = 1, n do
            local px, pz = randomInCircle(x, z, math.max(0, r - sr))
            local py = getTerrainHeightAtWorldPos(g_terrainNode, px, 0, pz)
            if not ruled or self:placeOk(px, py, pz) then
                local pick = self:pickWeighted(fol)
                sendEvent(LandscapingSculptEvent.new(false, Landscaping.OPERATION.FOLIAGE, px, py, pz, nil, nil, nil, nil, nil, nil, sr, 1, shape, 0, nil, pick.foliagePaint.id, pick.foliageState))
            end
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
        local budget = { left = g_currentMission:getMoney() }
        local area = math.pi * r * r
        local avgCr = self:avgCrown(trees)
        local expected = dens * area / ((2 * avgCr + self.rules.gap + 0.5) ^ 2) * 0.6
        local want = math.floor(expected)
        if math.random() < expected - want then want = want + 1 end
        local planted = 0
        for _ = 1, want * 12 do
            if planted >= want then break end
            local px, pz = randomInCircle(x, z, r)
            local pick = self:pickWeighted(trees)
            local res, stop = self:plantTreeAt(pick, px, pz, self.treeMem, budget)
            if stop then break end
            if res ~= nil then
                planted = planted + 1
                if res.node ~= nil then
                    self.curStroke = self.curStroke or {}
                    table.insert(self.curStroke, res.node)
                end
                if #self.treeMem > 500 then table.remove(self.treeMem, 1) end
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
-- zone: draw an area with the knife tool (or use a square). Everything selected is filled in live.
----------------------------------------------------------------------------
local ZONE_GRID_MAX = 12000
local ZONE_ITEMS_PER_FRAME = 80
local function nowMs()
    if os ~= nil and os.clock ~= nil then return os.clock() * 1000 end
    if getTimeSec ~= nil then return getTimeSec() * 1000 end
    return 0
end
local ZONE_CLOSE_DIST = 3.0
local ZONE_HANDLE_DIST = 3.5

local function pointInPoly(poly, x, z)
    local inside = false
    local j = #poly
    for i = 1, #poly do
        local xi, zi, xj, zj = poly[i][1], poly[i][2], poly[j][1], poly[j][2]
        if ((zi > z) ~= (zj > z)) and (x < (xj - xi) * (z - zi) / (zj - zi) + xi) then inside = not inside end
        j = i
    end
    return inside
end

local function polyArea(poly)
    local a = 0
    local j = #poly
    for i = 1, #poly do
        a = a + (poly[j][1] + poly[i][1]) * (poly[j][2] - poly[i][2])
        j = i
    end
    return math.abs(a) / 2
end

local function polyBounds(poly)
    local minx, maxx, minz, maxz = math.huge, -math.huge, math.huge, -math.huge
    for _, p in ipairs(poly) do
        minx, maxx = math.min(minx, p[1]), math.max(maxx, p[1])
        minz, maxz = math.min(minz, p[2]), math.max(maxz, p[2])
    end
    return minx, maxx, minz, maxz
end

-- grid points inside the polygon (nil when the area is too large)
local function gridPoints(poly, step, jitter)
    local minx, maxx, minz, maxz = polyBounds(poly)
    if ((maxx - minx) / step + 1) * ((maxz - minz) / step + 1) > ZONE_GRID_MAX then return nil end
    local out = {}
    local x = minx
    while x <= maxx do
        local zz = minz
        while zz <= maxz do
            local px, pz = x, zz
            if jitter then
                px = px + (math.random() - 0.5) * step * 0.6
                pz = pz + (math.random() - 0.5) * step * 0.6
            end
            if pointInPoly(poly, px, pz) then out[#out + 1] = { px, pz } end
            zz = zz + step
        end
        x = x + step
    end
    return out
end

local function distToSeg(px, pz, a, b)
    local dx, dz = b[1] - a[1], b[2] - a[2]
    local len2 = dx * dx + dz * dz
    local t = 0
    if len2 > 0 then t = math.max(0, math.min(1, ((px - a[1]) * dx + (pz - a[2]) * dz) / len2)) end
    local cx, cz = a[1] + dx * t, a[2] + dz * t
    return math.sqrt((px - cx) ^ 2 + (pz - cz) ^ 2)
end

function P:zoneTouch()
    local z = self.zone
    if z ~= nil and not z.drawing then
        z.dirty = true
        z.dirtyAt = g_time or 0
    end
end

function P:zoneNewSquare()
    local x, zz = self.cursorX, self.cursorZ
    if x == nil then return end
    local s = 10
    self.zone = { pts = { { x - s, zz - s }, { x + s, zz - s }, { x + s, zz + s }, { x - s, zz + s } },
        live = true, trees = {}, dirty = true, dirtyAt = g_time or 0 }
    self.zoneDrag = nil
end

function P:zoneStartDraw()
    if self.zone ~= nil then
        if self.zone.queue ~= nil then return end
        self:zoneFinish()
    end
    self.zone = { pts = {}, drawing = true, live = true, trees = {} }
    self.zoneDrag = nil
end

function P:zoneClose()
    local z = self.zone
    if z == nil or #z.pts < 3 then return end
    z.drawing = false
    z.lines = nil
    z.dirty = true
    z.dirtyAt = g_time or 0
end

function P:zoneNearest(x, zz, maxD)
    local z = self.zone
    if z == nil or x == nil then return nil end
    local best, bd
    for i, p in ipairs(z.pts) do
        local d = math.sqrt((p[1] - x) ^ 2 + (p[2] - zz) ^ 2)
        if d <= maxD and (bd == nil or d < bd) then best, bd = i, d end
    end
    return best
end

function P:zoneInsertOnEdge(x, zz)
    local z = self.zone
    local n = #z.pts
    local bd, bi
    for i = 1, n do
        local d = distToSeg(x, zz, z.pts[i], z.pts[(i % n) + 1])
        if bd == nil or d < bd then bd, bi = d, i end
    end
    if bi ~= nil and bd < 4 then
        table.insert(z.pts, bi + 1, { x, zz })
        z.lines = nil
        self:zoneTouch()
        return bi + 1
    end
    return nil
end

function P:zoneAddPoint()
    local z = self.zone
    if z == nil or z.drawing or #z.pts < 3 then return end
    local n = #z.pts
    local bi, bl = 1, -1
    for i = 1, n do
        local a, b = z.pts[i], z.pts[(i % n) + 1]
        local l = (a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2
        if l > bl then bi, bl = i, l end
    end
    local a, b = z.pts[bi], z.pts[(bi % n) + 1]
    table.insert(z.pts, bi + 1, { (a[1] + b[1]) / 2, (a[2] + b[2]) / 2 })
    z.lines = nil
    self:zoneTouch()
end

function P:zoneRemovePoint(i)
    local z = self.zone
    if z == nil or z.drawing or #z.pts <= 3 then return end
    table.remove(z.pts, i or #z.pts)
    z.lines = nil
    self.zoneDrag = nil
    self:zoneTouch()
end

function P:zoneMouseDown()
    local z = self.zone
    local x, zz = self.cursorX, self.cursorZ
    if z == nil or x == nil then return end
    if z.drawing then
        if #z.pts >= 3 then
            local d = math.sqrt((z.pts[1][1] - x) ^ 2 + (z.pts[1][2] - zz) ^ 2)
            if d < ZONE_CLOSE_DIST then
                self:zoneClose()
                return
            end
        end
        table.insert(z.pts, { x, zz })
        z.lines = nil
        return
    end
    local i = self:zoneNearest(x, zz, ZONE_HANDLE_DIST)
    if i == nil and isShift() then i = self:zoneInsertOnEdge(x, zz) end
    if i ~= nil then self.zoneDrag = i end
end

function P:zoneRightDown()
    local z = self.zone
    if z == nil then return end
    if z.drawing then
        if #z.pts > 0 then
            table.remove(z.pts)
            z.lines = nil
        else
            self.zone = nil
        end
        return
    end
    local i = self:zoneNearest(self.cursorX, self.cursorZ, ZONE_HANDLE_DIST)
    if i ~= nil then self:zoneRemovePoint(i) end
end

function P:zoneStatus()
    local z = self.zone
    if z == nil then return "" end
    if z.drawing then return "drawing" end
    if z.tooLarge then return "zone too large" end
    if z.queue ~= nil then
        return string.format("updating %d%%", math.floor((z.qi - 1) / math.max(1, #z.queue) * 100))
    end
    if z.dirty then return z.live and "waiting" or "changed" end
    return "up to date"
end

function P:zoneRemoveTrees(keepPoly)
    local z = self.zone
    if z == nil or #z.trees == 0 then return end
    local refund, cx, cz = 0, nil, nil
    local kept = {}
    for _, rec in ipairs(z.trees) do
        local alive = rec.node ~= nil and entityExists(rec.node)
        if alive and keepPoly ~= nil and rec.x ~= nil and pointInPoly(keepPoly, rec.x, rec.z) then
            table.insert(kept, rec)
        elseif alive then
            if rec.x ~= nil then
                cx, cz = rec.x, rec.z
            else
                local nx, _ny, nz = getWorldTranslation(rec.node)
                cx, cz = nx, nz
            end
            removeTreeNode(rec.node)
            refund = refund + (rec.price or 0)
        end
    end
    z.trees = kept
    if refund > 0 and g_server ~= nil then
        g_currentMission:addMoney(refund, g_localPlayer.farmId, MoneyType.SHOP_PROPERTY_SELL or MoneyType.SHOP_PROPERTY_BUY, true)
    end
    if cx ~= nil then self:cleanupTrees(cx, cz) end
end

-- everything that changes what the zone contains except its shape
function P:zoneSig()
    local r = self.rules
    local parts = { self.selVersion, self.density, r.gap, r.age, r.slope, r.altMin, r.altMax, tostring(r.field), tostring(r.road), tostring(r.building) }
    for _, kind in ipairs(KINDS) do
        for _, e in ipairs(self:selectedOf(kind)) do
            parts[#parts + 1] = e.key .. "=" .. string.format("%.1f", self:share(e))
        end
    end
    return table.concat(parts, "|")
end

local function distToPoly(poly, x, z)
    local best = math.huge
    local n = #poly
    for i = 1, n do
        best = math.min(best, distToSeg(x, z, poly[i], poly[(i % n) + 1]))
    end
    return best
end

-- builds the work queue that (re)fills the zone. When only the shape changed, just the changed parts are redone.
function P:zoneStart()
    local z = self.zone
    if z == nil or z.queue ~= nil or z.drawing or #z.pts < 3 then return end
    z.dirty = false
    z.tooLarge = false
    z.lastRun = g_time or 0
    local poly = {}
    for i, p in ipairs(z.pts) do poly[i] = { p[1], p[2] } end
    local area = polyArea(poly)
    local dens = self.density / 100
    local tex, fol, trees = self:selectedOf("texture"), self:selectedOf("foliage"), self:selectedOf("tree")
    local ruled = self:rulesActive()
    local q = {}

    local sig = self:zoneSig()
    local prev = (z.sig == sig and z.prevPoly ~= nil) and z.prevPoly or nil   -- incremental when only the shape changed
    z.sig = sig
    local function newOnly(pts)
        if prev == nil then return pts end
        local out = {}
        for _, p in ipairs(pts) do
            if not pointInPoly(prev, p[1], p[2]) then out[#out + 1] = p end
        end
        return out
    end

    local skipTrees = g_server == nil and z.clientTrees == true
    if not skipTrees then table.insert(q, { op = "removeTrees", keep = prev ~= nil and poly or nil }) end

    if z.hadFoliage and z.prevPoly ~= nil then
        local pts = gridPoints(z.prevPoly, 2.0, false)
        if pts ~= nil then
            for _, p in ipairs(pts) do
                -- incremental: only the area that really left the zone (stay 1.5 m clear of the new edge)
                if prev == nil or (not pointInPoly(poly, p[1], p[2]) and distToPoly(poly, p[1], p[2]) > 1.5) then
                    table.insert(q, { op = "erase", x = p[1], z = p[2] })
                end
            end
        end
    end

    if #tex > 0 then
        local single = #tex == 1
        local step, rad = single and 3.0 or 2.0, single and 2.2 or 1.5
        local pts = gridPoints(poly, step, not single)
        if pts == nil then z.tooLarge = true else
            for _, p in ipairs(newOnly(pts)) do
                local pick = self:pickWeighted(tex)
                table.insert(q, { op = "tex", x = p[1], z = p[2], r = rad, layer = pick.layer, ruled = ruled })
            end
        end
    end

    if #fol > 0 then
        local pts = gridPoints(poly, 2.0, true)
        if pts == nil then z.tooLarge = true else
            for _, p in ipairs(newOnly(pts)) do
                if dens >= 1 or math.random() < dens then
                    local pick = self:pickWeighted(fol)
                    table.insert(q, { op = "fol", x = p[1], z = p[2], r = 1.5, id = pick.foliagePaint.id, state = pick.foliageState, ruled = ruled })
                end
            end
        end
    end

    if #trees > 0 and g_treePlantManager ~= nil and not skipTrees then
        local avgCr = self:avgCrown(trees)
        local want = math.min(500, math.floor(dens * area / ((2 * avgCr + self.rules.gap + 0.5) ^ 2) * 0.7 + 0.5))
        if want > 0 then
            local minx, maxx, minz, maxz = polyBounds(poly)
            local maxTries = math.max(60, want * 15)
            z.fill = { want = want, planted = 0, tries = 0, maxTries = maxTries, mem = {}, trees = trees,
                poly = poly, minx = minx, maxx = maxx, minz = minz, maxz = maxz }
            table.insert(q, { op = "treeInit" })
            for _ = 1, math.ceil(maxTries / 40) do table.insert(q, { op = "treeChunk" }) end
            if g_server == nil then z.clientTrees = true end
        end
    end

    z.queue, z.qi, z.pendingPoly, z.pendingFoliage = q, 1, poly, #fol > 0
end

function P:zoneRemoveContent()
    local z = self.zone
    if z == nil or z.queue ~= nil or z.drawing then return end
    local q = { { op = "removeTrees" } }
    if z.hadFoliage and z.prevPoly ~= nil then
        local pts = gridPoints(z.prevPoly, 2.0, false)
        if pts ~= nil then
            for _, p in ipairs(pts) do table.insert(q, { op = "erase", x = p[1], z = p[2] }) end
        end
    end
    z.queue, z.qi, z.pendingPoly, z.pendingFoliage = q, 1, nil, false
    z.dirty = false
end

-- ends the zone but keeps everything it created (trees can still be undone with Undo trees)
function P:zoneFinish()
    local z = self.zone
    if z == nil or z.queue ~= nil then return end
    if #z.trees > 0 then
        local nodes = {}
        for _, rec in ipairs(z.trees) do table.insert(nodes, rec.node) end
        self.strokes = self.strokes or {}
        table.insert(self.strokes, nodes)
    end
    self.zone = nil
    self.zoneDrag = nil
end

function P:zoneItem(it)
    local z = self.zone
    local op = it.op
    local shape = Landscaping.BRUSH_SHAPE.CIRCLE
    if op == "removeTrees" then
        self:zoneRemoveTrees(it.keep)
    elseif op == "erase" then
        local noBrush = TerrainDeformation ~= nil and TerrainDeformation.NO_TERRAIN_BRUSH or nil
        local py = getTerrainHeightAtWorldPos(g_terrainNode, it.x, 0, it.z)
        if canUse(it.x, py, it.z) then
            sendEvent(LandscapingSculptEvent.new(false, Landscaping.OPERATION.PAINT, it.x, py, it.z, nil, nil, nil, nil, nil, nil, it.r or 1.5, 1, shape, 0, noBrush))
        end
    elseif op == "pathTrees" then
        self:pathEraseTrees(it.pts, it.half)
    elseif op == "flat" then
        if Landscaping.OPERATION.FLATTEN ~= nil and canUse(it.x, it.y, it.z) then
            sendEvent(LandscapingSculptEvent.new(false, Landscaping.OPERATION.FLATTEN, it.x, it.y, it.z, 0, 1, 0, 0, 0, 0, it.r, 1, shape, 0))
        end
    elseif op == "smooth" then
        local py = getTerrainHeightAtWorldPos(g_terrainNode, it.x, 0, it.z)
        if Landscaping.OPERATION.SMOOTH ~= nil and canUse(it.x, py, it.z) then
            sendEvent(LandscapingSculptEvent.new(false, Landscaping.OPERATION.SMOOTH, it.x, py, it.z, 0, 1, 0, 0, 0, 0, it.r, 1, shape, 0))
        end
    elseif op == "tex" or op == "fol" then
        local py = getTerrainHeightAtWorldPos(g_terrainNode, it.x, 0, it.z)
        if canUse(it.x, py, it.z) and (not it.ruled or self:placeOk(it.x, py, it.z)) then
            if op == "tex" then
                sendEvent(LandscapingSculptEvent.new(false, Landscaping.OPERATION.PAINT, it.x, py, it.z, nil, nil, nil, nil, nil, nil, it.r, 1, shape, 1, it.layer))
            else
                sendEvent(LandscapingSculptEvent.new(false, Landscaping.OPERATION.FOLIAGE, it.x, py, it.z, nil, nil, nil, nil, nil, nil, it.r, 1, shape, 0, nil, it.id, it.state))
            end
        end
    elseif op == "treeInit" then
        local f = z.fill
        f.budget = { left = g_currentMission:getMoney() }
        -- trees that stayed in the zone count and keep their space
        for _, rec in ipairs(z.trees) do
            if rec.x ~= nil then table.insert(f.mem, { rec.x, rec.z, rec.cr or 2 }) end
        end
        f.planted = #z.trees
    elseif op == "treeChunk" then
        local f = z.fill
        if f == nil or f.budget == nil then return end
        local placedNow = 0
        for _ = 1, 40 do
            if f.planted >= f.want or placedNow >= 8 or f.tries >= f.maxTries then break end
            f.tries = f.tries + 1
            local px = f.minx + math.random() * (f.maxx - f.minx)
            local pz = f.minz + math.random() * (f.maxz - f.minz)
            if pointInPoly(f.poly, px, pz) then
                local pick = self:pickWeighted(f.trees)
                local res, stop = self:plantTreeAt(pick, px, pz, f.mem, f.budget)
                if stop then
                    f.tries = f.maxTries
                    break
                end
                if res ~= nil then
                    f.planted = f.planted + 1
                    placedNow = placedNow + 1
                    if res.node ~= nil then table.insert(z.trees, { node = res.node, price = res.price, x = px, z = pz, cr = res.cr }) end
                end
            end
        end
    end
end

function P:zoneStep()
    local z = self.zone
    local q = z.queue
    if q == nil then return end
    local n = 0
    local t0 = nowMs()
    while n < ZONE_ITEMS_PER_FRAME and z.qi <= #q do
        if n >= 8 and nowMs() - t0 > 6 then break end
        local it = q[z.qi]
        z.qi = z.qi + 1
        n = n + 1
        local ok, err = pcall(self.zoneItem, self, it)
        if not ok and not z.errLogged then
            z.errLogged = true
            Logging.error('[MultiBrushSelect] zone error (%s): %s', tostring(it.op), tostring(err))
        end
    end
    if z.qi > #q then
        z.queue = nil
        z.fill = nil
        z.prevPoly = z.pendingPoly
        z.hadFoliage = z.pendingFoliage
    end
end

function P:zoneTick()
    local z = self.zone
    if z == nil then return end
    if self.zoneDrag ~= nil and not z.drawing and self.cursorX ~= nil then
        local p = z.pts[self.zoneDrag]
        if p ~= nil and (math.abs(p[1] - self.cursorX) > 0.05 or math.abs(p[2] - self.cursorZ) > 0.05) then
            p[1], p[2] = self.cursorX, self.cursorZ
            z.lines = nil
            z.dirty = true
            z.dirtyAt = g_time
        end
    end
    if z.queue ~= nil then
        self:zoneStep()
        return
    end
    if z.dirty and z.live and not z.drawing then
        local pause = g_time - (z.dirtyAt or 0) >= 120
        local dragging = self.zoneDrag ~= nil and g_time - (z.lastRun or 0) >= 100
        if pause or dragging then self:zoneStart() end
    end
end

local function sampleSeg(out, a, b)
    local len = math.sqrt((b[1] - a[1]) ^ 2 + (b[2] - a[2]) ^ 2)
    local steps = math.max(1, math.ceil(len / 2.5))
    local prev
    for s = 0, steps do
        local t = s / steps
        local x, zz = a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t
        local p = { x, getTerrainHeightAtWorldPos(g_terrainNode, x, 0, zz) + 0.25, zz }
        if prev ~= nil then out[#out + 1] = { prev, p } end
        prev = p
    end
end

function P:drawZone(screen)
    local z = self.zone
    if z == nil or #z.pts == 0 then return end
    if z.lines == nil then
        local out = {}
        local n = #z.pts
        for i = 1, n - 1 do sampleSeg(out, z.pts[i], z.pts[i + 1]) end
        if not z.drawing and n >= 3 then sampleSeg(out, z.pts[n], z.pts[1]) end
        z.lines = out
    end
    local lr, lg, lb = 0.65, 1.0, 0.1
    for _, seg in ipairs(z.lines) do
        local a, b = seg[1], seg[2]
        drawDebugLine(a[1], a[2], a[3], lr, lg, lb, b[1], b[2], b[3], lr, lg, lb, false)
    end
    -- preview of the next knife cut
    if z.drawing and self.cursorX ~= nil then
        local last = z.pts[#z.pts]
        local out = {}
        sampleSeg(out, last, { self.cursorX, self.cursorZ })
        for _, seg in ipairs(out) do
            local a, b = seg[1], seg[2]
            drawDebugLine(a[1], a[2], a[3], 1, 1, 1, b[1], b[2], b[3], 1, 1, 1, false)
        end
    end
    local hover = (self.cursorX ~= nil and not self:overPanel(self.mouseX, self.mouseY)) and self:zoneNearest(self.cursorX, self.cursorZ, ZONE_HANDLE_DIST) or nil
    for i, p in ipairs(z.pts) do
        local h = getTerrainHeightAtWorldPos(g_terrainNode, p[1], 0, p[2])
        local cr, cg, cb = 1.0, 0.85, 0.0
        if self.zoneDrag == i then cr, cg, cb = 1.0, 0.2, 0.0
        elseif hover == i then cr, cg, cb = 1, 1, 1
        elseif z.drawing and i == 1 and #z.pts >= 3 then cr, cg, cb = 0.2, 1.0, 1.0 end
        drawDebugLine(p[1], h, p[2], cr, cg, cb, p[1], h + 3.0, p[2], cr, cg, cb, false)
        drawDebugLine(p[1] - 0.7, h + 3.0, p[2], cr, cg, cb, p[1] + 0.7, h + 3.0, p[2], cr, cg, cb, false)
        drawDebugLine(p[1], h + 3.0, p[2] - 0.7, cr, cg, cb, p[1], h + 3.0, p[2] + 0.7, cr, cg, cb, false)
    end
end

----------------------------------------------------------------------------
-- path: cut a path through a forest (trees out, surface painted, terrain smoothed, grass / leaves on the edges)
----------------------------------------------------------------------------
local EDGE_LABEL = { "Auto", "Leaves", "Grass", "Off" }
local MID_LABEL = { "Grass", "Leaves", "Selected", "Off" }
local LANE_LABEL = { "Single", "Double" }
local SURF_LABEL = { "Wheel tracks", "Full road" }
-- width = width of one lane, lanes = 1 / 2, middle = strip between the wheel tracks, texture = key of the wheel track texture (nil = selected textures)
P.pathCfg = { width = 4, lanes = 1, surface = 1, middle = 1, edge = 3, level = true, texture = nil }
P.pathPicking = false
P.drawMode = "zone"

local function pathLength(pts)
    local len = 0
    for i = 1, #pts - 1 do
        len = len + math.sqrt((pts[i + 1][1] - pts[i][1]) ^ 2 + (pts[i + 1][2] - pts[i][2]) ^ 2)
    end
    return len
end

local function distToPolyline(pts, x, z)
    local best = math.huge
    for i = 1, #pts - 1 do best = math.min(best, distToSeg(x, z, pts[i], pts[i + 1])) end
    return best
end

local function nearestPt(pts, x, z, maxD)
    if x == nil then return nil end
    local best, bd
    for i, p in ipairs(pts) do
        local d = math.sqrt((p[1] - x) ^ 2 + (p[2] - z) ^ 2)
        if d <= maxD and (bd == nil or d < bd) then best, bd = i, d end
    end
    return best
end

-- points along the polyline every `step` metres with the unit direction: { x, z, tx, tz }
local function samplePolyline(pts, step)
    local out = {}
    local carry = 0
    for i = 1, #pts - 1 do
        local a, b = pts[i], pts[i + 1]
        local dx, dz = b[1] - a[1], b[2] - a[2]
        local len = math.sqrt(dx * dx + dz * dz)
        if len > 0.001 then
            local tx, tz = dx / len, dz / len
            local d = carry
            while d <= len do
                out[#out + 1] = { a[1] + tx * d, a[2] + tz * d, tx, tz }
                d = d + step
            end
            carry = d - len
        end
    end
    local last = pts[#pts]
    if last ~= nil then
        local o = out[#out]
        if o == nil or math.abs(o[1] - last[1]) + math.abs(o[2] - last[2]) > step * 0.5 then
            out[#out + 1] = { last[1], last[2], o and o[3] or 1, o and o[4] or 0 }
        end
    end
    return out
end

function P:pathStartDraw()
    if self.path ~= nil and self.path.queue ~= nil then return end
    self.path = { pts = {}, drawing = true }
    self.pathDrag = nil
    self.pathNote = nil
end

function P:pathFinishDraw()
    local p = self.path
    if p == nil or #p.pts < 2 then return end
    p.drawing = false
    p.lines = nil
end

function P:pathMouseDown()
    local p = self.path
    local x, zz = self.cursorX, self.cursorZ
    if p == nil or x == nil or p.queue ~= nil then return end
    if p.drawing then
        local n = #p.pts
        if n >= 2 then
            local last = p.pts[n]
            if math.sqrt((last[1] - x) ^ 2 + (last[2] - zz) ^ 2) < 2.0 then
                self:pathFinishDraw()
                return
            end
        end
        table.insert(p.pts, { x, zz })
        p.lines = nil
        return
    end
    local i = nearestPt(p.pts, x, zz, ZONE_HANDLE_DIST)
    if i == nil and isShift() then
        local bd, bi
        for k = 1, #p.pts - 1 do
            local d = distToSeg(x, zz, p.pts[k], p.pts[k + 1])
            if bd == nil or d < bd then bd, bi = d, k end
        end
        if bi ~= nil and bd < 4 then
            table.insert(p.pts, bi + 1, { x, zz })
            p.lines = nil
            i = bi + 1
        end
    end
    if i ~= nil then self.pathDrag = i end
end

function P:pathRightDown()
    local p = self.path
    if p == nil or p.queue ~= nil then return end
    if p.drawing then
        if #p.pts > 0 then
            table.remove(p.pts)
            p.lines = nil
        else
            self.path = nil
        end
        return
    end
    local i = nearestPt(p.pts, self.cursorX, self.cursorZ, ZONE_HANDLE_DIST)
    if i ~= nil and #p.pts > 2 then
        table.remove(p.pts, i)
        p.lines = nil
        self.pathDrag = nil
    end
end

function P:findFoliage(word)
    local out = {}
    if self.data == nil then return out end
    for _, e in ipairs(self.data.foliage) do
        local pn = ""
        if e.foliagePaint ~= nil then pn = tostring(e.foliagePaint.name or e.foliagePaint.paintName or "") end
        if string.find(string.lower(tostring(e.name) .. " " .. pn), word, 1, true) then out[#out + 1] = e end
    end
    return out
end

-- foliage used on the path edges (selected foliage, or leaves / grass found in the game)
function P:pathEdgeList()
    local mode = self.pathCfg.edge
    if mode == 4 or self.data == nil then return {} end
    if mode == 1 then
        local fol = self:selectedOf("foliage")
        if #fol > 0 then return fol end
        local l = self:findFoliage("leaves")
        if #l > 0 then return l end
        return self:findFoliage("grass")
    elseif mode == 2 then
        return self:findFoliage("leaves")
    end
    return self:findFoliage("grass")
end

-- foliage of the strip between the wheel tracks
function P:pathMiddleList()
    local mode = self.pathCfg.middle
    if mode == 4 or self.data == nil then return {} end
    if mode == 2 then return self:findFoliage("leaves") end
    if mode == 3 then
        local fol = self:selectedOf("foliage")
        if #fol > 0 then return fol end
    end
    return self:findFoliage("grass")
end

-- lanes, wheel tracks and clearing width of the path
function P:pathGeom()
    local cfg = self.pathCfg
    local W, lanes, gap, edgeW = cfg.width, cfg.lanes, 1.0, 1.0
    local total = lanes * W + (lanes - 1) * gap          -- road width between the two edge strips
    local centers = { 0 }
    if lanes == 2 then centers = { -(W + gap) / 2, (W + gap) / 2 } end
    local tw = math.max(0.8, math.min(1.4, W * 0.25))   -- width of one wheel track
    return { W = W, total = total, roadHalf = total / 2, edgeW = edgeW, half = total / 2 + edgeW, gap = gap,
        centers = centers, tw = tw,
        ro = W / 2 - tw / 2,                             -- distance of a wheel track from its lane centre
        rr = tw / 2 }                              -- radius of a wheel track patch
end

function P:pathDirty()
    if self.path ~= nil then self.path.lines = nil end
end

function P:pathEraseTrees(pts, half)
    if g_server == nil then
        Logging.info('[MultiBrushSelect] path: removing trees works for the host / singleplayer only')
        return
    end
    local td = g_treePlantManager ~= nil and g_treePlantManager.treesData or nil
    if td == nil then return end
    local victims, cx, cz = {}, nil, nil
    for _, list in ipairs({ td.growingTrees, td.splitTrees }) do
        for _, tree in ipairs(list) do
            if distToPolyline(pts, tree.x, tree.z) <= half + 0.5 then
                table.insert(victims, tree.node)
                cx, cz = tree.x, tree.z
            end
        end
    end
    for _, node in ipairs(victims) do removeTreeNode(node) end
    if #victims > 0 then self:cleanupTrees(cx, cz) end
    Logging.info('[MultiBrushSelect] path: %d trees removed', #victims)
end

function P:pathBuild()
    local p = self.path
    if p == nil or p.drawing or #p.pts < 2 or p.queue ~= nil then return end
    local cfg = self.pathCfg
    local g = self:pathGeom()
    local half = g.half
    local pts = {}
    for i, pt in ipairs(p.pts) do pts[i] = { pt[1], pt[2] } end
    local q = {}

    if not P.opsLogged then
        P.opsLogged = true
        local names = {}
        if Landscaping ~= nil and Landscaping.OPERATION ~= nil then
            for k, v in pairs(Landscaping.OPERATION) do table.insert(names, tostring(k) .. "=" .. tostring(v)) end
        end
        table.sort(names)
        Logging.info('[MultiBrushSelect] landscaping operations: %s', table.concat(names, ", "))
    end

    -- 1. trees out (road + edge strips)
    table.insert(q, { op = "pathTrees", pts = pts, half = half })

    -- 2. level the terrain: follow the ground with a smoothed height profile, then smooth the borders
    if cfg.level and Landscaping ~= nil and Landscaping.OPERATION ~= nil then
        local samples = samplePolyline(pts, 1.5)
        local hs = {}
        for i, sm in ipairs(samples) do hs[i] = getTerrainHeightAtWorldPos(g_terrainNode, sm[1], 0, sm[2]) end
        local n = #samples
        if Landscaping.OPERATION.FLATTEN ~= nil then
            for i, sm in ipairs(samples) do
                local sum, cnt = 0, 0
                for j = math.max(1, i - 5), math.min(n, i + 5) do sum = sum + hs[j] cnt = cnt + 1 end
                table.insert(q, { op = "flat", x = sm[1], z = sm[2], y = sum / cnt, r = g.roadHalf + 1.0 })
            end
        end
        if Landscaping.OPERATION.SMOOTH ~= nil then
            for _ = 1, 3 do
                for i = 1, n, 2 do
                    table.insert(q, { op = "smooth", x = samples[i][1], z = samples[i][2], r = half + 1.5 })
                end
            end
        end
    end

    -- 3. clear the grass on the road (the edge strips get their own grass afterwards)
    for _, sm in ipairs(samplePolyline(pts, 1.2)) do
        table.insert(q, { op = "erase", x = sm[1], z = sm[2], r = g.roadHalf + 0.3 })
    end

    -- 4. wheel tracks painted with the chosen texture (same texture on every track)
    local tex = self:selectedOf("texture")
    if cfg.texture ~= nil then
        local chosen = self:entryByKey(cfg.texture)
        if chosen ~= nil then tex = { chosen } end
    end
    if #tex == 0 and self.data ~= nil then
        for _, word in ipairs({ "gravel", "asphalt", "pave", "concrete", "dirt" }) do
            for _, e in ipairs(self.data.texture) do
                if string.find(string.lower(tostring(e.name)), word, 1, true) then tex = { e } break end
            end
            if #tex > 0 then break end
        end
    end
    if #tex > 0 then
        local samples = samplePolyline(pts, 0.6)
        for _, c in ipairs(g.centers) do
            for side = -1, 1, 2 do
                local d = c + side * g.ro
                for _, sm in ipairs(samples) do
                    local pick = self:pickWeighted(tex)
                    table.insert(q, { op = "tex", x = sm[1] - sm[4] * d, z = sm[2] + sm[3] * d, r = g.rr, layer = pick.layer })
                end
            end
        end
    end

    -- 5. grass in the middle of every lane (between the two wheel tracks) and in the gap between two lanes
    local mid = self:pathMiddleList()
    if #mid > 0 then
        local samples = samplePolyline(pts, 0.8)
        local function strip(d0, d1)
            local w = math.abs(d1 - d0)
            local rows = math.max(1, math.ceil(w / 0.7))
            for k = 0, rows - 1 do
                local d = d0 + (d1 - d0) * (k + 0.5) / rows
                for _, sm in ipairs(samples) do
                    local pick = self:pickWeighted(mid)
                    table.insert(q, { op = "fol", x = sm[1] - sm[4] * d, z = sm[2] + sm[3] * d, r = math.max(0.3, w / rows * 0.5),
                        id = pick.foliagePaint.id, state = pick.foliageState })
                end
            end
        end
        for _, c in ipairs(g.centers) do
            local inner = g.W / 2 - g.tw
            if inner > 0.5 then strip(c - inner + 0.15, c + inner - 0.15) end
        end
        if cfg.lanes == 2 then strip(-g.gap / 2 + 0.15, g.gap / 2 - 0.15) end
    end

    -- 6. edge strips of 1 m on both sides
    local edge = self:pathEdgeList()
    if #edge > 0 then
        local samples = samplePolyline(pts, 0.8)
        for _, sm in ipairs(samples) do
            for side = -1, 1, 2 do
                for _, off in ipairs({ 0.5 }) do
                    local d = g.roadHalf + off
                    local pick = self:pickWeighted(edge)
                    table.insert(q, { op = "fol", x = sm[1] - sm[4] * side * d, z = sm[2] + sm[3] * side * d, r = 0.5,
                        id = pick.foliagePaint.id, state = pick.foliageState })
                end
            end
        end
    end

    p.queue, p.qi = q, 1
    Logging.info('[MultiBrushSelect] path: %d points, %d m, %d steps, %d lane(s) of %.1f m', #pts, math.floor(pathLength(pts)), #q, cfg.lanes, cfg.width)
end

function P:pathStep()
    local p = self.path
    local q = p.queue
    local n, t0 = 0, nowMs()
    while n < 60 and p.qi <= #q do
        if n >= 6 and nowMs() - t0 > 6 then break end
        local it = q[p.qi]
        p.qi = p.qi + 1
        n = n + 1
        local ok, err = pcall(self.zoneItem, self, it)
        if not ok and not p.errLogged then
            p.errLogged = true
            Logging.error('[MultiBrushSelect] path error (%s): %s', tostring(it.op), tostring(err))
        end
    end
    if p.qi > #q then
        self.path = nil
        self.pathDrag = nil
        self.pathNote = "Path built."
    end
end

function P:pathTick()
    local p = self.path
    if p == nil then return end
    if p.queue ~= nil then
        self:pathStep()
        return
    end
    if self.pathDrag ~= nil and not p.drawing and self.cursorX ~= nil then
        local pt = p.pts[self.pathDrag]
        if pt ~= nil and (math.abs(pt[1] - self.cursorX) > 0.05 or math.abs(pt[2] - self.cursorZ) > 0.05) then
            pt[1], pt[2] = self.cursorX, self.cursorZ
            p.lines = nil
        end
    end
end

function P:drawPath(screen)
    local p = self.path
    if p == nil or #p.pts == 0 then return end
    local g = self:pathGeom()
    if p.lines == nil then
        local out = {}
        for i = 1, #p.pts - 1 do sampleSeg(out, p.pts[i], p.pts[i + 1]) end
        local edges, tracks = {}, {}
        if #p.pts >= 2 then
            local samples = samplePolyline(p.pts, 2.5)
            local function offsetLine(dest, d)
                local prev
                for _, s in ipairs(samples) do
                    local pt = { s[1] - s[4] * d, s[2] + s[3] * d }
                    if prev ~= nil then sampleSeg(dest, prev, pt) end
                    prev = pt
                end
            end
            offsetLine(edges, g.half)
            offsetLine(edges, -g.half)
            for _, c in ipairs(g.centers) do
                offsetLine(tracks, c + g.ro)
                offsetLine(tracks, c - g.ro)
            end
        end
        p.lines, p.edges, p.tracks = out, edges, tracks
    end
    for _, seg in ipairs(p.lines) do
        local a, b = seg[1], seg[2]
        drawDebugLine(a[1], a[2], a[3], 0.65, 1.0, 0.1, b[1], b[2], b[3], 0.65, 1.0, 0.1, false)
    end
    for _, seg in ipairs(p.edges or {}) do
        local a, b = seg[1], seg[2]
        drawDebugLine(a[1], a[2], a[3], 0.9, 0.9, 0.9, b[1], b[2], b[3], 0.9, 0.9, 0.9, false)
    end
    for _, seg in ipairs(p.tracks or {}) do
        local a, b = seg[1], seg[2]
        drawDebugLine(a[1], a[2], a[3], 0.3, 0.8, 1.0, b[1], b[2], b[3], 0.3, 0.8, 1.0, false)
    end
    if p.drawing and self.cursorX ~= nil and #p.pts > 0 then
        local out = {}
        sampleSeg(out, p.pts[#p.pts], { self.cursorX, self.cursorZ })
        for _, seg in ipairs(out) do
            local a, b = seg[1], seg[2]
            drawDebugLine(a[1], a[2], a[3], 1, 1, 1, b[1], b[2], b[3], 1, 1, 1, false)
        end
    end
    local hover = (self.cursorX ~= nil and not self:overPanel(self.mouseX, self.mouseY)) and nearestPt(p.pts, self.cursorX, self.cursorZ, ZONE_HANDLE_DIST) or nil
    for i, pt in ipairs(p.pts) do
        local h = getTerrainHeightAtWorldPos(g_terrainNode, pt[1], 0, pt[2])
        local cr, cg, cb = 1.0, 0.85, 0.0
        if self.pathDrag == i then cr, cg, cb = 1.0, 0.2, 0.0
        elseif hover == i then cr, cg, cb = 1, 1, 1
        elseif p.drawing and i == #p.pts and #p.pts >= 2 then cr, cg, cb = 0.2, 1.0, 1.0 end
        drawDebugLine(pt[1], h, pt[2], cr, cg, cb, pt[1], h + 3.0, pt[2], cr, cg, cb, false)
        drawDebugLine(pt[1] - 0.7, h + 3.0, pt[2], cr, cg, cb, pt[1] + 0.7, h + 3.0, pt[2], cr, cg, cb, false)
        drawDebugLine(pt[1], h + 3.0, pt[2] - 0.7, cr, cg, cb, pt[1], h + 3.0, pt[2] + 0.7, cr, cg, cb, false)
    end
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

local function stepperRow(self, x0, w, yy, label, valueText, onMinus, onPlus)
    txt(x0, yy + 0.007, TEXT, label, 0.85, 0.87, 0.92)
    local bx = x0 + w * 0.42
    button(self, bx, yy, 0.022, 0.025, "-", false, onMinus)
    txt(bx + 0.022 + (w * 0.58 - 0.044) / 2, yy + 0.007, TEXT, valueText, GR, GG, GB, true, RenderText.ALIGN_CENTER)
    button(self, x0 + w - 0.022, yy, 0.022, 0.025, "+", false, onPlus)
end

local function infoLines(x, y, lines, size)
    size = size or TEXT * 0.85
    for i, l in ipairs(lines) do
        txt(x, y - (i - 1) * size * 1.25, size, l, 0.82, 0.84, 0.9)
    end
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
    local TABS = { "texture", "foliage", "tree" }
    local tw = w / #TABS
    for i, kind in ipairs(TABS) do
        local count = #self:selectedOf(kind)
        local label = KIND_LABEL[kind] .. (count > 0 and (" (" .. count .. ")") or "")
        button(self, x0 + (i - 1) * tw, y, tw - 0.002, 0.027, fit(label, TEXT, tw - 0.01), self.kind == kind, function() self.kind = kind end)
    end
    y = y - 0.032
    local TABS2 = { { "mix", "Mix" }, { "rules", "Rules" }, { "zone", (self.zone ~= nil or self.path ~= nil) and "Draw *" or "Draw" }, { "preset", "Presets" } }
    tw = w / #TABS2
    for i, t in ipairs(TABS2) do
        local kind, label = t[1], t[2]
        button(self, x0 + (i - 1) * tw, y, tw - 0.002, 0.027, fit(label, TEXT, tw - 0.01), self.kind == kind, function()
            self.kind = kind
            if kind == "preset" and self.presets == nil then self:loadPresets() end
        end)
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
    elseif self.kind == "mix" then
        -- share of every selected item (per kind the shares add up to 100%)
        self.listRect = { x = px, y = listBottom, w = pw, h = y - listBottom, rows = 1, max = 0 }
        if self.mixRowsVersion ~= self.selVersion then
            local rows = {}
            for _, kind in ipairs(KINDS) do
                local list = self:selectedOf(kind)
                if #list > 0 then
                    table.insert(rows, { header = KIND_LABEL[kind] })
                    local sorted = {}
                    for _, e in ipairs(list) do table.insert(sorted, e) end
                    table.sort(sorted, function(a, b) return tostring(a.name) < tostring(b.name) end)
                    for _, e in ipairs(sorted) do table.insert(rows, { e = e }) end
                end
            end
            self.mixRows, self.mixRowsVersion = rows, self.selVersion
        end
        local rows = self.mixRows
        local rowsVisible = math.max(1, math.floor((y - listBottom) / ROW_H))
        local maxScroll = math.max(0, #rows - rowsVisible)
        local scroll = math.max(0, math.min(self.scroll.mix or 0, maxScroll))
        self.scroll.mix = scroll
        scrollbar(y, rowsVisible, #rows, scroll, maxScroll, "mix")
        if #rows == 0 then
            txt(x0 + 0.004, y - 0.03, TEXT, "Select items first.", 0.82, 0.84, 0.9)
            infoLines(x0 + 0.004, y - 0.055, { "Here you set the share of each", "item, e.g. 60% grass, 30% soil,", "10% gravel (per kind)." })
        end
        for i = 1, rowsVisible do
            local row = rows[scroll + i]
            if row == nil then break end
            local ry = y - i * ROW_H
            local rw = w - sbW - 0.005
            if row.header ~= nil then
                txt(x0 + 0.004, ry + ROW_H * 0.3, TEXT, row.header, GR, GG, GB, true)
                drawFilledRect(x0, ry + 0.001, rw, 0.0012, 0, 0, 0, 1)
            else
                local e = row.e
                local single = #self:selectedOf(e.kind) <= 1
                local ctrlW = 0.076
                drawFilledRect(x0, ry, rw, ROW_H - 0.002, 0.035, 0.04, 0.06, 1)
                frame(x0, ry, rw, ROW_H - 0.002, 0.0012, 0, 0, 0, 1)
                txt(x0 + 0.005, ry + ROW_H * 0.3, TEXT * 0.92, fit(e.name, TEXT * 0.92, rw - ctrlW - 0.012), GR, GG, GB, true)
                local bx = x0 + rw - ctrlW
                if not single then
                    button(self, bx, ry + 0.002, 0.02, ROW_H - 0.006, "-", false, function() self:setShare(e, self:share(e) - 5) end)
                    button(self, bx + ctrlW - 0.022, ry + 0.002, 0.02, ROW_H - 0.006, "+", false, function() self:setShare(e, self:share(e) + 5) end)
                end
                local share = single and 100 or self:share(e)
                txt(bx + ctrlW / 2, ry + ROW_H * 0.3, TEXT * 0.9, string.format("%d%%", math.floor(share + 0.5)), 1, 1, 1, true, RenderText.ALIGN_CENTER)
            end
        end
    elseif self.kind == "rules" then
        self.listRect = { x = px, y = listBottom, w = pw, h = y - listBottom, rows = 1, max = 0 }
        local R = self.rules
        local rowH = 0.032
        local yy = y - 0.03
        local fast = isShift()
        local cy = self.cursorY
        stepperRow(self, x0, w, yy, "Tree gap", string.format("%.1f m", R.gap),
            function() R.gap = math.max(0, R.gap - 0.5) self:zoneTouch() end,
            function() R.gap = math.min(10, R.gap + 0.5) self:zoneTouch() end)
        yy = yy - rowH
        stepperRow(self, x0, w, yy, "Tree age", AGE_LABEL[R.age],
            function() R.age = R.age - 1 if R.age < 1 then R.age = #AGE_LABEL end self:zoneTouch() end,
            function() R.age = R.age + 1 if R.age > #AGE_LABEL then R.age = 1 end self:zoneTouch() end)
        yy = yy - rowH
        stepperRow(self, x0, w, yy, "Max slope", R.slope >= 90 and "off" or (R.slope .. " deg"),
            function() R.slope = math.max(5, R.slope - 5) self:zoneTouch() end,
            function() R.slope = math.min(90, R.slope + 5) self:zoneTouch() end)
        yy = yy - rowH
        local function snap(v) return math.floor(v / 5 + 0.5) * 5 end
        stepperRow(self, x0, w, yy, "Min altitude", R.altMin <= ALT_OFF_MIN and "off" or (R.altMin .. " m"),
            function()
                R.altMin = math.max(ALT_OFF_MIN, R.altMin - (fast and 25 or 5))
                self:zoneTouch()
            end,
            function()
                if R.altMin <= ALT_OFF_MIN and cy ~= nil then R.altMin = snap(cy) else R.altMin = math.min(ALT_OFF_MAX - 5, R.altMin + (fast and 25 or 5)) end
                self:zoneTouch()
            end)
        yy = yy - rowH
        stepperRow(self, x0, w, yy, "Max altitude", R.altMax >= ALT_OFF_MAX and "off" or (R.altMax .. " m"),
            function()
                if R.altMax >= ALT_OFF_MAX and cy ~= nil then R.altMax = snap(cy) else R.altMax = math.max(ALT_OFF_MIN + 5, R.altMax - (fast and 25 or 5)) end
                self:zoneTouch()
            end,
            function()
                R.altMax = math.min(ALT_OFF_MAX, R.altMax + (fast and 25 or 5))
                self:zoneTouch()
            end)
        yy = yy - rowH - 0.004
        local bw3 = w / 3
        button(self, x0, yy, bw3 - 0.002, 0.026, "Fields", R.field, function() R.field = not R.field self:zoneTouch() end)
        button(self, x0 + bw3, yy, bw3 - 0.002, 0.026, "Roads", R.road, function() R.road = not R.road self:zoneTouch() end)
        button(self, x0 + bw3 * 2, yy, bw3 - 0.002, 0.026, "Buildings", R.building, function() R.building = not R.building self:zoneTouch() end)
        yy = yy - 0.022
        txt(x0, yy, TEXT * 0.85, "Active buttons: trees, grass and textures", 0.82, 0.84, 0.9)
        txt(x0, yy - 0.0155, TEXT * 0.85, "stay away from them (brush and zone).", 0.82, 0.84, 0.9)
        yy = yy - 0.042
        if cy ~= nil and self.cursorX ~= nil then
            txt(x0, yy, TEXT * 0.9, string.format("Cursor: %d m altitude, %d deg slope", math.floor(cy + 0.5), math.floor(P.slopeDeg(self.cursorX, self.cursorZ) + 0.5)), GR, GG, GB, true)
            txt(x0, yy - 0.0155, TEXT * 0.8, "Altitude + (min) / - (max) start at the cursor.", 0.7, 0.72, 0.78)
        end
    elseif self.kind == "zone" then
        self.listRect = { x = px, y = listBottom, w = pw, h = y - listBottom, rows = 1, max = 0 }
        local z = self.zone
        local half = w / 2
        button(self, x0, y - 0.03, half - 0.002, 0.026, "Zone", self.drawMode ~= "path", function() self.drawMode = "zone" end)
        button(self, x0 + half, y - 0.03, half - 0.002, 0.026, "Path", self.drawMode == "path", function() self.drawMode = "path" end)
        local yy = y - 0.064
        if self.drawMode == "path" and self.pathPicking then
            -- pick the path surface texture
            local cfg = self.pathCfg
            button(self, x0, yy, half - 0.002, 0.026, "Use selected", cfg.texture == nil, function() cfg.texture = nil self.pathPicking = false end)
            button(self, x0 + half, yy, half - 0.002, 0.026, "Back", false, function() self.pathPicking = false end)
            yy = yy - 0.03
            local listTop = yy
            local list = self.data.texture
            local rowsVisible = math.max(1, math.floor((listTop - listBottom) / ROW_H))
            local maxScroll = math.max(0, #list - rowsVisible)
            local scroll = math.max(0, math.min(self.scroll.pathtex or 0, maxScroll))
            self.scroll.pathtex = scroll
            scrollbar(listTop, rowsVisible, #list, scroll, maxScroll, "pathtex")
            local iconH = ROW_H * 0.86
            local iconW = iconH / aspect
            local rw = w - sbW - 0.005
            for i = 1, rowsVisible do
                local e = list[scroll + i]
                if e == nil then break end
                local ry = listTop - i * ROW_H
                local sel = cfg.texture == e.key
                local hv = self.mouseX >= x0 and self.mouseX <= x0 + rw and self.mouseY >= ry and self.mouseY <= ry + ROW_H
                if sel then
                    drawFilledRect(x0, ry, rw, ROW_H - 0.002, GR, GG, GB, 1)
                else
                    drawFilledRect(x0, ry, rw, ROW_H - 0.002, hv and 0.055 or 0.035, hv and 0.062 or 0.04, hv and 0.09 or 0.06, 1)
                end
                frame(x0, ry, rw, ROW_H - 0.002, 0.0012, 0, 0, 0, 1)
                self:drawIcon(e, x0 + 0.002, ry + 0.002, iconW, iconH)
                local nx = x0 + iconW + 0.006
                txt(nx, ry + ROW_H * 0.3, TEXT * 0.92, fit(e.name, TEXT * 0.92, x0 + rw - 0.003 - nx), sel and 0.06 or GR, sel and 0.08 or GG, sel and 0.02 or GB, true)
                self:addHit(x0, ry, rw, ROW_H - 0.002, function() cfg.texture = e.key self.pathPicking = false end)
            end
        elseif self.drawMode == "path" then
            local p = self.path
            local cfg = self.pathCfg
            local building = p ~= nil and p.queue ~= nil
            local function settings()
                stepperRow(self, x0, w, yy, "Width", string.format("%.1f m", cfg.width),
                    function() cfg.width = math.max(3, cfg.width - 0.5) self:pathDirty() end,
                    function() cfg.width = math.min(10, cfg.width + 0.5) self:pathDirty() end)
                yy = yy - 0.03
                stepperRow(self, x0, w, yy, "Lanes", LANE_LABEL[cfg.lanes],
                    function() cfg.lanes = cfg.lanes == 1 and 2 or 1 self:pathDirty() end,
                    function() cfg.lanes = cfg.lanes == 1 and 2 or 1 self:pathDirty() end)
                yy = yy - 0.03
                stepperRow(self, x0, w, yy, "Middle", MID_LABEL[cfg.middle],
                    function() cfg.middle = cfg.middle - 1 if cfg.middle < 1 then cfg.middle = #MID_LABEL end end,
                    function() cfg.middle = cfg.middle + 1 if cfg.middle > #MID_LABEL then cfg.middle = 1 end end)
                yy = yy - 0.03
                stepperRow(self, x0, w, yy, "Edge", EDGE_LABEL[cfg.edge],
                    function() cfg.edge = cfg.edge - 1 if cfg.edge < 1 then cfg.edge = #EDGE_LABEL end end,
                    function() cfg.edge = cfg.edge + 1 if cfg.edge > #EDGE_LABEL then cfg.edge = 1 end end)
                yy = yy - 0.031
                button(self, x0, yy, w, 0.025, cfg.level and "Level terrain: ON" or "Level terrain: OFF", cfg.level, function() cfg.level = not cfg.level end)
                yy = yy - 0.03
                local tname = "selected textures"
                if cfg.texture ~= nil then
                    local te = self:entryByKey(cfg.texture)
                    if te ~= nil then tname = te.name end
                end
                button(self, x0, yy, w, 0.025, fit("Texture: " .. tname, TEXT, w - 0.012), cfg.texture ~= nil, function() self.pathPicking = true end)
                yy = yy - 0.028
                if cfg.texture == nil and #self:selectedOf("texture") == 0 then
                    txt(x0, yy + 0.006, TEXT * 0.8, "Press Texture to pick asphalt, gravel, concrete...", 0.82, 0.84, 0.9)
                end
            end
            if p == nil then
                infoLines(x0 + 0.002, yy + 0.006, {
                    "1 m edge, wheel track, grass middle, track.",
                    "them. Draw the line with the knife, click",
                    "the last point again to finish.",
                })
                yy = yy - 0.05
                button(self, x0, yy, w, 0.027, "Draw path (knife)", true, function() self:pathStartDraw() end)
                yy = yy - 0.034
                if self.pathNote ~= nil then
                    txt(x0, yy + 0.008, TEXT * 0.95, self.pathNote, GR, GG, GB, true)
                    yy = yy - 0.02
                end
                settings()
            elseif building then
                txt(x0, yy, TEXT, string.format("Building %d%%", math.floor((p.qi - 1) / math.max(1, #p.queue) * 100)), GR, GG, GB, true)
                yy = yy - 0.03
            elseif p.drawing then
                txt(x0, yy, TEXT, string.format("Drawing: %d points", #p.pts), GR, GG, GB, true)
                infoLines(x0 + 0.002, yy - 0.02, {
                    "Click on the terrain to add points.",
                    "Click the last point again to finish.",
                    "Right-click removes the last point.",
                })
                yy = yy - 0.075
                button(self, x0, yy, half - 0.002, 0.026, "Finish line", #p.pts >= 2, function() self:pathFinishDraw() end)
                button(self, x0 + half, yy, half - 0.002, 0.026, "Cancel", false, function() self.path = nil end)
                yy = yy - 0.034
            else
                txt(x0, yy, TEXT, string.format("%d points | %d m", #p.pts, math.floor(pathLength(p.pts) + 0.5)), GR, GG, GB, true)
                yy = yy - 0.032
                button(self, x0, yy, half - 0.002, 0.028, "Build path", true, function() self:pathBuild() end)
                button(self, x0 + half, yy, half - 0.002, 0.028, "Cancel", false, function() self.path = nil end)
                yy = yy - 0.034
                settings()
                txt(x0, yy + 0.004, TEXT * 0.8, "Drag points | Shift+click line adds | RMB deletes", 0.7, 0.72, 0.78)
            end
        elseif z == nil then
            infoLines(x0 + 0.002, yy + 0.006, {
                "Fill an area with the selection.",
                "Draw it with the knife: click the",
                "start, click along the outline,",
                "click the start again to close.",
            })
            yy = yy - 0.07
            button(self, x0, yy, w, 0.028, "Draw zone (knife)", true, function() self:zoneStartDraw() end)
            yy = yy - 0.034
            button(self, x0, yy, w, 0.026, "Square zone at cursor", false, function() self:zoneNewSquare() end)
            yy = yy - 0.034
            infoLines(x0 + 0.002, yy, { "Then drag the points. Trees, grass and", "textures update live inside the zone." })
        elseif z.drawing then
            txt(x0, yy, TEXT, string.format("Drawing: %d points", #z.pts), GR, GG, GB, true)
            infoLines(x0 + 0.002, yy - 0.02, {
                "Click on the terrain to add points.",
                "Click the first point (cyan) to close.",
                "Right-click removes the last point.",
            })
            yy = yy - 0.075
            button(self, x0, yy, half - 0.002, 0.026, "Close zone", #z.pts >= 3, function() self:zoneClose() end)
            button(self, x0 + half, yy, half - 0.002, 0.026, "Cancel", false, function() self.zone = nil end)
        else
            local area = 0
            do
                local a, j = 0, #z.pts
                for i = 1, #z.pts do
                    a = a + (z.pts[j][1] + z.pts[i][1]) * (z.pts[j][2] - z.pts[i][2])
                    j = i
                end
                area = math.abs(a) / 2
            end
            txt(x0, yy, TEXT, fit(string.format("%d points | %d m2", #z.pts, math.floor(area + 0.5)), TEXT, w), GR, GG, GB, true)
            txt(x0, yy - 0.0175, TEXT * 0.9, "Status: " .. self:zoneStatus(), 0.85, 0.87, 0.92)
            yy = yy - 0.052
            button(self, x0, yy, half - 0.002, 0.026, "Add point", false, function() self:zoneAddPoint() end)
            button(self, x0 + half, yy, half - 0.002, 0.026, "Remove point", false, function() self:zoneRemovePoint() end)
            yy = yy - 0.031
            button(self, x0, yy, half - 0.002, 0.026, z.live and "Live: ON" or "Live: OFF", z.live, function() z.live = not z.live if z.live then self:zoneTouch() end end)
            button(self, x0 + half, yy, half - 0.002, 0.026, "Update now", false, function() if z.queue == nil then self:zoneStart() end end)
            yy = yy - 0.031
            button(self, x0, yy, half - 0.002, 0.026, "Remove content", false, function() self:zoneRemoveContent() end)
            button(self, x0 + half, yy, half - 0.002, 0.026, "Finish (keep)", false, function() self:zoneFinish() end)
            yy = yy - 0.034
            infoLines(x0 + 0.002, yy, {
                "Drag a yellow point to reshape.",
                "Shift+click an edge adds a point.",
                "Right-click a point deletes it.",
                "Changing items, mix or rules updates",
                "the zone. Moved-out textures stay.",
            })
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
        function() self.density = math.max(10, self.density - 10) self:zoneTouch() end,
        function() self.density = math.min(300, self.density + 10) self:zoneTouch() end)
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
    if screen == nil or screen.cursor == nil or self.listRect == nil or self.kind == "zone" then return end
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
        elseif self.kind == "zone" then
            if self.drawMode == "path" then self:pathMouseDown() else self:zoneMouseDown() end   -- knife / point dragging instead of painting
        else
            self.lmb = true
            self.lastX = nil
            self.lastTreeX = nil
            self.treeMem = {}
        end
    elseif isDown and button == (Input.MOUSE_BUTTON_RIGHT or 3) and not self:overPanel(posX, posY) then
        if self.kind == "zone" then
            if self.drawMode == "path" then self:pathRightDown() else self:zoneRightDown() end
        else
            self.rmb = true
            self.lastEraseX = nil
        end
    elseif isUp and button == (Input.MOUSE_BUTTON_RIGHT or 3) then
        self.rmb = false
        self.lastEraseX = nil
    elseif isUp and button == left then
        self.zoneDrag = nil
        self.pathDrag = nil
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
            local skey = (self.kind == "zone" and self.drawMode == "path" and self.pathPicking) and "pathtex" or self.kind
            self.scroll[skey] = math.max(0, (self.scroll[skey] or 0) + step)
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
        -- cursor position on the terrain (zone knife, point dragging, rules info)
        self.cursorX, self.cursorY, self.cursorZ = nil, nil, nil
        if screen.cursor ~= nil then
            local cx, cy, cz = screen.cursor:getHitTerrainPosition()
            if cx ~= nil and not self:overPanel(self.mouseX, self.mouseY) then
                self.cursorX, self.cursorY, self.cursorZ = cx, cy, cz
            end
        end
        self:zoneTick()
        self:pathTick()
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
    self:drawZone(screen)
    self:drawPath(screen)
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
